import json
import os
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from unittest.mock import patch

from player import choose, parse_order_response
from policy import default_order
from test_policy import VIEW


class NativeLlmTest(unittest.TestCase):
    def test_prompt_policy_prefers_native_sidecar_without_provider_key(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append((self.path, body))
                reply = json.dumps({"content": [{"text": json.dumps(default_order(VIEW))}]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(reply)))
                self.end_headers()
                self.wfile.write(reply)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.dict(
                os.environ,
                {
                    "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
                    "COWORLD_LLM_MODEL": "anthropic/claude-sonnet-4.6",
                },
                clear=True,
            ):
                action, source, _, _ = choose(
                    {
                        "view": VIEW,
                        "turn": 3,
                        "attempt_id": "3-0-1",
                        "prompt_configuration": {"promptVariant": "canonical", "promptSeed": 0},
                    },
                    None,
                    "carry carefully",
                )
                self.assertEqual(action, default_order(VIEW))
                self.assertEqual(source, "llm")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0][0], "/v1/messages")
        self.assertEqual(requests[0][1]["model"], "anthropic/claude-sonnet-4.6")
        self.assertNotIn("anthropic_version", requests[0][1])

    def test_coworld_llm_enabled_calls_sidecar_without_player_prompt(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append((self.path, body))
                reply = json.dumps({"content": [{"text": json.dumps(default_order(VIEW))}]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(reply)))
                self.end_headers()
                self.wfile.write(reply)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.dict(
                os.environ,
                {
                    "COWORLD_LLM_ENABLED": "true",
                    "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
                    "COWORLD_LLM_MODEL": "anthropic/claude-haiku-4.5",
                },
                clear=True,
            ):
                action, source, _, _ = choose(
                    {
                        "view": VIEW,
                        "turn": 1,
                        "seat": 0,
                        "attempt_id": "1-0-1",
                        "prompt_configuration": {"promptVariant": "canonical", "promptSeed": 0},
                    },
                    None,
                    "",
                )
                self.assertEqual(action, default_order(VIEW))
                self.assertEqual(source, "llm")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0][0], "/v1/messages")

    def test_coworld_llm_enabled_without_endpoint_raises_instead_of_heuristic(self):
        with patch.dict(os.environ, {"COWORLD_LLM_ENABLED": "true"}, clear=True):
            with self.assertRaises(ValueError):
                choose(
                    {
                        "view": VIEW,
                        "turn": 1,
                        "attempt_id": "1-0-1",
                        "prompt_configuration": {"promptVariant": "canonical", "promptSeed": 0},
                    },
                    None,
                    "",
                )

    def test_parse_order_response_accepts_raw_and_single_fence_only(self):
        raw = json.dumps(default_order(VIEW))
        self.assertEqual(parse_order_response(raw), default_order(VIEW))
        self.assertEqual(
            parse_order_response(f"```json\n{raw}\n```"),
            default_order(VIEW),
        )
        for rejected in (
            f"Sure! Here is my move: {raw}",
            f"{raw}\nextra trailing text",
            f"```json\n{raw}\n```\n```json\n{raw}\n```",
            "no json here",
        ):
            with self.assertRaises(ValueError, msg=rejected):
                parse_order_response(rejected)
