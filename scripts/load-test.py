"""Bounded synthetic load against the Phase 8 disposable Compose project."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
import re
import statistics
import threading
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def run(concurrency, iterations, max_p95_ms):
    # Fixed internal destination avoids accidentally load-testing the user's app.
    base = "http://web"
    samples = []
    failures = []
    counts = {}
    lock = threading.Lock()

    def call(method, path, expected, body=None, version=None):
        headers = {"Host": "localhost"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if version is not None:
            headers["If-Match"] = f'"{version}"'
        request = Request(base + path, method=method, headers=headers,
                          data=json.dumps(body).encode() if body is not None else None)
        started = time.perf_counter()
        try:
            try:
                response = urlopen(request, timeout=15)
            except HTTPError as error:
                response = error
            with response:
                status = response.code
                raw = response.read()
            if status != expected:
                raise AssertionError(f"{method} returned {status}; expected {expected}")
            return json.loads(raw) if raw else None
        finally:
            elapsed = (time.perf_counter() - started) * 1000
            with lock:
                samples.append(elapsed)
                key = f"{method} expected {expected}"
                counts[key] = counts.get(key, 0) + 1

    def worker(worker_id):
        for iteration in range(iterations):
            try:
                title = f"Load check {worker_id}:{iteration}"
                note = call("POST", "/api/notes", 201, {"title": title, "content": "Synthetic load data"})
                path = f"/api/notes/{note['id']}"
                read = call("GET", path, 200)
                if read != note:
                    raise AssertionError("Created note did not round-trip")
                updated = call("PUT", path, 200, {"title": title, "content": "Updated under concurrent load"}, note["updated_at"])
                if updated["content"] != "Updated under concurrent load" or updated["updated_at"] == note["updated_at"]:
                    raise AssertionError("Update content/version did not change")
                call("DELETE", path, 412, version=note["updated_at"])
                if call("GET", path, 200) != updated:
                    raise AssertionError("Stale delete changed the note")
                call("DELETE", path, 204, version=updated["updated_at"])
                call("GET", path, 404)
            except Exception as error:
                with lock:
                    failures.append(f"worker {worker_id}, iteration {iteration}: {type(error).__name__}: {error}")
                return

    started = time.perf_counter()
    try:
        if os.environ.get("PGDATABASE") != "notes_load" or not re.fullmatch(
                r"notes-load-[a-f0-9]{12}", os.environ.get("NOTES_LOAD_PROJECT", "")):
            raise AssertionError("Load generator requires a marked disposable notes_load project")
        if call("GET", "/api/notes", 200):
            raise AssertionError("Load test requires an empty disposable database")
        before = call("GET", "/api/stats", 200)
        if not before["redis_available"]:
            raise AssertionError("Redis unavailable before load")
        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            list(pool.map(worker, range(concurrency)))
        if call("GET", "/api/notes", 200):
            raise AssertionError("Synthetic notes remained after load")
        after = call("GET", "/api/stats", 200)
        if not after["redis_available"] or after["writes"] - before["writes"] != concurrency * iterations * 3:
            raise AssertionError("Redis count differs from committed create/update/delete operations")
        health = call("GET", "/api/health", 200)
        if health != {"status": "ok", "postgres": "ok", "redis": "ok"}:
            raise AssertionError("Dependencies unhealthy after load")
    except Exception as error:
        failures.append(f"verification: {type(error).__name__}: {error}")
    duration = time.perf_counter() - started
    ordered = sorted(samples)
    p95 = ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)] if ordered else 0
    if p95 > max_p95_ms:
        failures.append(f"p95 {p95:.1f} ms exceeded {max_p95_ms:.1f} ms")
    report = {
        "passed": not failures, "concurrency": concurrency, "iterations_per_worker": iterations,
        "requests": len(samples), "duration_seconds": round(duration, 3),
        "requests_per_second": round(len(samples) / duration, 2),
        "median_ms": round(statistics.median(samples), 2) if samples else 0,
        "p95_ms": round(p95, 2), "max_ms": round(max(samples), 2) if samples else 0,
        "max_p95_ms": max_p95_ms, "operations": counts, "failures": failures,
    }
    print(json.dumps(report))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--concurrency", type=int, choices=range(1, 17), default=4)
    parser.add_argument("--iterations", type=int, choices=range(1, 101), default=25)
    parser.add_argument("--max-p95-ms", type=float, default=2000)
    args = parser.parse_args()
    if not math.isfinite(args.max_p95_ms) or args.max_p95_ms <= 0:
        parser.error("max-p95-ms must be a finite positive number")
    raise SystemExit(run(args.concurrency, args.iterations, args.max_p95_ms))
