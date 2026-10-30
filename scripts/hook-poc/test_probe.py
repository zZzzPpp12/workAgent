import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("probe.py")
spec = importlib.util.spec_from_file_location("probe", SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class HookProbeTests(unittest.TestCase):
    def test_sensitive_content_is_excluded(self):
        event = probe.sanitize({"hook_event_name": "PermissionRequest", "session_id": "s", "tool_input": {"command": "private"}, "prompt": "private", "cwd": "/private/project", "access_token": "secret"}, "Codex")
        self.assertEqual(event["session_id"], "s")
        for name in ("tool_input", "prompt", "cwd", "access_token"):
            self.assertNotIn(name, event)

    def test_unknown_events_are_ignored(self):
        self.assertIsNone(probe.sanitize({"hook_event_name": "unknown"}, "Codex"))

    def test_probe_records_metadata_and_returns_no_decision(self):
        for source in ("Codex", "Claude"):
            with tempfile.TemporaryDirectory() as directory:
                result = subprocess.run(["/usr/bin/python3", str(SCRIPT), "--source", source, "--output", directory], input='{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"private"}', capture_output=True, text=True, check=True)
                self.assertEqual(json.loads(result.stdout), {})
                records = list(Path(directory).glob("*.json"))
                self.assertEqual(len(records), 1)
                record = json.loads(records[0].read_text())
                self.assertEqual(record["source"], source)
                self.assertNotIn("last_assistant_message", record)

    def test_invalid_input_never_blocks_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["/usr/bin/python3", str(SCRIPT), "--source", "Codex", "--output", directory], input="partial json", capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout), {})
            self.assertEqual(list(Path(directory).glob("*.json")), [])


if __name__ == "__main__":
    unittest.main()
