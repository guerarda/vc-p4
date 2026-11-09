;;; vc-p4-compare-tests.el --- Native comparison contracts -*- lexical-binding: t; -*-
(require 'vc-p4-history-tests)
(require 'vc-p4-compare)

(defmacro vc-p4-compare-test (&rest body)
  "Run BODY in a visiting FILE with deterministic immutable revision contents."
  (declare (indent 0))
  `(vc-p4-history-test
    (vc-p4-test-with-file "one\nold\n"
                          (let ((vc-handled-backends nil)
                                (history (vc-p4-history--parse vc-p4-history-test-records))
                                (output (generate-new-buffer " *p4-compare-test*")))
                            (save-window-excursion
                              (switch-to-buffer (find-file-noselect file))
                              (vc-file-setprop file 'vc-backend 'P4)
                              (cl-letf (((symbol-function 'vc-p4-working-revision) (lambda (_) "1"))
                                        ((symbol-function 'vc-p4--stat) (lambda (&rest _) '((haveRev . "1") (headType . "text"))))
                                        ((symbol-function 'vc-p4-history--entries) (lambda (&rest _) history))
                                        ((symbol-function 'vc-p4--base)
                                         (lambda (_ rev) (if (member rev '("1" "//depot/new.txt#1")) "one\nold\n" "one\nnew\n"))))
                                (unwind-protect (progn ,@body)
                                  (when (buffer-live-p output) (kill-buffer output))
                                  (vc-file-clearprops file))))))))

(ert-deftest vc-p4-compare-unsaved-text-honors-buffer-local-context ()
  (vc-p4-compare-test
   (setq-local vc-diff-switches '("-U0"))
   (goto-char (point-min)) (forward-line 1)
   (delete-region (point) (line-end-position)) (insert "unsaved")
   (let ((source (current-buffer)))
     (narrow-to-region (line-beginning-position) (line-end-position))
     (cl-letf (((symbol-function 'accept-process-output)
                (lambda (&rest _) (ert-fail "Comparison command waited"))))
       (vc-p4-compare (list file) nil nil output))
     (vc-p4-test-await (lambda () (not (get-buffer-process output))))
     (with-current-buffer output
       (should (string-match-p (regexp-quote "@@ -2 +2 @@\n-old\n+unsaved\n") (buffer-string)))
       (should (eq major-mode 'diff-mode)))
     (with-current-buffer source (should (buffer-narrowed-p)) (should (buffer-modified-p)))
     (should (equal (vc-p4--local-bytes file) "one\nold\n")))))

(ert-deftest vc-p4-compare-initial-add-uses-unsaved-contents ()
  (vc-p4-compare-test
   (erase-buffer) (insert "new unsaved\n")
   (cl-letf (((symbol-function 'vc-p4-working-revision) (lambda (_) "0"))
             ((symbol-function 'vc-p4--base)
              (lambda (_ revision) (should (equal revision "0")) "")))
     (vc-p4-compare (list file) nil nil output)
     (vc-p4-test-await (lambda () (not (get-buffer-process output))))
     (with-current-buffer output
       (should (string-match-p (regexp-quote "+new unsaved") (buffer-string)))))))

(ert-deftest vc-p4-compare-multiple-unsaved-files-and-second-source-expiry ()
  (dolist (stale '(nil t))
    (vc-p4-compare-test
     (vc-p4-test-with-file "one\nsecond old\n"
                           (let ((second file) (second-buffer (find-file-noselect file))
                                 (first buffer-file-name) ready)
                             (with-current-buffer second-buffer
                               (erase-buffer) (insert "one\nsecond unsaved\n"))
                             (erase-buffer) (insert "one\nfirst unsaved\n")
                             (cl-letf (((symbol-function 'vc-p4--base)
                                        (lambda (_ _revision) (when ready "one\nold\n"))))
                               (vc-p4-compare (list first second) nil nil output)
                               (when stale (with-current-buffer second-buffer (goto-char (point-max)) (insert "later\n")))
                               (setq ready t)
                               (vc-p4-test-await (lambda () (not (get-buffer-process output))))
                               (with-current-buffer output
                                 (if stale
                                     (should (string-match-p "comparison changed or failed" (buffer-string)))
                                   (should (string-match-p (regexp-quote "+first unsaved") (buffer-string)))
                                   (should (string-match-p (regexp-quote "+second unsaved") (buffer-string)))))))))))

(ert-deftest vc-p4-compare-historical-pair-survives-unrelated-edit-and-save ()
  (vc-p4-compare-test
   (let ((source (current-buffer)) ready)
     (cl-letf (((symbol-function 'vc-p4--base)
                (lambda (_ rev) (when ready (if (equal rev "1") "old\n" "new\n")))))
       (vc-p4-diff (list file) "1" "2" output t)
       (with-current-buffer source
         (goto-char (point-max)) (insert "later working text\n")
         (let ((coding-system-for-write 'utf-8-unix))
           (write-region (point-min) (point-max) file nil 'silent)))
       (setq ready t)
       (vc-p4-test-await (lambda () (not (get-buffer-process output))))
       (with-current-buffer output
         (should (string-match-p (regexp-quote "-old\n+new\n") (buffer-string))))))))

(ert-deftest vc-p4-compare-switch-change-supersedes-pending-diff ()
  (vc-p4-compare-test
   (cl-letf (((symbol-function 'vc-p4--base) (lambda (&rest _) nil)))
     (let ((vc-diff-switches '("-U0"))) (vc-p4-diff (list file) nil nil output t))
     (let ((old (car vc-p4--diff-tasks)))
       (let ((vc-diff-switches '("-U3"))) (vc-p4-diff (list file) nil nil output t))
       (should (vc-p4--diff-task-done old))
       (should (equal (vc-p4--diff-task-switches (car vc-p4--diff-tasks)) '("-U3")))))))

(ert-deftest vc-p4-compare-snapshot-coding-change-invalidates-result ()
  (vc-p4-compare-test
   (let ((snapshots (vc-p4-compare--snapshots (list file))))
     (should (vc-p4--diff-snapshots-valid-p snapshots))
     (setq buffer-file-coding-system 'utf-8-dos)
     (should-not (vc-p4--diff-snapshots-valid-p snapshots)))))

(ert-deftest vc-p4-ediff-actual-native-session-and-owned-buffer-cleanup ()
  (vc-p4-compare-test
   (require 'ediff)
   (let ((ediff-window-setup-function #'ediff-setup-windows-plain)
         (source (current-buffer)) request control variants)
     (unwind-protect
         (progn
           (setq request (vc-version-ediff (list file) "1" "2"))
           (vc-p4-test-await (lambda () (not (buffer-live-p request))))
           (setq control (buffer-local-value 'vc-p4-compare--ediff-control source))
           (should (buffer-live-p control))
           (with-current-buffer control
             (should (= ediff-number-of-differences 1))
             (setq variants (list ediff-buffer-A ediff-buffer-B))
             (with-current-buffer ediff-buffer-A
               (should (equal (buffer-string) "one\nold\n")) (should-not buffer-file-name))
             (with-current-buffer ediff-buffer-B
               (should (equal (buffer-string) "one\nnew\n")) (should-not buffer-file-name))
             (ediff-really-quit nil))
           (should-not (cl-some #'buffer-live-p variants))
           (should (equal (vc-p4--local-bytes file) "one\nold\n")))
       (when (buffer-live-p control) (with-current-buffer control (ediff-really-quit nil)))
       (dolist (buffer variants) (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest vc-p4-compare-fixed-revisions-ignore-working-metadata-invalidation ()
  (vc-p4-compare-test
   (let* ((vc-p4-diff-program vc-p4-test-diff-worker)
          (process-environment (copy-sequence process-environment))
          (key (list (vc-p4--context file) file (list "fstat" (vc-p4--escape file)))))
     (setenv "VC_P4_FAULT_DELAY" "0.2")
     (puthash key (vc-p4--make-entry :value '((haveRev . "1"))) vc-p4--metadata)
     (vc-p4-compare (list file) "1" "2" output)
     (vc-p4-test-await (lambda () (vc-p4--diff-task-worker (car vc-p4--diff-tasks))))
     (remhash key vc-p4--metadata)
     (vc-p4-test-await (lambda () (not (get-buffer-process output))))
     (with-current-buffer output
       (should (string-match-p (regexp-quote "-old\n+new\n") (buffer-string)))))))

(ert-deftest vc-p4-ediff-default-working-text-and-empty-add-baseline ()
  (dolist (added '(nil t))
    (vc-p4-compare-test
     (erase-buffer) (insert "unsaved text\n")
     (let ((source (current-buffer)) (control (generate-new-buffer " *p4-fake-ediff*")) request)
       (cl-letf (((symbol-function 'vc-p4-working-revision) (lambda (_) (if added "0" "1")))
                 ((symbol-function 'vc-p4-history--entries)
                  (lambda (&rest _) (if added (ert-fail "Queried history of an addition") history)))
                 ((symbol-function 'vc-p4--base)
                  (lambda (_ rev) (if (equal rev "0") "" "one\nold\n")))
                 ((symbol-function 'vc-p4-compare--ediff-buffers)
                  (lambda (_ operands)
                    (should (equal (plist-get (car operands) :bytes) (if added "" "one\nold\n")))
                    (should (equal (plist-get (cadr operands) :bytes) "unsaved text\n"))
                    control)))
         (unwind-protect
             (progn
               (setq request (vc-ediff nil))
               (vc-p4-test-await (lambda () (not (buffer-live-p request))))
               (should (eq (buffer-local-value 'vc-p4-compare--ediff-control source) control)))
           (kill-buffer control)))))))

(ert-deftest vc-p4-ediff-repeated-requests-launch-only-the-latest ()
  (vc-p4-compare-test
   (let ((control (generate-new-buffer " *p4-fake-ediff*"))
         (calls 0) ready first second)
     (cl-letf (((symbol-function 'vc-p4--base) (lambda (&rest _) (when ready "old\n")))
               ((symbol-function 'vc-p4-compare--ediff-buffers)
                (lambda (&rest _) (cl-incf calls) control)))
       (unwind-protect
           (progn
             (setq first (vc-p4-ediff file))
             (setq second (vc-p4-ediff file))
             (setq ready t)
             (vc-p4-test-await (lambda () (and (not (buffer-live-p first)) (not (buffer-live-p second)))))
             (should (= calls 1)))
         (kill-buffer control))))))

(ert-deftest vc-p4-compare-rejects-remote-paths-before-file-access ()
  (let ((directory-p (symbol-function 'file-directory-p)))
    (cl-letf (((symbol-function 'file-directory-p)
               (lambda (path)
                 (when (string-prefix-p "/ssh:" path) (ert-fail "Inspected a remote filesystem"))
                 (funcall directory-p path))))
      (should-error (vc-p4-compare--files '("/ssh:example:/file")) :type 'user-error))))

(ert-deftest vc-p4-ediff-cancelled-focus-and-text-cannot-open-a-late-session ()
  (dolist (change '(text point window))
    (vc-p4-compare-test
     (let (request ready)
       (cl-letf (((symbol-function 'vc-p4--base) (lambda (&rest _) (when ready "old\n")))
                 ((symbol-function 'vc-p4-compare--ediff-buffers)
                  (lambda (&rest _) (ert-fail "Opened obsolete Ediff"))))
         (setq request (vc-p4-ediff file))
         (pcase change
           ('text (insert "typed"))
           ('point (goto-char (point-max)))
           ('window (switch-to-buffer (get-buffer-create " *p4-ediff-other*"))))
         (setq ready t)
         (vc-p4-test-await (lambda () (not (buffer-live-p request)))))))))

(ert-deftest vc-p4-ediff-binary-content-is-rejected-with-comparison-alternative ()
  (should-not (vc-p4-compare--text-p (list :bytes (unibyte-string 0 1 2))))
  (should-not (vc-p4-compare--text-p (list :bytes "printable binary" :type "binary+l")))
  (should (vc-p4-compare--text-p (list :bytes (encode-coding-string "λ\n" 'utf-16le-with-signature)))))

(ert-deftest vc-p4-ediff-native-adapters-delegate-other-backends ()
  (cl-letf (((symbol-function 'vc-deduce-fileset) (lambda (&rest _) '(Git ("file"))))
            ((symbol-function 'vc-backend) (lambda (_) 'Git)))
    (should (eq (vc-p4-compare--vc-ediff
                 (lambda (historic essential) (should (equal (list historic essential) '(t t))) 'delegated)
                 t t) 'delegated))
    (should (eq (vc-p4-compare--vc-version-ediff
                 (lambda (files left right)
                   (should (equal (list files left right) '(("file") "a" "b"))) 'delegated)
                 '("file") "a" "b") 'delegated))))

(ert-deftest vc-p4-ediff-retains-a-snapshot-edited-during-the-session ()
  (vc-p4-compare-test
   (require 'ediff)
   (let ((ediff-window-setup-function #'ediff-setup-windows-plain) control variant)
     (unwind-protect
         (progn
           (setq control (vc-p4-compare--ediff-buffers
                          file (list (list :bytes "old\n" :label "old")
                                     (list :bytes "new\n" :label "new"))))
           (with-current-buffer control
             (setq variant ediff-buffer-A)
             (with-current-buffer variant
               (let ((inhibit-read-only t)) (goto-char (point-max)) (insert "keep this\n")))
             (ediff-really-quit nil))
           (should (buffer-live-p variant))
           (with-current-buffer variant (should (string-match-p "keep this" (buffer-string)))))
       (when (buffer-live-p control) (with-current-buffer control (ediff-really-quit nil)))
       (when (buffer-live-p variant) (kill-buffer variant))))))

(ert-deftest vc-p4-ediff-snapshots-finish-language-mode-and-fontification ()
  (require 'ediff)
  (let* ((ediff-window-setup-function #'ediff-setup-windows-plain)
         (hook-files nil)
         (emacs-lisp-mode-hook
          (list (lambda () (push buffer-file-name hook-files))))
         control)
    (save-window-excursion
      (unwind-protect
          (progn
            (setq control
                  (vc-p4-compare--ediff-buffers
                   "/tmp/p4-language.el"
                   (list (list :bytes "(defun example () \"old\")\n" :label "#1")
                         (list :bytes "(defun example () \"new\")\n" :label "working"))))
            (should (equal hook-files '(nil nil)))
            (with-current-buffer control
              (dolist (variant (list ediff-buffer-A ediff-buffer-B))
                (with-current-buffer variant
                  (should (eq major-mode 'emacs-lisp-mode))
                  (should-not buffer-file-name)
                  (should-not delayed-mode-hooks)
                  (font-lock-ensure)
                  (should (eq (get-text-property 2 'face) 'font-lock-keyword-face))))))
        (when (buffer-live-p control)
          (with-current-buffer control (ediff-really-quit nil)))))))

(provide 'vc-p4-compare-tests)
