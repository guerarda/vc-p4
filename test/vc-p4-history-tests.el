;;; vc-p4-history-tests.el --- Native read-only history contracts -*- lexical-binding: t; -*-
(require 'vc-p4-tests)
(require 'vc-p4-history)

(defconst vc-p4-history-test-records
  '(((depotFile . "//depot/new.txt") (rev0 . "1") (change0 . "30")
     (action0 . "move/add") (user0 . "alice") (time0 . "1700000030")
     (desc0 . "moved\n\nfull message")
     (how0\,0 . "moved from") (file0\,0 . "//depot/old.txt")
     (srev0\,0 . "#none") (erev0\,0 . "#2"))
    ((depotFile . "//depot/old.txt") (rev0 . "2") (change0 . "20")
     (action0 . "edit") (user0 . "bob") (time0 . "1700000020") (desc0 . "older")
     (rev1 . "1") (change1 . "10") (action1 . "add") (user1 . "alice")
     (time1 . "1700000010") (desc1 . "first"))))

(defmacro vc-p4-history-test (&rest body)
  "Run BODY with isolated asynchronous history tasks."
  (declare (indent 0))
  `(vc-p4-test-async
    (let ((vc-p4-history--tasks nil))
      (unwind-protect (progn ,@body)
        (dolist (task (copy-sequence vc-p4-history--tasks))
          (vc-p4-history--finish task "Test cleanup"))))))

(ert-deftest vc-p4-history-identities-and-native-log-parsing ()
  (let ((rows (vc-p4-history--parse vc-p4-history-test-records)))
    (should (equal (mapcar (lambda (row) (plist-get row :identity)) rows)
                   '("//depot/new.txt#1" "//depot/old.txt#2" "//depot/old.txt#1")))
    (with-temp-buffer
      (vc-p4-log-view-mode)
      (let ((inhibit-read-only t)) (vc-p4-history--render (list (cons "/tmp/new.txt" rows))))
      (goto-char (point-min)) (re-search-forward "^Revision: ")
      (should (equal (log-view-current-tag) "//depot/new.txt#1"))
      (should (equal (log-view-current-file) "/tmp/new.txt"))
      (should (equal (vc-p4-previous-revision nil (log-view-current-tag)) "//depot/old.txt#2"))
      (should-not (vc-p4-next-revision nil (log-view-current-tag)))
      (should (string-match-p "Changelist: @30" (buffer-string)))
      (should (string-match-p "    full message" (buffer-string)))
      (should (string-match-p "moved from //depot/old.txt#none,#2" (buffer-string)))
      (should buffer-read-only))))

(ert-deftest vc-p4-history-native-log-completes-after-cold-data ()
  (vc-p4-history-test
   (vc-p4-test-with-file "unsaved-safe\n"
                         (let* (callback finished
                                         (vc-log-finish-functions (list (lambda () (setq finished t)))))
                           (cl-letf (((symbol-function 'vc-p4--run-async)
                                      (lambda (_ callback-arg &rest args)
                                        (should (equal (seq-take args 4) '("-Mj" "-ztag" "filelog" "-i")))
                                        (setq callback callback-arg) 'pending)))
                             (save-window-excursion
                               (unwind-protect
                                   (progn
                                     (cl-letf (((symbol-function 'accept-process-output)
                                                (lambda (&rest _) (ert-fail "History command waited"))))
                                       (vc-print-log-internal 'P4 (list file) nil nil 10))
                                     (vc-p4-test-await (lambda () callback))
                                     (should (process-live-p (get-buffer-process "*vc-change-log*")))
                                     (funcall callback (list :status 'success :stdout
                                                             (mapconcat #'json-serialize vc-p4-history-test-records "\n")))
                                     (vc-p4-test-await (lambda () finished))
                                     (with-current-buffer "*vc-change-log*"
                                       (should (derived-mode-p 'vc-p4-log-view-mode))
                                       (should (string-match-p "//depot/old.txt#2" (buffer-string)))))
                                 (when (get-buffer "*vc-change-log*") (kill-buffer "*vc-change-log*")))))))))

(ert-deftest vc-p4-history-qualified-base-keeps-depot-identity ()
  (vc-p4-test-with-file "new contents\n"
                        (let (args)
                          (cl-letf (((symbol-function 'vc-p4--stat)
                                     (lambda (&rest _) (ert-fail "Looked up current depot mapping")))
                                    ((symbol-function 'vc-p4--cached)
                                     (lambda (_ command raw immutable)
                                       (setq args command)
                                       (should raw) (should immutable) "old contents\n")))
                            (should (equal (vc-p4--base file "//depot/old%23name.txt#2") "old contents\n"))
                            (should (equal args '("print" "-q" "-o" "-" "//depot/old%23name.txt#2")))))))

(ert-deftest vc-p4-history-revision-buffer-is-async-and-preserves-source ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (let ((rows (vc-p4-history--parse vc-p4-history-test-records)) ready buffer)
                           (with-temp-buffer
                             (setq buffer-file-name file buffer-file-coding-system 'utf-8-dos)
                             (insert "unsaved working\n")
                             (cl-letf (((symbol-function 'vc-p4-history--entries) (lambda (&rest _) rows))
                                       ((symbol-function 'vc-p4--base)
                                        (lambda (&rest _) (when ready (encode-coding-string "café\r\n" 'utf-8-unix)))))
                               (unwind-protect
                                   (progn
                                     (cl-letf (((symbol-function 'accept-process-output)
                                                (lambda (&rest _) (ert-fail "Revision view waited"))))
                                       (setq buffer (vc-find-revision file "//depot/old.txt#2" 'P4)))
                                     (should (buffer-live-p buffer))
                                     (should (process-live-p (get-buffer-process buffer)))
                                     (setq ready t)
                                     (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                     (with-current-buffer buffer
                                       (should (equal (buffer-string) "café\n"))
                                       (should buffer-read-only)
                                       (should-not buffer-file-name)
                                       (should vc-p4-revision-mode)
                                       (should (equal vc-buffer-revision "//depot/old.txt#2")))
                                     (should (equal (buffer-string) "unsaved working\n"))
                                     (should (buffer-modified-p))
                                     (should (equal (vc-p4--local-bytes file) "working\n")))
                                 (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(ert-deftest vc-p4-history-stale-context-cannot-publish ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (let ((context 'first) acquired rendered
                               (output (generate-new-buffer " *history-stale*")))
                           (unwind-protect
                               (cl-letf (((symbol-function 'vc-p4--context) (lambda (_) context)))
                                 (vc-p4-history--start
                                  (list file) output
                                  (lambda () (setq acquired t) (signal 'vc-p4-pending nil))
                                  (lambda (_) (setq rendered t)))
                                 (vc-p4-test-await (lambda () acquired))
                                 (setq context 'second)
                                 (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                 (should-not rendered)
                                 (with-current-buffer output
                                   (should (string-match-p "configuration changed" (buffer-string)))))
                             (kill-buffer output))))))

(ert-deftest vc-p4-history-view-cancellation-releases-timer-and-gate ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (let ((output (generate-new-buffer " *history-cancel*")))
                           (vc-p4-history--start
                            (list file) output (lambda () (signal 'vc-p4-pending nil))
                            (lambda (_) (ert-fail "Published cancelled view")))
                           (let ((task (car vc-p4-history--tasks)))
                             (kill-buffer output)
                             (should (vc-p4-history--task-done task))
                             (should-not (process-live-p (vc-p4-history--task-gate task)))
                             (should-not vc-p4-history--tasks))))))

(ert-deftest vc-p4-history-completion-loads-without-blocking ()
  (vc-p4-test-with-file "working\n"
                        (let ((rows (vc-p4-history--parse vc-p4-history-test-records)) ready)
                          (cl-letf (((symbol-function 'vc-p4-history--entries)
                                     (lambda (&rest _) (if ready rows (signal 'vc-p4-pending nil)))))
                            (let ((table (vc-p4-revision-completion-table (list file))))
                              (should-not (all-completions "//" table))
                              (setq ready t)
                              (should (member "//depot/old.txt#2" (all-completions "//" table)))
                              (should (member "#1" (all-completions "#" table)))
                              (should (member "@30" (all-completions "@" table)))
                              (should-not (member "30" (all-completions "" table))))))))

(ert-deftest vc-p4-history-navigation-skips-deleted-content ()
  (with-temp-buffer
    (setq vc-p4-history--entries
          (list (list :depot "//depot/file" :identity "//depot/file#3" :revision "3" :action "delete")
                (list :depot "//depot/file" :identity "//depot/file#2" :revision "2" :action "edit")
                (list :depot "//depot/file" :identity "//depot/file#1" :revision "1" :action "add")))
    (should (equal (vc-p4-previous-revision nil "//depot/file#3") "//depot/file#2"))
    (should-not (vc-p4-next-revision nil "//depot/file#2"))
    (should-not (vc-p4-previous-revision nil "//depot/file#1"))))

(ert-deftest vc-p4-history-revision-detects-utf16-from-log-buffer ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (let ((rows (vc-p4-history--parse vc-p4-history-test-records)) buffer)
                           (cl-letf (((symbol-function 'vc-p4-history--entries) (lambda (&rest _) rows))
                                     ((symbol-function 'vc-p4--base)
                                      (lambda (&rest _) (encode-coding-string "hello λ\n" 'utf-16le-with-signature))))
                             (unwind-protect
                                 (progn
                                   (setq buffer (vc-find-revision file "//depot/old.txt#2" 'P4))
                                   (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                   (with-current-buffer buffer
                                     (should (equal (buffer-string) "hello λ\n"))))
                               (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest vc-p4-history-symbolic-revision-does-not-reuse-old-content ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (let ((rows (vc-p4-history--parse vc-p4-history-test-records))
                               (contents "first\n") buffers)
                           (cl-letf (((symbol-function 'vc-p4-history--entries) (lambda (&rest _) rows))
                                     ((symbol-function 'vc-p4--base) (lambda (&rest _) contents)))
                             (unwind-protect
                                 (progn
                                   (push (vc-find-revision file "#head" 'P4) buffers)
                                   (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                   (setq contents "second\n")
                                   (push (vc-find-revision file "#head" 'P4) buffers)
                                   (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                   (with-current-buffer (car buffers)
                                     (should (equal (buffer-string) "second\n"))))
                               (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(ert-deftest vc-p4-history-failed-revision-can-be-retried ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (let ((rows (vc-p4-history--parse vc-p4-history-test-records)) ready buffer)
                           (cl-letf (((symbol-function 'vc-p4-history--entries) (lambda (&rest _) rows))
                                     ((symbol-function 'vc-p4--base)
                                      (lambda (&rest _) (if ready "recovered\n" (signal 'vc-p4-error '("Unavailable"))))))
                             (unwind-protect
                                 (progn
                                   (setq buffer (vc-find-revision file "//depot/old.txt#2" 'P4))
                                   (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                   (setq ready t)
                                   (setq buffer (vc-find-revision file "//depot/old.txt#2" 'P4))
                                   (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                   (with-current-buffer buffer
                                     (should (equal (buffer-string) "recovered\n"))))
                               (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest vc-p4-history-find-revision-delegates-other-backends ()
  (should (eq (vc-p4-history--find-revision
               (lambda (file revision backend)
                 (should (equal (list file revision backend) '("file" "HEAD" Git))) 'delegated)
               "file" "HEAD" 'Git) 'delegated)))

(ert-deftest vc-p4-history-start-revision-retains-ancestor-path ()
  (vc-p4-test-with-file "working\n"
                        (cl-letf (((symbol-function 'vc-p4--cached)
                                   (lambda (_ args &rest _)
                                     (should (equal args '("filelog" "-i" "-l" "-m" "1" "//depot/old.txt#2")))
                                     vc-p4-history-test-records)))
                          (should (vc-p4-history--entries file "//depot/old.txt#2" 1)))))

(ert-deftest vc-p4-history-view-queue-is-bounded-and-supersedes-output ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (let ((vc-p4-max-pending-views 1)
                               (first (generate-new-buffer " *history-first*"))
                               (second (generate-new-buffer " *history-second*")))
                           (unwind-protect
                               (progn
                                 (vc-p4-history--start (list file) first (lambda () (signal 'vc-p4-pending nil)) #'ignore)
                                 (let ((old (car vc-p4-history--tasks)))
                                   (vc-p4-history--start (list file) first (lambda () "latest") #'insert)
                                   (should (vc-p4-history--task-done old)))
                                 (should-error (vc-p4-history--start (list file) second #'ignore #'ignore) :type 'user-error)
                                 (should (= (length vc-p4-history--tasks) 1))
                                 (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                 (with-current-buffer first (should (equal (buffer-string) "latest"))))
                             (kill-buffer first) (kill-buffer second))))))

(ert-deftest vc-p4-history-view-retains-invoking-workspace-settings ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (with-temp-buffer
                           (setq-local vc-p4-program "/custom/p4")
                           (setq-local process-environment (cons "P4CLIENT=history-client" process-environment))
                           (let ((output (generate-new-buffer " *history-settings*")))
                             (unwind-protect
                                 (progn
                                   (vc-p4-history--start (list file) output (lambda () "history") #'insert)
                                   (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                   (with-current-buffer output
                                     (should (local-variable-p 'vc-p4-program))
                                     (should (equal vc-p4-program "/custom/p4"))
                                     (should (equal (getenv "P4CLIENT") "history-client"))))
                               (kill-buffer output)))))))

(ert-deftest vc-p4-history-submitted-changes-describe-and-affected-file-links ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (let ((rows (vc-p4-history--parse vc-p4-history-test-records)) buffers commands)
                           (save-window-excursion
                             (cl-letf (((symbol-function 'vc-p4-history--records)
                                        (lambda (_ args)
                                          (push args commands)
                                          (pcase (car args)
                                            ("changes" '(((change . "30") (user . "alice") (time . "1700000030") (desc . "submitted"))))
                                            ("describe" '(((change . "30") (user . "alice") (time . "1700000030")
                                                           (desc . "full\ndescription") (status . "submitted")
                                                           (depotFile0 . "//depot/new.txt") (rev0 . "1") (action0 . "move/add")
                                                           (depotFile1 . "//depot/old.txt") (rev1 . "3") (action1 . "move/delete")))))))
                                       ((symbol-function 'vc-p4-history--entries) (lambda (&rest _) rows))
                                       ((symbol-function 'vc-p4--base)
                                        (lambda (_ revision) (should (equal revision "//depot/new.txt#1")) "submitted bytes\n")))
                               (unwind-protect
                                   (progn
                                     (vc-p4-changes file 2)
                                     (push (current-buffer) buffers)
                                     (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                     (should buffer-read-only)
                                     (should (equal (car commands)
                                                    (list "changes" "-i" "-l" "-s" "submitted" "-m" "2" (vc-p4--escape file))))
                                     (goto-char (point-min)) (search-forward "@30")
                                     (button-activate (button-at (1- (point))))
                                     (push (current-buffer) buffers)
                                     (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                     (should (equal (car commands) '("describe" "-s" "30")))
                                     (should (string-match-p "move/delete  //depot/old.txt#3 (no content)" (buffer-string)))
                                     (goto-char (point-min)) (search-forward "//depot/new.txt#1")
                                     (button-activate (button-at (1- (point))))
                                     (push (current-buffer) buffers)
                                     (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                     (should (equal (buffer-string) "submitted bytes\n"))
                                     (should buffer-read-only)
                                     (should-not buffer-file-name)
                                     (should (equal (vc-p4--local-bytes file) "working\n")))
                                 (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer))))))))))

(ert-deftest vc-p4-history-describe-rejects-pending-changelists ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (save-window-excursion
                           (cl-letf (((symbol-function 'vc-p4-history--records)
                                      (lambda (&rest _) '(((change . "10") (status . "pending"))))))
                             (vc-p4-describe-change "@10" file)
                             (unwind-protect
                                 (progn
                                   (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                   (should (string-match-p "not a submitted changelist" (buffer-string))))
                               (kill-buffer (current-buffer))))))))

(ert-deftest vc-p4-history-affected-file-uses-its-own-history ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (let ((rows (vc-p4-history--parse vc-p4-history-test-records)) buffer queried)
                           (cl-letf (((symbol-function 'vc-p4-history--entries)
                                      (lambda (_ &optional _start _limit depot)
                                        (if depot
                                            (progn (setq queried depot)
                                                   (list (list :depot depot :identity (concat depot "#1") :revision "1" :action "add")))
                                          rows)))
                                     ((symbol-function 'vc-p4--base) (lambda (&rest _) "other file\n")))
                             (unwind-protect
                                 (progn
                                   (setq buffer (vc-find-revision file "//depot/unrelated.txt#1" 'P4))
                                   (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                   (should (equal queried "//depot/unrelated.txt"))
                                   (with-current-buffer buffer
                                     (should (equal vc-p4-history--depot "//depot/unrelated.txt"))
                                     (should-error (vc-p4-revision-previous) :type 'user-error)))
                               (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest vc-p4-history-native-log-revert-preserves-local-context ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (with-temp-buffer
                           (setq-local vc-p4-program "/custom/p4")
                           (let ((rows (vc-p4-history--parse vc-p4-history-test-records)))
                             (save-window-excursion
                               (cl-letf (((symbol-function 'vc-p4-history--entries) (lambda (&rest _) rows)))
                                 (unwind-protect
                                     (progn
                                       (vc-print-log-internal 'P4 (list file) nil nil 10)
                                       (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                       (should (equal vc-p4-program "/custom/p4"))
                                       (revert-buffer t t)
                                       (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                       (should (equal vc-p4-program "/custom/p4"))
                                       (should (string-match-p "Revision: //depot/new.txt#1" (buffer-string))))
                                   (when (get-buffer "*vc-change-log*") (kill-buffer "*vc-change-log*"))))))))))

(ert-deftest vc-p4-history-changelist-numbers-are-not-file-revisions ()
  (should (equal (vc-p4-history--change-number "@123") "123"))
  (dolist (invalid '("#3" "0" "default" "3\n4" "-2" "@"))
    (should-error (vc-p4-history--change-number invalid) :type 'user-error)))

(provide 'vc-p4-history-tests)
