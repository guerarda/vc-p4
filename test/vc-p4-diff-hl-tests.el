;;; vc-p4-diff-hl-tests.el --- Consumer contract tests -*- lexical-binding: t; -*-
(require 'vc-p4-tests)
(require 'diff-hl)
(require 'diff-hl-flydiff)

(ert-deftest vc-p4-diff-hl-reference-cache-follows-workspace ()
  (vc-p4-test-with-file "first\n"
    (let ((temporary-file-directory (make-temp-file "vc-p4-reference-" t))
          (context "first-client")
          (depot "//depot/first")
          (base "first\n")
          buffer)
      (unwind-protect
          (cl-letf (((symbol-function 'vc-p4--context) (lambda (_) context))
                    ((symbol-function 'vc-p4--stat)
                     (lambda (&rest _) `((depotFile . ,depot) (haveRev . "1"))))
                    ((symbol-function 'vc-p4--base) (lambda (&rest _) base)))
            (setq buffer (find-file-noselect file))
            (vc-file-setprop file 'vc-backend 'P4)
            (let ((first (diff-hl-create-revision file "1")))
              (should (equal (vc-p4--local-bytes first) "first\n"))
              (setq context "second-client" base "second\n")
              (let ((second (diff-hl-create-revision file "1")))
                (should-not (equal first second))
                (should (equal (vc-p4--local-bytes second) "second\n"))
                ;; A server-side view edit can change the depot mapping
                ;; without changing the local configuration or revision.
                (setq depot "//depot/remapped" base "third\n")
                (should (equal (vc-p4--local-bytes
                                (diff-hl-create-revision file "1")) "third\n")))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (vc-file-clearprops file)
        (delete-directory temporary-file-directory t)))))

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
          (vc-p4-test-await (lambda () (vc-p4-test-hunks)))
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
                           (vc-p4-test-await (lambda () (vc-p4-test-hunks)))
                           (should (equal (vc-p4-test-hunks) '((2 change)))))
                  (diff-hl-flydiff-mode -1)))
              (vc-file-clearprops file)))
        (delete-directory temporary-file-directory t)))))

(provide 'vc-p4-diff-hl-tests)
