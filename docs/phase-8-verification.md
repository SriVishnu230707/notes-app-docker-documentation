# Phase 8 verification

Verified locally on 2026-10-08 (Asia/Calcutta) with Docker Desktop Linux
containers and PowerShell 7.

| Check | Result |
| --- | --- |
| Default concurrent workload | 705 requests, four workers, 100 complete note lifecycles |
| Data and expected HTTP statuses | Passed, including 100 stale deletes rejected with 412 |
| Redis activity consistency | Exactly 300 committed create/update/delete mutations |
| Request latency | p95 270.16 ms; median 108.20 ms; maximum 382.83 ms |
| Total workload duration | 23.003 seconds, approximately 30.65 requests/second |
| Engine CPU, memory, PID and log rotation settings | Verified for all five containers |
| Deliberately failing 1 ms p95 gate | Rejected, with report retained and temporary resources removed |
| Status command against normal stack | Four healthy services and successful migration |
| Status command against absent project | Raised failure as expected |
| Resource profile applied to normal stack | Existing note snapshot and Redis activity preserved |
| Backend tests under resource limits | 31 passed |
| Frontend request helper tests | 9 passed |
| Live Docker browser tests | 3 passed |
| Docker script failure-path checks | 11 passed |
| PowerShell/Python syntax, Git whitespace and workflow lint | Passed |

Measured latency reflects this laptop and the API-container load generator,
not a promised production service level. Resource stats are sampled after the
workload. The report contains only synthetic data and lives in ignored
`test-results/notes-load-065c9782f82a/report.json`.

Before recreating the normal stack, a PostgreSQL dump/checksum pair was saved
under ignored `backups/`. The regular project retains its existing PostgreSQL
and Redis volumes. Disposable load and regression projects were removed.
GitHub repeats the full application tests, recovery drill and load gate, then
packages and verifies the final release; results live on its Actions run.
