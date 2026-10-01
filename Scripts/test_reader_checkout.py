"""Actual checkout helper regression; local Git only, no network or SDK mocks."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).with_name("checkout-reader-baseline.sh")


def git(*args):
    return subprocess.check_output(["git", *map(str, args)], text=True, stderr=subprocess.PIPE).strip()


class ReaderCheckoutTests(unittest.TestCase):
    def test_shallow_fetch_head_baseline_is_explicitly_fetched_in_reader(self):
        with tempfile.TemporaryDirectory(prefix="reader-checkout-") as temporary:
            root = Path(temporary)
            source, shallow, reader = (root / name for name in ["source", "shallow", "reader"])
            git("init", "--quiet", "--initial-branch=main", source)
            git("-C", source, "config", "user.name", "Synthetic fixture")
            git("-C", source, "config", "user.email", "fixture@example.invalid")
            commits = []
            for text in ["initial", "reader baseline", "candidate"]:
                (source / "version").write_text(text)
                git("-C", source, "add", "version")
                git("-C", source, "commit", "--quiet", "-m", text)
                commits.append(git("-C", source, "rev-parse", "HEAD"))
            baseline = commits[1]
            expected_tree = git("-C", source, "rev-parse", baseline + "^{tree}")
            git("clone", "--quiet", "--no-local", "--depth=1", "--single-branch", source, shallow)
            git("-C", shallow, "fetch", "--quiet", "origin", baseline)
            self.assertEqual(git("-C", shallow, "rev-parse", "FETCH_HEAD"), baseline)
            subprocess.run(["bash", str(HELPER), str(shallow), str(reader), baseline], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(git("-C", reader, "rev-parse", "HEAD"), baseline)
            self.assertEqual(git("-C", reader, "rev-parse", "HEAD^{tree}"), expected_tree)
            self.assertEqual((reader / "version").read_text(), "reader baseline")
            self.assertEqual(git("-C", shallow, "rev-parse", "HEAD"), commits[2])
            self.assertEqual(git("-C", shallow, "status", "--porcelain"), "")

    def test_invalid_commit_is_rejected_before_creating_a_checkout(self):
        with tempfile.TemporaryDirectory(prefix="reader-checkout-invalid-") as temporary:
            destination = Path(temporary) / "reader"
            result = subprocess.run(["bash", str(HELPER), temporary, str(destination), "main"],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 64)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
