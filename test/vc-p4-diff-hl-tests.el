;;; vc-p4-diff-hl-tests.el --- Consumer contract tests -*- lexical-binding: t; -*-
(require 'vc-p4-tests)
(require 'diff-hl)
(require 'diff-hl-flydiff)

(defun vc-p4-test-hunks ()
  "Return the actual gutter hunk types and line positions."
  (sort (delq nil (mapcar
                  (lambda (overlay)
                    (when (overlay-get overlay 'diff-hl-hunk)
                      (list (line-number-at-pos (overlay-start overlay))
                            (overlay-get overlay 'diff-hl-hunk-type))))
                  (overlays-in (point-min) (point-max))))
        (lambda (a b) (< (car a) (car b)))))

(ert-deftest vc-p4-diff-hl-saved-change-overlay ()
  (vc-p4-test-with-file "one\nchanged\nthree\n"
    ;; Mock only the P4 boundary; exercise VC dispatch, actual local diff,
    ;; diff-hl parsing and overlay creation together.
    (cl-letf (((symbol-function 'vc-p4--stat)
               (lambda (&rest _) '((haveRev . "7") (headRev . "8"))))
              ((symbol-function 'vc-p4--base)
               (lambda (_ rev) (should (equal rev "7")) "one\ntwo\nthree\n")))
      (with-temp-buffer
        (insert-file-contents file)
        (setq buffer-file-name file)
        (vc-file-setprop file 'vc-backend 'P4)
        (vc-file-setprop file 'vc-state 'edited)
        (setq-local diff-hl-mode t)
        (let ((diff-hl-update-async nil))
          (diff-hl-update)
          (should (equal (vc-p4-test-hunks) '((2 change)))))
        (vc-file-clearprops file)))))

(ert-deftest vc-p4-diff-hl-unsaved-change-overlay ()
  (vc-p4-test-with-file "one\ntwo\nthree\n"
    (let ((temporary-file-directory (make-temp-file "vc-p4-flydiff-" t)))
      (unwind-protect
          (cl-letf (((symbol-function 'vc-p4--stat)
                     (lambda (&rest _) '((haveRev . "7") (headRev . "8"))))
                    ((symbol-function 'vc-p4--base)
                     (lambda (_ rev) (should (equal rev "7")) "one\ntwo\nthree\n")))
            (with-current-buffer (find-file-noselect file)
              (vc-file-setprop file 'vc-backend 'P4)
              (vc-file-setprop file 'vc-state 'up-to-date)
              (goto-char (point-min))
              (forward-line 1)
              (delete-region (point) (line-end-position))
              (insert "changed")
              (setq-local diff-hl-mode t)
        (let ((diff-hl-update-async nil))
                (unwind-protect
                    (progn (diff-hl-flydiff-mode 1)
                           (diff-hl-update)
                           (should (equal (vc-p4-test-hunks) '((2 change)))))
                  (diff-hl-flydiff-mode -1)))
              (vc-file-clearprops file)))
        (delete-directory temporary-file-directory t)))))
