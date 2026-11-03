;;; vc-p4-operation-tests.el --- Native VC mutation contracts -*- lexical-binding: t; -*-
(require 'vc-p4-tests)
(require 'vc-p4-ops)

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

(ert-deftest vc-p4-operations-autoload-from-native-vc-in-fresh-emacs ()
  (vc-p4-test-with-file "original\n"
    (with-temp-buffer
      (let ((form `(progn
                     (require 'vc-p4)
                     (when (featurep 'vc-p4-ops) (error "Operations loaded eagerly"))
                     (setq vc-p4-program "/nonexistent/p4")
                     (vc-file-setprop ,file 'vc-backend 'P4)
                     (let ((operation (vc-checkout ,file)))
                       (unless (featurep 'vc-p4-ops) (error "Missing operation module"))
                       (vc-p4--cancel (vc-p4--operation-job operation))))))
        (should (zerop (call-process
                        (expand-file-name invocation-name invocation-directory)
                        nil t nil "-Q" "--batch" "-L"
                        (file-name-directory (locate-library "vc-p4"))
                        "--eval" (prin1-to-string form))))))))

(ert-deftest vc-p4-register-native-front-end-defers-state-and-buffer-effects ()
  (vc-p4-test-operation
    (cl-letf (((symbol-function 'vc-p4-registered) (lambda (_) nil)))
      (vc-file-setprop file 'vc-backend 'none)
      (let ((before (buffer-string)))
        (vc-register (list 'P4 (list file)))
        (should (eq (vc-file-getprop file 'vc-backend) 'none))
        (should (equal (vc-p4--job-command job) (list "-Mj" "-ztag" "add" "-f" file)))
        (insert "typing while pending")
        (vc-p4-test-complete-operation job '(:status success :stdout "{\"action\":\"add\"}\n"))
        (should (string-match-p (regexp-quote before) (buffer-string)))
        (should (buffer-modified-p))
        (should-not (vc-file-getprop file 'vc-state))))))

(ert-deftest vc-p4-register-failure-never-claims-a-new-file ()
  (vc-p4-test-operation
    (cl-letf (((symbol-function 'vc-p4-registered) (lambda (_) nil)))
      (vc-file-setprop file 'vc-backend 'none)
      (vc-register (list 'P4 (list file)))
      (vc-p4-test-complete-operation job '(:status error :stderr "not in view"))
      (should-not (eq (vc-file-getprop file 'vc-backend) 'P4))
      (should (equal (buffer-string) "original\n"))
      (should (file-exists-p file)))))

(ert-deftest vc-p4-register-delegates-other-backends-and-rejects-directories ()
  (should (equal (vc-p4--vc-register #'list '(Git ("file")) "comment")
                 '((Git ("file")) "comment")))
  (should-error (vc-p4-register (list temporary-file-directory)) :type 'user-error))

(ert-deftest vc-p4-revert-defers-reload-and-protects-newer-unsaved-text ()
  (vc-p4-test-operation
    (cl-letf (((symbol-function 'vc-p4--stat) (lambda (_) '((action . "edit")))))
      (let ((operation (vc-revert-file file)))
        (funcall (vc-p4--job-prepare job))
        (should (equal (buffer-string) "original\n"))
        (insert "new typing ")
        (should-error (save-buffer) :type 'user-error)
        (should (equal (vc-p4--local-bytes file) "original\n"))
        ;; Model the server replacing disk contents while input keeps running.
        (with-temp-file file (insert "reverted\n"))
        (vc-p4-test-complete-operation job)
        (should (equal (buffer-string) "new typing original\n"))
        (should (buffer-modified-p))
        (should-not (vc-p4--operation-for file))
        (should-not (vc-p4--operation-recovery operation))))))

(ert-deftest vc-p4-destructive-failure-retains-recoverable-bytes ()
  (dolist (status '(error timeout cancelled))
    (vc-p4-test-operation
      (cl-letf (((symbol-function 'vc-p4--stat) (lambda (_) '((action . "edit")))))
        (let ((operation (vc-revert-file file)))
          (funcall (vc-p4--job-prepare job))
          (let ((recovery (vc-p4--operation-recovery operation)))
            (unwind-protect
                (progn
                  (with-temp-file file (insert "partially changed\n"))
                  (vc-p4-test-complete-operation job (list :status status :stderr "failure"))
                  (should (equal (vc-p4--local-bytes (expand-file-name "1" recovery)) "original\n"))
                  (should (file-exists-p (expand-file-name "files.el" recovery)))
                  (should (equal (buffer-string) "original\n"))
                  (should (vc-p4--operation-error operation))
                  (should-not (vc-p4--operation-for file)))
              (delete-directory recovery t))))))))

(ert-deftest vc-p4-destructive-operation-rechecks-queued-files ()
  (vc-p4-test-operation
    (cl-letf (((symbol-function 'vc-p4--stat) (lambda (_) '((action . "edit")))))
      (vc-revert-file file)
      (with-temp-file file (insert "external change\n"))
      (should-error (funcall (vc-p4--job-prepare job)) :type 'user-error)
      (should-not (vc-p4--operation-recovery vc-p4-last-operation))
      (vc-p4-cancel-operation))))

(ert-deftest vc-p4-delete-native-front-end-never-deletes-on-failure ()
  (vc-p4-test-operation
    (cl-letf (((symbol-function 'vc-p4--stat) (lambda (_) '((haveRev . "1"))))
              ((symbol-function 'vc-p4-state) (lambda (_) 'up-to-date))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (vc-delete-file file)
      (should (file-exists-p file))
      (vc-p4-test-complete-operation job '(:status error :stderr "denied"))
      (should (file-exists-p file))
      (should (buffer-live-p (current-buffer)))
      (should (equal (buffer-string) "original\n")))))

(ert-deftest vc-p4-revert-confirmation-and-other-backend-delegation ()
  (vc-p4-test-operation
    (cl-letf (((symbol-function 'vc-deduce-fileset) (lambda (&rest _) (list 'P4 (list file))))
              ((symbol-function 'vc-p4--stat) (lambda (_) '((action . "edit"))))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-error (vc-revert) :type 'user-error)
      (should-not job))
    (vc-file-setprop file 'vc-backend 'Git)
    (should (equal (vc-p4--vc-revert-file #'list file) (list file)))
    (should (equal (vc-p4--vc-delete-file #'list file) (list file)))))

(ert-deftest vc-p4-operation-cleanup-failure-still-releases-file ()
  (vc-p4-test-operation
    (let ((operation (vc-p4--operate "test" (list file) '("revert" "file") nil t)))
      (funcall (vc-p4--job-prepare job))
      (let ((recovery (vc-p4--operation-recovery operation)))
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'delete-directory) (lambda (&rest _) (error "Cleanup denied"))))
                (vc-p4-test-complete-operation job))
              (should-not (vc-p4--operation-for file))
              (should (vc-p4--operation-error operation))
              (should (file-directory-p recovery)))
          (delete-directory recovery t))))))

(ert-deftest vc-p4-operation-sequence-retains-one-recovery-copy-on-partial-failure ()
  (vc-p4-test-operation
    (let* ((operation (vc-p4--operate "move" (list file)
                                       '(("edit" "source") ("move" "source" "target")) nil t))
           (first job))
      (funcall (vc-p4--job-prepare first))
      (let ((recovery (vc-p4--operation-recovery operation)))
        (unwind-protect
            (progn
              (vc-p4-test-complete-operation first)
              (should-not (eq job first))
              (should (eq (vc-p4--operation-for file) operation))
              (should (equal (vc-p4--job-command job) '("-Mj" "-ztag" "move" "source" "target")))
              (funcall (vc-p4--job-prepare job))
              (should (equal (vc-p4--operation-recovery operation) recovery))
              (vc-p4-test-complete-operation job '(:status error :stderr "move denied"))
              (should-not (vc-p4--operation-for file))
              (should (equal (vc-p4--local-bytes (expand-file-name "1" recovery)) "original\n")))
          (delete-directory recovery t))))))

(ert-deftest vc-p4-move-defers-rename-and-preserves-newer-buffer-text ()
  (vc-p4-test-operation
    (let ((new (concat file "-moved")))
      (unwind-protect
          (cl-letf (((symbol-function 'vc-p4--workspace-identity) (lambda (_) '("server" "client" "root")))
                    ((symbol-function 'vc-p4--stat) (lambda (_) '((action . "edit") (haveRev . "1"))))
                    ((symbol-function 'vc-p4-state) (lambda (_) 'edited)))
            (let ((operation (vc-rename-file file new)))
              (funcall (vc-p4--job-prepare job))
              (should (equal buffer-file-name file))
              (should (file-exists-p file))
              (should-not (file-exists-p new))
              (insert "pending typing ")
              (let ((undo buffer-undo-list))
                (rename-file file new)
                (vc-p4-test-complete-operation job)
                (should-not (vc-p4--operation-error operation))
                (should (equal buffer-file-name new))
                (should (equal (buffer-string) "pending typing original\n"))
                (should (eq undo buffer-undo-list))
                (should (buffer-modified-p))
                (should-not (vc-p4--operation-for new)))))
        (when (file-exists-p new) (rename-file new file))
        (set-visited-file-name file t t)))))

(ert-deftest vc-p4-move-refuses-target-arriving-while-queued ()
  (vc-p4-test-operation
    (let ((new (concat file "-new")))
      (unwind-protect
          (cl-letf (((symbol-function 'vc-p4--workspace-identity) (lambda (_) 'same))
                    ((symbol-function 'vc-p4--stat) (lambda (_) '((action . "edit"))))
                    ((symbol-function 'vc-p4-state) (lambda (_) 'edited)))
            (vc-rename-file file new)
            (with-temp-file new (insert "do not overwrite\n"))
            (should-error (funcall (vc-p4--job-prepare job)) :type 'user-error)
            (vc-p4-cancel-operation)
            (should (equal buffer-file-name file))
            (should (equal (vc-p4--local-bytes new) "do not overwrite\n")))
        (when (file-exists-p new) (delete-file new))))))

(ert-deftest vc-p4-move-delegates-other-backends ()
  (vc-p4-test-operation
    (vc-file-setprop file 'vc-backend 'Git)
    (should (equal (vc-p4--vc-rename-file #'list file "new") (list file "new")))))

(ert-deftest vc-p4-register-cold-discovery-never-offers-repository-creation ()
  (vc-p4-test-operation
   (vc-file-setprop file 'vc-backend 'none)
   (let ((vc-handled-backends '(P4)))
     (dolist (status '(pending error))
       (cl-letf (((symbol-function 'vc-p4-registered) (lambda (_) nil))
                 ((symbol-function 'vc-p4-responsible-p)
                  (lambda (_) (setq vc-p4-status status) nil))
                 ((symbol-function 'completing-read)
                  (lambda (&rest _) (ert-fail "Offered repository creation while discovery pending"))))
         (should-error (vc-backend-for-registration file) :type (if (eq status 'pending) 'vc-p4-pending 'vc-p4-error))
         (should-not job))))
   (cl-letf (((symbol-function 'vc-responsible-backend)
              (lambda (&rest _) (setq vc-p4-status 'pending) 'Git)))
     (should (equal (vc-p4--vc-backend-for-registration #'identity file) file)))))

(ert-deftest vc-p4-failed-add-remains-visible-after-background-publication ()
  (vc-p4-test-operation
   (vc-p4-register (list file))
   (vc-p4-test-complete-operation job '(:status error :stderr "denied"))
   (cl-letf (((symbol-function 'vc-p4-registered) (lambda (_) nil)))
     (vc-p4--publish (current-buffer) file (vc-p4--context file)))
   (should (equal vc-mode " P4!"))
   (vc-p4-refresh)
   (should-not vc-p4--operation-error)))

(ert-deftest vc-p4-checkout-ignores-a-buffer-switched-to-another-backend ()
  (vc-p4-test-operation
   (setq buffer-read-only t)
   (vc-checkout file)
   (vc-file-setprop file 'vc-backend 'Git)
   (vc-p4-test-complete-operation job)
   (should buffer-read-only)
   (should (eq (vc-file-getprop file 'vc-backend) 'Git))))

(ert-deftest vc-p4-operation-completion-uses-owning-buffer-environment ()
  (vc-p4-test-operation
   (setq-local process-environment (copy-sequence process-environment))
   (setenv "P4CLIENT" "buffer-client")
   (setq buffer-read-only t)
   (vc-checkout file)
   (with-temp-buffer
     (let ((process-environment (copy-sequence (default-value 'process-environment))))
       (setenv "P4CLIENT" "unrelated-client")
       (funcall (vc-p4--job-prepare job))
       (vc-p4-test-complete-operation job)))
   (should-not buffer-read-only)
   (should-not (vc-p4--operation-for file))))

(ert-deftest vc-p4-preparation-quit-releases-operation-without-starting-worker ()
  (vc-p4-test-async
   (vc-p4-test-with-file "original\n"
			 (let ((operation (vc-p4--operate "test" (list file) '("edit" "file") nil t
							  (lambda () (signal 'quit nil)))))
			   (should (condition-case nil (progn (vc-p4--dispatch) t) (quit nil)))
			   (should (eq (plist-get (vc-p4--operation-result operation) :status) 'cancelled))
			   (should-not (vc-p4--job-process (vc-p4--operation-job operation)))
			   (should-not (vc-p4--operation-for file))))))

(ert-deftest vc-p4-operations-reject-ellipsis-file-specifications ()
  (vc-p4-test-operation
   (should-error (vc-p4-checkout (concat file "...")) :type 'user-error)
   (should-not job)))

(ert-deftest vc-p4-registration-discovery-queues-independent-metadata-together ()
  (vc-p4-test-operation
   (vc-p4-root file)
   (let (commands)
     (maphash (lambda (key _) (push (car (nth 2 key)) commands)) vc-p4--metadata)
     (should (member "where" commands))
     (should (member "info" commands)))))

(ert-deftest vc-p4-checkout-model-accepts-native-single-file-argument ()
  (vc-p4-test-operation
   (cl-letf (((symbol-function 'vc-p4--stat)
              (lambda (path) (should (equal path file)) '((headType . "text"))))
             ((symbol-function 'vc-p4--cached)
              (lambda (&rest _) '(((Options . "noallwrite"))))))
     (should (eq (vc-checkout-model 'P4 file) 'announce)))))

(ert-deftest vc-p4-next-action-opens-edited-file-without-comment-buffer ()
  (vc-p4-test-operation
    (vc-file-setprop file 'vc-state 'edited)
    (cl-letf (((symbol-function 'vc-p4--stat) (lambda (_) '((haveRev . "1"))))
              ((symbol-function 'vc-checkin) (lambda (&rest _) (ert-fail "Checkin prompt"))))
      (vc-next-action nil)
      (should (equal (nth 2 (vc-p4--job-command job)) "edit"))
      (vc-p4-test-complete-operation job))))

(ert-deftest vc-p4-revert-continues-after-metadata-without-second-command ()
  (vc-p4-test-operation
    (let (ready)
      (cl-letf (((symbol-function 'vc-p4--require-stat)
                 (lambda (_) (if ready '((action . "edit")) (signal 'vc-p4-pending nil))))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (vc-revert)
        (should vc-p4--waiting-command)
        (should-not job)
        (setq ready t)
        (vc-p4-test-await (lambda () job))
        (should-not vc-p4--waiting-command)
        (should (equal (nth 2 (vc-p4--job-command job)) "revert"))
        (vc-p4-test-complete-operation job)))))

(ert-deftest vc-p4-registration-uses-mapping-despite-inferred-git ()
  (vc-p4-test-operation
    (vc-file-setprop file 'vc-backend 'Git)
    (let ((vc-handled-backends '(Git P4)) ready)
      (cl-letf (((symbol-function 'vc-p4-root)
                 (lambda (_) (if ready "/workspace/" (setq vc-p4-status 'pending) nil)))
                ((symbol-function 'vc-p4-registered) (lambda (_) nil)))
        (vc-p4--vc-register (lambda (&rest _) (ert-fail "Wrong Git registration")))
        (should vc-p4--waiting-command)
        (setq ready t)
        (vc-p4-test-await (lambda () job))
        (should (equal (nth 2 (vc-p4--job-command job)) "add"))
        (vc-p4-test-complete-operation job)))))

(ert-deftest vc-p4-registration-preserves-real-git-repository-selection ()
  (vc-p4-test-operation
    (let ((vc-handled-backends '(Git P4)))
      (vc-file-setprop file 'vc-backend 'Git)
      (cl-letf (((symbol-function 'vc-find-root) (lambda (&rest _) "/git/"))
                ((symbol-function 'vc-p4-root) (lambda (_) (ert-fail "P4 query in Git registration"))))
        (should (equal (vc-p4--vc-register #'list) (list (list 'Git (list file)) nil)))))))

(ert-deftest vc-p4-waiting-command-aborts-after-user-edits ()
  (vc-p4-test-operation
    (let (ready started)
      (vc-p4--continue-command (list file)
                              (lambda () (if ready (setq started t) (signal 'vc-p4-pending nil))))
      (insert "newer text")
      (setq ready t)
      (vc-p4-test-await (lambda () (null vc-p4--waiting-command)))
      (should-not started))))
