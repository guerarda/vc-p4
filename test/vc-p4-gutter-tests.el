;;; vc-p4-gutter-tests.el --- Incremental rendering tests -*- lexical-binding: t; -*-
(require 'vc-p4-diff-hl-tests)
(require 'vc-p4-gutter)

(defun vc-p4-test-line-overlays ()
  "Return the current P4 visual overlays ordered by position."
  (sort (cl-remove-if-not
         (lambda (ov) (eq (car (overlay-get ov 'vc-p4-gutter)) 'line))
         (append (car (overlay-lists)) (cdr (overlay-lists))))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(ert-deftest vc-p4-gutter-identical-result-does-not-touch-overlays ()
  (with-temp-buffer
    (insert "one\ntwo\nthree\nfour\n")
    (let ((diff-hl-fallback-to-margin nil))
      (vc-p4-gutter--reconcile '((2 2 2 change)) nil)
      (let ((before (overlay-lists)))
        (cl-letf (((symbol-function 'make-overlay) (lambda (&rest _) (ert-fail "Created overlay")))
                  ((symbol-function 'delete-overlay) (lambda (&rest _) (ert-fail "Deleted overlay")))
                  ((symbol-function 'move-overlay) (lambda (&rest _) (ert-fail "Moved overlay")))
                  ((symbol-function 'overlay-put) (lambda (&rest _) (ert-fail "Rewrote overlay"))))
          (vc-p4-gutter--reconcile '((2 2 2 change)) nil))
        (should (equal before (overlay-lists)))))))

(ert-deftest vc-p4-gutter-change-only-replaces-affected-line ()
  (with-temp-buffer
    (insert "one\ntwo\nthree\nfour\n")
    (let ((diff-hl-draw-borders nil) (diff-hl-fallback-to-margin nil))
      (vc-p4-gutter--reconcile '((2 2 2 change)) nil)
      (let* ((lines (vc-p4-test-line-overlays)) (unchanged (car lines)) (changed (cadr lines)))
        (goto-char (overlay-start changed)) (insert "edit")
        ;; Editing inside a hunk does not delete its other line indicators.
        (should (overlay-buffer unchanged))
        (vc-p4-gutter--reconcile '((2 1 1 change) (3 1 0 insert)) nil)
        (should (eq unchanged (car (vc-p4-test-line-overlays))))
        (should-not (overlay-buffer changed))
        (vc-p4-gutter--reconcile nil nil)
        (should-not (vc-p4-test-line-overlays))
        (should-not (vc-p4-test-hunks))))))

(ert-deftest vc-p4-gutter-retains-markers-shifted-by-insertion ()
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (let ((diff-hl-fallback-to-margin nil))
      (vc-p4-gutter--reconcile '((2 1 1 change)) nil)
      (let ((line (car (vc-p4-test-line-overlays))))
        (goto-char (point-min)) (insert "new\n")
        (vc-p4-gutter--reconcile '((1 1 0 insert) (3 1 1 change)) nil)
        (should (eq line (cadr (vc-p4-test-line-overlays)))))) ))

(ert-deftest vc-p4-gutter-reference-overlap-and-eof-deletion ()
  (with-temp-buffer
    (insert "one\ntwo\nthree")
    (let ((diff-hl-fallback-to-margin nil))
      (vc-p4-gutter--reconcile '((2 1 1 change) (3 0 1 delete)) '((1 2 0 insert)))
      (should (= 3 (length (vc-p4-test-line-overlays))))
      (should (equal (mapcar (lambda (ov) (nth 1 (overlay-get ov 'vc-p4-gutter)))
                             (vc-p4-test-line-overlays)) '(insert change delete)))
      (let ((before (vc-p4-test-line-overlays)))
        (vc-p4-gutter--reconcile '((2 1 1 change) (3 0 1 delete)) '((1 2 0 insert)))
        (should (equal before (vc-p4-test-line-overlays)))))))

(ert-deftest vc-p4-gutter-older-completion-cannot-replace-latest ()
  (vc-p4-test-with-file "one\ntwo\nthree\n"
			(with-temp-buffer
			  (insert-file-contents file)
			  (setq buffer-file-name file)
			  (let ((diff-hl-mode t) callbacks)
			    (cl-letf (((symbol-function 'diff-hl-changes) (lambda () '((:working . "pending"))))
				      ((symbol-function 'vc-p4-gutter--resolve)
				       (lambda (value cb) (if (listp value) (funcall cb value) (push cb callbacks)))))
			      (vc-p4-gutter--update)
			      (vc-p4-gutter--update)
			      (funcall (car callbacks) '((3 1 0 insert)))
			      (let ((latest (vc-p4-test-line-overlays)))
				(funcall (cadr callbacks) '((2 1 1 change)))
				(should (equal latest (vc-p4-test-line-overlays))))
			      (should (equal (vc-p4-test-hunks) '((3 insert)))))))))

(ert-deftest vc-p4-gutter-async-completion-without-private-buffer-helper ()
  (vc-p4-test-with-file "one\nchanged\nthree\n"
    (with-temp-buffer
      (insert-file-contents file)
      (setq buffer-file-name file)
      (setq-local diff-hl-mode t)
      (let* ((source (current-buffer))
             (indirect (make-indirect-buffer source " *p4-indirect*" t))
             (output (generate-new-buffer " *p4-test-diff*"))
             (helper (and (fboundp 'diff-hl--target-buffer)
                          (symbol-function 'diff-hl--target-buffer)))
             process callback-error)
        (unwind-protect
            (progn
              (setq process (make-process :name "p4-test-diff" :buffer output
                                          :command '("cat") :connection-type 'pipe
                                          :noquery t :sentinel #'ignore))
              ;; Isolate acquisition, but use native asynchronous completion
              ;; and diff-hl's real parser.
              (cl-letf (((symbol-function 'diff-hl-changes)
                         (lambda () `((:working . ,output)))))
                (vc-p4-gutter--update))
              (let ((sentinel (process-sentinel process)))
                (set-process-sentinel
                 process (lambda (proc event)
                           (condition-case err (funcall sentinel proc event)
                             (error (setq callback-error err))))))
              (fmakunbound 'diff-hl--target-buffer)
              (process-send-string process
                                   "--- base\n+++ working\n@@ -2 +2 @@\n-two\n+changed\n")
              (process-send-eof process)
              (vc-p4-test-await
               (lambda () (or callback-error
                              (with-current-buffer source (vc-p4-test-hunks)))))
              (should-not callback-error)
              (dolist (buffer (list source indirect))
                (with-current-buffer buffer
                  (should (equal (vc-p4-test-hunks) '((2 change)))))))
          (when helper (fset 'diff-hl--target-buffer helper))
          (when (process-live-p process) (delete-process process))
          (kill-buffer output)
          (kill-buffer indirect))))))

(ert-deftest vc-p4-gutter-non-p4-update-is-not-intercepted ()
  (vc-p4-test-with-file "contents"
    (with-temp-buffer
      (setq buffer-file-name file)
      (vc-file-setprop file 'vc-backend 'Git)
      (unwind-protect
          (let ((calls 0))
            (cl-letf (((symbol-function 'vc-p4-gutter--update)
                       (lambda () (ert-fail "Intercepted Git"))))
              (vc-p4--gutter-update (lambda () (cl-incf calls))))
            (should (= calls 1)))
        (vc-file-clearprops file)))))

(ert-deftest vc-p4-gutter-closed-output-ignores-late-success-sentinel ()
  (vc-p4-test-with-file "one\nchanged\n"
    (with-temp-buffer
      (setq buffer-file-name file)
      (setq-local diff-hl-mode t)
      (let* ((output (generate-new-buffer " *p4-closed-output*"))
             (process (make-process :name "p4-closed-output" :buffer output
                                    :command '("cat") :connection-type 'pipe
                                    :noquery t :sentinel #'ignore)))
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'diff-hl-changes)
                         (lambda () `((:working . ,output)))))
                (vc-p4-gutter--update))
              ;; The diff is complete but its successful exit event has not
              ;; reached the consumer when a save/refresh closes the output.
              (let ((sentinel (process-sentinel process)))
                (set-process-sentinel process #'ignore)
                (process-send-eof process)
                (vc-p4-test-await (lambda () (eq (process-status process) 'exit)))
                (kill-buffer output)
                ;; A replacement with the same name must not be read either.
                (setq output (generate-new-buffer " *p4-closed-output*"))
                (cl-letf (((symbol-function 'diff-hl-changes-from-buffer)
                           (lambda (&rest _) (ert-fail "Parsed obsolete diff")))
                          ((symbol-function 'vc-p4-gutter--reconcile)
                           (lambda (&rest _) (ert-fail "Rendered obsolete diff"))))
                  (funcall sentinel process "finished\n"))))
          (when (process-live-p process) (delete-process process))
          (when (buffer-live-p output) (kill-buffer output)))))))

(provide 'vc-p4-gutter-tests)

(ert-deftest vc-p4-gutter-disabled-mode-cleans-up-and-rejects-late-result ()
  (vc-p4-test-with-file "one\ntwo\nthree\n"
    (with-temp-buffer
      (insert-file-contents file)
      (setq buffer-file-name file)
      (vc-file-setprop file 'vc-backend 'P4)
      (let ((diff-hl-mode t) callback)
        (vc-p4-gutter--reconcile '((2 1 1 change)) nil)
        (cl-letf (((symbol-function 'diff-hl-changes) (lambda () '((:working . "pending"))))
                  ((symbol-function 'vc-p4-gutter--resolve)
                   (lambda (value cb) (if (listp value) (funcall cb value) (setq callback cb)))))
          (vc-p4-gutter--update)
          (setq diff-hl-mode nil)
          (vc-p4--update-gutters)
          (should-not (vc-p4-test-hunks))
          (funcall callback '((2 1 1 change)))
          (should-not (vc-p4-test-hunks))))
      (vc-file-clearprops file))))

(ert-deftest vc-p4-gutter-failed-baseline-keeps-last-display ()
  (vc-p4-test-with-file "one\ntwo\nthree\n"
    (with-temp-buffer
      (insert-file-contents file)
      (setq buffer-file-name file)
      (vc-file-setprop file 'vc-backend 'P4)
      (let ((diff-hl-mode t))
        (vc-p4-gutter--reconcile '((2 1 1 change)) nil)
        (let ((before (vc-p4-test-line-overlays)))
          (cl-letf (((symbol-function 'vc-p4--stat)
                     (lambda (&rest _) '((haveRev . "1") (headRev . "1"))))
                    ((symbol-function 'vc-p4--base)
                     (lambda (&rest _) (setq vc-p4-status 'error) nil)))
            (diff-hl-update))
          (should (eq vc-p4-status 'error))
          (should (equal before (vc-p4-test-line-overlays)))))
      (vc-file-clearprops file))))
