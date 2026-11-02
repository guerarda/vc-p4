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
loaded an older backend, restart with the new checkout or explicitly evaluate
`(load-file "/path/to/p4vc/vc-p4.el")` before testing.

## Five-minute check

1. Visit the chosen file and run `M-x vc-p4-refresh`, then `M-x diff-hl-mode`
   to enable highlighting if it is off. A clean file should
   have no markers after pending work completes. The initial mode line may show
   `P4?`; `M-: (vc-backend buffer-file-name)` should eventually return `P4`.
2. In the terminal, run `p4 edit path/to/file`. Revisit/revert the Emacs buffer
   to refresh its read-only flag, then change one line and save. Expect one
   change marker at that line. Insert/delete a line and check the corresponding
   markers. `M-x diff-hl-next-hunk` should navigate to a changed hunk.
3. Run `M-x diff-hl-flydiff-mode` to enable unsaved highlighting. Make another
   edit without saving; expect its marker after the idle delay. This mode is optional.
4. Restore this test-only file using `p4 revert path/to/file`, then
   `M-x revert-buffer`, `M-x vc-p4-refresh`, and `M-x diff-hl-update`.
   Expect no markers. Discard only the disposable edits made in this check.
5. If a safely available file has an older have revision than head, check that
   local edits are compared with have, not head. No need to change production
   history or sync backwards just to manufacture this case; it is automated.

## Responsiveness check

1. With a versioned file open, run `M-x vc-p4-refresh` and immediately type
   and move the cursor. Refresh should return immediately, including on a cold
   cache. Repeat after leaving the buffer idle long enough for metadata to expire.
2. Save a disposable edit, then keep typing/navigation going while the gutter
   updates. Repeat with flydiff enabled and unsaved edits. Old results must not
   overwrite newer markers or replace buffer text.
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
