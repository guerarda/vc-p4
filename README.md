# vc-p4

An experimental native Perforce backend for Emacs VC, targeting Emacs 30.1+.
The first milestone is diff-hl highlighting against each file's synced revision.

## Current status

The M1 candidate has real-server and diff-hl tests on Emacs 30.2 and 31.1.
It supports discovery, accurate have-revision state, byte-preserving pristine
retrieval, unified diff, saved/unsaved gutters and explicit cache refresh.
Workspace and GUI validation remains a separate smoke check.

Checkout/add/revert/submit through VC remain unsupported. Use the P4 CLI for
mutations. Cold queries are synchronous; disable diff-hl async updates. Windows,
TRAMP, Unicode-mode servers, complex overlays and UTF-16 textual gutters are
not validated/supported yet. See [DEVELOPMENT.md](DEVELOPMENT.md) for details.

## Development

Requirements: Emacs 30.1+, GNU Make (or compatible make), and a `diff` executable
supporting `--label`. Python 3.9+ and P4 binaries are needed for the server fixture.

```sh
make check EMACS=/path/to/emacs
make test-diff-hl EMACS=/path/to/emacs DIFF_HL_DIR=/path/to/diff-hl
python3 scripts/p4_fixture.py --p4 /path/to/p4 --p4d /path/to/p4d --emacs /path/to/emacs
```

`make check` byte-compiles with warnings treated as errors and runs 26 tests.
`test-diff-hl` runs those plus three consumer tests (29 total). No tests use a
personal P4 server. The Python fixture creates its own server, users and clients
under a temporary directory, verifies the server root, and shuts it down on exit.
Its initial history leaves Alice at revision 1 while Bob submits revision 2;
Alice's local edit must still be compared with revision 1.

For a local experimental installation (see [VALIDATION.md](VALIDATION.md) for
the complete workspace checklist and rollback):

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
