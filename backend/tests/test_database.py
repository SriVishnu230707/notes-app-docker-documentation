"""Integration checks against migrated PostgreSQL; each test rolls back its writes."""
import unittest
from uuid import UUID, uuid4

from psycopg.errors import CheckViolation, NotNullViolation, StringDataRightTruncation

from app.database import database
from app import repository


class NotesDatabaseTests(unittest.TestCase):
    def setUp(self):
        self.conn = database()

    def tearDown(self):
        self.conn.rollback()
        self.conn.close()

    def test_revision_applied(self):
        revision = self.conn.execute("SELECT version_num FROM alembic_version").fetchone()
        self.assertEqual(revision["version_num"], "0002_monotonic_note_versions")

    def test_crud_and_defaults(self):
        note = repository.create_note(self.conn, "Database check")
        self.assertIsInstance(note["id"], UUID)
        self.assertEqual(note["content"], "")
        self.assertIsNotNone(note["created_at"].tzinfo)
        self.assertEqual(repository.get_note(self.conn, note["id"])["title"], "Database check")
        self.assertIn(note["id"], [item["id"] for item in repository.list_notes(self.conn)])
        updated = repository.update_note(self.conn, note["id"], "Edited", "New content")
        self.assertEqual(updated["content"], "New content")
        self.assertGreater(updated["updated_at"], note["updated_at"])
        self.assertEqual(updated["created_at"], note["created_at"])
        self.assertEqual(repository.delete_note(self.conn, note["id"])["id"], note["id"])
        self.assertIsNone(repository.get_note(self.conn, note["id"]))

    def test_missing_note(self):
        missing = uuid4()
        self.assertIsNone(repository.get_note(self.conn, missing))
        self.assertIsNone(repository.update_note(self.conn, missing, "Missing", ""))
        self.assertIsNone(repository.delete_note(self.conn, missing))

    def test_sql_text_is_stored_as_data(self):
        title = "Robert'); DROP TABLE notes; --"
        note = repository.create_note(self.conn, title, "Quotes: ' and Unicode: café")
        self.assertEqual(repository.get_note(self.conn, note["id"])["title"], title)

    def test_invalid_values_rejected(self):
        invalid = [
            ("", "", CheckViolation),
            (" \t\n", "", CheckViolation),
            ("x" * 201, "", StringDataRightTruncation),
            (None, "", NotNullViolation),
            ("Valid title", None, NotNullViolation),
            ("Valid title", "x" * 50001, CheckViolation),
        ]
        for title, content, error in invalid:
            with self.subTest(title_length=len(title) if title is not None else None):
                with self.assertRaises(error):
                    with self.conn.transaction():
                        repository.create_note(self.conn, title, content)

    def test_maximum_lengths_accepted(self):
        note = repository.create_note(self.conn, "x" * 200, "y" * 50000)
        self.assertEqual(len(note["title"]), 200)
        self.assertEqual(len(note["content"]), 50000)

    def test_rollback_discards_note(self):
        note = repository.create_note(self.conn, "Rolled back")
        self.conn.rollback()
        self.assertIsNone(repository.get_note(self.conn, note["id"]))

    def test_version_checks_prevent_stale_update_and_delete(self):
        note = repository.create_note(self.conn, 'Original')
        updated = repository.update_note(self.conn, note['id'], 'Other writer', '', note['updated_at'])
        self.assertGreater(updated['updated_at'], note['updated_at'])
        self.assertIsNone(repository.update_note(self.conn, note['id'], 'Stale', '', note['updated_at']))
        self.assertIsNone(repository.delete_note(self.conn, note['id'], note['updated_at']))
        self.assertEqual(repository.get_note(self.conn, note['id'])['title'], 'Other writer')
        self.assertIsNotNone(repository.delete_note(self.conn, note['id'], updated['updated_at']))


if __name__ == "__main__":
    unittest.main()
