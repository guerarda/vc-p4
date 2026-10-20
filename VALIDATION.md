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
(setq diff-hl-update-async nil)
```

The CLI must inherit the same P4CONFIG/environment as your terminal. From the
workspace terminal, `p4 info` should name the expected client/server. Use the
normal `p4 login` flow if needed; never include authentication tickets or passwords in reports.
No persistent Emacs configuration changes are required.

## Five-minute check

1. Visit the chosen file and run `M-x vc-p4-refresh`, then `M-x diff-hl-mode`
   to enable highlighting if it is off. A clean file should
   have no markers. `M-: (vc-backend buffer-file-name)` should return `P4`.
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

Report pass/fail, including
Emacs version and `p4 -V`, expected versus actual line markers, and whether
saved and unsaved checks both passed. For discovery failures, inspect
`M-: vc-p4-last-error` and sanitize server/user/path details before sharing.
If GUI rendering is wrong, describe the marker and line position.

## Rollback

Remove the load snippet if you made it persistent and restart Emacs. A restart
removes the backend, save hook and both diff-hl compatibility advice functions.
The snippet does not change files or submit anything. Disable flydiff again if
you enabled it only for this check. Restore only your disposable test edits
using the CLI as described above.
