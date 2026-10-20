;;; vc-p4-gutter-integration-tests.el --- P4 to actual gutters -*- lexical-binding: t; -*-
(require 'vc-p4-integration-tests)
(require 'diff-hl)
(require 'diff-hl-flydiff)

(defun vc-p4-gutter-hunks ()
  "Return sorted (LINE TYPE) gutter hunks in the current buffer."
  (sort (delq nil (mapcar
                  (lambda (overlay)
                    (when (overlay-get overlay 'diff-hl-hunk)
                      (list (line-number-at-pos (overlay-start overlay))
                            (overlay-get overlay 'diff-hl-hunk-type))))
                  (overlays-in (point-min) (point-max))))
        (lambda (a b) (< (car a) (car b)))))

(defmacro vc-p4-gutter-with-file (&rest body)
  "Visit a real fixture file, evaluate BODY and restore the fixture."
  (declare (indent 0))
  `(let* ((file (vc-p4-integration-file "gutter.txt"))
          (dir (file-name-directory file))
          (diff-hl-update-async nil)
          (make-backup-files nil)
          (auto-save-default nil)
          (buffer nil))
     (unwind-protect
         (progn
           (vc-p4--run dir "edit" (vc-p4--escape file))
           (setq buffer (find-file-noselect file))
           (with-current-buffer buffer
             (diff-hl-mode 1)
             ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (vc-p4--run dir "revert" (vc-p4--escape file))
       (vc-file-clearprops file)
       (clrhash vc-p4--metadata)
       (clrhash vc-p4--contents))))

(ert-deftest vc-p4-real-gutter-save-and-external-revert ()
  (vc-p4-gutter-with-file
    (should (eq (vc-backend file) 'P4))
    (should-not (vc-p4-gutter-hunks))
    (goto-char (point-min)) (forward-line 1)
    (delete-region (point) (line-end-position)) (insert "changed")
    (save-buffer)
    (diff-hl-update)
    (should (equal (vc-p4-gutter-hunks) '((2 change))))
    (vc-p4--run dir "revert" (vc-p4--escape file))
    (revert-buffer t t)
    (vc-p4-refresh)
    (diff-hl-update)
    (should-not (vc-p4-gutter-hunks))))

(ert-deftest vc-p4-real-gutter-insertion-and-deletion ()
  (vc-p4-gutter-with-file
    (goto-char (point-min)) (forward-line 1)
    (insert "inserted\n") (save-buffer) (diff-hl-update)
    (should (equal (vc-p4-gutter-hunks) '((2 insert))))
    (erase-buffer) (insert "one\nthree\n")
    (save-buffer) (diff-hl-update)
    (should (equal (vc-p4-gutter-hunks) '((2 delete))))))

(ert-deftest vc-p4-real-gutter-unsaved-edit ()
  (vc-p4-gutter-with-file
    (unwind-protect
        (progn
          (diff-hl-flydiff-mode 1)
          (goto-char (point-min)) (forward-line 1)
          (delete-region (point) (line-end-position)) (insert "unsaved")
          (diff-hl-update)
          (should (equal (vc-p4-gutter-hunks) '((2 change))))
          (should (equal (vc-p4--local-bytes file) "one\ntwo\nthree\n")))
      (diff-hl-flydiff-mode -1))))

(provide 'vc-p4-gutter-integration-tests)

(ert-deftest vc-p4-real-gutter-behind-depot-head ()
  (let* ((file (getenv "VC_P4_TEST_FILE"))
         (buffer (find-file-noselect file))
         (diff-hl-update-async nil))
    (unwind-protect
        (with-current-buffer buffer
          (should (eq (vc-state file) 'needs-merge))
          (diff-hl-mode 1) (diff-hl-update)
          (should (equal (vc-p4-gutter-hunks) '((2 change)))))
      (kill-buffer buffer)
      (vc-file-clearprops file))))
