"""Exercise the ordinary receiver, including retry selection and older servers."""

import hashlib
import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import MagicMock, patch

from player import main
from test_policy import VIEW
from websocket import ABNF


class ReceiptTest(unittest.TestCase):
    def test_private_receipt_keeps_attempts_and_uses_server_selection(self):
        def turn(n, attempt):
            return dict(type="turn", turn=n, attempt_id=f"{n}-0-{attempt}", view=VIEW, prompt_configuration={})

        executed = {"q": [4096, 0, 255, 0, 0, 0], "note": "", "say": ""}
        frames = [
            turn(0, 1), turn(0, 2),
            dict(type="decision_result", turn=0, accepted=True, selected_attempt_id="0-0-2", executed_action=executed),
            turn(1, 1), turn(1, 2),
            dict(type="decision_result", turn=1, accepted=False, selected_attempt_id=None, executed_action=executed),
            dict(type="decision_result", turn=2, accepted=False, selected_attempt_id=None, executed_action=executed),
            turn(3, 1), dict(type="decision_result", turn=3, accepted=True),
            dict(type="final", scores=[0, 0], reason="complete"),
        ]
        for training in (False, True):
            with self.subTest(training=training), tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / "player.zip"
                env = {
                    "COWORLD_PLAYER_WS_URL": "ws://localhost/player?slot=0",
                    "COWORLD_PLAYER_ARTIFACT_UPLOAD_URL": target.as_uri(),
                    "COWORLD_EPISODE_ID": "local-episode",
                    "TANDEM_SOURCE_REVISION": "test",
                    "TANDEM_CAPTURE_TRAINING" if training else "TANDEM_CAPTURE_RECEIPTS": "1",
                }
                socket = MagicMock()
                socket.recv_data.side_effect = [(ABNF.OPCODE_TEXT, json.dumps(f)) for f in frames]
                with patch.dict(os.environ, env, clear=True), patch("player.connect_player", return_value=socket):
                    main()
                with zipfile.ZipFile(target) as archive:
                    receipt = json.loads(archive.read("decision_results.json"))
                    training_rows = json.loads(archive.read("trajectory.json"))["decisions"]
                self.assertEqual([r["tick"] for r in training_rows], [0, 3] if training else [])
                self.assertEqual((receipt["episode_id"], receipt["slot"]), ("local-episode", 0))
                first, rejected, guard, legacy = receipt["results"]
                self.assertEqual([a["attempt_id"] for a in first["attempts"]], ["0-0-1", "0-0-2"])
                self.assertEqual(first["selected_attempt_id"], "0-0-2")
                self.assertEqual(first["executed_action"], executed)
                issued = [json.loads(c.args[0]) for c in socket.send.call_args_list if isinstance(c.args[0], str)]
                action = json.dumps(issued[1]["action"], sort_keys=True, separators=(",", ":")).encode()
                self.assertEqual(first["attempts"][1]["issued_action_sha256"], hashlib.sha256(action).hexdigest())
                self.assertFalse(rejected["accepted"])
                self.assertIsNone(rejected["selected_attempt_id"])
                self.assertEqual(len(rejected["attempts"]), 2)
                self.assertEqual(guard["attempts"], [])
                self.assertNotIn("selected_attempt_id", legacy)
                self.assertNotIn("executed_action", legacy)
