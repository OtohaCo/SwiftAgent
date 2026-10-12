#!/usr/bin/env python3
"""Verify bounded sibling-process stack capture on the isolated Linux CI runner."""
import subprocess
import sys

from ci_stage import has_gdb_backtrace


def main():
    child = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"],
                             stdin=subprocess.PIPE)
    try:
        result = subprocess.run(["gdb", "-p", str(child.pid), "-batch", "-ex", "thread apply all bt"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=10)
        print(result.stdout, flush=True)
        if result.returncode != 0 or not has_gdb_backtrace(result.stdout):
            raise RuntimeError("Linux stack sampler cannot capture a live child; check ptrace permissions.")
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


if __name__ == "__main__":
    main()
