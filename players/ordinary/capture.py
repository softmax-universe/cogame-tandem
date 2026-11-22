"""Private turn receipts and optional accepted training decisions."""

from __future__ import annotations

import hashlib
import io
import json
import os
import urllib.request
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlsplit

from prompts import PromptSelection


class Capture:
    def __init__(self, slot: int, backend: str) -> None:
        self.slot = slot
        self.backend = backend
        self.revision = os.environ["TANDEM_SOURCE_REVISION"]
        self.upload_url = os.environ["COWORLD_PLAYER_ARTIFACT_UPLOAD_URL"]
        self.training = os.environ.get("TANDEM_CAPTURE_TRAINING") == "1"
        self.results: list[dict] = []
        self.rows: list[dict] = []

    @staticmethod
    def attempt(evidence: dict, action: dict, source: str) -> dict:
        issued = json.dumps(action, sort_keys=True, separators=(",", ":")).encode()
        return {
            "attempt_id": evidence["attempt_id"],
            "platform_call_id": evidence["platform_call_id"],
            "provider_request_id": evidence["provider_request_id"],
            "source": source,
            "issued_action_sha256": hashlib.sha256(issued).hexdigest(),
        }

    def record_result(self, frame: dict, attempts: dict) -> None:
        fields = ("turn", "accepted", "selected_attempt_id", "executed_action")
        receipt = {key: frame[key] for key in fields if key in frame}
        receipt["attempts"] = [identity for identity, _ in attempts.values()]
        self.results.append(receipt)
        if self.training and frame["accepted"]:
            # Legacy turn-only ACKs used the last submission for training. Preserve
            # that format without inventing a server-selected ID in the receipt.
            selected = frame.get("selected_attempt_id") or next(reversed(attempts))
            self.record(*attempts[selected][1])

    def record(self, system: str, user: str, action: dict, source: str, tick: int, selection: PromptSelection) -> None:
        self.rows.append(
            {
                "decision_id": len(self.rows),
                "tick": tick,
                "source": source,
                "prompt_template": selection.metadata(system, user),
                "prompt": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                "completion": [{"role": "assistant", "content": json.dumps(action, sort_keys=True)}],
            }
        )

    def upload(self, scores: list[float], reason: str) -> None:
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr(
                "decision_results.json",
                json.dumps({
                    "schema_version": 1,
                    "episode_id": os.environ.get("COWORLD_EPISODE_ID"),
                    "slot": self.slot,
                    "backend": self.backend,
                    "source_revision": self.revision,
                    "reason": reason,
                    "scores": scores,
                    "results": self.results,
                }),
            )
            output.writestr(
                "trajectory.json",
                json.dumps(
                    {
                        "schema_version": 1,
                        "game": "tandem",
                        "slot": self.slot,
                        "backend": self.backend,
                        "source_revision": self.revision,
                        "complete": True,
                        "reason": reason,
                        "scores": scores,
                        "decisions": self.rows,
                    }
                ),
            )
        data = archive.getvalue()
        url = urlsplit(self.upload_url)
        if url.scheme == "file":
            target = Path(unquote(url.path))
            pending = target.with_name(target.name + ".tmp")
            pending.write_bytes(data)
            os.replace(pending, target)
        else:
            request = urllib.request.Request(
                self.upload_url,
                data=data,
                method="PUT",
                headers={"Content-Type": "application/zip"},
            )
            with urllib.request.urlopen(request, timeout=10) as response:
                response.read()
