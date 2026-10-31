"""Compiler selection is tested through the executable CI script boundary."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent


class ToolchainTests(unittest.TestCase):
    def test_preinstalled_proxy_publishes_a_compiler_independent_of_reader_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            proxy = directory / 'proxy'
            compiler = directory / 'compiler'
            reader = directory / 'old-reader'
            for path in (proxy, compiler, reader):
                path.mkdir()
            (reader / '.swift-version').write_text('6.4\n')
            (proxy / 'swift').write_text(
                '#!/usr/bin/env python3\nfrom pathlib import Path\n'
                'pin = Path(".swift-version")\n'
                'version = pin.read_text().strip() if pin.exists() else "6.4.1"\n'
                'print("Swift version " + version)\n')
            (proxy / 'swiftly').write_text(
                '#!/bin/sh\n[ "$1" = run ] && [ "$2" = +6.4.1 ] || exit 1\n'
                'printf "%s\\n" "$FIXTURE_COMPILER"\n')
            (compiler / 'swift').write_text('#!/bin/sh\necho "Swift version 6.4.1"\n')
            for path in (proxy / 'swift', proxy / 'swiftly', compiler / 'swift'):
                path.chmod(0o755)
            github_path = directory / 'github-path'
            github_path.touch()
            env = dict(os.environ, PATH=str(proxy) + os.pathsep + os.environ['PATH'],
                       SWIFT_AGENT_REQUIRED_SWIFT='6.4.1', GITHUB_PATH=str(github_path),
                       FIXTURE_COMPILER=str(compiler / 'swift'))
            install = subprocess.run(['bash', str(SCRIPTS / 'install-linux-swift.sh')],
                                     cwd=directory, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(install.returncode, 0, install.stdout + install.stderr)
            # Apply the published PATH exactly as the following Actions step does.
            published = github_path.read_text().splitlines()
            env['PATH'] = os.pathsep.join(reversed(published)) + os.pathsep + env['PATH']
            result = subprocess.run(['bash', str(SCRIPTS / 'require-toolchain.sh')],
                                    cwd=reader, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(published, [str(compiler)])

    def test_patch_pin_accepts_only_the_requested_stable_version(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'swift'
            executable.write_text('#!/bin/sh\nprintf "%s\\n" "$FIXTURE_SWIFT_VERSION"\n')
            executable.chmod(0o755)
            for report, expected in [
                ('Apple Swift version 6.4.1 (swift-6.4.1-RELEASE)', 0),
                ('Swift version 6.4.1 (swift-6.4.1-RELEASE)', 0),
                ('Swift version 6.4 (swift-6.4-RELEASE)', 1),
                ('Swift version 6.4.2 (swift-6.4.2-RELEASE)', 1),
                ('Swift version 6x4x1 (invalid)', 1),
                ('Swift version 6.4.1-dev (snapshot)', 1),
                ('Swift version 6.4.1.2 (invalid)', 1),
            ]:
                with self.subTest(report=report):
                    env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'],
                               SWIFT_AGENT_REQUIRED_SWIFT='6.4.1', FIXTURE_SWIFT_VERSION=report)
                    result = subprocess.run(['bash', str(SCRIPTS / 'require-toolchain.sh')],
                                            env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    @unittest.skipUnless(sys.platform == 'darwin', 'plutil is macOS-only')
    def test_identifier_reads_standalone_and_xcode_toolchain_layouts(self):
        with tempfile.TemporaryDirectory() as directory:
            standalone = Path(directory) / 'swift-6.4.2-RELEASE.xctoolchain'
            xcode = Path(directory) / 'XcodeDefault.xctoolchain'
            for path in (standalone, xcode):
                path.mkdir()
            with (standalone / 'Info.plist').open('wb') as plist:
                plistlib.dump({'CFBundleIdentifier': 'org.swift.642'}, plist)
            # Xcode's own toolchain has no Info.plist.
            with (xcode / 'ToolchainInfo.plist').open('wb') as plist:
                plistlib.dump({'Identifier': 'com.apple.dt.toolchain.XcodeDefault'}, plist)
            for toolchain, expected in [(standalone, 'org.swift.642'),
                                        (xcode, 'com.apple.dt.toolchain.XcodeDefault')]:
                with self.subTest(toolchain=toolchain.name):
                    result = subprocess.run(
                        ['bash', '-c', '. "$1"; toolchain_identifier "$2"', '_',
                         str(SCRIPTS / 'toolchain-version.sh'), str(toolchain)],
                        capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(result.stdout.strip(), expected)


if __name__ == '__main__':
    unittest.main()
