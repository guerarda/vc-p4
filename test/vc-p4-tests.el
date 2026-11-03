;;; vc-p4-tests.el --- Backend contract tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'vc-p4)

(defmacro vc-p4-test-with-file (contents &rest body)
  "Create an isolated FILE containing CONTENTS and evaluate BODY."
  (declare (indent 1))
  `(let* ((file (make-temp-file "vc-p4-test-"))
          (vc-p4--metadata (make-hash-table :test #'equal))
          (vc-p4--contents (make-hash-table :test #'equal)))
     (unwind-protect
         (progn (with-temp-file file (insert ,contents)) ,@body)
       (when-let* ((buffer (get-file-buffer file)))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-file file))))

(ert-deftest vc-p4-package-registers-backend ()
  (should (memq 'P4 vc-handled-backends))
  (should (eq 'file (vc-call-backend 'P4 'revision-granularity))))

(ert-deftest vc-p4-mutations-fail-explicitly ()
  (dolist (operation '(checkin))
    (should-error (vc-call-backend 'P4 operation "unused") :type 'user-error)))

(ert-deftest vc-p4-path-escaping-is-literal ()
  (let ((default-directory "/tmp/"))
    (should (equal (vc-p4--escape "a b%23#@*.txt")
                   "/tmp/a b%2523%23%40%2A.txt"))))

(ert-deftest vc-p4-revision-syntax ()
  (dolist (pair '(("7" . "#7") ("" . "#head") ("#have" . "#have")
                  ("@123" . "@123") ("@=123" . "@=123")))
    (should (equal (vc-p4--revision-spec (car pair)) (cdr pair)))))

(ert-deftest vc-p4-rejects-ambiguous-revisions ()
  (dolist (rev '("HEAD" "#1\n#2" "@"))
    (should-error (vc-p4--revision-spec rev) :type 'user-error)))

(ert-deftest vc-p4-json-records-preserve-values ()
  (should (equal (vc-p4--parse-json
                  "{\"depotFile\":\"//depot/a b\",\"haveRev\":\"7\"}\n{\"action\":\"edit\"}\n")
                 '(((depotFile . "//depot/a b") (haveRev . "7"))
                   ((action . "edit"))))))

(ert-deftest vc-p4-json-rejects-partial-errors ()
  (should-error (vc-p4--parse-json
                 "{\"haveRev\":\"7\"}\n{\"severity\":3,\"data\":\"Login expired\"}\n")
                :type 'vc-p4-error))

(ert-deftest vc-p4-process-preserves-arguments ()
  (let ((vc-p4-program "/bin/sh"))
    (should (equal (vc-p4--run temporary-file-directory "-c" "printf '%s' \"$1\""
                               "test" "a b; $(false) * # @")
                   "a b; $(false) * # @"))))

(ert-deftest vc-p4-process-exits-before-stdin-closes ()
  (let ((vc-p4-program "/bin/sh")
        (send-eof (symbol-function 'process-send-eof)))
    (cl-letf (((symbol-function 'process-send-eof)
               (lambda (process)
                 (while (process-live-p process)
                   (accept-process-output process 0.01))
                 (funcall send-eof process))))
      (should (equal (vc-p4--run temporary-file-directory "-c" "printf done")
                     "done")))))

(ert-deftest vc-p4-process-keeps-stderr-out-of-content ()
  (let ((vc-p4-program "/bin/sh"))
    (should (equal (vc-p4--run temporary-file-directory "-c"
                               "printf content; printf diagnostic >&2") "content"))))

(ert-deftest vc-p4-process-reports-failure ()
  (let ((vc-p4-program "/bin/sh"))
    (should-error (vc-p4--run temporary-file-directory "-c"
                             "printf denied >&2; exit 1") :type 'vc-p4-error)))

(ert-deftest vc-p4-process-timeout-cleans-up ()
  (let ((vc-p4-program "/bin/sh") (vc-p4-command-timeout 0.05)
        (before (process-list)))
    (should-error (vc-p4--run temporary-file-directory "-c" "while :; do :; done")
                  :type 'vc-p4-error)
    (should-not (cl-set-difference (process-list) before))))

(ert-deftest vc-p4-missing-cli-does-not-claim-files ()
  (let ((vc-p4-program "/nonexistent/p4"))
    (should-not (vc-p4-registered "/tmp/file"))))

(ert-deftest vc-p4-remote-files-are-not-claimed ()
  (should-not (vc-p4-registered "/ssh:example:/tmp/file")))

(ert-deftest vc-p4-working-revision-is-have-not-head ()
  (cl-letf (((symbol-function 'vc-p4--stat)
             (lambda (&rest _) '((haveRev . "7") (headRev . "8")))))
    (should (equal (vc-p4-working-revision "file") "7"))))

(ert-deftest vc-p4-add-has-empty-baseline ()
  (cl-letf (((symbol-function 'vc-p4--stat)
             (lambda (&rest _) '((action . "add")))))
    (should (equal (vc-p4-working-revision "file") "0"))
    (should (equal (vc-p4--base "file" "0") ""))))

(ert-deftest vc-p4-state-retains-local-edits-when-head-advances ()
  (vc-p4-test-with-file "changed\n"
    (cl-letf (((symbol-function 'vc-p4--stat)
               (lambda (&rest _) '((haveRev . "7") (headRev . "8"))))
              ((symbol-function 'vc-p4--base)
               (lambda (_ rev) (should (equal rev "7")) "original\n")))
      (should (eq (vc-p4-state file) 'needs-merge)))))

(ert-deftest vc-p4-opened-unchanged-file-is-clean ()
  (vc-p4-test-with-file "original\n"
    (cl-letf (((symbol-function 'vc-p4--stat)
               (lambda (&rest _) '((haveRev . "7") (action . "edit"))))
              ((symbol-function 'vc-p4--base) (lambda (&rest _) "original\n")))
      (should (eq (vc-p4-state file) 'up-to-date)))))

(ert-deftest vc-p4-diff-honors-zero-context-and-have-revision ()
  (vc-p4-test-with-file "one\nchanged\nthree\n"
    (let ((vc-diff-switches '("-U0")))
      (cl-letf (((symbol-function 'vc-p4-working-revision) (lambda (_) "7"))
                ((symbol-function 'vc-p4--base)
                 (lambda (_ rev) (should (equal rev "7")) "one\ntwo\nthree\n")))
        (with-temp-buffer
          (should (= 1 (vc-p4-diff (list file) nil nil (current-buffer))))
          (should (string-match-p (regexp-quote "@@ -2 +2 @@") (buffer-string)))
          (should (string-match-p (regexp-quote "-two\n+changed") (buffer-string))))))))

(ert-deftest vc-p4-empty-diff-returns-zero ()
  (vc-p4-test-with-file "same\n"
    (cl-letf (((symbol-function 'vc-p4-working-revision) (lambda (_) "1"))
              ((symbol-function 'vc-p4--base) (lambda (&rest _) "same\n")))
      (with-temp-buffer
        (should (= 0 (vc-p4-diff (list file) nil nil (current-buffer))))
        (should (equal (buffer-string) ""))))))

(ert-deftest vc-p4-immutable-base-cached-but-symbolic-base-expires ()
  (vc-p4-test-with-file ""
    (let ((calls 0) callback)
      (cl-letf (((symbol-function 'vc-p4--stat)
                 (lambda (&rest _) '((depotFile . "//depot/file"))))
                ((symbol-function 'vc-p4--run-async)
                 (lambda (_ cb &rest _) (cl-incf calls) (setq callback cb) 'pending)))
        (should-not (vc-p4--base file "7"))
        (should-not (vc-p4--base file "7"))
        (should (= calls 1))
        (funcall callback '(:status success :stdout "base"))
        (should (equal (vc-p4--base file "7") "base"))
        (should-not (vc-p4--base file "#head"))
        (funcall callback '(:status success :stdout "head"))
        (should (equal (vc-p4--base file "#head") "head"))
        (let ((vc-p4-metadata-ttl -1))
          (should (equal (vc-p4--base file "7") "base"))
          (should-not (vc-p4--base file "#head")))
        (should (= calls 3))))))

(provide 'vc-p4-tests)

(ert-deftest vc-p4-diff-refresh-removes-stale-hunks ()
  (vc-p4-test-with-file "changed\n"
    (cl-letf (((symbol-function 'vc-p4-working-revision) (lambda (_) "1"))
              ((symbol-function 'vc-p4--base) (lambda (&rest _) "original\n")))
      (with-temp-buffer
        (vc-p4-diff (list file) nil nil (current-buffer))
        (should (> (buffer-size) 0))
        (with-temp-file file (insert "original\n"))
        (should (= 0 (vc-p4-diff (list file) nil nil (current-buffer))))
        (should (= 0 (buffer-size)))))))

(ert-deftest vc-p4-process-preserves-non-ascii-bytes ()
  (let ((vc-p4-program "/bin/sh"))
    (let ((bytes (vc-p4--run temporary-file-directory "-c" "printf '\\303\\251\\000\\377'")))
      (should-not (multibyte-string-p bytes))
      (should (equal bytes (unibyte-string 195 169 0 255))))))

(ert-deftest vc-p4-cache-context-tracks-config-edits ()
  (let* ((dir (make-temp-file "vc-p4-config-" t))
         (process-environment (copy-sequence process-environment))
         (file (expand-file-name "file.txt" dir))
         (config (expand-file-name ".p4config" dir)))
    (unwind-protect
        (progn
          (setenv "P4CONFIG" ".p4config")
          (let ((before (vc-p4--context file)))
            (with-temp-file config (insert "P4CLIENT=first\n"))
            (should-not (equal before (vc-p4--context file))))
          (let ((first (vc-p4--context file)))
            (with-temp-file config (insert "P4CLIENT=another-client\n"))
            (should-not (equal first (vc-p4--context file)))))
      (delete-directory dir t))))

(ert-deftest vc-p4-process-quit-cleans-up ()
  (let ((vc-p4-program "/bin/sh")
        (before (process-list))
        (buffers (buffer-list))
        quit-seen)
    (cl-letf (((symbol-function 'accept-process-output)
               (lambda (&rest _) (signal 'quit nil))))
      (condition-case nil
          (vc-p4--run temporary-file-directory "-c" "while :; do :; done")
        (quit (setq quit-seen t))))
    (should quit-seen)
    (should-not (cl-set-difference (process-list) before))
    (should-not (cl-set-difference (buffer-list) buffers))))

(ert-deftest vc-p4-outage-does-not-claim-file-and-keeps-diagnostic ()
  (let ((vc-p4-program "/bin/sh")
        (vc-p4-last-error nil))
    (cl-letf (((symbol-function 'vc-p4--stat)
               (lambda (&rest _) (signal 'vc-p4-error '("TCP connect failed")))))
      (should-not (vc-p4-registered "/tmp/file"))
      (should (string-match-p "TCP connect failed" vc-p4-last-error)))))

(defmacro vc-p4-test-async (&rest body)
  "Run BODY with an isolated asynchronous runner and guaranteed cleanup."
  (declare (indent 0))
  `(let ((vc-p4--queue nil) (vc-p4--active nil) (vc-p4--diff-tasks nil)
         (vc-p4--dispatch-timer nil) (vc-p4-program "/bin/sh")
         (vc-p4-command-timeout 2) (vc-p4-max-processes 1))
     (unwind-protect (progn ,@body)
       (dolist (task (copy-sequence vc-p4--diff-tasks)) (vc-p4--diff-finish task nil t))
       (dolist (job (append vc-p4--queue vc-p4--active)) (vc-p4--cancel job))
       (when vc-p4--dispatch-timer (cancel-timer vc-p4--dispatch-timer)))))

(defun vc-p4-test-await (predicate)
  "Pump test events until PREDICATE succeeds, with a finite deadline."
  (let ((deadline (+ (float-time) 4)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should (funcall predicate))))

(ert-deftest vc-p4-async-preserves-bytes-arguments-and-stderr ()
  (vc-p4-test-async
    (let* (result
           (job (vc-p4--run-async
                 temporary-file-directory (lambda (value) (setq result value))
                 "-c" "printf '%s' \"$1\"; printf '\\000\\377'; printf diagnostic >&2"
                 "test" "a b; $(false) * # @")))
      (should-not result)
      (vc-p4-test-await (lambda () result))
      (should (eq (plist-get result :status) 'success))
      (should (equal (plist-get result :stdout)
                     (concat "a b; $(false) * # @" (unibyte-string 0 255))))
      (should (equal (plist-get result :stderr) "diagnostic"))
      (should-not (buffer-live-p (vc-p4--job-output job)))
      (should-not (buffer-live-p (vc-p4--job-errors job)))
      (should-not (vc-p4--job-timer job)))))

(ert-deftest vc-p4-async-returns-without-waiting-and-cancels-once ()
  (vc-p4-test-async
    (let ((calls 0) result job)
      ;; A wait loop in submission or dispatch is a regression even if it
      ;; pumps timers.  Event pumping belongs only to the test harness.
      (cl-letf (((symbol-function 'accept-process-output)
                 (lambda (&rest _) (ert-fail "Runner waited for output"))))
        (setq job (vc-p4--run-async
                   temporary-file-directory
                   (lambda (value) (cl-incf calls) (setq result value))
                   "-c" "while :; do :; done"))
        (cancel-timer vc-p4--dispatch-timer)
        (vc-p4--dispatch)
        (should (process-live-p (vc-p4--job-process job)))
        (should-not result)
        (vc-p4--cancel job))
      (vc-p4--cancel job)
      (vc-p4--completed job)
      (should (= calls 1))
      (should (eq (plist-get result :status) 'cancelled))
      (should-not vc-p4--active))))

(ert-deftest vc-p4-async-timeout-releases-queue ()
  (vc-p4-test-async
    (let* ((vc-p4-command-timeout 0.1) (calls 0) first second
           (job (vc-p4--run-async
                 temporary-file-directory
                 (lambda (value) (cl-incf calls) (setq first value))
                 "-c" "while :; do :; done")))
      (vc-p4--run-async temporary-file-directory (lambda (value) (setq second value))
                        "-c" "printf next")
      (vc-p4-test-await (lambda () (vc-p4--job-process job)))
      (should (= (length vc-p4--active) 1))
      (should (= (length vc-p4--queue) 1))
      (vc-p4-test-await (lambda () second))
      (should (eq (plist-get first :status) 'timeout))
      (should (equal (plist-get second :stdout) "next"))
      (vc-p4--cancel job)
      (should (= calls 1))
      (should-not vc-p4--active))))

(ert-deftest vc-p4-async-cancel-before-start ()
  (vc-p4-test-async
    (let* ((calls 0)
           (job (vc-p4--run-async temporary-file-directory
                                 (lambda (_) (cl-incf calls)) "-c" "exit 99")))
      (vc-p4--cancel job)
      (vc-p4--cancel job)
      (should (= calls 1))
      (should-not (vc-p4--job-process job))
      (should-not vc-p4--queue))))

(ert-deftest vc-p4-async-reports-exit-and-start-failures ()
  (vc-p4-test-async
    (let (result)
      (vc-p4--run-async temporary-file-directory (lambda (value) (setq result value))
                        "-c" "printf partial; printf denied >&2; exit 7")
      (vc-p4-test-await (lambda () result))
      (should (eq (plist-get result :status) 'error))
      (should (= (plist-get result :exit-code) 7))
      (should (equal (plist-get result :stderr) "denied"))
      (setq result nil)
      (let ((vc-p4-program "/nonexistent/p4"))
        (vc-p4--run-async temporary-file-directory (lambda (value) (setq result value))))
      (vc-p4-test-await (lambda () result))
      (should (eq (plist-get result :status) 'error))
      (should-not vc-p4--active))))

(ert-deftest vc-p4-async-captures-submission-environment ()
  (vc-p4-test-async
    (let ((process-environment (copy-sequence process-environment)) result)
      (setenv "VC_P4_TEST_VALUE" "submitted")
      (vc-p4--run-async temporary-file-directory (lambda (value) (setq result value))
                        "-c" "printf '%s' \"$VC_P4_TEST_VALUE\"")
      (setenv "VC_P4_TEST_VALUE" "changed")
      (vc-p4-test-await (lambda () result))
      (should (equal (plist-get result :stdout) "submitted")))))

(ert-deftest vc-p4-async-drains-large-output ()
  (vc-p4-test-async
    (let (result)
      (vc-p4--run-async
       temporary-file-directory (lambda (value) (setq result value))
       "-c" "i=0; while [ $i -lt 10000 ]; do printf abcdefgh; printf 12345678 >&2; i=$((i+1)); done")
      (vc-p4-test-await (lambda () result))
      (should (eq (plist-get result :status) 'success))
      (should (= (length (plist-get result :stdout)) 80000))
      (should (= (length (plist-get result :stderr)) 80000)))))

(ert-deftest vc-p4-async-callback-error-does-not-stop-queue ()
  (vc-p4-test-async
    (let (result)
      (vc-p4--run-async temporary-file-directory (lambda (_) (error "Consumer failed"))
                        "-c" "exit 0")
      (vc-p4--run-async temporary-file-directory (lambda (value) (setq result value))
                        "-c" "printf next")
      (vc-p4-test-await (lambda () result))
      (should (equal (plist-get result :stdout) "next"))
      (should-not vc-p4--active))))

(ert-deftest vc-p4-cold-vc-paths-only-schedule-work ()
  (vc-p4-test-with-file "contents"
    (let ((calls 0) (vc-p4-program "/bin/sh"))
      (cl-letf (((symbol-function 'vc-p4--run) (lambda (&rest _) (ert-fail "Synchronous P4")))
                ((symbol-function 'vc-p4--run-async)
                 (lambda (&rest _) (cl-incf calls) 'pending)))
        (should-not (vc-p4-registered file))
        (should-not (vc-p4-state file))
        (should-not (vc-p4-working-revision file))
        (should-not (vc-p4-root file))
        (should (eq (vc-p4-checkout-model (list file)) 'announce))
        (with-temp-buffer
          (should-error (vc-p4-find-revision file "1" (current-buffer)) :type 'vc-p4-pending)
          (should (= (buffer-size) 0)))
        (dotimes (_ 10) (vc-p4-registered file) (vc-p4-state file))
        (should (= calls 3))))))

(ert-deftest vc-p4-cache-expiry-does-not-report-clean ()
  (vc-p4-test-with-file "contents"
    (let (callback)
      (cl-letf (((symbol-function 'vc-p4--run-async)
                 (lambda (_ cb &rest _) (setq callback cb) 'pending)))
        (should-not (vc-p4--stat file))
        (funcall callback '(:status success :stdout "{\"haveRev\":\"1\",\"clientFile\":\"file\"}\n"))
        (should (equal (vc-p4-working-revision file) "1"))
        (let ((vc-p4-metadata-ttl -1))
          (should-not (vc-p4-state file))
          (should-not (vc-p4-working-revision file)))))))

(ert-deftest vc-p4-cache-error-backs-off-and-retains-diagnostic ()
  (vc-p4-test-with-file "contents"
    (let ((calls 0) callback)
      (cl-letf (((symbol-function 'vc-p4--run-async)
                 (lambda (_ cb &rest _) (cl-incf calls) (setq callback cb) 'pending)))
        (vc-p4--stat file)
        (funcall callback '(:status error :stderr "Login expired" :stdout ""))
        (dotimes (_ 20) (should-not (vc-p4-state file)))
        (should (= calls 1))
        (should (string-match-p "Login expired" vc-p4-last-error))
        (should (eq vc-p4-status 'error))))))

(ert-deftest vc-p4-cache-ignores-replaced-entry ()
  (vc-p4-test-with-file "contents"
    (let (callback)
      (cl-letf (((symbol-function 'vc-p4--run-async)
                 (lambda (_ cb &rest _) (setq callback cb) 'pending)))
        (vc-p4--stat file)
        (let ((old callback))
          (clrhash vc-p4--metadata)
          (vc-p4--stat file)
          (funcall old '(:status success :stdout "{\"haveRev\":\"99\"}\n"))
          (should-not (vc-p4-working-revision file))
          (funcall callback '(:status success :stdout "{\"haveRev\":\"1\"}\n"))
          (should (equal (vc-p4-working-revision file) "1")))))))

(ert-deftest vc-p4-diff-async-honors-contract-and-context ()
  (vc-p4-test-async
    (vc-p4-test-with-file "one\nchanged\nthree\n"
      (let ((vc-diff-switches '("-U0")))
        (cl-letf (((symbol-function 'vc-p4-working-revision) (lambda (_) "7"))
                  ((symbol-function 'vc-p4--base) (lambda (&rest _) "one\ntwo\nthree\n")))
          (with-temp-buffer
            (should (= 1 (vc-p4-diff (list file) nil nil (current-buffer) t)))
            (should (process-live-p (get-buffer-process (current-buffer))))
            (vc-p4-test-await (lambda () (not (get-buffer-process (current-buffer)))))
            (should (string-match-p (regexp-quote "@@ -2 +2 @@") (buffer-string)))
            (should (string-match-p (regexp-quote "-two\n+changed") (buffer-string)))))))))

(ert-deftest vc-p4-diff-async-rejects-obsolete-source ()
  (vc-p4-test-async
    (vc-p4-test-with-file "one\n"
      (let ((output (generate-new-buffer " *p4-test-diff*")))
        (unwind-protect
            (cl-letf (((symbol-function 'vc-p4-working-revision) (lambda (_) "1"))
                      ((symbol-function 'vc-p4--base) (lambda (&rest _) "base\n")))
              (with-temp-buffer
                (setq buffer-file-name file)
                (insert "one\n")
                (vc-p4-diff (list file) nil nil output t)
                (insert "changed before dispatch\n")
                (vc-p4-test-await (lambda () (not (get-buffer-process output))))
                (with-current-buffer output (should (= (buffer-size) 0)))))
          (kill-buffer output))))))

(ert-deftest vc-p4-killed-source-cancels-requests-and-diff ()
  (vc-p4-test-async
    (vc-p4-test-with-file "one\n"
      (let ((source (generate-new-buffer " *p4-test-source*"))
            (output (generate-new-buffer " *p4-test-output*")))
        (unwind-protect
            (progn
              (with-current-buffer source
                (setq buffer-file-name file)
                (vc-p4--cached file '("-c" "while :; do :; done") t)
                (vc-p4-diff (list file) nil nil output t))
              (kill-buffer source)
              (vc-p4-test-await (lambda () (not (get-buffer-process output))))
              (should-not vc-p4--queue)
              (should-not vc-p4--active)
              (should-not vc-p4--diff-tasks))
          (when (buffer-live-p source) (kill-buffer source))
          (kill-buffer output))))))

(ert-deftest vc-p4-refresh-cancels-obsolete-work ()
  (vc-p4-test-async
    (vc-p4-test-with-file "one\n"
      (vc-p4--cached file '("-c" "while :; do :; done") t)
      (let ((job (car vc-p4--queue)))
        (vc-p4-refresh)
        (should (vc-p4--job-done job))
        (should (eq (plist-get (vc-p4--job-result job) :status) 'cancelled))
        (should (= (hash-table-count vc-p4--contents) 0))))))

(ert-deftest vc-p4-workspace-change-clears-old-vc-properties ()
  (vc-p4-test-with-file "one\n"
    (with-temp-buffer
      (setq buffer-file-name file)
      (let ((process-environment (copy-sequence process-environment)))
        (setenv "P4CLIENT" "first")
        (vc-p4--ensure-context)
        (vc-file-setprop file 'vc-backend 'P4)
        (vc-file-setprop file 'vc-state 'up-to-date)
        (setenv "P4CLIENT" "second")
        (vc-p4--ensure-context)
        (should-not (vc-file-getprop file 'vc-backend))
        (should-not (vc-file-getprop file 'vc-state))))))

(ert-deftest vc-p4-refresh-discards-legacy-cache-entries ()
  (vc-p4-test-with-file "contents"
    (puthash (list (vc-p4--context file) file)
             (cons (float-time) '((haveRev . "1"))) vc-p4--metadata)
    (puthash (list (vc-p4--context file) "//depot/file" "1")
             "contents" vc-p4--contents)
    (vc-p4--cancel-file-work file)
    (vc-p4-refresh)
    (should (= (hash-table-count vc-p4--metadata) 0))
    (should (= (hash-table-count vc-p4--contents) 0))))

(ert-deftest vc-p4-new-diff-revision-supersedes-without-error-backoff ()
  (vc-p4-test-async
    (vc-p4-test-with-file "contents"
      (let ((output (generate-new-buffer " *p4-revision-test*")))
        (unwind-protect
            (with-temp-buffer
              (setq buffer-file-name file)
              (insert "contents")
              (vc-file-setprop file 'vc-backend 'P4)
              (vc-file-setprop file 'vc-state 'edited)
              (vc-file-setprop file 'vc-working-revision "1")
              (vc-p4-diff (list file) "1" nil output t)
              (let ((old (car vc-p4--diff-tasks)))
                (should (vc-p4--diff-valid-p old))
                (vc-p4-diff (list file) "2" nil output t)
                (should (vc-p4--diff-task-done old))
                (should (equal (vc-p4--diff-task-rev1 (car vc-p4--diff-tasks)) "2"))
                (should-not (buffer-local-value 'vc-p4--diff-failed-until output))))
          (kill-buffer output)
          (vc-file-clearprops file))))))

(ert-deftest vc-p4-diff-disappearing-destination-cleans-without-hooks ()
  (vc-p4-test-async
    (vc-p4-test-with-file "contents"
      (let ((output (generate-new-buffer " *p4-disappearing-output*")))
        (vc-p4-diff (list file) nil nil output t)
        (let ((task (car vc-p4--diff-tasks)))
          (with-current-buffer output
            (let ((kill-buffer-hook nil)) (kill-buffer output)))
          (vc-p4--diff-step task)
          (should (vc-p4--diff-task-done task))
          (should-not (process-live-p (vc-p4--diff-task-gate task)))
          (should-not vc-p4--diff-tasks))))))
