#!/usr/bin/env python3
"""Exercise whole stores with binaries compiled against immutable RC4 and the candidate SDK."""
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid


def run(binary, mode, store, session):
    result = subprocess.run([str(binary), mode, str(store), str(session)],
                            capture_output=True, text=True, timeout=45)
    return {"exit": result.returncode, "output": (result.stdout + result.stderr).strip()}


def digest_tree(store):
    files = {}
    for file in sorted(store.rglob("*")):
        if file.is_file() and file.name != ".writer.lock":
            files[str(file.relative_to(store))] = hashlib.sha256(file.read_bytes()).hexdigest()
    return files


def verify(condition, message):
    if not condition:
        raise AssertionError(message)


def fields(result):
    return dict(re.findall(r"([A-Za-z]+)=([^\s]+)", result["output"]))


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: verify.py RC4_CHECKOUT NEW_CHECKOUT RC4_BINARY NEW_BINARY")
    old_checkout, new_checkout, old_bin, new_bin = map(pathlib.Path, sys.argv[1:])
    old_sha = subprocess.check_output(["git", "-C", str(old_checkout), "rev-parse", "HEAD"], text=True).strip()
    verify(old_sha == "3f01599ef3d0923659226025a7d34d4144ed1800", "old reader must be original RC4")
    new_sha = subprocess.check_output(["git", "-C", str(new_checkout), "rev-parse", "HEAD"], text=True).strip()
    results = {"oldSDK": old_sha, "newSDK": new_sha,
               "oldTree": subprocess.check_output(["git", "-C", str(old_checkout), "rev-parse", "HEAD^{tree}"], text=True).strip(),
               "newTree": subprocess.check_output(["git", "-C", str(new_checkout), "rev-parse", "HEAD^{tree}"], text=True).strip()}
    with tempfile.TemporaryDirectory(prefix="swiftagent-reader-matrix-") as temporary:
        root = pathlib.Path(temporary)
        session = uuid.uuid4()
        old_store, new_store, capable, rejected = [root / name for name in (
            "rc4-store", "new-default", "new-capable-no-rejection", "new-rejection")]

        results["oldCreatesOrdinary"] = run(old_bin, "create-default", old_store, session)
        results["newReadsOld"] = run(new_bin, "inspect", old_store, session)
        copy = root / "old-copy"
        shutil.copytree(old_store, copy)
        old_copy_before = digest_tree(copy)
        old_copy_root = json.loads((copy / "CURRENT").read_text())["root"]
        results["newAppendsOldCopy"] = run(new_bin, "append", copy, session)
        results["newAppendOldRootChanged"] = old_copy_root != json.loads((copy / "CURRENT").read_text())["root"]
        results["newAppendOldFilesChanged"] = old_copy_before != digest_tree(copy)
        results["newMaintainsOldCopy"] = run(new_bin, "maintain", copy, session)
        verify(results["oldCreatesOrdinary"]["exit"] == results["newReadsOld"]["exit"] ==
               results["newAppendsOldCopy"]["exit"] == results["newMaintainsOldCopy"]["exit"] == 0,
               "new reader must preserve RC4 ordinary store")
        verify(results["newAppendOldRootChanged"] and results["newAppendOldFilesChanged"] and
               fields(results["newReadsOld"])["storeID"] == fields(results["newAppendsOldCopy"])["storeID"] and
               int(fields(results["newAppendsOldCopy"])["messages"]) >
               int(fields(results["newReadsOld"])["messages"]), "new append must change content, not identity")

        results["newCreatesOrdinary"] = run(new_bin, "create-default", new_store, session)
        results["oldReadsNewOrdinary"] = run(old_bin, "inspect", new_store, session)
        copy = root / "new-default-copy"
        shutil.copytree(new_store, copy)
        new_default_before = digest_tree(copy)
        new_default_root = json.loads((copy / "CURRENT").read_text())["root"]
        results["oldAppendsNewOrdinaryCopy"] = run(old_bin, "append", copy, session)
        results["oldAppendNewDefaultRootChanged"] = new_default_root != json.loads((copy / "CURRENT").read_text())["root"]
        results["oldAppendNewDefaultFilesChanged"] = new_default_before != digest_tree(copy)
        results["oldMaintainsNewOrdinaryCopy"] = run(old_bin, "maintain", copy, session)
        verify(results["newCreatesOrdinary"]["exit"] == results["oldReadsNewOrdinary"]["exit"] ==
               results["oldAppendsNewOrdinaryCopy"]["exit"] == results["oldMaintainsNewOrdinaryCopy"]["exit"] == 0,
               "default store must retain RC4 disk encoding")
        verify(results["oldAppendNewDefaultRootChanged"] and results["oldAppendNewDefaultFilesChanged"] and
               fields(results["oldReadsNewOrdinary"])["storeID"] ==
               fields(results["oldAppendsNewOrdinaryCopy"])["storeID"] and
               int(fields(results["oldAppendsNewOrdinaryCopy"])["messages"]) >
               int(fields(results["oldReadsNewOrdinary"])["messages"]),
               "old append must change content, not identity")

        results["newCreatesCapableWithoutRejection"] = run(new_bin, "create-capable-without-rejection", capable, session)
        results["oldReadsCapableWithoutRejection"] = run(old_bin, "inspect", capable, session)
        copy = root / "capable-copy"
        shutil.copytree(capable, copy)
        before_capable = digest_tree(copy)
        results["oldAppendsCapableCopy"] = run(old_bin, "append", copy, session)
        results["oldRefusalCapableLeftStoreUntouched"] = before_capable == digest_tree(copy)
        verify(results["newCreatesCapableWithoutRejection"]["exit"] == 0 and
               results["oldReadsCapableWithoutRejection"]["exit"] != 0 and
               results["oldAppendsCapableCopy"]["exit"] != 0 and
               results["oldRefusalCapableLeftStoreUntouched"],
               "opt-in capable format is reserved at creation even before a rejection")

        results["newCreatesRejection"] = run(new_bin, "create-rejection", rejected, session)
        results["newReadsRejection"] = run(new_bin, "inspect", rejected, session)
        copy = root / "rejection-copy"
        shutil.copytree(rejected, copy)
        before = digest_tree(copy)
        results["oldReadsRejection"] = run(old_bin, "inspect", copy, session)
        results["oldAppendsRejectionCopy"] = run(old_bin, "append", copy, session)
        results["oldRefusalLeftStoreUntouched"] = before == digest_tree(copy)
        verify(results["newCreatesRejection"]["exit"] == results["newReadsRejection"]["exit"] == 0,
               "new reader must restore rejection store")
        verify(results["oldReadsRejection"]["exit"] != 0 and
               results["oldAppendsRejectionCopy"]["exit"] != 0 and
               "unsupportedFormat" in results["oldReadsRejection"]["output"] and
               results["oldRefusalLeftStoreUntouched"], "RC4 reader must reject without changing store")
        results["newMaintainsRejection"] = run(new_bin, "maintain", rejected, session)
        results["newReadsAfterMaintenance"] = run(new_bin, "inspect", rejected, session)
        verify(results["newMaintainsRejection"]["exit"] == results["newReadsAfterMaintenance"]["exit"] == 0,
               "new reader must retain the store after maintenance")
        verify(fields(results["newReadsRejection"])["storeID"] ==
               fields(results["newReadsAfterMaintenance"])["storeID"] and
               fields(results["newReadsRejection"])["messages"] ==
               fields(results["newReadsAfterMaintenance"])["messages"] and
               fields(results["newReadsAfterMaintenance"])["rejectedMutation"] == "none",
               "maintenance must retain identity and formal history without inventing mutation")
        results["rootAndFormat"] = {}
        for label, store in (("rc4", old_store), ("newDefault", new_store),
                             ("newCapableNoRejection", capable), ("newRejection", rejected)):
            current = json.loads((store / "CURRENT").read_text())
            fmt = json.loads((store / "format.json").read_text())
            results["rootAndFormat"][label] = {"root": current["root"], "storeID": fmt["storeID"],
                                               "schema": fmt["schema"], "files": len(digest_tree(store))}
    print(json.dumps(results, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
