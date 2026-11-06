;;; vc-p4-compare-integration-tests.el --- Actual comparison contents -*- lexical-binding: t; -*-
(require 'vc-p4-integration-tests)
(require 'vc-p4-compare)
(require 'ediff)

(ert-deftest vc-p4-real-compare-ancestral-file-revisions ()
  (let* ((file (vc-p4-integration-file "history-moved.txt"))
         (bytes (vc-p4--local-bytes file))
         (output (generate-new-buffer " *p4-real-revision-diff*")))
    (save-window-excursion
      (unwind-protect
          (progn
            (vc-p4-compare (list file) "//depot/history-source.txt#1" "//depot/history-moved.txt#1" output)
            (vc-p4-integration-drain)
            (with-current-buffer output
              (should (string-match-p (regexp-quote "-history one\n+branch edit\n") (buffer-string))))
            (should (equal (vc-p4--local-bytes file) bytes)))
        (kill-buffer output)))))

(ert-deftest vc-p4-real-compare-multiple-unsaved-buffers-against-have ()
  (let* ((files (mapcar #'vc-p4-integration-file '("sample.txt" "clean.txt")))
         (buffers (mapcar #'find-file-noselect files))
         (before (mapcar #'vc-p4--local-bytes files))
         (opened (vc-p4--query (file-name-directory (car files)) "opened"))
         (output (generate-new-buffer " *p4-real-working-diff*")))
    (save-window-excursion
      (unwind-protect
          (progn
            (switch-to-buffer (car buffers))
            (let ((inhibit-read-only t)) (erase-buffer) (insert "one\nunsaved sample\nthree\n"))
            (with-current-buffer (cadr buffers)
              (let ((inhibit-read-only t)) (erase-buffer) (insert "unsaved clean\n")))
            (vc-p4-compare files nil nil output)
            (vc-p4-integration-drain)
            (with-current-buffer output
              (should (string-match-p (regexp-quote "-two\n+unsaved sample") (buffer-string)))
              (should (string-match-p (regexp-quote "-unchanged\n+unsaved clean") (buffer-string)))
              (should-not (string-match-p "new depot line" (buffer-string))))
            (should (equal (mapcar #'vc-p4--local-bytes files) before))
            (should (equal (vc-p4--query (file-name-directory (car files)) "opened") opened)))
        (kill-buffer output)
        (dolist (buffer buffers)
          (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))))))

(ert-deftest vc-p4-real-ediff-history-and-decoded-utf16-working-text ()
  (dolist (name '("history-moved.txt" "utf16.txt"))
    (let* ((file (vc-p4-integration-file name))
           (source (find-file-noselect file))
           (bytes (vc-p4--local-bytes file))
           (ediff-window-setup-function #'ediff-setup-windows-plain)
           request control)
      (save-window-excursion
        (unwind-protect
            (progn
              (switch-to-buffer source)
              (when (equal name "utf16.txt")
                (let ((inhibit-read-only t)) (erase-buffer) (insert "hello\nchanged\n")))
              (setq request
                    (if (equal name "utf16.txt") (vc-p4-ediff file)
                      (vc-p4-ediff file "//depot/history-source.txt#1" "//depot/history-moved.txt#1")))
              (vc-p4-integration-drain)
              (should-not (buffer-live-p request))
              (setq control (buffer-local-value 'vc-p4-compare--ediff-control source))
              (should (buffer-live-p control))
              (with-current-buffer control
                (should (= ediff-number-of-differences 1))
                (with-current-buffer ediff-buffer-A
                  (should-not buffer-file-name)
                  (should (equal (buffer-string)
                                 (if (equal name "utf16.txt") "hello\nworld\n" "history one\nshared original\n"))))
                (with-current-buffer ediff-buffer-B
                  (should (equal (buffer-string)
                                 (if (equal name "utf16.txt") "hello\nchanged\n" "branch edit\nshared original\n"))))
                (ediff-really-quit nil))
              (should (equal (vc-p4--local-bytes file) bytes)))
          (when (buffer-live-p control) (with-current-buffer control (ediff-really-quit nil)))
          (with-current-buffer source (set-buffer-modified-p nil))
          (kill-buffer source))))))

(ert-deftest vc-p4-real-binary-comparison-reports-difference-without-ediff ()
  (let* ((file (vc-p4-integration-file "binary.dat"))
         (source (find-file-noselect file))
         (bytes (vc-p4--local-bytes file))
         (output (generate-new-buffer " *p4-real-binary-diff*")) request)
    (save-window-excursion
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (let ((inhibit-read-only t)) (goto-char (point-max)) (insert "different"))
            (vc-p4-compare (list file) nil nil output)
            (vc-p4-integration-drain)
            (with-current-buffer output
              (should (> (buffer-size) 0))
              (should-not (string-match-p "^@@" (buffer-string))))
            (switch-to-buffer source)
            (setq request (vc-p4-ediff file))
            (vc-p4-integration-drain)
            (should-not (buffer-live-p request))
            (should-not (buffer-local-value 'vc-p4-compare--ediff-control source))
            (should (string-match-p "requires text" vc-p4-last-error))
            (should (equal (vc-p4--local-bytes file) bytes)))
        (kill-buffer output)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source)))))

(provide 'vc-p4-compare-integration-tests)
