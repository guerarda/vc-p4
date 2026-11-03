;;; vc-p4-operation-tests.el --- Native VC mutation contracts -*- lexical-binding: t; -*-
(require 'vc-p4-tests)

(defmacro vc-p4-test-operation (&rest body)
  "Run BODY with a visiting FILE and a manually completed mutation JOB."
  (declare (indent 0))
  `(vc-p4-test-with-file "original\n"
     (let ((vc-p4--operations (make-hash-table :test #'equal))
           (process-environment (copy-sequence process-environment))
           (vc-handled-backends nil) job)
       (with-current-buffer (find-file-noselect file)
         (vc-file-setprop file 'vc-backend 'P4)
         (cl-letf (((symbol-function 'vc-p4--run-async)
                    (lambda (_dir callback &rest args)
                      (setq job (vc-p4--make-job :callback callback :command args)))))
           ,@body)))))

(defun vc-p4-test-complete-operation (job &optional result)
  "Complete fake JOB with RESULT or a confirmed edit."
  (funcall (vc-p4--job-callback job)
           (or result '(:status success :stdout "{\"action\":\"edit\"}\n"))))

(ert-deftest vc-p4-checkout-defers-permissions-and-preserves-buffer ()
  (vc-p4-test-operation
    (insert "unsaved ")
    (let ((contents (buffer-string)) (undo buffer-undo-list)
          (hook-count 0))
      (setq buffer-read-only t)
      (let ((vc-checkout-hook (list (lambda () (cl-incf hook-count)))))
        (let ((operation (vc-checkout file)))
          (should (vc-p4--operation-p operation))
          (should (equal (vc-p4--job-command job)
                         (list "-Mj" "-ztag" "edit" (vc-p4--escape file))))
          (should buffer-read-only)
          (should (= hook-count 0))
          (should-error (vc-checkout file) :type 'user-error)
          (vc-p4-test-complete-operation job)
          (should-not buffer-read-only)
          (should (equal contents (buffer-string)))
          (should (eq undo buffer-undo-list))
          (should (buffer-modified-p))
          (should (= hook-count 1))
          (should-not (vc-p4--operation-for file)))))))

(ert-deftest vc-p4-checkout-rejects-partial-errors-and-empty-success ()
  (dolist (result '((:status success :stdout "{\"action\":\"edit\"}\n{\"severity\":3,\"data\":\"denied\"}\n")
                    (:status success :stdout "{\"severity\":2,\"data\":\"not in view\"}\n")
                    (:status error :stderr "exclusive lock held")))
    (vc-p4-test-operation
      (setq buffer-read-only t)
      (let ((operation (vc-checkout file)))
        (vc-p4-test-complete-operation job result)
        (should (vc-p4--operation-error operation))
        (should buffer-read-only)
        (should (equal (buffer-string) "original\n"))
        (should (equal (vc-p4-mode-line-string file) "P4!"))
        (should-not (vc-p4--operation-for file))))))

(ert-deftest vc-p4-operation-cancel-releases-file-without-retry ()
  (vc-p4-test-operation
    (let ((operation (vc-checkout file)))
      (vc-p4-cancel-operation)
      (should (eq (plist-get (vc-p4--operation-result operation) :status) 'cancelled))
      (should (vc-p4--operation-error operation))
      (should-not (vc-p4--operation-for file))
      (should (equal (buffer-string) "original\n")))))

(ert-deftest vc-p4-operation-rejects-queued-config-change-and-stale-completion ()
  (vc-p4-test-operation
    (setenv "P4CLIENT" "first")
    (setq buffer-read-only t)
    (vc-checkout file)
    (setenv "P4CLIENT" "second")
    (should-error (funcall (vc-p4--job-prepare job)) :type 'user-error)
    (vc-file-setprop file 'vc-backend 'Git)
    (vc-p4-test-complete-operation job)
    (should buffer-read-only)
    (should (eq (vc-file-getprop file 'vc-backend) 'Git))
    (should-not (vc-p4--operation-for file))))

(ert-deftest vc-p4-checkout-revision-and-other-backend-contracts ()
  (vc-p4-test-operation
    (should-error (vc-checkout file t) :type 'user-error)
    (should-not job)
    (vc-file-setprop file 'vc-backend 'Git)
    (should (equal (vc-p4--vc-checkout #'list file "branch")
                   (list file "branch")))))

(ert-deftest vc-p4-async-prepare-failure-does-not-start-process ()
  (vc-p4-test-async
    (let (result)
      (let ((job (vc-p4--run-async temporary-file-directory
                                  (lambda (value) (setq result value))
                                  "-c" "exit 0")))
        (setf (vc-p4--job-prepare job) (lambda () (user-error "Changed")))
        (vc-p4-test-await (lambda () result))
        (should (eq (plist-get result :status) 'error))
        (should-not (vc-p4--job-process job))
        (should-not vc-p4--active)))))

(provide 'vc-p4-operation-tests)
