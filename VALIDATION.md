# Workspace smoke check

Run this check in a workspace accessible from your graphical Emacs. No
server setup or history export is needed. Use a disposable, already-versioned
text file with no existing local changes. Do not revert any unrelated work.

## Load for this Emacs session

Evaluate this in the Emacs instance that can access the workspace, adjusting
paths if it is on another machine:

```elisp
(add-to-list 'load-path "/path/to/p4vc")
(require 'vc-p4)
;; Set this to your authenticated CLI executable if it is not on PATH:
(setq vc-p4-program "/path/to/p4")
(require 'diff-hl)
(setq diff-hl-update-async t)
```

The CLI must inherit the same P4CONFIG/environment as your terminal. From the
workspace terminal, `p4 info` should name the expected client/server. Use the
normal `p4 login` flow if needed; never include authentication tickets or passwords in reports.
No persistent Emacs configuration changes are required. If this session already
loaded an older backend, restart with the new checkout or, once any running
mutation has finished, explicitly reload the backend and its companion modules:

```elisp
(load-file "/path/to/p4vc/vc-p4.el")
(load-file "/path/to/p4vc/vc-p4-ops.el")
(load-file "/path/to/p4vc/vc-p4-gutter.el")
(load-file "/path/to/p4vc/vc-p4-history.el")
```

## Five-minute check

1. Visit the chosen file and run `M-x vc-p4-refresh`, then `M-x diff-hl-mode`
   to enable highlighting if it is off. A clean file should
   have no markers after pending work completes. The initial mode line may show
   `P4?`; `M-: (vc-backend buffer-file-name)` should eventually return `P4`.
2. Use `C-x v v` on the clean file, or `M-x vc-p4-edit`. After checkout completes,
   the buffer should become writable. Change one line and save. Expect one
   change marker at that line. Insert/delete a line and check the corresponding
   markers. `M-x diff-hl-next-hunk` should navigate to a changed hunk.
   At that hunk, `M-x diff-hl-show-hunk` should display its inline diff once ready,
   without a "No next hunk" error. Dismiss it and repeat after another saved edit.
3. Run `M-x diff-hl-flydiff-mode` to enable unsaved highlighting. Make another
   edit without saving; expect its marker after the idle delay. Check
   `M-x diff-hl-show-hunk` on that unsaved change too. This mode is optional.
4. Save the disposable edits, then use `C-x v u` and confirm the selected test
   file. Expect its synced contents, the appropriate read-only flag, and no
   markers after completion. Without further typing, the buffer should show no
   unsaved-change indicator, and `M-: (buffer-modified-p)` should return `nil`.
   Discard only the disposable edits made in this check.
5. If a safely available file has an older have revision than head, check that
   local edits are compared with have, not head. No need to change production
   history or sync backwards just to manufacture this case; it is automated.

## Windows explicit diff check

After loading the updated modules on Windows, change one line in a disposable
tracked text file and save it. Run `M-x vc-diff`. Expect readable headers and
hunk lines without extra `^M` from the diff executable's CRLF output. The
changed line should still appear correctly. Actual carriage returns in file
content or a genuine LF/CRLF difference may remain visible in a byte-preserving
diff; do not change the file's coding or the client's LineEnd setting to make
this check pass.

Report whether this resolves the original display problem. If it persists,
include Emacs, P4 and diff executable versions, `buffer-file-coding-system`
from the editing buffer, the client's LineEnd setting, and whether `^M` occurs
in diff headers as well as content lines. Sanitize private paths and server
details. Revert only the disposable edit after checking.

## File history and revisions

1. Visit a tracked file and run `C-x v l`. Check the revision, author, full
   description and separately labeled changelist. Use `n`/`p` and `f` to open
   an entry in a read-only revision buffer. No working-file changes are needed.
2. In that revision buffer, use `C-c C-p` and `C-c C-n` to visit older/newer
   contents. On a file with existing move/integration history, confirm the depot
   paths stay distinct as navigation follows the displayed ancestry. The
   disposable server fixture covers this when no convenient real file exists.
3. From the working file, use `C-x v ~`. Completion accepts file revisions
   (`3`, `#3`, or `//depot/path#3`) separately from changelists (`@123`). A cold
   completion list loads asynchronously; another TAB can show newly loaded
   candidates. Verify the chosen contents without saving or syncing anything.
4. Leave a disposable unsaved edit in the working buffer while viewing history.
   Confirm it remains intact. Closing a pending view must not produce a late
   buffer switch or error popup. Report actual GUI behaviour separately from
   automated validation.
5. Follow a changelist link in the log, or use `M-x vc-p4-changes` and select
   one. Check the description and affected-file actions, then follow a file
   revision link. `M-x vc-p4-describe-change` also accepts `@number` directly.
   Verify that `g` refreshes these views using the same workspace context.

## Native editing lifecycle

Use only a disposable tracked file with no unrelated work. Check `p4 opened`
alongside VC state; nothing in this check submits a changelist.

1. Run the checkout/save/revert steps above. Type in another buffer while each
   command is pending. In an allwrite workspace, also try `M-x vc-p4-edit`.
2. Create a disposable file, insert text, and use `C-x v i`. If discovery is
   pending, the command should continue automatically without another keypress;
   it should not offer to create a repository.
   Verify an `add` action with `p4 opened`. Revert it using `C-x v u`: the file
   and its contents should remain, and its pending add should disappear.
3. Move the disposable tracked file using `M-x vc-rename-file` to a new unused
   name in the same workspace. The buffer name should follow only after success.
   Use `C-x v u` on the moved-to file; it should continue automatically if its move-partner mapping is still
   being retrieved. Expect the original name and contents to return.
4. Delete the clean tracked test file with `M-x vc-delete-file`. Expect a pending
   delete and a retained read-only visiting buffer. Use `C-x v u` there to restore
   the file. Confirm no test actions remain with `p4 opened`.

Report pauses, unexpected prompts, incorrect buffer names/permissions, missing
eventual gutters, or sanitized `vc-p4-last-error`. Do not manufacture an outage,
exclusive-lock conflict or destructive external race: automated tests cover these.
For a failed or cancelled operation, keep the recovery directory reported in
`*Messages*` until you have checked actual files and opened actions. Cancellation
does not roll back a command that P4 has already applied.

## Responsiveness check

1. With a versioned file open, run `M-x vc-p4-refresh` and immediately type
   and move the cursor. Refresh should return immediately, including on a cold
   cache. Repeat after leaving the buffer idle long enough for metadata to expire.
2. Save a disposable edit, then keep typing/navigation going while the gutter
   updates. Repeat with flydiff enabled and unsaved edits. Add a change away
   from an existing marker: the existing marker should remain stable through
   the completed update, not disappear and return. Repeat refresh without any
   edits. Undo a change and confirm only its marker disappears once confirmed.
   Old results must not overwrite newer markers or replace buffer text.
   If Flycheck is enabled, create and fix a diagnostic on a changed line. Both
   indicators should remain visible on separate sides. P4's auto placement
   should not move when individual diagnostics appear or disappear.
3. During a normal external sync that you already intend to run, keep editing
   an unrelated buffer. Then refresh the affected test file. Do not manufacture
   destructive sync/revert operations just for this check. Preserve unsaved work
   before reloading files changed by external commands.
4. Close a test buffer while a refresh is pending and revisit it. It should
   rediscover cleanly. A failed query should show `P4!`, not claim a clean file;
   after fixing connectivity/login, `M-x vc-p4-refresh` should recover.

Slow/hung P4 and local diff, authentication failure and outage are injected by
the automated tests. The GUI check is to confirm behaviour with your actual
Emacs configuration and workspace; no server outage is required.

Report pass/fail, including
Emacs version and `p4 -V`, expected versus actual line markers, and whether
saved and unsaved checks both passed. Include whether typing/navigation paused
during visit, save, refresh or concurrent external work. For discovery failures, inspect
`M-: vc-p4-last-error` and sanitize server/user/path details before sharing.
If GUI rendering is wrong, describe the marker and line position.

## Rollback

Remove the load snippet if you made it persistent and restart Emacs. A restart
removes the backend, its hooks and its diff-hl compatibility advice.
The snippet does not change files or submit anything. Disable flydiff again if
you enabled it only for this check. Restore only your disposable test edits
using the CLI as described above.
