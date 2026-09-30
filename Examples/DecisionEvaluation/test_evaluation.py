import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import evaluation as e


class EvaluationTests(unittest.TestCase):
    def test_failures_stay_in_denominator_and_latency_only_counts_valid_success(self):
        task = {"id": "a", "kind": "choice", "allowed": ["Yes"],
                "candidates": [{"id": "Yes"}, {"id": "No"}], "repeatGroup": "a"}
        trials = [dict(task=task, status="success", selected="Yes", latencyMs=20,
                       probabilities={"Yes": .8, "No": .2}, confidence=.99),
                  dict(task=task, status="timeout"), dict(task=task, status="invalid_response")]
        s = e.summarize(trials, "fixture")
        self.assertEqual(s["attempts"], 3)
        self.assertEqual(s["correct"], 1)
        self.assertEqual(s["accuracy"], 1 / 3)
        self.assertEqual(s["latencySuccessful"], {"n": 1, "p50Ms": 20, "p95Ms": 20})
        self.assertAlmostEqual(s["calibration"]["meanBrier"], .08)
        self.assertEqual(s["repeatConsistency"]["consistentGroups"], 0)
        self.assertIsNone(s["actualCostUSD"])
        self.assertEqual(s["qualityQualification"], "NOT_RUN")

    def test_missing_probability_and_non_normalized_mass_are_not_invented(self):
        t = {"id": "a", "kind": "choice", "allowed": ["A"],
             "candidates": [{"id": "A"}, {"id": "a"}], "repeatGroup": "a"}
        for p in [None, {"A": .8, "a": .8}]:
            s = e.summarize([dict(task=t, status="success", selected="A", confidence=1,
                                 latencyMs=1, probabilities=p)], "live")
            self.assertEqual(s["calibration"]["n"], 0)
            self.assertIsNone(s["calibration"]["meanBrier"])

    def test_dataset_hash_order_repeat_and_language_are_pre_registered(self):
        d = e.load_dataset(Path(__file__).with_name("dataset-v1.json"))
        p = e.plan(d, repetitions=2, seed=73)
        self.assertEqual(p, e.plan(d, repetitions=2, seed=73))
        self.assertEqual({x["task"]["language"] for x in p}, {"en", "zh", "ja"})
        self.assertEqual(len({x["trialID"] for x in p}), len(p))
        self.assertNotEqual(e.data_hash(d), e.data_hash(dict(d, version="altered")))

    def test_unknown_cost_cannot_pass_strict_live_budget(self):
        b = e.Budget(2, 100, 1, .1, None, None)
        with self.assertRaises(e.SafeFailure):
            b.reserve(live=True)
        b.reserve(live=False)
        b.reserve(live=False)
        with self.assertRaises(e.SafeFailure):
            b.reserve(live=False)

    def test_reservations_count_failed_and_uncertain_attempts(self):
        b = e.Budget(2, 100, 60, .1, 50, .05)
        b.reserve(live=True)
        b.reserve(live=True)
        self.assertEqual(b.reserved_tokens, 100)
        self.assertAlmostEqual(b.reserved_usd, .1)
        with self.assertRaises(e.SafeFailure):
            b.reserve(live=True)

    def test_ledger_recovery_never_replays_unknown_or_double_counts_duplicates(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "trials.jsonl"
            e.append_record(path, {"event": "started", "trialID": "one", "task": {"id": "a"}})
            self.assertEqual(e.read_trials(path)[0]["status"], "unknown")
            e.append_record(path, {"event": "finished", "trialID": "one", "status": "timeout"})
            self.assertEqual(len(e.read_trials(path)), 1)
            e.append_record(path, {"event": "finished", "trialID": "one", "status": "success"})
            with self.assertRaises(e.SafeFailure):
                e.read_trials(path)

    def test_dry_run_does_not_construct_transport_even_with_a_key_in_environment(self):
        with tempfile.TemporaryDirectory() as root, patch.dict("os.environ", {"TYPESAFE_API_KEY": "private-key"}), \
                patch("evaluation.run_child", side_effect=AssertionError("no dispatch")):
            out = Path(root) / "attempt"
            with patch("builtins.print"):
                self.assertEqual(e.main(["--provider", "jev", "--output", str(out)]), 0)
            s = json.loads((out / "summary.json").read_text())
            self.assertEqual(s["attempts"], 0)
            self.assertEqual(s["budget"]["reservedRequests"], 0)
            self.assertNotIn("private-key", (out / "plan.json").read_text())
            with self.assertRaises(FileExistsError):
                e.main(["--provider", "jev", "--output", str(out)])

    def test_native_protocol_is_unsupported_without_fallback_or_network(self):
        with tempfile.TemporaryDirectory() as root, patch("evaluation.run_child", side_effect=AssertionError("no dispatch")):
            out = Path(root) / "attempt"
            with patch("builtins.print"):
                e.main(["--provider", "openai-native-decisions", "--mode", "fixture", "--output", str(out)])
            s = json.loads((out / "summary.json").read_text())
            self.assertEqual(s["statuses"], {"unsupported": 48})
            self.assertEqual(s["attempts"], 0)
            self.assertEqual(s["protocolQualification"], "NOT_RUN")
            self.assertIsNone(s["configuration"]["requestedModel"])

    def test_original_absolute_budget_deadline_does_not_reset(self):
        now = [10.0]
        b = e.Budget(2, 100, 10, .1, 50, .05, clock=lambda: now[0])
        b.reserve(live=True)
        now[0] = 21
        with self.assertRaises(e.SafeFailure):
            b.reserve(live=True)
        self.assertEqual(b.deadline, 20)

    def test_sdk_deadline_is_counted_as_timeout_and_empty_usage_is_absent(self):
        task = {"id": "a", "kind": "choice", "allowed": ["A"], "candidates": [{"id": "A"}], "repeatGroup": "a"}
        s = e.summarize([dict(task=task, status="deadline_exceeded")], "live")
        self.assertEqual(s["timeoutRate"], 1)
        self.assertEqual(s["usage"]["observedTrials"], 0)

    def test_mutated_image_input_is_rejected_before_dispatch(self):
        d = e.load_dataset(Path(__file__).with_name("dataset-v1.json"))
        d["tasks"][0]["modality"] = "image"
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "data.json"
            path.write_text(json.dumps(d))
            with self.assertRaises(e.SafeFailure):
                e.load_dataset(path)

    def test_scoring_allowed_set_and_case_sensitive_candidates(self):
        t = {"id": "a", "kind": "choice", "allowed": ["A", "clarify"],
             "candidates": [{"id": "A"}, {"id": "a"}, {"id": "clarify"}], "repeatGroup": "a"}
        s = e.summarize([dict(task=t, status="success", selected="a", latencyMs=1),
                         dict(task=t, status="success", selected="clarify", latencyMs=2)], "live")
        self.assertEqual(s["accuracy"], .5)
        self.assertEqual(s["calibration"]["n"], 0)  # Ambiguous allowed truth is not a calibration target.

    def test_unknown_cost_live_preflight_fails_before_key_read_or_dispatch(self):
        with tempfile.TemporaryDirectory() as root, patch("evaluation.run_child", side_effect=AssertionError("no dispatch")):
            out = Path(root) / "attempt"
            with self.assertRaises(e.SafeFailure):
                e.main(["--mode", "live", "--provider", "jev", "--endpoint", "https://example.invalid/systemone",
                        "--model", "jev-latest", "--deployment", "test-deployment", "--key-environment", "TEST_KEY",
                        "--consent-live", "--host-bound-reference", "host-pricing-v1", "--output", str(out)])
            self.assertFalse(out.exists())

    def test_result_projection_drops_private_extensions_and_refuses_wrong_candidates(self):
        payload = {"candidates": [{"id": "Yes"}, {"id": "No"}]}
        value = dict(status="success", selected="Yes", latencyMs=1, actualModel="https://private.example",
                     apiKey="private-key", AuthorizationDecision={"outcome": "allow"})
        view = e.result_view(value, payload)
        self.assertNotIn("private", json.dumps(view))
        self.assertNotIn("apiKey", view)
        self.assertNotIn("AuthorizationDecision", view)
        self.assertNotIn("probabilities", view)
        with self.assertRaises(ValueError):
            e.result_view(dict(value, selected="yes"), payload)

    def test_expired_parent_deadline_never_launches_child(self):
        with patch("evaluation.subprocess.Popen", side_effect=AssertionError("no launch")):
            r = e.run_child(Path("irrelevant"), {}, deadline=1, clock=lambda: 2)
        self.assertEqual(r["remoteConsumption"], "not_dispatched")

    def test_ledger_rejects_mixed_evaluation_configuration(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "trials.jsonl"
            e.append_record(path, dict(event="started", trialID="one", evaluationID="first", task={}))
            e.append_record(path, dict(event="started", trialID="two", evaluationID="second", task={}))
            with self.assertRaises(e.SafeFailure):
                e.read_trials(path)


if __name__ == "__main__":
    unittest.main()
