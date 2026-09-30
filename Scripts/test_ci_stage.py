import json
import argparse
import importlib.util
from unittest import mock
import os
import select
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil
import unittest

STAGE = Path(__file__).with_name("ci_stage.py")

class CIStageTests(unittest.TestCase):
    def test_sampling_depth_uses_parents_not_pid_order_and_is_bounded(self):
        module = self.sampling_module()
        rows = self.sampling_rows((100, 1), (900, 100), (10, 900), (800, 100), (5, 10))
        self.assertEqual(module.sampling_targets(module.process_rows(rows), 100), [100, 5, 10])

    def test_sampling_rechecks_exit_and_pid_identity_before_attach(self):
        for change in ['exit', 'reuse']:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                module = self.sampling_module()
                original = self.sampling_rows((100, 1), (200, 100))
                changed = self.sampling_rows((100, 1)) if change == 'exit' else original.replace(
                    '200 100 100 S Wed Sep 30 12:00:00 2026 child',
                    '200 100 100 S Wed Sep 30 12:01:00 2026 child')
                snapshots, sampled = [], []
                def capture(command, timeout, outcome=None):
                    if command[0] == 'env':
                        snapshots.append(command)
                        return changed if len(snapshots) >= 4 else original
                    sampled.append(int(command[1]))
                    outcome.update(exitCode=0, timedOut=False)
                    return 'controlled sample'
                process = mock.Mock(pid=100); process.poll.return_value = None
                with mock.patch.object(module, 'capture', side_effect=capture), mock.patch.object(module.shutil, 'which', return_value='/fixture/sample'):
                    module.collect(Path(directory), process, {100, 200, 999}, 5)
                self.assertEqual(sampled, [100])
                results = json.loads((Path(directory)/'sampling.json').read_text())['targets']
                self.assertEqual(results[1]['status'], 'unavailable_target_exited' if change == 'exit' else 'unavailable_identity_changed')

    def test_sampling_no_debugger_failure_and_owner_exit_are_explicit(self):
        for condition in ['missing', 'failure', 'owner-exit']:
            with self.subTest(condition=condition), tempfile.TemporaryDirectory() as directory:
                module = self.sampling_module(); sampled = []
                def capture(command, timeout, outcome=None):
                    if command[0] == 'env': return self.sampling_rows((100, 1), (200, 100))
                    sampled.append(int(command[1])); outcome.update(exitCode=9, timedOut=False)
                    return 'controlled sampler failure'
                process = mock.Mock(pid=100); process.poll.return_value = 0 if condition == 'owner-exit' else None
                with mock.patch.object(module, 'capture', side_effect=capture), mock.patch.object(module.shutil, 'which', return_value=None if condition == 'missing' else '/fixture/sample'):
                    module.collect(Path(directory), process, {100, 200, 999}, 5)
                results = json.loads((Path(directory)/'sampling.json').read_text())['targets']
                expected = {'missing':'unavailable_no_debugger','failure':'failed','owner-exit':'unavailable_owner_exited'}[condition]
                self.assertTrue(all(x['status'] == expected for x in results))
                self.assertEqual(sampled, [100, 200] if condition == 'failure' else [])

    def test_sampling_detected_post_attach_identity_race_is_not_certified(self):
        module = self.sampling_module(); snapshots = []
        original = self.sampling_rows((100, 1), (200, 100))
        changed = original.replace('200 100 100 S Wed Sep 30 12:00:00 2026 child',
                                   '200 100 100 S Wed Sep 30 12:01:00 2026 child')
        def capture(command, timeout, outcome=None):
            if command[0] == 'env':
                snapshots.append(command)
                return changed if len(snapshots) >= 5 else original
            outcome.update(exitCode=0, timedOut=False)
            return 'controlled sample'
        process = mock.Mock(pid=100); process.poll.return_value = None
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(module, 'capture', side_effect=capture), mock.patch.object(module.shutil, 'which', return_value='/fixture/sample'):
                module.collect(Path(directory), process, {100, 200}, 5)
            result = json.loads((Path(directory)/'sampling.json').read_text())['targets'][1]
            self.assertEqual(result['status'], 'unavailable_identity_race')
            self.assertEqual(result['captureStatus'], 'sampled')

    def test_sampling_root_and_children_share_one_total_budget(self):
        module = self.sampling_module(); elapsed = [0.0]; allowances = []
        def capture(command, timeout, outcome=None):
            if command[0] == 'env':
                return self.sampling_rows((100, 1), (200, 100), (300, 200))
            allowances.append(timeout); elapsed[0] += timeout
            outcome.update(exitCode=-15, timedOut=True)
            return 'controlled sampling timeout'
        process = mock.Mock(pid=100); process.poll.return_value = None
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(module, 'capture', side_effect=capture), mock.patch.object(module.shutil, 'which', return_value='/fixture/sample'), mock.patch.object(module.time, 'monotonic', side_effect=lambda:elapsed[0]):
                module.collect(Path(directory), process, {100, 200, 300, 999}, 6)
            self.assertEqual(allowances, [2, 2, 2])
            results = json.loads((Path(directory)/'sampling.json').read_text())['targets']
            self.assertEqual([x['pid'] for x in results], [100, 300, 200])
            self.assertTrue(all(x['status'] == 'timeout' for x in results))

    def sampling_module(self):
        spec = importlib.util.spec_from_file_location('ci_sampling_fixture', STAGE)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        return module

    def sampling_rows(self, *pairs):
        return '\n'.join(f'{pid} {parent} 100 S Wed Sep 30 12:00:00 2026 '+('root' if pid == 100 else 'child') for pid,parent in pairs)+'\n'

    def test_sampling_uses_live_owned_tree_after_later_child_exits(self):
        spec = importlib.util.spec_from_file_location('ci_sampling_fixture', STAGE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        worker = """import subprocess,sys,json
long = subprocess.Popen([sys.executable, '-c', 'import sys; sys.stdin.read()'], stdin=subprocess.PIPE)
short = subprocess.Popen([sys.executable, '-c', 'import sys; sys.stdin.read()'], stdin=subprocess.PIPE)
print(json.dumps([long.pid, short.pid]), flush=True)
sys.stdin.readline()
short.stdin.close(); short.wait()
print('short exited', flush=True)
sys.stdin.read()
long.stdin.close(); long.wait()
"""
        root = subprocess.Popen([sys.executable, '-u', '-c', worker], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            self.assertTrue(select.select([root.stdout], [], [], 10)[0])
            long, short = json.loads(root.stdout.readline())
            observed, _ = module.process_tree(root.pid)
            self.assertIn(short, observed)
            root.stdin.write('exit short\n'); root.stdin.flush()
            self.assertTrue(select.select([root.stdout], [], [], 10)[0])
            self.assertEqual(root.stdout.readline().strip(), 'short exited')
            # The OS fixture creates this PID later; no sleeps or PID-size depth assumption.
            self.assertEqual(max(observed), short)
            with tempfile.TemporaryDirectory() as directory:
                directory = Path(directory)
                sample = directory / 'sample'
                sample.write_text('#!' + sys.executable + '\nimport os,sys\n'
                                  "with open(os.environ['SAMPLE_TARGETS'],'a') as f:f.write(sys.argv[1]+'\\n')\n"
                                  "try:os.kill(int(sys.argv[1]),0)\nexcept ProcessLookupError:sys.exit(9)\n")
                sample.chmod(0o755)
                targets = directory / 'targets'
                with mock.patch.dict(os.environ, PATH=str(directory)+os.pathsep+os.environ['PATH'],
                                     SAMPLE_TARGETS=str(targets)):
                    history = module.collect(directory, root, observed, 5)
                sampled = {int(x) for x in targets.read_text().splitlines()}
                self.assertIn(long, sampled, 'still-live owned child must be sampled')
                self.assertIn(root.pid, sampled, 'root is also relevant evidence')
                self.assertNotIn(short, sampled, 'exited historical maximum is not a sampling target')
                self.assertIn(short, history, 'historical observations remain retained')
        finally:
            root.stdin.close()
            if root.poll() is None:
                try: root.wait(timeout=5)
                except subprocess.TimeoutExpired: module.terminate_group(root)
            root.stdout.close()

    def test_terminal_audit_gate_is_owned_and_tee_directory_exists_before_dispatch(self):
        for name in ['ci-macos.sh', 'ci-linux.sh']:
            script = STAGE.with_name(name).read_text()
            audit = script.index('run_stage audited-authorization env ')
            self.assertLess(script.index('mkdir -p .build/ci-logs'), audit)

    def test_artifact_upload_explicitly_includes_only_ci_evidence_paths(self):
        workflow = (STAGE.parent.parent / '.github/workflows/ci.yml').read_text()
        uploads = workflow.split('uses: actions/upload-artifact@v4')[1:]
        self.assertEqual(len(uploads), 2)
        for upload in uploads:
            block = upload.split('      - name:', 1)[0]
            self.assertIn('include-hidden-files: true', block)
            paths = block.split('          path: |\n', 1)[1].split('          if-no-files-found:', 1)[0]
            self.assertEqual([line.strip() for line in paths.splitlines()], [
                '.build/ci-logs/', '.ci-logs/', '.build/execution-reporting-acceptance.json'])

    def test_success_and_each_attempt_keeps_its_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            for _ in range(2):
                result = subprocess.run([sys.executable, str(STAGE), "--stage", "success", "--log-dir", directory,
                                         "--timeout", "20", "--", sys.executable, "-c", "print('fixture pass')"], capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
            entries = list(Path(directory).glob("*/metadata.json"))
            self.assertEqual(len(entries), 2)
            for entry in entries:
                data = json.loads(entry.read_text())
                self.assertEqual(data["result"], "pass")
                self.assertEqual(data["exitCode"], 0)
                self.assertEqual(len(data["sourceCommitSHA"]), 40)
                self.assertEqual(len(data["sourceTreeSHA"]), 40)

    def test_timeout_has_ready_barrier_and_does_not_kill_unrelated_child(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE)
        try:
            with tempfile.TemporaryDirectory() as directory:
                ready = Path(directory) / "ready"
                # Ready is published before the owned worker blocks in an actual read.
                worker = "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(str(__import__('os').getpid())); sys.stdin.read()"
                pipe = subprocess.PIPE
                runner = subprocess.Popen([sys.executable, str(STAGE), "--stage", "blocked", "--log-dir", directory,
                                           "--timeout", "3", "--evidence-timeout", "1", "--", sys.executable, "-c", worker, str(ready)],
                                          stdin=pipe, stdout=pipe, stderr=pipe)
                out, err = self.wait_without_closing_barrier(runner)
                self.assertEqual(runner.returncode, 124, (out, err))
                self.assertTrue(ready.exists(), "timeout must reach the controlled worker")
                metadata = json.loads(next(Path(directory).glob("*/metadata.json")).read_text())
                self.assertEqual(metadata["result"], "timeout")
                self.assertEqual(metadata["exitCode"], 124)
                self.assertIn(int(ready.read_text()), metadata["observedPIDs"])
                self.assertIsNone(unrelated.poll())
                self.assertTrue(next(Path(directory).glob("*/processes.txt")).exists())
        finally:
            unrelated.stdin.close()
            unrelated.wait(timeout=10)

    def test_core_build_before_execution_reporting_is_bounded_and_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            executable = directory / "swift"
            ready = directory / "ready"
            executable.write_text("#!/usr/bin/env python3\nimport os,pathlib,sys\nif '--version' in sys.argv:\n print('Swift version 6.4'); sys.exit(0)\nif sys.argv[1:3] == ['package','clean']:sys.exit(0)\npathlib.Path(os.environ['FIXTURE_READY']).write_text('core build entered')\nsys.stdin.read()\n")
            executable.chmod(0o755)
            env = os.environ.copy()
            env.update(PATH=str(directory) + os.pathsep + env['PATH'], FIXTURE_READY=str(ready),
                       SWIFT_AGENT_CI_CASE_TIMEOUT_SECONDS='2', SWIFT_AGENT_CI_STAGE_LOG_DIR=str(directory / 'inner'))
            runner = subprocess.Popen([sys.executable, str(STAGE), '--stage', 'outer-test-owner', '--log-dir', str(directory / 'outer'),
                                       '--timeout', '8', '--evidence-timeout', '1', '--', 'bash', str(STAGE.with_name('ci-linux.sh'))],
                                      env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            out, err = self.wait_without_closing_barrier(runner)
            self.assertTrue(ready.exists())
            self.assertEqual(runner.returncode, 124, (out, err))
            records = list((directory / 'inner').glob('core-build-AgentModels-*/metadata.json'))
            self.assertEqual(len(records), 1, 'core stage needs its own evidence before reporting script')
            self.assertEqual(json.loads(records[0].read_text())['result'], 'timeout')

    def test_cancellation_and_noncooperative_descendant_are_owned_until_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            fifo = directory / 'ready-fifo'
            os.mkfifo(fifo)
            ready_reader = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
            worker = "import subprocess,sys; child=subprocess.Popen([sys.executable,'-c',\"import os,signal,sys; signal.signal(signal.SIGTERM,signal.SIG_IGN); f=open(sys.argv[1],'w'); f.write(str(os.getpid())); f.close(); sys.stdin.read()\",sys.argv[1]]); sys.stdin.read()"
            runner = subprocess.Popen([sys.executable, str(STAGE), '--stage', 'cancellation', '--log-dir', str(directory / 'evidence'),
                                       '--timeout', '30', '--evidence-timeout', '1', '--', sys.executable, '-c', worker, str(fifo)],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                readable, _, _ = select.select([ready_reader], [], [], 10)
                self.assertTrue(readable, 'actual owned child publishes readiness')
                descendant = int(os.read(ready_reader, 64))
                runner.send_signal(signal.SIGTERM)
                out, err = self.wait_without_closing_barrier(runner)
                self.assertEqual(runner.returncode, 130, (out, err))
                data = json.loads(next((directory / 'evidence').glob('*/metadata.json')).read_text())
                self.assertEqual(data['result'], 'cancelled')
                self.assertIn(descendant, data['observedPIDs'])
                # No running descendant; a short-lived reparented zombie may await OS reaping.
                listing = subprocess.run(['ps', '-o', 'stat=', '-p', str(descendant)], capture_output=True, timeout=2).stdout.decode().strip()
                self.assertTrue(not listing or listing.startswith('Z'), listing)
            finally:
                os.close(ready_reader)
                if runner.poll() is None:
                    runner.send_signal(signal.SIGTERM); runner.wait(timeout=20)

    def test_evidence_write_failure_releases_actual_owned_worker(self):
        spec = importlib.util.spec_from_file_location('ci_stage_fixture', STAGE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original_handler = signal.getsignal(signal.SIGTERM)
        original_popen = module.subprocess.Popen
        original_write = module.Path.write_text
        processes = []
        def launch(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            processes.append(process)
            return process
        def fail_metadata(path, text, *args, **kwargs):
            if path.name == 'metadata.json':
                raise OSError('controlled evidence write failure')
            return original_write(path, text, *args, **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            fifo = Path(directory) / 'blocked'
            os.mkfifo(fifo)
            args = argparse.Namespace(stage='write-failure', log_dir=directory, timeout=30, evidence_timeout=1,
                command=[sys.executable, '-c', 'import os,sys; os.open(sys.argv[1],os.O_RDONLY)', str(fifo)])
            try:
                with mock.patch.object(module.subprocess, 'Popen', side_effect=launch), mock.patch.object(module.Path, 'write_text', new=fail_metadata):
                    with self.assertRaises(OSError):
                        module.run(args)
                self.assertIsNotNone(processes[-1].poll(), 'failed evidence cannot abandon the owned worker')
                self.assertEqual(signal.getsignal(signal.SIGTERM), original_handler)
            finally:
                for process in processes:
                    if process.poll() is None:
                        module.terminate_group(process)

    def test_actual_swift_package_clean_does_not_erase_its_stage_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Scripts').mkdir()
            script = root / 'Scripts/ci_stage.py'
            shutil.copyfile(STAGE, script)
            (root / 'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "CleanFixture")\n')
            subprocess.run(['git', 'init', '--quiet'], cwd=root, check=True)
            subprocess.run(['git', 'add', '.'], cwd=root, check=True)
            subprocess.run(['git', '-c', 'user.name=CI Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'fixture'], cwd=root, check=True)
            result = subprocess.run([sys.executable, str(script), '--stage', 'package-clean', '--timeout', '30', '--',
                                     'swift', 'package', 'clean'], cwd=root, capture_output=True, timeout=45)
            self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
            records = list((root / '.ci-logs').glob('stages/package-clean-*/metadata.json'))
            self.assertEqual(len(records), 1, 'logs must live outside SwiftPM clean output')
            self.assertEqual(json.loads(records[0].read_text())['exitCode'], 0)

    def wait_without_closing_barrier(self, runner):
        # stdin stays open: closing it would falsely make the blocked test pass.
        runner.wait(timeout=20)
        runner.stdin.close()
        out, err = runner.stdout.read(), runner.stderr.read()
        runner.stdout.close(); runner.stderr.close()
        return out, err

if __name__ == "__main__":
    unittest.main()
