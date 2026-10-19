# vc-p4

An experimental native Perforce backend for Emacs VC, targeting Emacs 30.1+.
The first milestone is diff-hl highlighting against each file's synced revision.

## Current status

The existing backend prototype now has automated contract tests and saved/unsaved
diff-hl overlay tests. Those tests mock P4 metadata/content retrieval; they are
not evidence of real-server compatibility. The disposable-server harness is
prepared but has not yet run because `p4` and `p4d` are unavailable here.
Do not treat this as a completed milestone or a production-ready backend.

Implemented prototype: CLI runner, structured metadata parsing, discovery,
state, have-revision retrieval, cached base contents, local unified diff and
explicit cache refresh. Checkout/add/revert/submit through VC deliberately
report unsupported operations. Continue using the P4 CLI for mutations.

Open limitations include complex client mappings, P4CONFIG changes and cache
identity, file-type/encoding translation, behind-head state semantics,
async diff, and the full real-server edge-case matrix. Windows and TRAMP are
not currently validated. There is no automatic background server polling.

## Development

Requirements: Emacs 30.1+, GNU Make (or compatible make), and a `diff` executable
supporting `--label`. Python 3.9+ and P4 binaries are needed for the server fixture.

```sh
make check EMACS=/path/to/emacs
make test-diff-hl EMACS=/path/to/emacs DIFF_HL_DIR=/path/to/diff-hl
python3 scripts/p4_fixture.py --p4 /path/to/p4 --p4d /path/to/p4d --emacs /path/to/emacs
```

`make check` byte-compiles with warnings treated as errors and runs 21 tests.
`test-diff-hl` runs those plus two consumer tests (23 total). No tests use a
personal P4 server. The Python fixture creates its own server, users and clients
under a temporary directory, verifies the server root, and shuts it down on exit.
Its initial history leaves Alice at revision 1 while Bob submits revision 2;
Alice's local edit must still be compared with revision 1.

For a local experimental installation:

```elisp
(add-to-list 'load-path "/path/to/p4vc")
(require 'vc-p4)
(require 'diff-hl)
(global-diff-hl-mode 1)
;; Optional unsaved-buffer highlighting:
(diff-hl-flydiff-mode 1)
```

Configure the P4 CLI as usual. Use `M-x vc-p4-refresh` after external workspace
changes. Keep diff-hl async updates disabled for this initial prototype.

See [DEVELOPMENT.md](DEVELOPMENT.md) for validation evidence and current limits.
