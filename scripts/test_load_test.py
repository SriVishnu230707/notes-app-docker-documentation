"""Load-generator safety and correctness checks without a Docker engine."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("notes_load", Path(__file__).with_name("load-test.py"))
load = importlib.util.module_from_spec(spec)
spec.loader.exec_module(load)


class LoadSafetyTests(unittest.TestCase):
    def test_marked_disposable_project_reaches_http(self):
        with patch.dict(os.environ, {"PGDATABASE": "notes_load", "NOTES_LOAD_PROJECT": "notes-load-123456abcdef"}, clear=True), \
                patch.object(load, "urlopen", side_effect=AssertionError("Stopped after guard")) as http:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(load.run(1, 1, 2000), 1)
            http.assert_called_once()

    def test_normal_container_refused_before_http(self):
        for environment in ({}, {"PGDATABASE": "notes_load"},
                            {"PGDATABASE": "notes", "NOTES_LOAD_PROJECT": "notes-load-123456abcdef"},
                            {"PGDATABASE": "notes_load", "NOTES_LOAD_PROJECT": "notes-app"}):
            with self.subTest(environment=environment), patch.dict(os.environ, environment, clear=True), \
                    patch.object(load, "urlopen", side_effect=AssertionError("HTTP forbidden")) as http:
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    code = load.run(1, 1, 2000)
                report = json.loads(output.getvalue())
                self.assertEqual(code, 1)
                self.assertFalse(report["passed"])
                self.assertEqual(report["requests"], 0)
                http.assert_not_called()


if __name__ == "__main__":
    unittest.main()
