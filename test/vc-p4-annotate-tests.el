;;; vc-p4-annotate-tests.el --- Native attribution contracts -*- lexical-binding: t; -*-
(require 'vc-p4-history-tests)
(require 'vc-p4-annotate)

(defconst vc-p4-annotate-test-records
  '(((depotFile . "//depot/new.txt") (rev . "1") (type . "text"))
    ((data . "original\n") (lower . "10") (user . "alice")
     (depotFile0 . "//depot/new.txt") (lower0 . "1")
     (depotFile1 . "//depot/old.txt") (lower1 . "1"))))

(ert-deftest vc-p4-annotate-origin-uses-file-chain-not-changelist-number ()
  (should (equal (vc-p4-annotate--origin (cadr vc-p4-annotate-test-records)) "//depot/old.txt#1"))
  (should-error (vc-p4-annotate--origin '((data . "unknown") (lower . "10"))) :type 'vc-p4-error))

(ert-deftest vc-p4-annotate-native-render-navigation-and-time ()
  (let ((history (vc-p4-history--parse vc-p4-history-test-records)))
    (with-temp-buffer
      (vc-annotate-mode)
      (let ((inhibit-read-only t))
        (vc-p4-annotate--render
         "/tmp/file" "//depot/new.txt#1" history
         (list (list :identity "//depot/old.txt#2" :change "20" :user "bob"
                     :data "literal\rinside\r\n" :metadata (cadr history))) t))
      (goto-char (point-min))
      (should (equal (vc-annotate-extract-revision-at-line) '("//depot/old.txt#2" . "/tmp/file")))
      (should (string-match-p "#2 @20 bob .* | literal\rinside\n" (buffer-string)))
      (should (numberp (vc-p4-annotate-time)))
      (should (looking-at "literal"))
      (font-lock-ensure)
      (should (get-text-property (point) 'face))
      (cl-letf (((symbol-function 'vc-p4-describe-change)
                 (lambda (change file) (should (equal (list change file) '("20" "/tmp/file"))))))
        (vc-p4-annotate-describe-change)))))

(ert-deftest vc-p4-annotate-native-command-is-async-and-keeps-unsaved-text ()
  (vc-p4-history-test
   (vc-p4-test-with-file "working\n"
                         (with-temp-buffer
                           (setq buffer-file-name file)
                           (setq-local vc-p4-program "/custom/p4")
                           (insert "unsaved\n")
                           (let ((history (vc-p4-history--parse vc-p4-history-test-records))
                                 (source (current-buffer)) (wanted "//depot/new.txt#1") ready output)
                             (save-window-excursion
                               (cl-letf (((symbol-function 'vc-p4-history--entries) (lambda (&rest _) history))
                                         ((symbol-function 'vc-p4-working-revision) (lambda (_) "1"))
                                         ((symbol-function 'vc-p4-history--records)
                                          (lambda (_ args)
                                            (should (equal args (list "annotate" "-I" "-u" wanted)))
                                            (if ready vc-p4-annotate-test-records (signal 'vc-p4-pending nil)))))
                                 (unwind-protect
                                     (progn
                    (vc-file-setprop file 'vc-backend 'P4)
                                       (cl-letf (((symbol-function 'accept-process-output)
                                                  (lambda (&rest _) (ert-fail "Annotation command waited"))))
                                         (vc-annotate file nil nil nil nil 'P4))
                                       (setq output (window-buffer (selected-window)))
                                       (should vc-p4-history--tasks)
                                       (setq ready t)
                                       (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                       (with-current-buffer output
                                         (should (eq major-mode 'vc-annotate-mode))
                                         (should buffer-read-only)
                                         (should (equal vc-buffer-revision "//depot/new.txt#1"))
                                         (goto-char (point-min))
                                         (should (equal (vc-annotate-extract-revision-at-line)
                                                        (cons "//depot/old.txt#1" file)))
                                         (should (equal vc-p4-program "/custom/p4"))
                                         (setq wanted "//depot/old.txt#2")
                                         (vc-annotate-prev-revision 1)
                                         (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                         (should (equal vc-buffer-revision wanted))
                                         (should (equal vc-p4-program "/custom/p4"))
                                         (setq wanted "//depot/new.txt#1")
                                         (vc-annotate-next-revision 1)
                                         (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                         (should (equal vc-buffer-revision wanted)))
                                       (with-current-buffer source
                                         (should (equal (buffer-string) "unsaved\n"))
                                         (should (buffer-modified-p)))
                                       (should (equal (vc-p4--local-bytes file) "working\n")))
                (when (buffer-live-p output) (kill-buffer output))
                (vc-file-clearprops file)))))))))

(ert-deftest vc-p4-annotate-empty-text-is-valid-but-binary-is-explicit ()
  (dolist (binary '(nil t))
    (vc-p4-history-test
     (vc-p4-test-with-file "working\n"
                           (let ((history (vc-p4-history--parse vc-p4-history-test-records))
                                 (output (generate-new-buffer " *p4-empty-annotation*")))
                             (cl-letf (((symbol-function 'vc-p4-history--entries) (lambda (&rest _) history))
                                       ((symbol-function 'vc-p4-history--records)
                                        (lambda (&rest _)
                                          (list (list (cons 'depotFile "//depot/new.txt")
                                                      (cons 'type (if binary "binary" "text")))))))
                               (unwind-protect
                                   (progn
                                     (vc-p4-annotate-command file output "1")
                                     (vc-p4-test-await (lambda () (null vc-p4-history--tasks)))
                                     (with-current-buffer output
                                       (if binary
                                           (should (string-match-p "binary files" (buffer-string)))
                                         (should (equal (buffer-string) "")))))
                                 (kill-buffer output))))))))

(ert-deftest vc-p4-annotate-navigation-uses-displayed-history-after-cache-expiry ()
  (with-temp-buffer
    (setq vc-p4-history--file "/tmp/file"
          vc-p4-history--entries (vc-p4-history--parse vc-p4-history-test-records))
    (cl-letf (((symbol-function 'vc-p4-history--entries)
               (lambda (&rest _) (ert-fail "Navigation re-queried expired history"))))
      (should (equal (vc-p4-previous-revision "/tmp/file" "//depot/new.txt#1") "//depot/old.txt#2")))))

(ert-deftest vc-p4-annotate-failed-have-lookup-is-not-pending ()
  (cl-letf (((symbol-function 'vc-p4-working-revision)
             (lambda (_) (setq vc-p4-status 'error vc-p4-last-error "Login expired") nil)))
    (let ((error (should-error (vc-p4-history--target "/tmp/file" "" nil))))
      (should (eq (car error) 'vc-p4-error))
      (should (string-match-p "Login expired" (error-message-string error))))))

(ert-deftest vc-p4-annotate-log-navigation-reuses-a-matching-native-log ()
  (let* ((history (vc-p4-history--parse vc-p4-history-test-records))
         (file "/tmp/p4-attribution-context")
         (log (get-buffer-create "*vc-change-log*")))
    (save-window-excursion
      (unwind-protect
          (progn
            (with-current-buffer log
              (vc-p4-log-view-mode)
              (let ((inhibit-read-only t))
                (erase-buffer) (vc-p4-history--render (list (cons file history))))
              (setq-local log-view-vc-backend 'P4 log-view-vc-fileset (list file)))
            (with-temp-buffer
              (vc-annotate-mode)
              (let ((inhibit-read-only t))
                (vc-p4-annotate--render
                 file "//depot/new.txt#1" history
                 (list (list :identity "//depot/old.txt#2" :change "20" :user "bob"
                             :data "line\n" :metadata (cadr history))) nil))
              (goto-char (point-min))
              (cl-letf (((symbol-function 'vc-print-log-internal)
                         (lambda (&rest _) (ert-fail "Refetched an already displayed log entry"))))
                (vc-annotate-show-log-revision-at-line))
              (with-current-buffer log
                (should (equal (log-view-current-tag) "//depot/old.txt#2")))))
        (kill-buffer log)))))

(ert-deftest vc-p4-annotate-compact-columns-align-with-exact-source-navigation ()
  (let* ((history (vc-p4-history--parse vc-p4-history-test-records))
         (identities '("//depot/a/very/long/source-name.el#2" "//depot/x.el#123"))
         (rows (list (list :identity (car identities) :change "20" :user "bob"
                           :data "\tfirst\n" :metadata (car history))
                     (list :identity (cadr identities) :change "123456" :user "long-user界"
                           :data "second\n" :metadata (cadr history)))))
    (with-temp-buffer
      (vc-annotate-mode)
      (let ((inhibit-read-only t))
        (vc-p4-annotate--render "/tmp/file.el" "//depot/new.txt#1" history rows nil))
      (goto-char (point-min))
      (should (looking-at "#2 "))
      (should-not (string-match-p "//depot/" (buffer-string)))
      (let (separator-column)
        (dolist (identity identities)
          (should (equal (car (vc-p4-annotate-extract-revision-at-line)) identity))
          (should (equal (get-text-property (point) 'help-echo) identity))
          (search-forward " | ")
          (if separator-column
              (should (= (current-column) separator-column))
            (setq separator-column (current-column)))
          (forward-line 1)))
      (font-lock-ensure)
      (goto-char (point-min))
      (vc-p4-annotate-time)
      (should (looking-at "\tfirst"))
      (should (get-text-property (point) 'face))
      (vc-annotate-toggle-annotation-visibility)
      (should (invisible-p (line-beginning-position)))
      (should-not (invisible-p (point))))))

(provide 'vc-p4-annotate-tests)
