#!/usr/bin/env python3
"""Run a disposable two-workspace P4 fixture and Emacs integration tests.

Requires p4 and p4d; never connects to an existing server. Server launch flags:
https://help.perforce.com/helix-core/server-apps/p4sag/current/Content/P4SAG/appendix.p4d.html
"""
import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent


def executable(value):
    found = shutil.which(value)
    if not found:
        raise ValueError(f"Missing executable: {value}. Supply --p4/--p4d/--emacs paths.")
    return str(Path(found).resolve())


def run_fixture(args):
    p4, p4d, emacs = map(executable, (args.p4, args.p4d, args.emacs))
    with tempfile.TemporaryDirectory(prefix="vc-p4-fixture-") as temp:
        root = Path(temp)
        server = root / "server"
        server.mkdir()
        # Select a loopback port. Fail on a startup race rather than attaching
        # to an existing service; readiness also verifies serverRoot below.
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = f"127.0.0.1:{sock.getsockname()[1]}"
        env = {k: v for k, v in os.environ.items() if not k.upper().startswith("P4")}
        env.update(P4PORT=port, P4USER="alice", P4CLIENT="alice-client",
                   P4CONFIG=".vc-p4-test-config", P4ENVIRO=str(root / "enviro"),
                   P4TICKETS=str(root / "tickets"), P4TRUST=str(root / "trust"))

        def p4run(*cmd, user="alice", text=None):
            return subprocess.run(
                [p4, "-p", port, "-u", user, "-c", f"{user}-client", *cmd],
                input=text, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                cwd=root, env=env, check=True, timeout=10).stdout

        with (root / "server-output").open("w") as output:
            process = subprocess.Popen(
                [p4d, "-r", str(server), "-p", port, "-L", str(root / "server.log"),
                 "-J", str(root / "journal")], cwd=root, env=env,
                stdout=output, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 10
                while True:
                    if process.poll() is not None:
                        raise RuntimeError("Fixture server exited during startup")
                    try:
                        info = p4run("-ztag", "info")
                        if f"... serverRoot {server}" not in info:
                            raise RuntimeError("Refusing unexpected server root")
                        break
                    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                        if time.monotonic() >= deadline:
                            raise RuntimeError("Fixture server did not become ready")
                        time.sleep(0.1)
                for user in ("alice", "bob"):
                    workspace = root / user
                    workspace.mkdir()
                    p4run("user", "-i", user=user, text=(
                        f"User: {user}\nEmail: {user}@example.invalid\nFullName: {user}\n"))
                    p4run("client", "-i", user=user, text=(
                        f"Client: {user}-client\nOwner: {user}\nRoot: {workspace}\n"
                        "Options: noallwrite noclobber nocompress unlocked nomodtime normdir\n"
                        "LineEnd: unix\nView:\n"
                        f"\t//depot/... //{user}-client/...\n"))
                alice_file = root / "alice" / "sample.txt"
                alice_file.write_text("one\ntwo\nthree\n", encoding="utf-8")
                p4run("add", str(alice_file))
                p4run("submit", "-d", "fixture: initial contents")
                p4run("sync", "//depot/...", user="bob")
                bob_file = root / "bob" / "sample.txt"
                p4run("edit", str(bob_file), user="bob")
                bob_file.write_text("one\nnew depot line\nthree\n", encoding="utf-8")
                p4run("submit", "-d", "fixture: advance depot head", user="bob")
                p4run("edit", str(alice_file))
                alice_file.write_text("one\nlocal edit\nthree\n", encoding="utf-8")
                test_env = dict(env, VC_P4_TEST_FILE=str(alice_file), VC_P4_PROGRAM=p4)
                subprocess.run(
                    [emacs, "-Q", "--batch", "-L", str(REPO), "-L", str(REPO / "test"),
                     "-l", "vc-p4-integration-tests", "-f", "ert-run-tests-batch-and-exit"],
                    cwd=root, env=test_env, check=True, timeout=60)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                if (root / "server.log").exists() and process.returncode not in (0, -15):
                    print((root / "server.log").read_text(errors="replace")[-4000:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--p4", default="p4")
    parser.add_argument("--p4d", default="p4d")
    parser.add_argument("--emacs", default="emacs")
    args = parser.parse_args()
    try:
        run_fixture(args)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"P4 integration failed: {error}\n")


if __name__ == "__main__":
    main()
