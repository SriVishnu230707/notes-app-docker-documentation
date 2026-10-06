"""HTTP contract and failure checks with PostgreSQL/Redis boundaries replaced."""
import unittest
from contextlib import contextmanager
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch
from uuid import uuid4

import psycopg
from fastapi.testclient import TestClient
from redis.exceptions import ConnectionError as RedisConnectionError

from app.main import create_app


class NotesApiTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.conn = MagicMock()
        self.commit_error = None
        self.activity = MagicMock()
        self.activity.get.return_value = b"5"
        self.activity.incr.side_effect = lambda key: self.events.append("counter")
        now = datetime.now(timezone.utc)
        self.note = dict(id=uuid4(), title="Test note", content="Body", created_at=now, updated_at=now)
        self.path = f"/api/notes/{self.note['id']}"
        self.mocks = {}
        for name in ("create_note", "list_notes", "get_note", "update_note", "delete_note"):
            patcher = patch(f"app.main.repository.{name}")
            self.mocks[name] = patcher.start()
            self.addCleanup(patcher.stop)
        self.mocks["list_notes"].return_value = [self.note]
        for name in ("create_note", "get_note", "update_note", "delete_note"):
            self.mocks[name].return_value = self.note
        self.client = self.enterContext(TestClient(create_app(self.connect, self.activity)))

    @contextmanager
    def connect(self):
        try:
            yield self.conn
            if self.commit_error:
                raise self.commit_error
            self.events.append("commit")
        except Exception:
            self.events.append("rollback")
            raise

    def test_create_trims_title_and_counts_after_commit(self):
        response = self.client.post("/api/notes", json={"title": "  Test note  "})
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.headers["location"], self.path)
        self.assertEqual(response.json()["id"], str(self.note["id"]))
        self.mocks["create_note"].assert_called_once_with(self.conn, "Test note", "")
        self.assertEqual(self.events, ["commit", "counter"])

    def test_read_routes_do_not_increment_counter(self):
        listing = self.client.get("/api/notes")
        self.assertEqual(listing.status_code, 200)
        self.assertEqual(len(listing.json()), 1)
        self.assertEqual(self.client.get(self.path).status_code, 200)
        self.mocks["get_note"].assert_called_once_with(self.conn, self.note["id"])
        self.activity.incr.assert_not_called()

    def test_update_and_delete(self):
        response = self.client.put(self.path, json={"title": "Edited", "content": "Updated"})
        self.assertEqual(response.status_code, 200)
        self.mocks["update_note"].assert_called_once_with(self.conn, self.note["id"], "Edited", "Updated")
        deleted = self.client.delete(self.path)
        self.assertEqual(deleted.status_code, 204)
        self.assertEqual(deleted.content, b"")
        self.assertEqual(self.activity.incr.call_count, 2)

    def test_missing_notes_return_404_without_activity(self):
        for name in ("get_note", "update_note", "delete_note"):
            self.mocks[name].return_value = None
        responses = [self.client.get(self.path), self.client.put(self.path, json={"title": "Missing"}), self.client.delete(self.path)]
        for response in responses:
            self.assertEqual(response.status_code, 404)
            self.assertEqual(response.json()["detail"], "Note not found")
        self.activity.incr.assert_not_called()

    def test_invalid_input_never_reaches_database(self):
        cases = [{}, {"title": ""}, {"title": " \t\n"}, {"title": "x" * 201},
                 {"title": None}, {"title": 123}, {"title": "OK", "content": None},
                 {"title": "OK", "content": "x" * 50001}, {"title": "OK", "unknown": True}]
        for payload in cases:
            with self.subTest(payload_keys=list(payload)):
                self.assertEqual(self.client.post("/api/notes", json=payload).status_code, 422)
                self.assertEqual(self.client.put(self.path, json=payload).status_code, 422)
        self.assertEqual(self.events, [])
        self.mocks["create_note"].assert_not_called()
        self.mocks["update_note"].assert_not_called()

    def test_malformed_id_and_json(self):
        self.assertEqual(self.client.get("/api/notes/not-a-uuid").status_code, 422)
        self.assertEqual(self.client.post("/api/notes", content="{", headers={"Content-Type": "application/json"}).status_code, 422)
        self.assertEqual(self.events, [])

    def test_empty_list(self):
        self.mocks["list_notes"].return_value = []
        self.assertEqual(self.client.get("/api/notes").json(), [])

    def test_commit_failure_returns_503_without_counter(self):
        self.commit_error = psycopg.OperationalError("private connection details")
        response = self.client.post("/api/notes", json={"title": "Test note"})
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json(), {"detail": "Database is unavailable"})
        self.assertEqual(self.events, ["rollback"])
        self.activity.incr.assert_not_called()

    def test_database_failure_does_not_disclose_sql(self):
        self.mocks["list_notes"].side_effect = psycopg.ProgrammingError("private SQL")
        response = self.client.get("/api/notes")
        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.json(), {"detail": "Database operation failed"})

    def test_redis_failure_preserves_successful_writes(self):
        self.activity.incr.side_effect = RedisConnectionError("offline")
        self.assertEqual(self.client.post("/api/notes", json={"title": "Test note"}).status_code, 201)
        self.assertEqual(self.client.put(self.path, json={"title": "Test note"}).status_code, 200)
        self.assertEqual(self.client.delete(self.path).status_code, 204)
        self.assertEqual(self.events, ["commit"] * 3)

    def test_stats_handles_missing_invalid_or_unavailable_counter(self):
        self.assertEqual(self.client.get("/api/stats").json(), {"writes": 5, "redis_available": True})
        self.activity.get.return_value = None
        self.assertEqual(self.client.get("/api/stats").json()["writes"], 0)
        for invalid in (b"invalid", b"-1"):
            self.activity.get.return_value = invalid
            self.assertEqual(self.client.get("/api/stats").json(), {"writes": None, "redis_available": False})
        self.activity.get.side_effect = RedisConnectionError("offline")
        self.assertFalse(self.client.get("/api/stats").json()["redis_available"])

    def test_health_requires_schema_and_redis(self):
        self.assertEqual(self.client.get("/api/health").status_code, 200)
        self.conn.execute.assert_called_with("SELECT id FROM notes LIMIT 0")
        self.activity.ping.side_effect = RedisConnectionError("offline")
        self.assertEqual(self.client.get("/api/health").status_code, 503)
        self.activity.ping.side_effect = None
        self.conn.execute.side_effect = psycopg.ProgrammingError("notes missing")
        self.assertEqual(self.client.get("/api/health").status_code, 503)

    def test_openapi_and_docs(self):
        self.assertEqual(self.client.get("/docs").status_code, 200)
        spec = self.client.get("/openapi.json").json()
        self.assertEqual(spec["info"]["title"], "Notes API")
        self.assertIn("post", spec["paths"]["/api/notes"])
        self.assertIn("get", spec["paths"]["/api/notes/{note_id}"])


if __name__ == "__main__":
    unittest.main()
