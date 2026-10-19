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
  (dolist (operation '(checkout checkin register revert))
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
      (should (eq (vc-p4-state file) 'edited)))))

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

(ert-deftest vc-p4-immutable-base-cached-but-symbolic-base-refetched ()
  (vc-p4-test-with-file ""
    (let ((calls 0))
      (cl-letf (((symbol-function 'vc-p4--stat)
                 (lambda (&rest _) '((depotFile . "//depot/file"))))
                ((symbol-function 'vc-p4--run)
                 (lambda (&rest _) (cl-incf calls) "base")))
        (vc-p4--base file "7") (vc-p4--base file "7")
        (should (= calls 1))
        (vc-p4--base file "#head") (vc-p4--base file "#head")
        (should (= calls 3))))))

(provide 'vc-p4-tests)
