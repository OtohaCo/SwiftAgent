import json
import os
import subprocess
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import evaluation as e
from http_fixture import FixtureServer


class PublicSDKHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).parent
        result = subprocess.run(["swift", "build", "--package-path", str(root), "--show-bin-path"],
                                check=True, capture_output=True, text=True)
        cls.executable = Path(result.stdout.strip()) / "DecisionEvalTrial"
        if not cls.executable.is_file():
            raise RuntimeError("Build DecisionEvalTrial before running HTTP tests")

    def payload(self, endpoint):
        return dict(mode="fixture", endpoint=endpoint, model="fixture-jev", timeoutSeconds=5,
                    state="I was billed twice. Please review the duplicate charge.",
                    candidates=[dict(id="billing", description="payments"), dict(id="access", description="login")],
                    instructions="Select a review queue, never authorization.", promptVersion="fixture-v1")

    def invoke(self, endpoint):
        return e.run_child(self.executable, self.payload(endpoint), time.monotonic() + 10)

    def test_typed_actual_public_sdk_request_and_answer(self):
        with FixtureServer() as server:
            r = self.invoke(server.endpoint)
            self.assertEqual(r["status"], "success")
            self.assertEqual(r["selected"], "billing")
            self.assertEqual(r["actualModel"], "fixture-jev-snapshot")
            self.assertEqual(server.requests, 1)
            self.assertEqual(server.last_question_names, ["route"])
            self.assertEqual(server.last_candidates, {"billing", "access"})

    def test_protocol_faults_and_no_retry_or_private_diagnostics(self):
        cases = {"missing": "invalid_response", "extra": "invalid_response", "case": "invalid_response",
                 "enum": "invalid_response", "probability": "invalid_response", "truncated": "invalid_response",
                 "refusal": "invalid_response", "401": "authentication", "403": "permission_denied",
                 "429": "rate_limited", "503": "unavailable"}
        for mode, expected in cases.items():
            with self.subTest(mode=mode), FixtureServer(mode=mode) as server:
                r = self.invoke(server.endpoint)
                self.assertEqual(r["status"], expected)
                self.assertEqual(server.requests, 1)
                self.assertNotIn("private", json.dumps(r))
                self.assertNotIn("not-a-credential", json.dumps(r))

    def test_redirect_cannot_forward_authorization(self):
        with FixtureServer() as destination, FixtureServer(mode="redirect", redirect=destination.endpoint) as origin:
            self.assertEqual(self.invoke(origin.endpoint)["status"], "transport")
            self.assertEqual(destination.requests, 0)

    def test_actual_model_is_separate_and_private_metadata_is_redacted(self):
        with FixtureServer(mode="private-model") as server:
            r = self.invoke(server.endpoint)
            self.assertEqual(r["actualModel"], "redacted")
            self.assertTrue(r["actualModelRedacted"])

    def test_provider_confidence_is_preserved_without_inventing_probability(self):
        with FixtureServer(mode="confidence-one") as server:
            r = self.invoke(server.endpoint)
            self.assertEqual(r["confidence"], 1)
            self.assertEqual(r["probabilities"]["billing"], .8)
            self.assertNotIn("AuthorizationDecision", r)
            self.assertNotIn("Receipt", r)

    def test_parent_interruption_reaps_owned_request_without_late_success(self):
        with FixtureServer(mode="hold") as server:
            owned = []
            popen = subprocess.Popen
            def observe(*args, **kwargs):
                child = popen(*args, **kwargs)
                owned.append(child)
                return child
            def cancel_at_barrier():
                if not owned:
                    return time.monotonic()
                self.assertTrue(server.entered.wait(10))
                raise KeyboardInterrupt()
            with patch("evaluation.subprocess.Popen", side_effect=observe):
                with self.assertRaises(KeyboardInterrupt):
                    e.run_child(self.executable, self.payload(server.endpoint), time.monotonic() + 10,
                                clock=cancel_at_barrier)
            self.assertEqual(len(owned), 1)
            self.assertIsNotNone(owned[0].returncode)
            self.assertFalse(server.exited.is_set())
            server.release.set()

    def test_deadline_and_physical_owner_with_noncooperative_server(self):
        with FixtureServer(mode="hold") as server:
            payload = self.payload(server.endpoint)
            payload["timeoutSeconds"] = 1
            result = []
            worker = threading.Thread(target=lambda: result.append(e.run_child(
                self.executable, payload, time.monotonic() + 10)))
            worker.start()
            self.assertTrue(server.entered.wait(10))  # Target stage barrier; no short sleep.
            worker.join(10)
            self.assertFalse(worker.is_alive())
            self.assertEqual(result[0]["status"], "deadline_exceeded")
            self.assertFalse(server.exited.is_set())  # Remote work has not exited.
            server.release.set()
            self.assertTrue(server.exited.wait(10))

    def test_parent_timeout_reaps_only_owned_child_and_next_request_is_isolated(self):
        with FixtureServer(mode="hold") as server:
            result = []
            ready = threading.Event()
            clock_reads = 0
            def expire_at_barrier():
                nonlocal clock_reads
                clock_reads += 1
                if clock_reads == 1:
                    return 0
                self.assertTrue(server.entered.wait(10))
                return 2
            def run():
                result.append(e.run_child(self.executable, self.payload(server.endpoint), 1, clock=expire_at_barrier))
                ready.set()
            worker = threading.Thread(target=run)
            worker.start()
            self.assertTrue(server.entered.wait(10))
            self.assertTrue(ready.wait(10))
            worker.join()
            self.assertEqual(result[0]["status"], "timeout")
            self.assertEqual(result[0]["physicalExit"], "forced_reaped")
            server.release.set()
        with FixtureServer() as server:
            self.assertEqual(self.invoke(server.endpoint)["status"], "success")


if __name__ == "__main__":
    unittest.main()
