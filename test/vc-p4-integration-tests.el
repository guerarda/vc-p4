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
