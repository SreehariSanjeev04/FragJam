import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import monitor_reassembly as monitor


def clean_nodes():
    return {name: {"ip": {key: 0 for key in monitor.COUNTERS},
                   "frag_queues": 0} for name in monitor.NAMESPACES}


class MonitoringTests(unittest.TestCase):
    def test_reset_requires_empty_queues_and_fresh_counters(self):
        nodes = clean_nodes()
        with patch.object(monitor, "snapshot", return_value=nodes), \
             patch.object(monitor, "append") as append, \
             patch.object(monitor.subprocess, "run",
                          return_value=SimpleNamespace(stdout="10.200.1.1 dev veth-s")):
            monitor.assert_state("unused", "assert-reset")
            append.assert_called_once()
            nodes["fj-router"]["ip"]["ReasmFails"] = 1
            with self.assertRaisesRegex(RuntimeError, "not fresh"):
                monitor.assert_state("unused", "assert-reset")
            nodes["fj-router"]["ip"]["ReasmFails"] = 0
            nodes["fj-router"]["frag_queues"] = 1
            with self.assertRaisesRegex(RuntimeError, "queues remain"):
                monitor.assert_state("unused", "assert-reset")

    def test_reset_rejects_cached_trial_pmtu(self):
        with patch.object(monitor, "snapshot", return_value=clean_nodes()), \
             patch.object(monitor.subprocess, "run",
                          return_value=SimpleNamespace(stdout="10.200.1.1 mtu 552")):
            with self.assertRaisesRegex(RuntimeError, "PMTU"):
                monitor.assert_state("unused", "assert-reset")

    def test_probe_records_delivery_and_timeout_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            ping = Path(directory) / "ping.txt"
            records = Path(directory) / "observations.jsonl"
            ping.write_text("no answer yet for icmp_seq=2\n"
                            "4 packets transmitted, 3 received, 25% packet loss\n")
            monitor.record_probe(str(records), "pressure", str(ping))
            import json
            event = json.loads(records.read_text())
            self.assertEqual((event["sent"], event["received"], event["timeout_reports"]),
                             (4, 3, 1))


if __name__ == "__main__":
    unittest.main()
