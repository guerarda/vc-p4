#!/usr/bin/env python3
"""Deterministic slow/failing P4 and diff substitute for responsiveness tests."""
import json
import os
import subprocess
import sys
import time

mode = os.environ.get("VC_P4_FAULT_MODE", "normal")
time.sleep(float(os.environ.get("VC_P4_FAULT_DELAY", "0")))
if mode == "hang":
    time.sleep(60)
if mode in {"auth", "outage"}:
    print("Login expired" if mode == "auth" else "TCP connect failed", file=sys.stderr)
    sys.exit(1)
args = [arg for arg in sys.argv[1:] if arg not in {"-Mj", "-ztag"}]
if args and args[0] in {"edit", "add", "revert", "delete", "sync"}:
    print(json.dumps({"action": args[0], "clientFile": args[-1]}))
elif args and args[0] in {"fstat", "where", "info", "client", "print"}:
    command = args[0]
    if command == "print":
        sys.stdout.buffer.write(b"one\ntwo\nthree\n")
    else:
        record = {
            "fstat": {"clientFile": args[-1], "depotFile": "//test/file", "haveRev": "1", "headRev": "1"},
            "where": {"path": args[-1]},
            "info": {"clientRoot": os.getcwd()},
            "client": {"Options": "allwrite"},
        }[command]
        if command == "fstat" and os.environ.get("VC_P4_FAULT_ACTION"):
            record["action"] = os.environ["VC_P4_FAULT_ACTION"]
        print(json.dumps(record))
else:
    if mode == "dos-diff":
        # Simulate Windows text-mode stdout, independently of input file bytes.
        result = subprocess.run(["diff", *sys.argv[1:]], stdout=subprocess.PIPE)
        sys.stdout.buffer.write(result.stdout.replace(b"\n", b"\r\n"))
        sys.exit(result.returncode)
    os.execvp("diff", ["diff", *sys.argv[1:]])
