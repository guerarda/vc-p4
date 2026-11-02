# vc-p4

Perforce support for Emacs VC, with **diff-hl gutter highlighting** for local
workspaces.

Changes are compared with each file's synced Perforce revision (`#have`), so
newer changes in the depot do not appear as your local edits. The backend uses
the `p4` command-line client and integrates with Emacs's built-in VC interface.

**Status: experimental.** Gutter highlighting and read-only VC operations are
implemented. Continue using the P4 CLI for checkout, add, revert and submit;
those operations are not yet implemented through VC.

## Features

- Saved-file change, insertion and deletion markers through diff-hl.
- Optional unsaved-buffer highlighting through diff-hl-flydiff.
- Workspace discovery and VC states for local edits, additions, deletions,
  missing files, outdated revisions and unresolved conflicts.
- Pristine revision retrieval and unified diffs against the synced revision.
- Cached revision contents and explicit refresh after external P4 commands.

## Requirements

- Emacs 30.1 or later.
- The `p4` CLI, configured and authenticated for your workspace.
- diff-hl, installed separately, for gutter highlighting.
- A `diff` executable on PATH that supports `--label`.

Emacs must inherit the P4 environment/configuration needed by the CLI. Run
`p4 info` from your workspace to check the selected server and client.

## Installation

Use Emacs 30's built-in `use-package` and `:vc` support to install from
[GitHub](https://github.com/guerarda/vc-p4). Git must be available on Emacs's
`exec-path`.

```elisp
(use-package vc-p4
  :vc (:url "https://github.com/guerarda/vc-p4.git"
       :rev :newest)
  ;; Uncomment if p4 is not on Emacs's exec-path:
  ;; :custom (vc-p4-program "/path/to/p4")
  :demand t)

(use-package diff-hl
  :ensure t
  :demand t
  :custom
  (diff-hl-update-async nil)
  :config
  (global-diff-hl-mode 1))
```

`:rev :newest` selects the latest commit when installing. The backend is loaded
eagerly so that VC can discover Perforce files. `diff-hl` is installed from your
configured package archives.

For unsaved-buffer highlighting, add:

```elisp
(use-package diff-hl-flydiff
  :ensure nil                         ; Included with diff-hl.
  :after diff-hl
  :config
  (diff-hl-flydiff-mode 1))
```

The current backend still waits for P4 queries; disabling async updates does
not prevent those waits. Non-blocking operation is required before the package
is recommended for everyday use.

## Usage

Open a versioned file in your Perforce workspace. If highlighting is not
already enabled for the buffer, run `M-x diff-hl-mode`. In a workspace that
requires checkout, use `p4 edit` before editing the file.

Save an edit to see its gutter marker, or enable flydiff to see unsaved changes.
Use `M-x diff-hl-next-hunk` and `M-x diff-hl-previous-hunk` to navigate changes.

After an external `p4 sync`, `p4 revert` or `p4 submit`:

1. Reload the buffer with `M-x revert-buffer` if its file changed on disk,
   preserving any unsaved work first.
2. Run `M-x vc-p4-refresh` to refresh VC state and clear backend caches.
3. Run `M-x diff-hl-update` to refresh the gutter.

For a guided check and uninstall instructions, see
[the workspace smoke check](VALIDATION.md).

## Limitations

- Checkout, add, revert and submit through Emacs VC are not implemented yet.
- P4 queries are synchronous. Keep `diff-hl-update-async` disabled. Cold queries
  can wait up to `vc-p4-command-timeout` (10 seconds per command).
- There is no background polling for external workspace changes.
- Binary files and UTF-16 files do not produce textual gutter hunks. UTF-16
  pristine revision retrieval preserves the original bytes.
- Windows, TRAMP, Unicode-mode servers, streams and complex overlay mappings
  have not been validated.

Automated tests have run on macOS arm64 with Emacs 30.2 and 31.1, P4/P4D
2024.2, and diff-hl 1.10.0, using classic workspaces with local line endings.
See [development notes](DEVELOPMENT.md) for the exact matrix and remaining
validation scope.

## Troubleshooting

If a file is not recognized, evaluate `(vc-backend buffer-file-name)` in its
buffer; a recognized Perforce file should return `P4`. Check that Emacs can
find the configured `vc-p4-program` and that the CLI selects the correct client.
Inspect `vc-p4-last-error` for the most recent discovery failure.

When reporting a problem, include Emacs, diff-hl and P4 versions, the expected
behavior, and a small reproduction. Remove credentials and private server,
user and path details from diagnostics.

## Development

Run the backend and diff-hl consumer tests with GNU Make (or a compatible make):

```sh
make check EMACS=/path/to/emacs
make test-diff-hl EMACS=/path/to/emacs DIFF_HL_DIR=/path/to/diff-hl
```

For integration tests, supply Python 3.9+, `p4`, `p4d` and a diff-hl checkout:

```sh
python3 scripts/p4_fixture.py \
  --p4 /path/to/p4 --p4d /path/to/p4d \
  --emacs /path/to/emacs --diff-hl-dir /path/to/diff-hl
```

The fixture starts a disposable local server, seeds its own history and clients,
and shuts down on exit. It does not use your existing server or project history.
On macOS arm64, `python3 scripts/install_p4.py` installs checksum-pinned test
binaries into the ignored `.tools/` directory.
