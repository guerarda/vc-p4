;;; vc-p4-responsive-tests.el --- Input responsiveness gates -*- lexical-binding: t; -*-
(require 'vc-p4-gutter-tests)
(require 'vc-p4-operation-tests)
(defconst vc-p4-test-worker
  (expand-file-name "fault-worker.py" (file-name-directory load-file-name)))
(defvar vc-p4-test-command nil)
(defvar vc-p4-test-input-seen nil)

(defun vc-p4-test-start-command ()
  "Initiate backend work from a real keyboard command."
  (interactive)
  (funcall vc-p4-test-command))

(defun vc-p4-test-type-command ()
  "Execute queued input while backend work is pending."
  (interactive)
  (setq vc-p4-test-input-seen
        (and (or vc-p4--queue vc-p4--active vc-p4--diff-tasks vc-p4--notice-timer) (float-time)))
  (insert "typed"))

(defun vc-p4-test-queued-input (initiate)
  "Execute INITIATE followed by queued input through the command loop."
  (let* ((vc-p4-test-command initiate)
         (vc-p4-test-input-seen nil)
         (overriding-local-map (make-sparse-keymap))
         (start (float-time)))
    (define-key overriding-local-map [f13] #'vc-p4-test-start-command)
    (define-key overriding-local-map [f14] #'vc-p4-test-type-command)
    (execute-kbd-macro [f13 f14])
    (should vc-p4-test-input-seen)
    (let ((latency (- vc-p4-test-input-seen start)))
      (message "P4 queued-input latency: %.4fs" latency)
      (should (< latency 0.3)))))

(defmacro vc-p4-test-faults (&rest body)
  "Run BODY with isolated real worker processes and visiting-buffer cleanup."
  (declare (indent 0))
  `(vc-p4-test-async
     (vc-p4-test-with-file "one\ntwo\nthree\n"
       (let ((vc-p4-program vc-p4-test-worker)
             (vc-p4-diff-program vc-p4-test-worker)
             (vc-p4-metadata-ttl 60)
             (vc-p4-command-timeout 2)
             (vc-handled-backends '(P4))
             (vc-p4--diff-tasks nil)
             (process-environment (copy-sequence process-environment)))
         (setenv "VC_P4_FAULT_DELAY" "0")
         (setenv "VC_P4_FAULT_MODE" "normal")
         (unwind-protect (progn ,@body)
           (dolist (task (copy-sequence vc-p4--diff-tasks)) (vc-p4--diff-finish task))
           (when-let* ((buffer (get-file-buffer file)))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer))
           (vc-file-clearprops file))))))

(ert-deftest vc-p4-input-show-hunk-does-not-block-or-display-after-typing ()
  (require 'diff-hl-show-hunk)
  (vc-p4-test-faults
    (save-window-excursion
      (find-file file)
      (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date)))
      (goto-char (point-min)) (forward-line 1)
      (delete-region (point) (line-end-position)) (insert "changed")
      (setq-local diff-hl-mode t)
      (vc-p4-gutter--reconcile '((2 1 1 change)) nil)
      (setenv "VC_P4_FAULT_DELAY" "0.6")
      (let ((diff-hl-show-hunk-function (lambda (&rest _) (ert-fail "Popup after typing"))))
        (vc-p4-test-queued-input #'diff-hl-show-hunk)
        (vc-p4-test-await (lambda () (null vc-p4--diff-tasks)))
        (should (string-match-p "typed" (buffer-string)))))))

(ert-deftest vc-p4-input-cold-visit-and-discovery ()
  (vc-p4-test-faults
    (setenv "VC_P4_FAULT_DELAY" "0.6")
    (save-window-excursion
      (vc-p4-test-queued-input
       (lambda () (find-file file) (diff-hl-mode 1)))
      (should (string-match-p "typed" (buffer-string)))
      (should-not (eq (vc-file-getprop file 'vc-state) 'up-to-date))
      (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-backend) 'P4)))
      (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date))))))

(ert-deftest vc-p4-input-checkout-preserves-typing-during-slow-command ()
  (vc-p4-test-faults
    (save-window-excursion
      (find-file file)
      (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date)))
      (setenv "VC_P4_FAULT_DELAY" "0.6")
      (vc-p4-test-queued-input (lambda () (vc-checkout file)))
      (vc-p4-test-await (lambda () (not (vc-p4--operation-for file))))
      (should (string-match-p "typed" (buffer-string)))
      (should (buffer-modified-p))
      (should-not (vc-p4--operation-error vc-p4-last-operation)))))

(ert-deftest vc-p4-input-during-running-revert-preserves-typing ()
  (vc-p4-test-faults
    (setenv "VC_P4_FAULT_ACTION" "edit")
    (save-window-excursion
      (find-file file)
      (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date)))
      (setenv "VC_P4_FAULT_DELAY" "0.6")
      (let* ((operation (vc-revert-file file))
             (job (vc-p4--operation-job operation)))
        (vc-p4-test-await (lambda () (vc-p4--job-process job)))
        (vc-p4-test-queued-input #'ignore)
        (should (process-live-p (vc-p4--job-process job)))
        (should-error (save-buffer) :type 'user-error)
        (vc-p4-test-await (lambda () (not (vc-p4--operation-for file))))
        (should-not (vc-p4--operation-error operation))
        (should (string-match-p "typed" (buffer-string)))
        (should (buffer-modified-p))
        (should-not (vc-p4--operation-recovery operation))))))

(ert-deftest vc-p4-input-operation-timeout-releases-save-guard-with-recovery ()
  (vc-p4-test-faults
    (setenv "VC_P4_FAULT_ACTION" "edit")
    (save-window-excursion
      (find-file file)
      (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date)))
      (setenv "VC_P4_FAULT_MODE" "hang")
      (let* ((vc-p4-command-timeout 0.15)
             (operation (vc-revert-file file))
             (job (vc-p4--operation-job operation)))
        (unwind-protect
            (progn
              (vc-p4-test-await (lambda () (vc-p4--job-process job)))
              (vc-p4-test-queued-input #'ignore)
              (should-error (save-buffer) :type 'user-error)
              (vc-p4-test-await (lambda () (vc-p4--operation-result operation)))
              (should (eq (plist-get (vc-p4--operation-result operation) :status) 'timeout))
              (should-not (vc-p4--operation-for file))
              (should-not (process-live-p (vc-p4--job-process job)))
              (should (equal (vc-p4--local-bytes
                              (expand-file-name "1" (vc-p4--operation-recovery operation)))
                             "one\ntwo\nthree\n"))
              (should (string-match-p "typed" (buffer-string)))
              (vc-p4--check-operation-save))
          (when (vc-p4--operation-recovery operation)
            (delete-directory (vc-p4--operation-recovery operation) t)))))))

(ert-deftest vc-p4-input-expired-state-save-and-refresh ()
  (vc-p4-test-faults
    (save-window-excursion
      (find-file file)
      (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date)))
      (setenv "VC_P4_FAULT_DELAY" "0.6")
      (maphash (lambda (_ entry) (setf (vc-p4--entry-time entry) 0)) vc-p4--metadata)
      (vc-p4-test-queued-input
       (lambda ()
         (should-not (vc-p4-state file))
         (save-buffer)
         (vc-p4-refresh)))
      (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date))))))

(ert-deftest vc-p4-input-slow-local-diff-and-obsolete-result ()
  (vc-p4-test-faults
    (save-window-excursion
      (find-file file)
      (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date)))
      (diff-hl-mode 1)
      (unwind-protect
          (progn
            (diff-hl-flydiff-mode 1)
            (goto-char (point-min)) (insert "first\n")
            (setenv "VC_P4_FAULT_DELAY" "0.6")
            (let (obsolete)
              (vc-p4-test-queued-input
               (lambda () (diff-hl-update) (setq obsolete (car vc-p4--diff-tasks))))
              (should obsolete)
              (vc-p4-test-await (lambda () (vc-p4--diff-task-done obsolete)))
              (should (eq (process-status (vc-p4--diff-task-gate obsolete)) 'signal)))
            (diff-hl-update)
            (vc-p4-test-await (lambda () (vc-p4-test-hunks))))
        (diff-hl-flydiff-mode -1)))))

(ert-deftest vc-p4-input-hung-server-cancel-and-cleanup ()
  (vc-p4-test-faults
    (let ((vc-p4-command-timeout 0.15)
          (before (process-list)))
      (setenv "VC_P4_FAULT_MODE" "hang")
      (save-window-excursion
        (vc-p4-test-queued-input (lambda () (find-file file)))
        (vc-p4-test-await (lambda () (eq vc-p4-status 'error)))
        (should-not (eq (vc-file-getprop file 'vc-state) 'up-to-date))
        (set-buffer-modified-p nil)
        (kill-buffer (current-buffer)))
      (should-not (cl-set-difference (process-list) before)))))

(ert-deftest vc-p4-auth-and-outage-do-not-retry-on-every-update ()
  (dolist (mode '("auth" "outage"))
    (vc-p4-test-faults
      (setenv "VC_P4_FAULT_MODE" mode)
      (save-window-excursion
        (find-file file)
        (vc-p4-test-await (lambda () (eq vc-p4-status 'error)))
        (should (equal vc-mode " P4!"))
        (cl-letf (((symbol-function 'vc-p4--run-async)
                   (lambda (&rest _) (ert-fail "Retry storm"))))
          (dotimes (_ 10) (vc-p4-registered file) (vc-p4-state file)))
        (should-not (vc-file-getprop file 'vc-state))))))

(provide 'vc-p4-responsive-tests)

(ert-deftest vc-p4-hung-diff-cleans-temporaries-and-backs-off ()
  (vc-p4-test-faults
    (save-window-excursion
      (find-file file)
      (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date)))
      (diff-hl-mode 1)
      (unwind-protect
          (let ((vc-p4-command-timeout 0.15) task temps)
            (diff-hl-flydiff-mode 1)
            (insert "unsaved\n")
            (setenv "VC_P4_FAULT_MODE" "hang")
            (diff-hl-update)
            (setq task (car vc-p4--diff-tasks))
            (vc-p4-test-await (lambda () (vc-p4--diff-task-worker task)))
            (setq temps (copy-sequence (vc-p4--diff-task-temps task)))
            (should (= (length temps) 2))
            (vc-p4-test-await (lambda () (vc-p4--diff-task-done task)))
            (should (eq vc-p4-status 'error))
            (should-not (cl-some #'file-exists-p temps))
            (should-not (vc-p4-test-hunks))
            (cl-letf (((symbol-function 'vc-p4--run-async)
                       (lambda (&rest _) (ert-fail "Local diff retry storm"))))
              (diff-hl-update)))
        (diff-hl-flydiff-mode -1)))))

(ert-deftest vc-p4-pending-diffs-coalesce-and-have-a-limit ()
  (vc-p4-test-async
    (vc-p4-test-with-file "one\n"
      (let ((vc-p4-max-pending-diffs 1)
            (first (generate-new-buffer " *p4-limit-first*"))
            (second (generate-new-buffer " *p4-limit-second*")))
        (unwind-protect
            (progn
              (dotimes (_ 20) (vc-p4-diff (list file) nil nil first t))
              (should (= (length vc-p4--diff-tasks) 1))
              (should-error (vc-p4-diff (list file) nil nil second t) :type 'vc-p4-error)
              (should (= (length vc-p4--diff-tasks) 1)))
          (kill-buffer first)
          (kill-buffer second))
        (should-not vc-p4--diff-tasks)))))

(ert-deftest vc-p4-input-while-p4-worker-is-already-running ()
  (vc-p4-test-faults
    (setenv "VC_P4_FAULT_DELAY" "0.6")
    (save-window-excursion
      (find-file file)
      (vc-p4-test-await (lambda () vc-p4--active))
      (let ((worker (vc-p4--job-process (car vc-p4--active))))
        (should (process-live-p worker))
        (vc-p4-test-queued-input (lambda () (vc-p4-state file)))
        (should (process-live-p worker))))))

(ert-deftest vc-p4-save-retains-gutters-until-replacement-is-ready ()
  (dolist (flydiff '(nil t))
    (vc-p4-test-faults
      (save-window-excursion
        (find-file file)
        (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date)))
        (diff-hl-mode 1)
        (unwind-protect
            (let ((make-backup-files nil))
              (when flydiff (diff-hl-flydiff-mode 1))
              (goto-char (point-min)) (forward-line 1)
              (delete-region (point) (line-end-position)) (insert "changed")
              (save-buffer)
              (vc-p4-test-await (lambda () (equal (vc-p4-test-hunks) '((2 change)))))
              (vc-p4-test-await (lambda () (and (null vc-p4--active)
                                                (null vc-p4--queue)
                                                (null vc-p4--diff-tasks)
                                                (null vc-p4--notice-timer))))
              (setenv "VC_P4_FAULT_DELAY" "0.15")
              ;; Save a buffer with an existing marker, forcing rediscovery.
              (goto-char (point-max)) (insert "extra\n")
              (let ((overlays (cl-remove-if-not
                               (lambda (ov) (overlay-get ov 'diff-hl))
                               (overlays-in (point-min) (point-max)))))
                (should overlays)
                (save-buffer)
                (dotimes (_ 3) (diff-hl-update))
                (should (eq vc-p4-status 'pending))
                (vc-p4-test-await
                 (lambda ()
                   ;; Check each event-loop turn, including metadata completion.
                   (should (cl-every #'overlay-buffer overlays))
                   (cl-some #'vc-p4--diff-task-worker vc-p4--diff-tasks)))
                (should (equal (vc-p4-test-hunks) '((2 change))))
                (vc-p4-test-await (lambda () (equal (vc-p4-test-hunks) '((2 change) (4 insert)))))
                ;; Stability is required through completion, not just while pending.
                (should (cl-every #'overlay-buffer overlays))
                (dotimes (_ 3)
                  (diff-hl-update)
                  (vc-p4-test-await (lambda () (null vc-p4--diff-tasks)))
                  (should (cl-every #'overlay-buffer overlays))))
              (should (equal (vc-p4-test-hunks) '((2 change) (4 insert))))
              ;; A completed clean result must still clear the previous marker.
              (erase-buffer) (insert "one\ntwo\nthree\n") (save-buffer)
              (vc-p4-test-await (lambda () (eq (vc-file-getprop file 'vc-state) 'up-to-date)))
              (vc-p4-test-await (lambda () (null (vc-p4-test-hunks)))))
          (when flydiff (diff-hl-flydiff-mode -1)))))))
