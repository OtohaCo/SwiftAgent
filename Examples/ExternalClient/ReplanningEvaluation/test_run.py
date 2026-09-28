import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import run as evaluation


class ReplanningEvaluationTests(unittest.TestCase):
    def test_seeded_schedule_alternates_arms_without_changing_task_data(self):
        tasks, _ = evaluation.load_tasks(evaluation.TASKS)
        paired = [task for task in tasks if task["group"] != "safety"]
        first = evaluation.schedule(paired, 2, 17)
        self.assertEqual(first, evaluation.schedule(paired, 2, 17))
        for task in paired:
            arms = [(repeat, arm) for selected, repeat, arm in first if selected["id"] == task["id"]]
            self.assertEqual(arms, [(0, "enabled"), (0, "disabled"), (1, "disabled"), (1, "enabled")])

    def test_dry_run_binary_selection_does_not_launch_a_build(self):
        args = evaluation.options(["--mode", "dry-run"])
        with mock.patch.object(evaluation.subprocess, "run", side_effect=AssertionError("unexpected build")):
            self.assertTrue(Path(evaluation.build_child(args)).is_file())

    def test_offline_trials_score_execution_and_cleanup_without_a_credential(self):
        with tempfile.TemporaryDirectory(prefix="swiftagent-eval-test-") as root:
            output = Path(root) / "evaluation"
            args = evaluation.options(["--mode", "dry-run", "--output", str(output)])
            with mock.patch.dict(os.environ, {"OPENAI_API_KEY": "SHOULD_NEVER_APPEAR"}):
                location, summary, infra = evaluation.execute(args)
            self.assertFalse(infra)
            self.assertEqual(location, output.resolve())
            records = [json.loads(line) for line in (output / "trials.jsonl").read_text().splitlines()]
            self.assertEqual(len(records), 11)
            self.assertEqual(summary["planned"], 11)
            self.assertFalse((output / "trials").exists() and list((output / "trials").iterdir()))
            self.assertNotIn("SHOULD_NEVER_APPEAR", (output / "manifest.json").read_text())
            self.assertNotIn("SHOULD_NEVER_APPEAR", (output / "trials.jsonl").read_text())
            self.assertEqual(len(json.loads((output / "manifest.json").read_text())["trialBinarySHA256"]), 64)
            attempted = [record for record in records if record["facts"]]
            self.assertEqual(len(attempted), 11)
            self.assertEqual(len({r["facts"]["sessionID"] for r in attempted}), 11)
            self.assertEqual(len({r["facts"]["operationID"] for r in attempted}), 11)
            self.assertTrue(all(r["facts"]["httpRequests"] == 0 and r["facts"]["hostRetries"] == 0
                                and r["facts"]["reportComplete"] for r in attempted))
            controlled = {(r["arm"]): r for r in records if r["task"]["group"] == "controlled_error"}
            self.assertTrue(controlled["enabled"]["score"]["success"])
            self.assertEqual(controlled["enabled"]["score"]["recovery"], "success")
            self.assertEqual(controlled["enabled"]["facts"]["effectIDs"], ["A"])
            self.assertEqual(controlled["disabled"]["score"]["recovery"], "not_exercised")
            self.assertFalse(controlled["disabled"]["score"]["success"])
            self.assertEqual(controlled["disabled"]["facts"]["effectIDs"], [])
            t = controlled["enabled"]["facts"]["milestonesNS"]
            self.assertLessEqual(t["taskStart"], t["firstCandidate"])
            self.assertLess(t["rejection"], t["feedbackRequest"])
            self.assertLess(t["feedbackRequest"], t["effect"])
            self.assertLess(t["effect"], t["settlement"])
            self.assertLessEqual(t["logicalEnd"], t["physicalDrain"])
            safety = {r["task"]["scenario"]: r for r in records if r["task"]["group"] == "safety"}
            self.assertTrue(all(r["score"]["success"] for r in safety.values()))
            self.assertEqual(safety["unknown_after_write"]["facts"]["effectIDs"], ["A"])
            self.assertEqual(len(safety["unknown_after_write"]["facts"]["runIDs"]), 2)
            self.assertEqual(safety["unknown_after_write"]["facts"]["pendingStates"], ["needsReconciliation"])
            self.assertEqual(safety["cancel_after_request"]["facts"]["effectIDs"], [])
            self.assertEqual(safety["revoke_after_request"]["facts"]["effectIDs"], [])
            self.assertIsNone(summary["groups"]["controlled_error/enabled"]["reportedUsage"]["inputTokens"])
            self.assertEqual(summary["groups"]["controlled_error/disabled"]["failed"], 1)
            self.assertEqual(summary["groups"]["controlled_error/disabled"]["planned"], 1)
            self.assertEqual(summary["groups"]["controlled_error/disabled"]["failureRate"], 1.0)
            self.assertEqual(summary["groups"]["controlled_error/disabled"]["timeoutRate"], 0.0)
            self.assertEqual(summary["groups"]["controlled_error/disabled"]["cancellationRate"], 0.0)
            forbidden = next(t for t in evaluation.load_tasks(evaluation.TASKS)[0]
                             if t["id"] == "natural_list_only")
            wrong_effect = dict(controlled["enabled"]["facts"], effectIDs=["A"])
            self.assertTrue(evaluation.score(forbidden, wrong_effect)["safetyViolation"])

    def test_global_reservation_stops_and_keeps_not_run_trials_visible(self):
        with tempfile.TemporaryDirectory(prefix="swiftagent-eval-budget-") as root:
            parent = Path(root)
            task = next(t for t in evaluation.load_tasks(evaluation.TASKS)[0] if t["id"] == "natural_commit_A")
            task_file = parent / "tasks.json"
            task_file.write_text(json.dumps([task]))
            args = evaluation.options(["--mode", "dry-run", "--tasks", str(task_file),
                "--output", str(parent / "evaluation"), "--max-http-requests", "6",
                "--max-http-per-trial", "6"])
            _, summary, infra = evaluation.execute(args)
            self.assertFalse(infra)
            records = [json.loads(line) for line in (parent / "evaluation/trials.jsonl").read_text().splitlines()]
            self.assertEqual(summary["planned"], 2)
            self.assertEqual(sum(r["facts"] is not None for r in records), 1)
            self.assertEqual(records[1]["notRunReason"], "global_budget_or_deadline")
            self.assertEqual(summary["groups"]["natural/disabled"]["successRate"] +
                             summary["groups"]["natural/enabled"]["successRate"], 1.0)

    def test_token_and_cost_reservations_each_stop_before_an_extra_trial(self):
        task = next(t for t in evaluation.load_tasks(evaluation.TASKS)[0] if t["id"] == "natural_commit_A")
        for limit in ("tokens", "cost"):
            with tempfile.TemporaryDirectory(prefix="swiftagent-eval-reserve-") as root:
                parent = Path(root)
                task_file = parent / "tasks.json"
                task_file.write_text(json.dumps([task]))
                flags = (["--max-total-tokens", "98304"] if limit == "tokens"
                         else ["--max-total-usd", "0.06"])
                args = evaluation.options(["--mode", "dry-run", "--tasks", str(task_file),
                    "--output", str(parent / "evaluation"), *flags])
                _, summary, infra = evaluation.execute(args)
                self.assertFalse(infra)
                self.assertEqual(sum(group["attempted"] for group in summary["groups"].values()), 1)
                self.assertEqual(sum(group["notRun"] for group in summary["groups"].values()), 1)

    def test_live_requires_explicit_authorization_and_every_limit(self):
        output = io.StringIO()
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": "SHOULD_NEVER_APPEAR"}), contextlib.redirect_stderr(output):
            with self.assertRaises(SystemExit):
                evaluation.options(["--mode", "live", "--key-env", "OPENAI_API_KEY"])
        self.assertNotIn("SHOULD_NEVER_APPEAR", output.getvalue())
        self.assertIn("--authorized-live", output.getvalue())

    def test_timeout_keeps_trial_store_and_counts_it_in_the_denominator(self):
        with tempfile.TemporaryDirectory(prefix="swiftagent-eval-timeout-") as root:
            parent = Path(root)
            task = next(t for t in evaluation.load_tasks(evaluation.TASKS)[0] if t["id"] == "natural_commit_A")
            task_file = parent / "tasks.json"
            task_file.write_text(json.dumps([task]))
            args = evaluation.options(["--mode", "dry-run", "--tasks", str(task_file),
                "--output", str(parent / "evaluation")])
            binary = evaluation.build_child(args)
            with mock.patch.object(evaluation, "build_child", return_value=binary), \
                 mock.patch.object(evaluation, "sdk_identity", return_value=("sha", "tree", False)), \
                 mock.patch.object(evaluation.subprocess, "run",
                     side_effect=subprocess.TimeoutExpired(cmd=binary, timeout=1)):
                _, summary, infra = evaluation.execute(args)
            self.assertFalse(infra)
            records = [json.loads(line) for line in (parent / "evaluation/trials.jsonl").read_text().splitlines()]
            self.assertEqual(records[0]["failureKind"], "process_timeout")
            self.assertTrue(records[0]["attempted"])
            self.assertEqual(records[0]["score"]["recovery"], "not_observed")
            self.assertIsNone(records[0]["facts"])
            self.assertFalse(records[1].get("attempted", False))
            self.assertEqual(summary["stoppedReason"], "process_timeout")
            self.assertEqual(sum(group["timedOut"] for group in summary["groups"].values()), 1)
            self.assertEqual(sum(group["timeoutRate"] for group in summary["groups"].values()), 1.0)
            self.assertEqual(sum(group["planned"] for group in summary["groups"].values()), 2)
            self.assertEqual(len(list((parent / "evaluation/trials").iterdir())), 1)


if __name__ == "__main__":
    unittest.main()
