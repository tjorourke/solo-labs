"""Clear-history must survive refresh/replay without swallowing the next call."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import google_dlp as dlp


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = patch.object(dlp, "HISTORY_PATH", Path(self.tmp.name) / "history.json")
        self.state.start()
        dlp._cleared_after, dlp._ignored_traces = 0, set()
        dlp.pii_events.clear()
        dlp.gw_events.clear()

    def tearDown(self):
        self.state.stop()
        self.tmp.cleanup()

    def test_clear_discards_replayed_and_inflight_but_accepts_new_calls(self):
        dlp._keep(dlp.pii_events, {"ts": 90, "trace": "inflight", "kind": "incoming"})
        with patch.object(dlp.time, "time", return_value=100):
            self.assertTrue(dlp.clear_history()["ok"])
        dlp._keep(dlp.pii_events, {"ts": 90, "trace": "old", "kind": "request"})
        dlp._keep(dlp.pii_events, {"ts": 110, "trace": "inflight", "kind": "answer"})
        dlp._keep(dlp.gw_events, {"start": 99, "end": 120, "trace": "old-gateway"})
        self.assertEqual(dlp.pii_events, [])
        self.assertEqual(dlp.gw_events, [])
        dlp._keep(dlp.pii_events, {"ts": 101, "trace": "fresh", "kind": "request", "original": "hello"})
        self.assertEqual([r["trace"] for r in dlp._decisions()], ["fresh"])

    def test_restart_restores_cutoff_and_inflight_tombstones(self):
        dlp._keep(dlp.pii_events, {"ts": 90, "trace": "inflight", "kind": "incoming"})
        with patch.object(dlp.time, "time", return_value=100):
            dlp.clear_history()
        dlp._cleared_after, dlp._ignored_traces = 0, set()
        dlp._cleared_after, dlp._ignored_traces = dlp._load_history()
        self.assertEqual(dlp._cleared_after, 100)
        self.assertIn("inflight", dlp._ignored_traces)
        dlp._keep(dlp.pii_events, {"ts": 110, "trace": "inflight", "kind": "answer"})
        self.assertFalse(dlp.pii_events)
        self.assertNotIn("original", json.loads(dlp.HISTORY_PATH.read_text()))

    def test_storage_failure_does_not_claim_clear_succeeded(self):
        dlp.pii_events.append({"ts": 90, "trace": "retained"})
        with patch.object(dlp.os, "replace", side_effect=OSError("disk error")):
            with self.assertRaises(OSError):
                dlp.clear_history()
        self.assertEqual(dlp._cleared_after, 0)
        self.assertEqual(dlp.pii_events[0]["trace"], "retained")


if __name__ == "__main__":
    unittest.main()
