;;; vc-p4-ops.el --- Asynchronous Perforce file operations -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))

;;; Commentary:
;; Mutation lifecycle, recovery and native VC completion adapters for vc-p4.

;;; Code:
(require 'vc-p4)

(defvar-local vc-p4--waiting-command nil)

(defun vc-p4--continue-command (files function &optional cleanup)
  "Run FUNCTION, continuing automatically when FILES' metadata arrives.
Never replay a mutation: FUNCTION must signal pending only before starting it.
Abort if the initiating buffer, configuration, disk or buffer text changes.
Call CLEANUP once when the pending continuation ends, including cancellation."
  (when vc-p4--waiting-command (user-error "A P4 command is already waiting"))
  (let* ((buffer (current-buffer))
         (contexts (mapcar #'vc-p4--context files))
         (stamps (mapcar #'vc-p4--file-stamp files))
         (tick (buffer-chars-modified-tick))
         (deadline (+ (float-time) (* 4 vc-p4-command-timeout)))
         timer)
    (cl-labels
        ((cancel ()
           (when timer (cancel-timer timer))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (setq vc-p4--waiting-command nil)))
           (when cleanup
             (let ((function cleanup))
               (setq cleanup nil)
               (funcall function))))
         (step ()
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (condition-case err
                   (progn
                     (unless (and (< (float-time) deadline)
                                  (= tick (buffer-chars-modified-tick))
                                  (equal contexts (mapcar #'vc-p4--context files))
                                  (equal stamps (mapcar #'vc-p4--file-stamp files)))
                       (user-error "P4 command cancelled: file/context changed or metadata timed out"))
                     (let ((vc-p4-metadata-ttl most-positive-fixnum))
                       (funcall function))
                     (cancel))
                 (vc-p4-pending (setq timer (run-at-time 0.05 nil #'step)))
                 (error (cancel)
                        (setq vc-p4--operation-error (error-message-string err)
                              vc-p4-last-error vc-p4--operation-error vc-mode " P4!")
                        (message "%s" vc-p4-last-error)))))))
      (condition-case nil
          (funcall function)
        (vc-p4-pending
         (setq vc-p4--waiting-command #'cancel vc-mode " P4?")
         (add-hook 'kill-buffer-hook #'vc-p4--cancel-waiting-command nil t)
         (setq timer (run-at-time 0.05 nil #'step))
         (message "P4: waiting for metadata; command will continue automatically"))))))

(defun vc-p4--cancel-waiting-command ()
  "Cancel metadata acquisition for the current buffer's requested command."
  (when vc-p4--waiting-command (funcall vc-p4--waiting-command)))

;; VC's mutation frontends assume synchronous completion.  These narrow P4
;; adapters defer their buffer-side effects until the command has succeeded.
(cl-defstruct (vc-p4--operation (:constructor vc-p4--make-operation))
	      name files contexts job result error success stamps buffers destructive recovery
	      commands prepared validate keys environment exec-path program owner)

(defun vc-p4--operation-context (file owner)
  "Read FILE's current configuration in its visiting buffer, or OWNER."
  (with-current-buffer (or (get-file-buffer file)
                           (and (buffer-live-p owner) owner)
                           (current-buffer))
    (vc-p4--context file)))

(defun vc-p4--operation-buffer (operation file)
  "Return OPERATION's original visiting buffer if FILE still belongs to it."
  (let* ((snapshot (assoc file (vc-p4--operation-buffers operation)))
         (buffer (nth 1 snapshot))
         (index (cl-position file (vc-p4--operation-files operation) :test #'equal)))
    (when (and (buffer-live-p buffer)
               (equal (buffer-local-value 'buffer-file-name buffer) file)
               (memq (vc-file-getprop file 'vc-backend) '(nil none P4))
               (equal (vc-p4--operation-context file (vc-p4--operation-owner operation))
                      (nth index (vc-p4--operation-contexts operation))))
      buffer)))

(defun vc-p4--invalidate-file (file &optional keep-properties)
  "Invalidate FILE's metadata and cancel obsolete reads, preserving other files."
  (vc-p4--cancel-file-work file)
  (let (keys)
    (maphash (lambda (key _)
               (when (equal (file-truename (nth 1 key)) (file-truename file))
                 (push key keys))) vc-p4--metadata)
    (dolist (key keys) (remhash key vc-p4--metadata)))
  (unless keep-properties (vc-file-clearprops file)))

(defun vc-p4--check-saved (files)
  "Reject unsaved buffers visiting FILES before a destructive operation."
  (dolist (file files)
    (when-let* ((buffer (get-file-buffer file)))
      (when (buffer-modified-p buffer)
        (user-error "Save or undo buffer changes before operating on %s" file)))))

(defun vc-p4--operation-prepare (operation)
  "Recheck OPERATION at dispatch and save recoverable copies before changing files."
  (let ((files (vc-p4--operation-files operation)))
    (unless (equal (vc-p4--operation-contexts operation)
                   (mapcar (lambda (file)
                             (vc-p4--operation-context file (vc-p4--operation-owner operation))) files))
      (user-error "P4 configuration changed before operation started"))
    (when (vc-p4--operation-validate operation)
      (funcall (vc-p4--operation-validate operation)))
    (when (vc-p4--operation-destructive operation)
      (vc-p4--check-saved files)
      (unless (equal (vc-p4--operation-stamps operation) (mapcar #'vc-p4--file-stamp files))
        (user-error "Files changed before P4 operation started"))
      (unless (vc-p4--operation-prepared operation)
        (let ((directory (make-temp-file "vc-p4-recovery-" t)) (index 0) manifest)
          (setf (vc-p4--operation-recovery operation) directory)
          (dolist (file files)
            (when (file-exists-p file)
              (let ((copy (expand-file-name (number-to-string (cl-incf index)) directory)))
                (copy-file file copy nil t nil t)
                (push (cons file copy) manifest))))
          (with-temp-file (expand-file-name "files.el" directory)
            (prin1 (nreverse manifest) (current-buffer)))
          (setf (vc-p4--operation-prepared operation) t))))))

(defun vc-p4--buffer-matches-file-p (file)
  "Return non-nil if the full current buffer equals decoded contents of FILE.
Use the visiting buffer's coding system; ignore narrowing and text properties.
An unreadable or missing file cannot establish that the buffer is clean."
  (let ((source (current-buffer))
        (coding-system-for-read buffer-file-coding-system)
        (case-fold-search nil))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file)
          (let ((disk (current-buffer)))
            (with-current-buffer source
              (save-restriction
                (widen)
                (zerop (compare-buffer-substrings source nil nil disk nil nil))))))
      (file-error nil))))

(defun vc-p4--operation-resynch (operation file &optional target keep-text)
  "Update FILE's original buffer after OPERATION, optionally renaming to TARGET.
KEEP-TEXT skips reload for a move.  Newer buffer edits are always preserved."
  (when-let* ((snapshot (assoc file (vc-p4--operation-buffers operation)))
              (buffer (vc-p4--operation-buffer operation file)))
    (with-current-buffer buffer
      (when target
        (when-let* ((other (get-file-buffer target)))
          (unless (eq other buffer) (user-error "Already visiting move target %s" target)))
        (let ((modified (buffer-modified-p)))
          (set-visited-file-name target t t)
          (set-buffer-modified-p modified))
        (setq file target))
      (cond
       (keep-text (read-only-mode (if (file-writable-p file) -1 1)))
       ((or (buffer-modified-p) (/= (buffer-chars-modified-tick) (nth 2 snapshot)))
        ;; Auto-revert can load P4's result before the process callback runs.
        ;; A changed character tick alone does not imply unsaved user edits.
        (if (and (not (buffer-modified-p)) (vc-p4--buffer-matches-file-p file))
            (read-only-mode (if (file-writable-p file) -1 1))
          (message "P4 finished; kept newer buffer text in %s" (buffer-name))
          (set-buffer-modified-p t)))
       ((file-exists-p file)
        (progn (revert-buffer t t t)
               (read-only-mode (if (file-writable-p file) -1 1))))
       (t
        ;; Keep the visiting buffer available for undo/recovery after delete.
        (clear-visited-file-modtime)
        (read-only-mode 1))))))

(defun vc-p4--check-operation-save (&rest _)
  "Prevent a save racing a destructive P4 command; typing remains available."
  (when-let* ((operation (vc-p4--operation-for buffer-file-name)))
    (when (vc-p4--operation-destructive operation)
      (user-error "P4 %s is pending; wait or cancel before saving"
                  (vc-p4--operation-name operation)))))


(defun vc-p4--check-operation-result (result)
  "Require a confirmed file action in RESULT, preserving server diagnostics."
  (unless (eq (plist-get result :status) 'success)
    (signal 'vc-p4-error
            (list (format "%s: %s%s%s" (plist-get result :status)
                          (or (plist-get result :detail) "")
                          (or (plist-get result :stderr) "")
                          (or (plist-get result :stdout) "")))))
  (let ((records (vc-p4--parse-json (plist-get result :stdout))))
    (unless (cl-some (lambda (record) (alist-get 'action record)) records)
      (signal 'vc-p4-error
              (list (or (cl-some (lambda (record) (alist-get 'data record)) records)
                        "No file action confirmed"))))))

(defun vc-p4--operation-note-error (operation error)
  "Record ERROR on OPERATION without masking an earlier failure."
  (unless (vc-p4--operation-error operation)
    (setf (vc-p4--operation-error operation) (error-message-string error)))
  (setq vc-p4-last-error (vc-p4--operation-error operation)))

(defun vc-p4--operation-finish (operation result)
  "Publish RESULT for OPERATION and release files even if UI or cleanup fails."
  (setf (vc-p4--operation-result operation) result)
  (unwind-protect
      (condition-case err
          (progn
            (vc-p4--check-operation-result result)
            (when (vc-p4--operation-success operation)
              (funcall (vc-p4--operation-success operation) operation)))
        ((error quit) (vc-p4--operation-note-error operation err)))
    (dolist (key (vc-p4--operation-keys operation))
      (remhash key vc-p4--operations)))
  (when (and (vc-p4--operation-recovery operation)
             (not (vc-p4--operation-error operation)))
    (condition-case err
        (progn
          (delete-directory (vc-p4--operation-recovery operation) t)
          (setf (vc-p4--operation-recovery operation) nil))
      (error (vc-p4--operation-note-error operation err))))
  (cl-mapc
   (lambda (file context)
     (condition-case err
         (progn
           (vc-p4--invalidate-file
            file (or (not (equal context (vc-p4--operation-context file (vc-p4--operation-owner operation))))
                     (not (memq (vc-file-getprop file 'vc-backend) '(nil none P4)))))
           (when (and (equal context (vc-p4--operation-context file (vc-p4--operation-owner operation)))
                      (memq (vc-file-getprop file 'vc-backend) '(nil none P4)))
             (when-let* ((buffer (get-file-buffer file)))
               (with-current-buffer buffer
                 (setq vc-p4--operation-error (vc-p4--operation-error operation))))
             (vc-p4--notify file context)))
       (error (vc-p4--operation-note-error operation err))))
   (vc-p4--operation-files operation) (vc-p4--operation-contexts operation))
  (message "P4 %s: %s%s" (vc-p4--operation-name operation)
           (or (vc-p4--operation-error operation) "done")
           (if (vc-p4--operation-recovery operation)
               (format "; recovery copies: %s" (vc-p4--operation-recovery operation)) "")))

(defun vc-p4--operation-run (operation)
  "Queue the next command of OPERATION with its original execution environment."
  (let ((process-environment (vc-p4--operation-environment operation))
        (exec-path (vc-p4--operation-exec-path operation))
        (vc-p4-program (vc-p4--operation-program operation))
        (args (pop (vc-p4--operation-commands operation))))
    (setf (vc-p4--operation-job operation)
          (apply #'vc-p4--run-async (file-name-directory (car (vc-p4--operation-files operation)))
                 (lambda (result)
                   (if (vc-p4--operation-commands operation)
                       (if (condition-case nil
                               (progn (vc-p4--check-operation-result result) t)
                             (error nil))
                           (condition-case err
                               (progn
                                 (setf (vc-p4--operation-stamps operation)
                                       (mapcar #'vc-p4--file-stamp (vc-p4--operation-files operation)))
                                 (vc-p4--operation-run operation))
                             (error (vc-p4--operation-finish
                                     operation (list :status 'error :detail (error-message-string err)))))
                         (vc-p4--operation-finish operation result))
                     (vc-p4--operation-finish operation result)))
                 "-Mj" "-ztag" args))
    (setf (vc-p4--job-prepare (vc-p4--operation-job operation))
          (lambda () (vc-p4--operation-prepare operation)))))

(defun vc-p4--operate (name files args &optional success destructive validate)
  "Queue mutation NAME of FILES with ARGS and a SUCCESS completion function.
SUCCESS receives the completed operation.  DESTRUCTIVE enables disk recovery
copies and save protection.  VALIDATE checks operation-specific preconditions
at dispatch.  ARGS may be a list of commands to run in order.  Never retry."
  (setq files (mapcar #'expand-file-name files))
  (dolist (file files)
    (when (or (file-remote-p file) (file-directory-p file)
              (string-match-p "\\.\\.\\." file))
      (user-error "P4 operations require individual local files"))
    (when (vc-p4--operation-for file)
      (user-error "A P4 operation is already pending for %s" file)))
  (when destructive (vc-p4--check-saved files))
  (let* ((owner (or (get-file-buffer (car files)) (current-buffer)))
         (operation (vc-p4--make-operation
                     :name name :files files :owner owner
                     :contexts (mapcar (lambda (file) (vc-p4--operation-context file owner)) files)
                     :success success :destructive destructive
                     :commands (if (stringp (car args)) (list args) (copy-sequence args))
                     :environment (copy-sequence (buffer-local-value 'process-environment owner))
                     :exec-path (copy-sequence (buffer-local-value 'exec-path owner))
                     :program (buffer-local-value 'vc-p4-program owner)
                     :validate validate
                     :keys (delete-dups (append files (mapcar #'file-truename files)))
                     :stamps (mapcar #'vc-p4--file-stamp files)
                     :buffers (mapcar (lambda (file)
					(when-let* ((buffer (get-file-buffer file)))
                                          (list file buffer (with-current-buffer buffer
                                                              (buffer-chars-modified-tick))))) files))))
    (setq vc-p4-last-operation operation)
    (dolist (key (vc-p4--operation-keys operation))
      (puthash key operation vc-p4--operations))
    (dolist (file files)
      (vc-p4--invalidate-file file t)
      (vc-file-setprop file 'vc-state nil)
      (when-let* ((buffer (get-file-buffer file)))
        (with-current-buffer buffer
          (setq vc-p4--operation-error nil vc-mode " P4?"))))
    (vc-p4--operation-run operation)
    operation))

(defun vc-p4-cancel-operation ()
  "Cancel this file's pending P4 operation and refresh its actual state.
A running command may already have changed the workspace or server."
  (interactive)
  (if vc-p4--waiting-command (vc-p4--cancel-waiting-command)
    (if-let* ((operation (vc-p4--operation-for buffer-file-name)))
      (vc-p4--cancel (vc-p4--operation-job operation))
      (user-error "No P4 operation is pending for this file"))))

(defun vc-p4-checkout (file &optional revision)
  "Open FILE for edit asynchronously, preserving its HAVE revision and text.
Changing to REVISION is a sync operation and is not implemented here."
  (when revision (user-error "Use p4 sync to change revisions"))
  (let ((file (expand-file-name file)))
    (vc-p4--operate
     "edit" (list file) (list "edit" (vc-p4--escape file))
     (lambda (operation)
       (when-let* ((buffer (vc-p4--operation-buffer operation file)))
         (with-current-buffer buffer
           ;; edit changes permissions, never buffer contents or undo history.
           (read-only-mode (if (file-writable-p file) -1 1))
           (run-hooks 'vc-checkout-hook)))))))

(defun vc-p4--vc-checkout (original file &optional revision)
  "Route P4 checkout through completion handling; delegate ORIGINAL otherwise."
  (if (eq (vc-backend file) 'P4)
      (vc-p4-checkout file revision)
    (funcall original file revision)))

(defun vc-p4-edit ()
  "Open the current file for edit, including in an allwrite workspace."
  (interactive)
  (vc-checkout (or buffer-file-name (user-error "This buffer visits no file"))))


(defun vc-p4-register (files &optional _comment)
  "Open individual FILES for add asynchronously, preserving literal filenames."
  (setq files (mapcar #'expand-file-name (if (stringp files) (list files) files)))
  (dolist (file files)
    (when (or (file-remote-p file) (file-directory-p file) (not (file-exists-p file)))
      (user-error "Save each local file before adding it to P4"))
    (when (vc-p4--operation-for file)
      (user-error "A P4 operation is already pending for %s" file)))
  ;; add -f interprets raw names literally; escaping them would add the wrong
  ;; path.  One command per file also makes partial fileset failures explicit.
  (mapcar (lambda (file) (vc-p4--operate "add" (list file) (list "add" "-f" file)))
          files))

(defvar vc-p4--inferred-registration nil
  "Non-nil when the current next-action may pass an inferred registration backend.")

(defvar vc-git-program)

(defun vc-p4--vc-register (original &optional fileset comment)
  "Register P4 FILESET asynchronously, delegating ORIGINAL for other backends."
  (if (and (or (null fileset)
               (and vc-p4--inferred-registration
                    (equal (cadr fileset) (list buffer-file-name))))
           buffer-file-name (memq 'P4 vc-handled-backends))
      (let* ((file buffer-file-name)
             (git-marker (vc-find-root file ".git"))
             git-job git-result)
        (vc-buffer-sync)
        ;; A cached/inferred Git backend is not evidence of a Git repository.
        ;; Nor is a stray .git marker: ask Git before giving it precedence.
        (vc-p4--continue-command
         (list file)
         (lambda ()
           (let ((vc-p4-status nil)
                 (vc-p4--inferred-registration nil))
             (when git-marker
               (unless git-job
                 (require 'vc-git)
                 (let ((vc-p4-program vc-git-program)
                       (process-environment (cons "LC_ALL=C" process-environment)))
                   (setq git-job
                         (vc-p4--run-async
                          (file-name-directory file)
                          (lambda (result) (setq git-result result))
                          "rev-parse" "--is-inside-work-tree"))))
               (unless git-result (signal 'vc-p4-pending nil))
               ;; Git also uses exit 128 for access and ownership failures.
               ;; Only a rejected marker is evidence to try P4 instead.
               (unless (or (eq (plist-get git-result :status) 'success)
                           (and (eq (plist-get git-result :status) 'error)
                                (eq (plist-get git-result :exit-code) 128)
                                (string-match-p
                                 "not a git repository\\|invalid gitfile format\\|no path in gitfile"
                                 (or (plist-get git-result :stderr) ""))))
                 (signal 'vc-p4-error
                         (list "Git discovery failed"
                               (or (plist-get git-result :detail)
                                   (plist-get git-result :stderr))))))
             (cond ((and git-result
                         (eq (plist-get git-result :status) 'success)
                         (equal (string-trim (plist-get git-result :stdout)) "true"))
                    (funcall original (or fileset (list 'Git (list file))) comment))
                   ((vc-p4-root file)
                    (vc-p4--vc-register original (list 'P4 (list file)) comment))
                   ((eq vc-p4-status 'pending) (signal 'vc-p4-pending nil))
                   ((eq vc-p4-status 'error)
                    (signal 'vc-p4-error (list vc-p4-last-error)))
                   (t (funcall original nil comment)))))
         (lambda ()
           (when (and git-job (not git-result)) (vc-p4--cancel git-job)))))
  (let ((fileset (or fileset (vc-deduce-fileset nil t))))
    (if (not (eq (car fileset) 'P4))
        (funcall original fileset comment)
      (dolist (file (cadr fileset))
        (when (vc-p4-registered file)
          (user-error "This file is already registered: %s" file))
        (when-let* ((buffer (get-file-buffer file)))
          (with-current-buffer buffer (vc-buffer-sync))))
      (dolist (file (cadr fileset)) (vc-file-setprop file 'vc-backend 'none))
      (vc-p4-register (cadr fileset) comment)))))

(defun vc-p4--vc-next-action (original verbose)
  "Open an unopened P4 file for edit before offering a check-in workflow."
  (if (not (and buffer-file-name (eq (vc-backend buffer-file-name) 'P4)))
      ;; The generic frontend passes its inferred backend explicitly to
      ;; `vc-register'.  It is not a user choice unless VERBOSE was requested.
      (let ((vc-p4--inferred-registration (not verbose)))
        (funcall original verbose))
    (when verbose (user-error "Use p4 sync to change revisions"))
    (let ((file buffer-file-name))
      (vc-p4--continue-command
       (list file)
       (lambda ()
         (let ((action (alist-get 'action (vc-p4--require-stat file))))
           (if (or (null action) (equal action "edit"))
               (vc-p4-checkout file)
             (user-error "P4 file is open for %s; submit through the P4 CLI" action))))))))

(defun vc-p4--vc-backend-for-registration (original file)
  "Avoid repository creation while P4 discovery for FILE is pending or failed.
Delegate ORIGINAL when a responsible backend is already known."
  (let ((vc-p4-status nil))
    (when (and (memq 'P4 vc-handled-backends)
               (not (vc-responsible-backend file t)))
      (pcase vc-p4-status
        ('pending (signal 'vc-p4-pending
                          (list "Retry registration when workspace discovery is ready" file)))
        ('error (signal 'vc-p4-error
                        (list "P4 discovery failed; check configuration/login and refresh" vc-p4-last-error))))))
  (funcall original file))


(defun vc-p4--require-stat (file)
  "Return FILE's metadata or request that the caller retry after retrieval."
  (or (vc-p4--stat file)
      (if (eq vc-p4-status 'error)
          (signal 'vc-p4-error (list vc-p4-last-error))
        (signal 'vc-p4-pending (list "Retry when P4 metadata is ready" file)))))

(defun vc-p4-revert (file &optional _contents-done)
  "Revert FILE to HAVE asynchronously, retaining copies if the operation fails."
  (setq file (expand-file-name file))
  (let* ((stat (vc-p4--require-stat file))
         (action (alist-get 'action stat)))
    (unless (or action (alist-get 'haveRev stat))
      (user-error "No working revision to restore"))
    (if (member action '("move/add" "move/delete"))
        (let* ((depot (alist-get 'movedFile stat))
               (mappings (and depot (vc-p4--cached file (list "where" depot))))
               (partner (alist-get 'path (car (last mappings)))))
          (unless partner (signal 'vc-p4-pending (list "Retrieving move partner" file)))
          (if (equal action "move/delete") (vc-p4-revert partner)
            (vc-p4--check-move-target partner)
            (vc-p4--operate
             "revert move" (list file partner) (list "revert" (vc-p4--escape file))
             (lambda (operation) (vc-p4--operation-resynch operation file partner)) t
             (lambda () (vc-p4--check-move-target partner)))))
      (vc-p4--operate
       "revert" (list file)
       (if action (list "revert" (vc-p4--escape file))
         (list "sync" "-f" (concat (vc-p4--escape file) "#" (alist-get 'haveRev stat))))
       (lambda (operation) (vc-p4--operation-resynch operation file)) t))))

(defun vc-p4--vc-revert-file (original file)
  "Defer P4 buffer reload until revert completes, otherwise call ORIGINAL."
  (if (eq (vc-backend file) 'P4) (vc-p4-revert file) (funcall original file)))

(defun vc-p4--vc-revert (original)
  "Confirm P4 revert without a synchronous preview; delegate ORIGINAL otherwise."
  (let ((fileset (vc-deduce-fileset)))
    (if (not (eq (car fileset) 'P4)) (funcall original)
      (let ((files (cadr fileset)))
        (vc-p4--check-saved files)
        (unless (yes-or-no-p (format "Discard saved changes in %s? " (vc-delistify files)))
          (user-error "Revert canceled"))
        (unless (= (length files) 1)
          (user-error "Revert one P4 file at a time"))
        (vc-p4--continue-command files (lambda () (vc-p4-revert (car files))))))))

(defun vc-p4-delete-file (file)
  "Open FILE for deletion asynchronously, keeping a recovery copy on failure."
  (setq file (expand-file-name file))
  (vc-p4--require-stat file)
  (let ((state (vc-p4-state file)))
    (unless (memq state '(up-to-date needs-update missing))
      (if (null state) (signal 'vc-p4-pending (list file))
        (user-error "Revert local changes before deleting %s" file))))
  (vc-p4--operate "delete" (list file) (list "delete" (vc-p4--escape file))
                  (lambda (operation) (vc-p4--operation-resynch operation file)) t))

(defun vc-p4--vc-delete-file (original file)
  "Confirm and schedule P4 deletion; delegate ORIGINAL for other backends."
  (if (not (eq (vc-backend file) 'P4)) (funcall original file)
    (vc-p4--check-saved (list file))
    (unless (y-or-n-p (format "Really want to delete %s? " (file-name-nondirectory file)))
      (user-error "Delete canceled"))
    (vc-p4-delete-file file)))


(defun vc-p4--check-move-target (file)
  "Reject an existing or visited move target FILE, including dangling symlinks."
  (when (or (file-exists-p file) (file-symlink-p file) (get-file-buffer file))
    (user-error "Move target already exists or is visited: %s" file)))

(defun vc-p4--workspace-identity (file)
  "Return the confirmed server/client/root identity responsible for FILE."
  (let ((root (vc-p4-root file)))
    (unless root
      (if (eq vc-p4-status 'pending) (signal 'vc-p4-pending (list file))
        (user-error "File is not in a mapped P4 workspace: %s" file)))
    (let ((info (car (vc-p4--cached file '("info")))))
      (list (alist-get 'serverAddress info) (alist-get 'clientName info) root))))

(defun vc-p4-rename-file (old new)
  "Move OLD to NEW asynchronously, opening OLD for edit if necessary."
  (setq old (expand-file-name old)
        new (expand-file-name (if (string-suffix-p "/" new)
                                  (concat new (file-name-nondirectory old)) new)))
  (vc-p4--check-move-target new)
  (unless (file-exists-p old) (user-error "Move source is missing: %s" old))
  (unless (equal (vc-p4--workspace-identity old) (vc-p4--workspace-identity new))
    (user-error "P4 moves must stay within the same workspace"))
  (let* ((stat (vc-p4--require-stat old))
         (action (alist-get 'action stat))
         (state (vc-p4-state old)))
    (unless (and (member action '(nil "edit" "add" "move/add"))
                 (memq state '(up-to-date edited added)))
      (if (null state) (signal 'vc-p4-pending (list old))
        (user-error "Resolve or update the file before moving it")))
    (vc-p4--operate
     "move" (list old new)
     (append (unless action (list (list "edit" (vc-p4--escape old))))
             (list (list "move" (vc-p4--escape old) (vc-p4--escape new))))
     (lambda (operation) (vc-p4--operation-resynch operation old new t)) t
     (lambda () (vc-p4--check-move-target new)))))

(defun vc-p4--vc-rename-file (original old new)
  "Defer P4 buffer renaming until success; delegate ORIGINAL otherwise."
  (if (eq (vc-backend old) 'P4) (vc-p4-rename-file old new) (funcall original old new)))


(provide 'vc-p4-ops)
;;; vc-p4-ops.el ends here
