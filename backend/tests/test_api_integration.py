"""Opt-in HTTP tests using real PostgreSQL and Redis after migrations."""
import os
import unittest

from fastapi.testclient import TestClient

from app.main import create_app


@unittest.skipUnless(os.environ.get("RUN_API_INTEGRATION") == "1", "Enable with RUN_API_INTEGRATION=1")
class LiveNotesApiTests(unittest.TestCase):
    def test_persisted_crud_and_activity(self):
        with TestClient(create_app(), base_url="http://localhost") as client:
            self.assertEqual(client.get("/api/health").status_code, 200)
            before = client.get("/api/stats").json()["writes"]
            response = client.post("/api/notes", json={"title": "API integration check", "content": "Initial"})
            self.assertEqual(response.status_code, 201)
            path = response.headers["location"]
            try:
                self.assertEqual(client.get(path).json()["content"], "Initial")
                updated = client.put(path, json={"title": "Edited", "content": "Persisted"})
                self.assertEqual(updated.status_code, 200)
                # A new application/connection must observe the committed update.
                with TestClient(create_app(), base_url="http://localhost") as second:
                    self.assertEqual(second.get(path).json()["content"], "Persisted")
                self.assertEqual(client.delete(path).status_code, 204)
                self.assertEqual(client.get(path).status_code, 404)
                self.assertGreaterEqual(client.get("/api/stats").json()["writes"], before + 3)
            finally:
                client.delete(path)


if __name__ == "__main__":
    unittest.main()
