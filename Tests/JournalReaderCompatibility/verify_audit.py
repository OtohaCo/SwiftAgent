#!/usr/bin/env python3
"""Actual immutable RC5 reader vs the RC6 candidate. All stores are disposable."""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import uuid
from verify import digest_tree, run, verify


def main():
    old, candidate, old_binary, new_binary = map(pathlib.Path, sys.argv[1:])
    sha = lambda p: subprocess.check_output(["git", "-C", str(p), "rev-parse", "HEAD"], text=True).strip()
    tree = lambda p: subprocess.check_output(["git", "-C", str(p), "rev-parse", "HEAD^{tree}"], text=True).strip()
    verify(sha(old) == "24447b8298ccea84f9f8056374857c5c47d8f64c", "RC5 baseline must be immutable")
    verify(tree(old) == "f3fbd3297f5b776cbe0ad22681d89ebd2469d3bf", "RC5 tree must be immutable")
    evidence = {"baselineSHA": sha(old), "baselineTree": tree(old), "candidateSHA": sha(candidate), "candidateTree": tree(candidate), "cases": {}}
    session = uuid.uuid4()
    with tempfile.TemporaryDirectory(prefix="swiftagent-audit-readers-") as temporary:
        root = pathlib.Path(temporary)
        for mode in ["create-default", "create-capable-without-rejection"]:
            original = root / (mode + "-rc5")
            verify(run(old_binary, mode, original, session)["exit"] == 0, "RC5 must create store")
            for action in ["inspect", "append", "maintain"]:
                result = run(new_binary, action, original, session)
                evidence["cases"][f"new_{action}_old_{mode}"] = result
                verify(result["exit"] == 0, "new reader must preserve RC5 stores")
            new_store = root / (mode + "-rc6")
            verify(run(new_binary, mode, new_store, session)["exit"] == 0, "candidate must create ordinary store")
            for action in ["inspect", "append", "maintain"]:
                result = run(old_binary, action, new_store, session)
                evidence["cases"][f"old_{action}_new_{mode}"] = result
                verify(result["exit"] == 0, "ordinary schema 3/4 must remain compatible")
        for mode in ["create-audit-empty", "create-audit-denial"]:
            store = root / mode
            result = run(new_binary, mode, store, session)
            verify(result["exit"] == 0, f"audit store creation failed: {result}")
            verify(json.loads((store / "format.json").read_text())["schema"] == 5, "schema 5 must be reserved at creation")
            for action in ["inspect", "append", "maintain"]:
                copy = root / f"{mode}-{action}"
                shutil.copytree(store, copy)
                before = digest_tree(copy)
                result = run(old_binary, action, copy, session)
                evidence["cases"][f"old_{action}_{mode}"] = result | {"untouched": digest_tree(copy) == before}
                verify(result["exit"] != 0 and "unsupportedFormat" in result["output"] and digest_tree(copy) == before,
                       "the original reader must reject schema 5 without writes")
            for action in ["maintain", "inspect"]:
                result = run(new_binary, action, store, session)
                evidence["cases"][f"new_{action}_{mode}"] = result
                verify(result["exit"] == 0, "audit store must survive maintenance")
                if mode == "create-audit-denial": verify("deny=1" in result["output"], "typed denial must remain")
    print(json.dumps(evidence, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
