;;; vc-p4-integration-tests.el --- Real P4 server contract -*- lexical-binding: t; -*-
(require 'ert)
(require 'vc-p4)
(setq vc-p4-program (or (getenv "VC_P4_PROGRAM") "p4"))

(ert-deftest vc-p4-real-server-have-revision-baseline ()
  (let ((file (getenv "VC_P4_TEST_FILE")))
    (should file)
    (should (vc-p4-registered file))
    (should (equal (vc-p4-working-revision file) "1"))
    (should (equal (alist-get 'headRev (vc-p4--stat file t)) "2"))
    (should (eq (vc-p4-state file) 'edited))
    (with-temp-buffer
      (vc-p4-find-revision file "1" (current-buffer))
      (should (equal (buffer-string) "one\ntwo\nthree\n")))
    (with-temp-buffer
      (let ((vc-diff-switches '("-U0")))
        (should (= 1 (vc-p4-diff (list file) nil nil (current-buffer)))))
      (should (string-match-p (regexp-quote "-two\n+local edit") (buffer-string)))
      (should-not (string-match-p "new depot line" (buffer-string))))))

(defun vc-p4-integration-file (name)
  "Return fixture path for NAME."
  (expand-file-name name (getenv "VC_P4_TEST_ROOT")))

(ert-deftest vc-p4-real-server-fixture-configuration ()
  (let* ((dir (getenv "VC_P4_TEST_ROOT"))
         (info (car (vc-p4--query dir "info")))
         (client (car (vc-p4--query dir "client" "-o"))))
    (should (equal (alist-get 'caseHandling info) (getenv "VC_P4_TEST_CASE")))
    (should (equal (alist-get 'LineEnd client) "local"))
    (should-not (alist-get 'Stream client))
    (should (string-match-p "noallwrite" (alist-get 'Options client)))))

(ert-deftest vc-p4-real-server-lifecycle-states ()
  (dolist (entry '(("clean.txt" . up-to-date) ("opened.txt" . up-to-date)
                   ("unopened.txt" . edited) ("missing.txt" . missing)
                   ("deleted.txt" . removed) ("moved.txt" . removed)
                   ("renamed.txt" . added) ("added.txt" . added)))
    (let ((file (vc-p4-integration-file (car entry))))
      (should (vc-p4-registered file))
      (should (eq (vc-p4-state file) (cdr entry))))))

(ert-deftest vc-p4-real-server-special-paths ()
  (dolist (name '("space name.txt" "special#@%.txt"))
    (let ((file (vc-p4-integration-file name)))
      (should (vc-p4-registered file))
      (should (eq (vc-p4-state file) 'up-to-date)))))

(ert-deftest vc-p4-real-server-content-baselines ()
  (dolist (name '("unicode.txt" "crlf.txt" "no-newline.txt" "binary.dat"))
    (let ((file (vc-p4-integration-file name)))
      (should (eq (vc-p4-state file) 'up-to-date))
      (with-temp-buffer
        (should (= 0 (vc-p4-diff (list file) nil nil (current-buffer))))))))
