# vc-p4

Perforce support for Emacs VC, with **diff-hl gutter highlighting** for local
workspaces.

Changes are compared with each file's synced Perforce revision (`#have`), so
newer changes in the depot do not appear as your local edits. The backend uses
the `p4` command-line client and integrates with Emacs's built-in VC interface.

**Status: experimental.** Gutter highlighting and asynchronous checkout, add,
revert, delete and move are implemented through Emacs VC. Continue using the
P4 CLI for submit, pending changelist management and other depot workflows.
File history, annotation, revision comparisons and Ediff are also available.

## Features

- Saved-file change, insertion and deletion markers through diff-hl.
- Optional unsaved-buffer highlighting through diff-hl-flydiff.
- Workspace discovery and VC states for local edits, additions, deletions,
  missing files, outdated revisions and unresolved conflicts.
- Pristine revision retrieval and unified diffs against the synced revision.
- Cached revision contents and explicit refresh after external P4 commands.
- Background discovery, revision retrieval and gutter diffs with timeouts and cancellation.
- Native VC file operations with deferred buffer updates and failure recovery.
- Native file history, revision completion and read-only revision buffers,
  including submitted move and integration ancestry.
- Native line annotation with author/date, exact source revisions and
  changelist navigation through branch, move and integration history.
- Revision-to-revision and working-text comparisons, including multiple
  unsaved buffers, plus asynchronous preparation for native Ediff.

## Requirements

- Emacs 30.1 or later.
- The `p4` CLI, configured and authenticated for your workspace.
- diff-hl, installed separately, for gutter highlighting.
- A `diff` executable on PATH that supports `--label`, and `cat` for VC completion notifications.

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
  (diff-hl-update-async t)
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

P4 gutter updates use background processes, including flydiff and cold revision
retrieval. They remain asynchronous even if another package disables
`diff-hl-update-async`. Other VC backends keep their own settings.

## Usage

Open a versioned file in your Perforce workspace. If highlighting is not
already enabled for the buffer, run `M-x diff-hl-mode`. In a workspace that
requires checkout, use `C-x v v` to open the file for edit. The buffer
becomes writable after P4 confirms the checkout. `M-x vc-p4-edit` explicitly
opens the current file for edit, including in an allwrite workspace.

Save an edit to see its gutter marker, or enable flydiff to see unsaved changes.
Use `M-x diff-hl-next-hunk` and `M-x diff-hl-previous-hunk` to navigate changes.

| Operation | Command |
| --- | --- |
| Open for edit | `C-x v v`, or `M-x vc-p4-edit` |
| Add a new file | `C-x v i` (`vc-register`) |
| Revert saved changes | `C-x v u` (`vc-revert`), with confirmation |
| Delete a tracked file | `M-x vc-delete-file`, with confirmation |
| Move a tracked or added file | `M-x vc-rename-file` |
| File history | `C-x v l` (`vc-print-log`) |
| View a revision | `C-x v ~` (`vc-revision-other-window`) |
| Submitted changes affecting this file | `M-x vc-p4-changes` |
| Describe a submitted changelist | `M-x vc-p4-describe-change` |
| Annotate the synced revision | `C-x v g` (`vc-annotate`) |
| Compare revisions or unsaved working text | `M-x vc-p4-compare` |
| Ediff revisions or unsaved working text | `M-x vc-p4-ediff`, or `M-x vc-ediff` |
| Cancel this file's operation | `M-x vc-p4-cancel-operation` |

In the history buffer, `n` and `p` move between entries; `f` opens the entry's
revision. Revisions include their depot path, such as `//depot/file#3`, while
submitted changelists are labeled `@123`. In a revision buffer, `C-c C-p` and
`C-c C-n` visit older and newer content through the displayed ancestry. Deleted
and purged revisions have no content to visit. These views fetch data in the
background and do not sync, checkout or replace working-file text.
The changelist links in file history open a submitted-change description.
Use TAB/RET in submitted-change views to open affected-file revisions; deleted
files are identified as having no content. `g` refreshes the current view.
In annotation, `f` opens a line's originating file revision, `l` shows its log,
and `C-c C-d` describes its originating changelist. Native annotation's `p`/`n`
commands browse older/newer revisions. The default is the file's HAVE revision;
unsaved working edits remain intact.
Columns show the compact `#revision`, `@changelist`, author and date. Hover over
the revision for its full depot path; navigation retains that exact identity.

Comparison prompts accept `#revision`, `//depot/path#revision` and `@changelist`.
Leave the first operand empty for each file's HAVE revision, and the second for
working text. `vc-p4-compare` includes the complete contents of visiting buffers,
even when narrowed, and can compare an explicit fileset from Lisp. A changed
source invalidates a pending working-text comparison; fixed historical operands
remain independent of later working edits. `g` captures fresh working text.

Native `vc-ediff` and `vc-version-ediff` use asynchronous P4 preparation too.
Ediff compares decoded snapshots, leaving working buffers and files untouched.
It starts only while the initiating source and focus remain current; otherwise
run it again. Unchanged snapshots are cleaned up on quit; an edited snapshot is
retained. Ediff requires text; use `vc-p4-compare` for byte-level or binary
differences. Files with different buffer-local P4 settings need separate
working-text requests. Ediff compares one file at a time.

Commands return while P4 runs. Checkout, registration and interactive revert
continue automatically when required metadata arrives. Editing the initiating
buffer or changing its workspace while waiting cancels the queued command.
Delete and move may still require retrying when their metadata is pending.
`C-x v v` opens P4 files for edit; it does not open a submit-comment window. Revert, delete and move require
saved buffers; delete also requires no local content changes. Saves of affected
files are blocked while these operations run, but typing and navigation remain
available. Completion preserves any newer buffer edits. Moving a file updates
its visiting buffer's name only after success, and reverting a move restores the
original name. Reverting an addition keeps its local contents.

Mutations refresh the affected files without clearing unrelated caches. A failed
or cancelled destructive operation retains recovery copies in a temporary
directory reported in `*Messages*`; `files.el` there maps original paths to
numbered copies. Copy out anything you need before temporary files are cleaned
by the system. Cancellation stops this client's command; P4 may already have
changed server or workspace state. Check `p4 opened` and the refreshed VC state
before retrying. For example, a failed move can leave its source opened for edit.
There is no automatic rollback of partial operations.

After an external `p4 sync`, `p4 revert` or `p4 submit`:

1. Reload the buffer with `M-x revert-buffer` if its file changed on disk,
   preserving any unsaved work first.
2. Run `M-x vc-p4-refresh` to invalidate caches and schedule fresh VC state
   and gutters. The command returns immediately; the results arrive later.

`P4?` in the mode line means work is pending; `P4!` means retrieval or diff
failed. The last gutter display remains visible until a current result arrives,
including during explicit refresh. Unchanged line markers are retained in place;
only changed markers are replaced. A confirmed clean result removes its markers.
Pending or failed data is not reported as a confirmed clean file. Closing a
buffer cancels its pending reads and diffs; explicitly cancel a mutation before
closing its buffer if you want to stop it. External sync processes are not cancelled,
and the backend never replaces unsaved buffer text.

When Flycheck is enabled, P4 markers automatically use the opposite side if
Flycheck uses the same side as diff-hl. The side stays fixed as diagnostics
appear and disappear; Flycheck's settings are unchanged. Set
`vc-p4-gutter-side` to `left` or `right` to choose a fixed side, or leave it at
`auto`. Using the same fringe as diagnostics can hide one of the indicators.

For a guided check and uninstall instructions, see
[the workspace smoke check](VALIDATION.md).

## Limitations

- Submit, pending changelist management and `vc-dir` are not implemented yet.
- File operations support individual local paths. Directory operations,
  cross-workspace moves and revision-changing checkout use the P4 CLI.
- P4 revert confirms the files to discard without a synchronous diff preview.
  Use `C-x v =` to inspect changes before reverting.
- Automatic P4 queries and gutter diffs are asynchronous. Explicit synchronous
  VC consumers require cached revisions and report pending data instead of
  waiting; retry after retrieval finishes. Explicit synchronous local diff
  requests can still wait for the local `diff` executable.
- Background workers time out after `vc-p4-command-timeout` (10 seconds by
  default). Failed queries back off for `vc-p4-retry-delay` (10 seconds).
  At most `vc-p4-max-processes` workers (default 4) run concurrently;
  `vc-p4-max-pending-diffs` limits pending diff pipelines (default 32).
  `vc-p4-max-pending-views` similarly bounds history and revision views.
- There is no background polling for external workspace changes.
- Binary files and UTF-16 files do not produce textual gutter hunks. UTF-16
  pristine revision retrieval preserves the original bytes.
- Windows, TRAMP, Unicode-mode servers, streams and complex overlay mappings
  have not been validated.

Automated tests have run on macOS arm64 with Emacs 30.2 and 31.1, P4/P4D
2024.2, and diff-hl 1.11.2, using classic workspaces with local line endings.
See [development notes](DEVELOPMENT.md) for the exact matrix and remaining
validation scope.

## Troubleshooting

If a file is not recognized, evaluate `(vc-backend buffer-file-name)` in its
buffer; a recognized Perforce file should return `P4`. Check that Emacs can
find the configured `vc-p4-program` and that the CLI selects the correct client.
Discovery can initially return nil while its background query runs.
Inspect `vc-p4-last-error` for the most recent failure; after correcting the
CLI configuration or login, run `M-x vc-p4-refresh`.

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
