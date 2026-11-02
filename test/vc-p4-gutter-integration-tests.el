;;; vc-p4-gutter-integration-tests.el --- P4 to actual gutters -*- lexical-binding: t; -*-
(require 'vc-p4-integration-tests)
(require 'diff-hl)
(require 'diff-hl-flydiff)

(defun vc-p4-gutter-update ()
  "Schedule an actual consumer update, then await it only in the test harness."
  (diff-hl-update)
  (vc-p4-integration-drain))

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
           (vc-p4-integration-ready file)
           (setq buffer (find-file-noselect file))
           (with-current-buffer buffer
             (diff-hl-mode 1)
             (vc-p4-integration-drain)
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
    (vc-p4-gutter-update)
    (should (equal (vc-p4-gutter-hunks) '((2 change))))
    (vc-p4--run dir "revert" (vc-p4--escape file))
    (revert-buffer t t)
    (progn (vc-p4-refresh) (vc-p4-integration-drain))
    (vc-p4-gutter-update)
    (should-not (vc-p4-gutter-hunks))))

(ert-deftest vc-p4-real-gutter-insertion-and-deletion ()
  (vc-p4-gutter-with-file
    (goto-char (point-min)) (forward-line 1)
    (insert "inserted\n") (save-buffer) (vc-p4-gutter-update)
    (should (equal (vc-p4-gutter-hunks) '((2 insert))))
    (erase-buffer) (insert "one\nthree\n")
    (save-buffer) (vc-p4-gutter-update)
    (should (equal (vc-p4-gutter-hunks) '((2 delete))))))

(ert-deftest vc-p4-real-gutter-unsaved-edit ()
  (vc-p4-gutter-with-file
    (unwind-protect
        (progn
          (diff-hl-flydiff-mode 1)
          (goto-char (point-min)) (forward-line 1)
          (delete-region (point) (line-end-position)) (insert "unsaved")
          (vc-p4-gutter-update)
          (should (equal (vc-p4-gutter-hunks) '((2 change))))
          (should (equal (vc-p4--local-bytes file) "one\ntwo\nthree\n")))
      (diff-hl-flydiff-mode -1))))

(provide 'vc-p4-gutter-integration-tests)

(ert-deftest vc-p4-real-gutter-behind-depot-head ()
  (let* ((file (vc-p4-integration-ready (getenv "VC_P4_TEST_FILE")))
         (buffer (find-file-noselect file))
         (diff-hl-update-async nil))
    (unwind-protect
        (with-current-buffer buffer
          (should (eq (vc-state file) 'needs-merge))
          (diff-hl-mode 1) (vc-p4-gutter-update)
          (should (equal (vc-p4-gutter-hunks) '((2 change)))))
      (kill-buffer buffer)
      (vc-file-clearprops file))))

(ert-deftest vc-p4-real-gutter-warm-flydiff-does-not-query-server ()
  (vc-p4-gutter-with-file
    (let ((vc-p4-metadata-ttl 60))
      (unwind-protect
          (progn
            (diff-hl-flydiff-mode 1)
            (goto-char (point-min)) (insert "first\n")
            (vc-p4-gutter-update)
            (cl-letf (((symbol-function 'vc-p4--run)
                       (lambda (&rest _) (ert-fail "Warm typing queried P4"))))
              (insert "second\n") (vc-p4-gutter-update)
              (should (vc-p4-gutter-hunks))))
        (diff-hl-flydiff-mode -1)))))

(ert-deftest vc-p4-real-gutter-navigation-and-submit-refresh ()
  (vc-p4-gutter-with-file
    (goto-char (point-min)) (forward-line 1)
    (delete-region (point) (line-end-position)) (insert "submitted")
    (save-buffer) (vc-p4-gutter-update)
    (goto-char (point-min))
    (let ((diff-hl-next-previous-hunk-auto-recenter nil))
      (diff-hl-next-hunk))
    (should (= (line-number-at-pos) 2))
    (vc-p4--run dir "submit" "-d" "gutter test submission" (vc-p4--escape file))
    (progn (vc-p4-refresh) (vc-p4-integration-drain)) (vc-p4-gutter-update)
    (should (equal (vc-p4-working-revision file) "2"))
    (should-not (vc-p4-gutter-hunks))
    ;; Restore the base revision for other tests without undoing server history.
    (vc-p4--run dir "sync" (concat (vc-p4--escape file) "#1"))
    (revert-buffer t t) (progn (vc-p4-refresh) (vc-p4-integration-drain))
    (should (eq (vc-state file) 'needs-update))
    (should-not (vc-p4-gutter-hunks))))

(ert-deftest vc-p4-real-gutter-added-file ()
  (let* ((file (vc-p4-integration-file "added.txt"))
         (buffer (find-file-noselect file))
         (diff-hl-update-async nil))
    (unwind-protect
        (with-current-buffer buffer
          (diff-hl-mode 1) (vc-p4-gutter-update)
          (should (eq (vc-state file) 'added))
          (should (eq (cadar (vc-p4-gutter-hunks)) 'insert)))
      (kill-buffer buffer))))
