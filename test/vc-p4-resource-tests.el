;;; vc-p4-resource-tests.el --- Offline pipe lifetime diagnostics -*- lexical-binding: t; -*-

;;; Commentary:
;; Run separately in a fresh Emacs, especially on native Windows.  These tests
;; use shell builtins and a deliberately missing executable, never the P4 CLI.
;; Repetition can expose descriptors left behind outside `process-list'.

;;; Code:
(require 'ert)
(require 'vc-p4)

(defvar vc-p4-resource-test-iterations 120)

(defun vc-p4-resource-test-await (predicate)
  "Pump diagnostic events until PREDICATE succeeds, with a finite deadline."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should (funcall predicate))))

(defmacro vc-p4-resource-test-cycles (&rest body)
  "Repeat BODY, checking for surviving Emacs process objects afterward."
  (declare (indent 0))
  `(let ((before (process-list)) (default-directory temporary-file-directory))
     (dotimes (cycle vc-p4-resource-test-iterations)
       (ert-info ((format "Cycle %d/%d on %s %s" (1+ cycle)
                          vc-p4-resource-test-iterations emacs-version system-type))
         ,@body)
       ;; Allow Windows reader threads to retire without building a large
       ;; intentional concurrency peak.  This is an explicit test harness wait.
       (accept-process-output nil 0.01))
     (vc-p4-resource-test-await
      (lambda () (not (cl-set-difference (process-list) before))))))

(defun vc-p4-resource-test-native-command ()
  "Run one harmless command with separate stderr, releasing both streams."
  (let ((output (generate-new-buffer " *p4-resource-output*"))
        (errors (generate-new-buffer " *p4-resource-errors*")) process)
    (unwind-protect
        (progn
          (setq process
                (make-process :name "p4-resource-native" :buffer output
                              :command (list shell-file-name shell-command-switch "echo resource-probe")
                              :stderr errors :connection-type 'pipe
                              :coding 'no-conversion :noquery t :sentinel #'ignore))
          (condition-case failure
              (process-send-eof process)
            (error (when (process-live-p process)
                     (signal (car failure) (cdr failure)))))
          (vc-p4-resource-test-await (lambda () (not (process-live-p process))))
          (vc-p4-resource-test-await
           (lambda () (not (process-live-p (get-buffer-process errors)))))
          (should (zerop (process-exit-status process)))
          (with-current-buffer output (should (string-match-p "resource-probe" (buffer-string)))))
      (when (processp process) (delete-process process))
      (when-let* ((stderr (get-buffer-process errors))) (delete-process stderr))
      (kill-buffer output)
      (kill-buffer errors))))

(ert-deftest vc-p4-resource-01-native-pipe-deletion ()
  (vc-p4-resource-test-cycles
    (let ((buffer (generate-new-buffer " *p4-resource-pipe*")) pipe)
      (unwind-protect
          (setq pipe (make-pipe-process :name "p4-resource-pipe" :buffer buffer
                                        :noquery t :sentinel #'ignore))
        (when (processp pipe) (delete-process pipe))
        (kill-buffer buffer)))))

(ert-deftest vc-p4-resource-02-native-subprocess-completion ()
  (vc-p4-resource-test-cycles (vc-p4-resource-test-native-command)))

(defun vc-p4-resource-test-runner (kind)
  "Exercise repeated runner completion, cancellation or launch failure KIND."
  (let ((vc-p4--queue nil) (vc-p4--active nil) (vc-p4--dispatch-timer nil)
        (vc-p4-max-processes 1) (vc-p4-command-timeout 5)
        (vc-p4-program shell-file-name) (cancellations 0))
    (unwind-protect
        (vc-p4-resource-test-cycles
          (let* ((vc-p4-program
                  (if (eq kind 'failure)
                      (expand-file-name "vc-p4-missing-resource-probe.exe" temporary-file-directory)
                    vc-p4-program))
                 result
                 (job (progn
                        (when (eq kind 'failure) (should-not (file-exists-p vc-p4-program)))
                        (vc-p4--run-async
                         temporary-file-directory (lambda (value) (setq result value))
                         shell-command-switch "echo resource-probe"))))
            (when (eq kind 'cancel)
              ;; Dispatch without pumping output, then cancel a started job.
              (cancel-timer vc-p4--dispatch-timer)
              (vc-p4--dispatch)
              (vc-p4--cancel job))
            (vc-p4-resource-test-await (lambda () result))
            (should (memq (plist-get result :status)
                          (pcase kind ('failure '(error)) ('cancel '(cancelled success)) (_ '(success)))))
            (when (eq (plist-get result :status) 'cancelled) (cl-incf cancellations))
            (when (eq kind 'failure)
              ;; Resource exhaustion must not pass as the expected missing
              ;; executable failure merely because both have status `error'.
              (vc-p4-resource-test-native-command))
            (should-not vc-p4--active)
            (should-not vc-p4--queue)
            (should-not (buffer-live-p (vc-p4--job-output job)))
            (should-not (buffer-live-p (vc-p4--job-errors job)))))
      (dolist (job (append vc-p4--queue vc-p4--active)) (vc-p4--cancel job))
      (when (timerp vc-p4--dispatch-timer) (cancel-timer vc-p4--dispatch-timer)))
    (when (eq kind 'cancel) (should (> cancellations 0)))))

(ert-deftest vc-p4-resource-03-runner-completion ()
  (vc-p4-resource-test-runner 'complete))

(ert-deftest vc-p4-resource-04-runner-cancellation ()
  (vc-p4-resource-test-runner 'cancel))

(ert-deftest vc-p4-resource-05-runner-launch-failure ()
  (vc-p4-resource-test-runner 'failure))

(provide 'vc-p4-resource-tests)
;;; vc-p4-resource-tests.el ends here
