"""Run the offline join on a two-seat binary replay and a private player ZIP."""

import gzip
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from join_decision_receipts import audit
from replay_summary import FORMAT_VERSION, MAGIC, REC_CHAT


def text(value):
    raw = value.encode()
    return struct.pack("<H", len(raw)) + raw


class ReceiptReplayTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.replay = Path(tmp.name) / "game.replay.gz"
        self.artifact = Path(tmp.name) / "player.zip"
        action = {"q": [1, 2, 3, 4, 5, 6], "say": "", "note": ""}
        raw = MAGIC + struct.pack("<H", FORMAT_VERSION) + text("tandem") + text("1")
        raw += bytes(8) + text('{"seed":42,"num_agents":2}')
        for turn, seat, source in [(0, 1, "scripted"), (0, 0, "external"), (1, 0, "fallback")]:
            order = dict(action, k="order", seat=seat, turn=turn, source=source)
            raw += struct.pack("<BIB", REC_CHAT, turn, 0) + text(json.dumps(order))
        self.replay.write_bytes(gzip.compress(raw))
        self.receipt = {
            "schema_version": 1,
            "game": "tandem",
            "seed": 42,
            "slot": 0,
            "replay_sha256": hashlib.sha256(raw).hexdigest(),
            "results": [
                {
                    "turn": 0,
                    "accepted": True,
                    "selected_attempt_id": "0-0-2",
                    "executed_action": action,
                    "attempts": [
                        {"attempt_id": "0-0-1"},
                        {"attempt_id": "0-0-2", "platform_call_id": "call-2"},
                    ],
                },
                {"turn": 1, "accepted": False, "selected_attempt_id": None, "executed_action": action},
            ],
        }

    def join(self, **changes):
        with zipfile.ZipFile(self.artifact, "w") as archive:
            archive.writestr("decision_results.json", json.dumps(self.receipt | changes))
        return audit(42, 0, self.replay, self.artifact)["turns"]

    def test_retry_fallback_and_missing(self):
        accepted, fallback = self.join()
        self.assertEqual((accepted["join"], accepted["platform_call_id"]), ("verified_accepted", "call-2"))
        self.assertEqual(fallback["join"], "verified_fallback")
        ack = self.receipt["results"][0]
        for field in ("attempts", "executed_action", "accepted", "selected_attempt_id"):
            with self.subTest(field=field):
                row = {k: v for k, v in ack.items() if k != field}
                self.assertEqual([t["join"] for t in self.join(results=[row])], ["unknown", "unknown"])
        self.assertEqual(self.join(replay_sha256=None)[0]["join"], "unknown")
        replay_only = audit(42, 0, self.replay)["turns"][0]
        self.assertEqual(
            (replay_only["ack_accepted"], replay_only["replay_source"], replay_only["join"]),
            (None, "external", "unknown"),
        )

    def test_cli_ack_order_and_coverage(self):
        first, second = self.receipt["results"]
        command = [
            sys.executable, str(Path(__file__).with_name("join_decision_receipts.py")),
            "--seed", "42", "--seat", "0", "--replay", str(self.replay),
        ]
        for rows, late, presence, joins in [
            ([first, second], [], [True, True], ["verified_accepted", "verified_fallback"]),
            ([second, first], [0], [True, True], ["verified_accepted", "verified_fallback"]),
            ([second], [], [False, True], ["unknown", "verified_fallback"]),
            ([{"turn": 0}, second], [], [True, True], ["unknown", "verified_fallback"]),
            (None, [], [False, False], ["unknown", "unknown"]),
            ([second, first, second], None, None, None),
        ]:
            with self.subTest(rows=rows):
                args = command.copy()
                if rows is not None:
                    with zipfile.ZipFile(self.artifact, "w") as archive:
                        archive.writestr("decision_results.json", json.dumps(self.receipt | {"results": rows}))
                    args.extend(["--receipt", str(self.artifact)])
                result = subprocess.run(args, capture_output=True, text=True)
                if late is None:
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("duplicate ACK turn 1", result.stderr)
                    self.assertEqual(result.stdout, "")
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual((report["keyed_receipts"], report["keyed_orders"]), (len(rows or []), 2))
                self.assertEqual(report["out_of_order_ack_turns"], late)
                self.assertEqual([r["turn"] for r in report["turns"]], [0, 1])
                self.assertEqual([r["ack_present"] for r in report["turns"]], presence)
                self.assertEqual([r["join"] for r in report["turns"]], joins)

    def test_refuse_conflicting_evidence(self):
        ack = self.receipt["results"][0]
        for changes in [
            {"game": "other"},
            {"seed": 41},
            {"slot": 1},
            {"replay_sha256": "0" * 64},
            {"results": [ack, ack]},
            {"results": [dict(ack, turn=1)]},
            {"results": [dict(ack, selected_attempt_id="0-1-1")]},
            {"results": [dict(ack, executed_action=dict(ack["executed_action"], note="different"))]},
        ]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.join(**changes)


if __name__ == "__main__":
    unittest.main()
