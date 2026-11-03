;;; vc-p4.el --- Perforce backend for Emacs VC -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: vc, tools

;;; Commentary:
;; Native VC integration for local Perforce workspaces.  Uses the p4 CLI.
;; The working revision is the have revision, never implicitly depot head.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'vc)
(require 'subr-x)

(defgroup vc-p4 nil "Perforce support for VC." :group 'vc)
(defcustom vc-p4-program "p4" "Perforce command executable." :type 'string)
(defcustom vc-p4-command-timeout 10 "Maximum seconds for a P4 query."
  :type 'number)
(defcustom vc-p4-metadata-ttl 2 "Seconds to cache file metadata."
  :type 'number)
(defvar vc-p4--metadata (make-hash-table :test #'equal))
(defvar vc-p4--contents (make-hash-table :test #'equal))
(defvar vc-p4-last-error nil "Most recent discovery failure, for diagnostics.")
(define-error 'vc-p4-error "Perforce command failed")

(defcustom vc-p4-max-processes 4 "Maximum concurrent asynchronous P4 commands."
  :type 'natnum)
(cl-defstruct (vc-p4--job (:constructor vc-p4--make-job))
  directory command environment exec-path callback timeout
  process stderr-process output errors timer result done prepare)
(defvar vc-p4--queue nil)
(defvar vc-p4--active nil)
(defvar vc-p4--dispatch-timer nil)

(defun vc-p4--schedule ()
  "Schedule queued commands outside the initiating call."
  (unless vc-p4--dispatch-timer
    (setq vc-p4--dispatch-timer (run-at-time 0 nil #'vc-p4--dispatch))))

(defun vc-p4--finish (job status &optional detail)
  "Finish JOB exactly once with STATUS and optional DETAIL.
Release all resources before delivering the result to its callback."
  (unless (vc-p4--job-done job)
    (setf (vc-p4--job-done job) t)
    (let ((result (list :status status :detail detail
                        :process-status (when (vc-p4--job-process job)
                                          (process-status (vc-p4--job-process job)))
                        :exit-code (when (and (vc-p4--job-process job)
                                              (memq (process-status (vc-p4--job-process job))
                                                    '(exit signal)))
                                     (process-exit-status (vc-p4--job-process job)))
                        :stdout (if (buffer-live-p (vc-p4--job-output job))
                                    (with-current-buffer (vc-p4--job-output job)
                                      (buffer-string)) "")
                        :stderr (if (buffer-live-p (vc-p4--job-errors job))
                                    (with-current-buffer (vc-p4--job-errors job)
                                      (buffer-string)) ""))))
      (when (timerp (vc-p4--job-timer job))
        (cancel-timer (vc-p4--job-timer job)))
      (setf (vc-p4--job-timer job) nil)
      (dolist (process (list (vc-p4--job-process job)
                            (vc-p4--job-stderr-process job)))
        (when (processp process)
          (set-process-sentinel process #'ignore)
          (delete-process process)))
      (dolist (buffer (list (vc-p4--job-output job) (vc-p4--job-errors job)))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (setq vc-p4--active (delq job vc-p4--active)
            vc-p4--queue (delq job vc-p4--queue))
      (setf (vc-p4--job-result job) result)
      (when vc-p4--queue (vc-p4--schedule))
      (condition-case err
          (funcall (vc-p4--job-callback job) result)
        (error (message "P4 completion callback failed: %s"
                        (error-message-string err)))))))

(defun vc-p4--completed (job)
  "Deliver JOB only after both output streams have closed."
  (let ((process (vc-p4--job-process job))
        (stderr (vc-p4--job-stderr-process job)))
    (when (and process (memq (process-status process) '(exit signal failed))
               stderr (not (process-live-p stderr)))
      (vc-p4--finish job (if (and (eq (process-status process) 'exit)
                                (zerop (process-exit-status process)))
                               'success 'error)))))

(defun vc-p4--start (job)
  "Start JOB with the environment captured at submission."
  (push job vc-p4--active)
  (condition-case err
      (progn
        (when (vc-p4--job-prepare job)
          (funcall (vc-p4--job-prepare job)))
        (let ((default-directory (vc-p4--job-directory job))
            (process-environment (vc-p4--job-environment job))
            (exec-path (vc-p4--job-exec-path job)))
        (setf (vc-p4--job-output job) (generate-new-buffer " *vc-p4-async-output*")
              (vc-p4--job-errors job) (generate-new-buffer " *vc-p4-async-error*"))
        (dolist (buffer (list (vc-p4--job-output job) (vc-p4--job-errors job)))
          (with-current-buffer buffer (set-buffer-multibyte nil)))
        (setf (vc-p4--job-stderr-process job)
              (make-pipe-process
               :name "vc-p4-stderr" :buffer (vc-p4--job-errors job)
               :coding 'no-conversion :noquery t
               :sentinel (lambda (_process _event) (vc-p4--completed job))))
        (setf (vc-p4--job-process job)
              (make-process
               :name "vc-p4-async" :buffer (vc-p4--job-output job)
               :stderr (vc-p4--job-stderr-process job)
               :command (vc-p4--job-command job)
               :connection-type 'pipe :coding 'no-conversion :noquery t
               :sentinel (lambda (_process _event) (vc-p4--completed job))))
        (condition-case eof-error
            (process-send-eof (vc-p4--job-process job))
          (error (when (process-live-p (vc-p4--job-process job))
                   (signal (car eof-error) (cdr eof-error)))))
        (unless (vc-p4--job-done job)
          (setf (vc-p4--job-timer job)
                (run-at-time (vc-p4--job-timeout job) nil
                             #'vc-p4--finish job 'timeout
                             "P4 timed out; check connection/login"))
          (vc-p4--completed job))))
    (error (vc-p4--finish job 'error (error-message-string err)))))

(defun vc-p4--dispatch ()
  "Start queued jobs up to the concurrency limit."
  (setq vc-p4--dispatch-timer nil)
  (while (and vc-p4--queue (< (length vc-p4--active)
                             (max 1 vc-p4-max-processes)))
    (vc-p4--start (pop vc-p4--queue))))

(defun vc-p4--run-async (directory callback &rest args)
  "Queue P4 ARGS in DIRECTORY and return a cancellable job immediately.
CALLBACK receives a plist with :status (success, error, timeout or cancelled),
:stdout and :stderr as raw bytes, :exit-code and optional :detail.
Normal completion is deferred.  Cancellation delivers its callback immediately.
The timeout begins when the job starts; queued jobs consume no processes.
Callbacks must tolerate obsolete consumers and must not block."
  (let ((job (vc-p4--make-job
              :directory (file-name-as-directory (expand-file-name directory))
              :command (cons vc-p4-program (copy-sequence args))
              :environment (copy-sequence process-environment)
              :exec-path (copy-sequence exec-path)
              :callback callback :timeout vc-p4-command-timeout)))
    (setq vc-p4--queue (nconc vc-p4--queue (list job)))
    (vc-p4--schedule)
    job))

(defun vc-p4--cancel (job)
  "Cancel queued or running JOB, delivering exactly one completion."
  (vc-p4--finish job 'cancelled))

(defun vc-p4--run (directory &rest args)
  "Synchronous adapter for explicit batch tooling, using ARGS in DIRECTORY.
Never use this on automatic VC or gutter paths; use `vc-p4--run-async'.
Return stdout as bytes.  Use pipes and argument vectors, never a shell.
Enforce a deadline and
clean up processes and buffers on errors and keyboard quit."
  (let ((default-directory (file-name-as-directory directory))
        (out (generate-new-buffer " *vc-p4-output*"))
        (err (generate-new-buffer " *vc-p4-error*"))
        process)
    (unwind-protect
        (progn
          (with-current-buffer out (set-buffer-multibyte nil))
          (with-current-buffer err (set-buffer-multibyte nil))
          (setq process
                (make-process :name "vc-p4" :buffer out :stderr err
                              :command (cons vc-p4-program args)
                              :connection-type 'pipe :coding 'no-conversion
                              :noquery t :sentinel #'ignore))
          ;; Fast queries may finish before stdin is closed.  Their exit
          ;; status and captured output still need normal handling below.
          (condition-case err
              (process-send-eof process)
            (error (when (process-live-p process)
                     (signal (car err) (cdr err)))))
          (let ((deadline (+ (float-time) vc-p4-command-timeout)))
            (while (process-live-p process)
              (when (> (float-time) deadline)
                (signal 'vc-p4-error '("P4 timed out; check connection/login")))
              (accept-process-output process 0.02)))
          (accept-process-output process 0.01)
          (unless (zerop (process-exit-status process))
            (signal 'vc-p4-error
                    (list (format "P4 exited %s: %s%s"
                                  (process-exit-status process)
                                  (with-current-buffer err (buffer-string))
                                  (with-current-buffer out (buffer-string))))))
          (with-current-buffer out (buffer-string)))
      (when (and process (process-live-p process)) (delete-process process))
      (when-let* ((stderr-process (get-buffer-process err)))
        (delete-process stderr-process))
      (kill-buffer out)
      (kill-buffer err))))

(defun vc-p4--parse-json (output)
  "Parse newline-delimited P4 JSON OUTPUT; reject error records."
  (let (records)
    (dolist (line (split-string (decode-coding-string output 'utf-8) "\n" t))
      (let ((record (json-parse-string line :object-type 'alist
                                       :array-type 'list)))
        (when (>= (string-to-number (format "%s" (or (alist-get 'severity record) 0))) 3)
          (signal 'vc-p4-error (list (or (alist-get 'data record) "P4 error"))))
        (push record records)))
    (nreverse records)))

(defun vc-p4--query (directory &rest args)
  "Return structured P4 records for ARGS in DIRECTORY."
  (vc-p4--parse-json (apply #'vc-p4--run directory "-Mj" "-ztag" args)))

(defun vc-p4--escape (file)
  "Escape literal FILE for a P4 file specification."
  (let ((result (expand-file-name file)))
    (dolist (pair '(("%" . "%25") ("#" . "%23") ("@" . "%40") ("*" . "%2A")))
      (setq result (string-replace (car pair) (cdr pair) result)))
    result))

(defun vc-p4--config-signature (file)
  "Return local configuration file identities affecting FILE.
Use attributes rather than parsing credentials.  Include every ancestor
P4CONFIG candidate, so creating a nearer configuration invalidates caches."
  (let ((directory (file-name-directory (expand-file-name file)))
        (name (getenv "P4CONFIG"))
        (paths (list (expand-file-name (or (getenv "P4ENVIRO") "~/.p4enviro")))))
    (when (and name (not (string-empty-p name)))
      (if (file-name-absolute-p name)
          (push name paths)
        (while directory
          (push (expand-file-name name directory) paths)
          (let ((parent (file-name-directory (directory-file-name directory))))
            (setq directory (unless (equal parent directory) parent))))))
    (mapcar (lambda (path)
              (let ((attrs (file-attributes path 'string)))
                (list path (file-attribute-size attrs)
                      (file-attribute-modification-time attrs)
                      (file-attribute-status-change-time attrs)
                      (file-attribute-inode-number attrs))))
            paths)))

(defun vc-p4--context (file)
  "Return a cache context for FILE and its effective P4 configuration."
  (list (file-name-directory (expand-file-name file)) vc-p4-program
        (mapcar #'getenv '("P4PORT" "P4CLIENT" "P4USER" "P4CONFIG" "P4CHARSET"
                          "P4ENVIRO" "P4HOST" "P4TICKETS" "P4TRUST"))
        (vc-p4--config-signature file)))

(defcustom vc-p4-retry-delay 10 "Seconds before retrying a failed background query."
  :type 'number)
(define-error 'vc-p4-pending "P4 data is being retrieved" 'vc-p4-error)
(cl-defstruct (vc-p4--entry (:constructor vc-p4--make-entry))
  value time error job)
(defvar-local vc-p4--notice-context nil)
(defvar-local vc-p4--notice-timer nil)
(defvar-local vc-p4-status nil "Background status: pending, error, or nil.")
(defvar-local vc-p4--operation-error nil)
(defvar vc-p4-update-hook nil "Hook run after background data changes in a file buffer.")

(defun vc-p4--notify (file context)
  "Schedule a coalesced refresh of FILE if CONTEXT still matches."
  (when-let* ((buffer (get-file-buffer file)))
    (with-current-buffer buffer
      (when (and (equal context (vc-p4--context file))
                 (or (not vc-p4--notice-timer)
                     (not (equal context vc-p4--notice-context))))
        (when vc-p4--notice-timer (cancel-timer vc-p4--notice-timer))
        (setq vc-p4--notice-context context
              vc-p4--notice-timer
              (run-at-time 0 nil #'vc-p4--publish buffer file context))))))

(defun vc-p4--publish (buffer file context)
  "Refresh BUFFER's cached VC properties for FILE in CONTEXT."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq vc-p4--notice-timer nil)
      (when (and (equal buffer-file-name file)
                 (equal context (vc-p4--context file)))
        (setq vc-p4-status nil)
        (let ((backend (vc-file-getprop file 'vc-backend)))
          ;; Do not displace another backend that won discovery while pending.
          (when (memq backend '(nil none P4))
            (if (vc-p4-registered file)
                (progn
                  (vc-file-setprop file 'vc-backend 'P4)
                  (vc-file-setprop file 'vc-working-revision (vc-p4-working-revision file))
                  (vc-file-setprop file 'vc-state (vc-p4-state file))
                  (vc-file-setprop file 'vc-checkout-model (vc-p4-checkout-model (list file)))
                  (vc-mode-line file 'P4))
              (vc-file-setprop file 'vc-state nil)
              (when (eq backend 'P4)
                (vc-file-setprop file 'vc-backend 'none))
              (setq vc-mode (when vc-p4-status
                              (if (eq vc-p4-status 'error) " P4!" " P4?"))))
            (run-hooks 'vc-p4-update-hook)))))))

(defun vc-p4--cached (file args &optional raw immutable)
  "Return cached ARGS for FILE, scheduling missing or expired data.
RAW requests bytes; otherwise parse JSON.  IMMUTABLE entries do not expire.
Pending and failed queries return nil, never fabricated metadata or bytes."
  (let* ((file (expand-file-name file))
         (context (vc-p4--context file))
         (table (if raw vc-p4--contents vc-p4--metadata))
         (key (list context file args))
         (entry (gethash key table))
         (now (float-time)))
    (unless (and entry
                 (or (vc-p4--entry-job entry)
                     (and (vc-p4--entry-time entry)
                          (or (and immutable (not (vc-p4--entry-error entry)))
                              (< (- now (vc-p4--entry-time entry))
                                 (if (vc-p4--entry-error entry)
                                     vc-p4-retry-delay vc-p4-metadata-ttl))))))
      (setq entry (vc-p4--make-entry))
      (puthash key entry table)
      (setf (vc-p4--entry-job entry)
            (apply #'vc-p4--run-async
                   (if (file-directory-p file) file (file-name-directory file))
                   (lambda (result)
                     ;; Refresh can replace the entry while the worker runs.
                     (when (eq entry (gethash key table))
                       (setf (vc-p4--entry-job entry) nil
                             (vc-p4--entry-time entry) (float-time))
                       (condition-case err
                           (if (eq (plist-get result :status) 'success)
                               (setf (vc-p4--entry-value entry)
                                     (if raw (plist-get result :stdout)
                                       (vc-p4--parse-json (plist-get result :stdout))))
                             (signal 'vc-p4-error
                                     (list (format "%s: %s%s%s"
                                                   (plist-get result :status)
                                                   (or (plist-get result :detail) "")
                                                   (plist-get result :stderr)
                                                   (plist-get result :stdout)))))
                         (error (setf (vc-p4--entry-error entry) (error-message-string err))
                                (setq vc-p4-last-error (error-message-string err))))
                       (vc-p4--notify file context)))
                   (append (unless raw '("-Mj" "-ztag")) args))))
    (cond ((vc-p4--entry-job entry) (setq vc-p4-status 'pending) nil)
          ((vc-p4--entry-error entry) (setq vc-p4-status 'error) nil)
          (t (vc-p4--entry-value entry)))))

(defun vc-p4--stat (file &optional _fresh)
  "Return fresh cached fstat metadata for FILE, or nil while pending.
Explicit invalidation is handled by `vc-p4-refresh', not by a wait here."
  (unless (file-remote-p file)
    (if (vc-p4--operation-for file)
        (progn (setq vc-p4-status 'pending) nil)
      (car (vc-p4--cached file (list "fstat" (vc-p4--escape file)))))))

;;;###autoload
(defun vc-p4-registered (file)
  "Return non-nil when FILE is mapped and versioned in Perforce."
  (when (and (not (file-remote-p file)) (executable-find vc-p4-program))
    (condition-case err
        (let ((stat (vc-p4--stat file)))
          (and (alist-get 'clientFile stat)
               (or (alist-get 'haveRev stat) (alist-get 'action stat))))
      (error (setq vc-p4-last-error (error-message-string err)) nil))))

(defun vc-p4-revision-granularity () "Use per-file revisions." 'file)
(defun vc-p4-checkout-model (files)
  "Return the editing model for FILES in their current workspace."
  (if (null files) 'announce
    (if (cl-some (lambda (file)
                   (let* ((stat (vc-p4--stat file))
                          (type (or (alist-get 'type stat) (alist-get 'headType stat) "")))
                     (string-match-p "+[^+]*l" type))) files)
        'locking
      (let ((spec (car (vc-p4--cached (car files) '("client" "-o")))))
        (if (member "allwrite" (split-string (or (alist-get 'Options spec) "")))
            'implicit 'announce)))))
(defun vc-p4-working-revision (file)
  "Return the synced revision of FILE, or zero for an addition."
  (let ((stat (vc-p4--stat file)))
    (if (member (alist-get 'action stat) '("add" "move/add")) "0"
      (alist-get 'haveRev stat))))

(defun vc-p4-root (file)
  "Return the P4 workspace root for FILE if its mapping is valid."
  (unless (file-remote-p file)
    (condition-case nil
        (let* ((file (expand-file-name file))
               (spec (concat (vc-p4--escape file)
                             (when (file-directory-p file)
                               (if (string-suffix-p "/" file) "..." "/..."))))
               (mappings (vc-p4--cached file (list "where" spec)))
               (effective (make-hash-table :test #'equal))
               mapped)
          ;; Later mappings override the same path.  An excluded child does
          ;; not exclude the entire parent directory's wildcard mapping.
          (dolist (mapping mappings)
            (when-let* ((path (alist-get 'path mapping)))
              (puthash path (not (assq 'unmap mapping)) effective)))
          (maphash (lambda (_path included) (when included (setq mapped t))) effective)
          (when mapped
            (let ((root (alist-get 'clientRoot (car (vc-p4--cached file '("info"))))))
              (when (and root (not (equal root "null")))
                (file-name-as-directory root)))))
      (error nil))))
(defun vc-p4-responsible-p (file) "Return workspace responsibility for FILE." (vc-p4-root file))

(defun vc-p4--revision-spec (revision)
  "Convert REVISION to an unambiguous P4 suffix."
  (cond ((equal revision "") "#head")
        ((string-match-p "\\`[0-9]+\\'" revision) (concat "#" revision))
        ((string-match-p "\\`[#@][^\n\r]+\\'" revision) revision)
        (t (user-error "Use a file revision number, #revision or @changelist"))))

(defun vc-p4--base (file revision)
  "Return cached pristine bytes of FILE at REVISION, or nil while pending."
  (cond ((equal revision "0") "")
        ((null revision) nil)
        (t (when-let* ((depot (alist-get 'depotFile (vc-p4--stat file))))
             (vc-p4--cached
              file (list "print" "-q" "-o" "-"
                         (concat depot (vc-p4--revision-spec revision))) t
              (string-match-p "\\`[0-9]+\\'" revision))))))

(defun vc-p4-find-revision (file revision buffer)
  "Insert FILE at REVISION into BUFFER."
  (let ((bytes (vc-p4--base file revision)))
    (unless bytes (signal 'vc-p4-pending (list file revision)))
    (with-current-buffer buffer (insert bytes))))

(defun vc-p4--local-bytes (file)
  "Read FILE literally, using empty contents for a missing file."
  (if (not (file-exists-p file)) ""
    (with-temp-buffer (set-buffer-multibyte nil)
                      (insert-file-contents-literally file) (buffer-string))))

(defun vc-p4-state (file)
  "Return FILE's VC state, retaining depot freshness information."
  (let* ((stat (vc-p4--stat file t))
         (action (alist-get 'action stat))
         (behind (and (alist-get 'haveRev stat) (alist-get 'headRev stat)
                      (< (string-to-number (alist-get 'haveRev stat))
                         (string-to-number (alist-get 'headRev stat))))))
    (cond ((null stat) nil)
          ((member action '("add" "move/add")) 'added)
          ((member action '("delete" "move/delete")) 'removed)
          ((and (assq 'unresolved stat)
                (not (equal (alist-get 'unresolved stat) "0"))) 'conflict)
          ((not (file-exists-p file)) 'missing)
          ((null (vc-p4--base file (vc-p4-working-revision file))) nil)
          ((not (equal (vc-p4--local-bytes file)
                       (vc-p4--base file (vc-p4-working-revision file))))
           (if behind 'needs-merge 'edited))
          (behind 'needs-update)
          (t 'up-to-date))))

(defun vc-p4--after-save ()
  "Invalidate P4 state before consumers run their after-save hooks.
Emacs only invalidates up-to-date announce-model files by default; a
needs-update file can also become locally edited when saved."
  (when (and buffer-file-name
             (eq (vc-file-getprop buffer-file-name 'vc-backend) 'P4))
    (vc-file-setprop buffer-file-name 'vc-state nil)
    (vc-file-setprop buffer-file-name 'vc-working-revision nil)))

(add-hook 'after-save-hook #'vc-p4--after-save -90)

(defun vc-p4--diff-hl-modified-p (state)
  "Let diff-hl display P4 edits that also need a merge.
Some diff-hl versions only recognize edited/conflict.  Preserve accurate
VC states while extending that predicate narrowly for P4 buffers."
  (and (eq state 'needs-merge) buffer-file-name
       (eq (vc-backend buffer-file-name) 'P4)))

(defun vc-p4--diff-hl-temp-name (original file revision &optional manual)
  "Scope diff-hl's reference cache to the P4 configuration and depot path.
ORIGINAL computes its usual name for FILE, REVISION and MANUAL.  A file
revision alone is not unique across Perforce clients or servers."
  (let ((name (funcall original file revision manual)))
    (if (eq (vc-file-getprop file 'vc-backend) 'P4)
        (concat name "-p4-"
                (secure-hash 'sha256
                             (prin1-to-string
                              (list (vc-p4--context file)
                                    (alist-get 'depotFile (vc-p4--stat file))))))
      name)))

(with-eval-after-load 'diff-hl
  (advice-add 'diff-hl-modified-p :before-until #'vc-p4--diff-hl-modified-p)
  (advice-add 'diff-hl-make-temp-file-name :around #'vc-p4--diff-hl-temp-name))

(defcustom vc-p4-diff-program "diff" "Executable used for local differences."
  :type 'string)
(defcustom vc-p4-max-pending-diffs 32 "Maximum pending diff pipelines, including completion processes."
  :type 'natnum)
(defvar-local vc-p4--diff-failed-until nil)
(defvar vc-p4--generation 0)
(defvar vc-p4--diff-tasks nil)
(defvar-local vc-p4--diff-owner-task nil)
(cl-defstruct (vc-p4--diff-task (:constructor vc-p4--make-diff-task))
  files rev1 rev2 destination source tick contexts stamps generation
  gate worker timer temps chunks remaining snapshot switches baselines deadline done)

(defun vc-p4--file-stamp (file)
  "Return local FILE identity and modification attributes."
  (let ((attrs (file-attributes file)))
    (list (file-attribute-size attrs) (file-attribute-modification-time attrs)
          (file-attribute-status-change-time attrs) (file-attribute-inode-number attrs))))

(defun vc-p4--diff-valid-p (task)
  "Whether TASK still describes the current source and workspace."
  (and (buffer-live-p (vc-p4--diff-task-destination task))
       (= vc-p4--generation (vc-p4--diff-task-generation task))
       (equal (vc-p4--diff-task-contexts task)
              (mapcar #'vc-p4--context (vc-p4--diff-task-files task)))
       (equal (vc-p4--diff-task-stamps task)
              (mapcar #'vc-p4--file-stamp (vc-p4--diff-task-files task)))
       (cl-every (lambda (pair) (eq (cdr pair) (gethash (car pair) vc-p4--metadata)))
                 (vc-p4--diff-task-baselines task))
       (or (null (vc-p4--diff-task-source task))
           (and (buffer-live-p (vc-p4--diff-task-source task))
                (with-current-buffer (vc-p4--diff-task-source task)
                  (and (equal buffer-file-name (car (vc-p4--diff-task-files task)))
                       (= (buffer-chars-modified-tick) (vc-p4--diff-task-tick task))))))))

(defun vc-p4--diff-finish (task &optional success cancelled)
  "Release TASK; publish valid SUCCESS or quietly discard CANCELLED work."
  (unless (vc-p4--diff-task-done task)
    (setf (vc-p4--diff-task-done task) t)
    (when (timerp (vc-p4--diff-task-timer task))
      (cancel-timer (vc-p4--diff-task-timer task)))
    (when (vc-p4--diff-task-worker task)
      (vc-p4--cancel (vc-p4--diff-task-worker task)))
    (dolist (file (vc-p4--diff-task-temps task))
      (when (file-exists-p file) (delete-file file)))
    (setq vc-p4--diff-tasks (delq task vc-p4--diff-tasks))
    (let ((source (vc-p4--diff-task-source task)))
      (when (buffer-live-p source)
        (with-current-buffer source
          (let ((valid (vc-p4--diff-valid-p task)))
            (setq vc-p4-status (cond ((and success valid) nil)
                                     ((and valid (not cancelled)) 'error) (t 'pending)))
            (when (and valid (not success) (not cancelled))
              (with-current-buffer (vc-p4--diff-task-destination task)
                (setq vc-p4--diff-failed-until (+ (float-time) vc-p4-retry-delay))))
            (vc-mode-line buffer-file-name 'P4)))))
    (let ((gate (vc-p4--diff-task-gate task)))
      (when (process-live-p gate)
        (if (and success (vc-p4--diff-valid-p task))
            (progn
              (with-current-buffer (vc-p4--diff-task-destination task)
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (insert (decode-coding-string
                           (apply #'concat (nreverse (vc-p4--diff-task-chunks task)))
                           'utf-8-unix))))
              ;; VC and diff-hl attach continuations to this process.  It
              ;; exits only after the entire multi-stage result is available.
              (process-send-eof gate))
          (delete-process gate))))))

(defun vc-p4--diff-step (task)
  "Advance TASK without waiting for P4 or a local diff process."
  (when (and (not (vc-p4--diff-task-done task))
             (not (buffer-live-p (vc-p4--diff-task-destination task))))
    (vc-p4--diff-finish task nil t))
  (unless (vc-p4--diff-task-done task)
    (with-current-buffer (or (and (buffer-live-p (vc-p4--diff-task-source task))
                                 (vc-p4--diff-task-source task))
                            (vc-p4--diff-task-destination task))
      (condition-case err
          (cond
           ((or (not (vc-p4--diff-valid-p task))
                (> (float-time) (vc-p4--diff-task-deadline task)))
            (vc-p4--diff-finish task))
           ((null (vc-p4--diff-task-remaining task)) (vc-p4--diff-finish task t))
           (t
            (setq vc-p4-status nil)
            (let* ((file (car (vc-p4--diff-task-remaining task)))
                   (old (vc-p4--base file
                                    (or (vc-p4--diff-task-rev1 task)
                                        (if (vc-p4--diff-task-rev2 task) "0"
                                          (vc-p4-working-revision file)))))
                   (new (if (vc-p4--diff-task-rev2 task)
                            (vc-p4--base file (vc-p4--diff-task-rev2 task))
                          (or (vc-p4--diff-task-snapshot task)
                              (vc-p4--local-bytes file)))))
              (cond
               ((eq vc-p4-status 'error) (vc-p4--diff-finish task))
               ((or (null old) (null new))
                (setf (vc-p4--diff-task-timer task)
                      (run-at-time 0.05 nil #'vc-p4--diff-step task)))
               (t
                (let ((a (make-temp-file "vc-p4-old-"))
                      (b (make-temp-file "vc-p4-new-"))
                      (coding-system-for-write 'no-conversion)
                      (switches (vc-p4--diff-task-switches task)))
                  (let ((key (list (vc-p4--context file) file
                                   (list "fstat" (vc-p4--escape file)))))
                    (when-let* ((entry (gethash key vc-p4--metadata)))
                      (push (cons key entry) (vc-p4--diff-task-baselines task))))
                  (setf (vc-p4--diff-task-temps task) (list a b))
                  (write-region old nil a nil 'silent)
                  (write-region new nil b nil 'silent)
                  (let ((vc-p4-program vc-p4-diff-program))
                    (setf (vc-p4--diff-task-worker task)
                          (apply #'vc-p4--run-async
                                 (file-name-directory file)
                                 (lambda (result)
                                   (unless (vc-p4--diff-task-done task)
                                     (if (and (eq (plist-get result :process-status) 'exit)
                                              (memq (plist-get result :status) '(success error))
                                              (memq (plist-get result :exit-code) '(0 1)))
                                         (progn
                                           (push (plist-get result :stdout)
                                                 (vc-p4--diff-task-chunks task))
                                           (dolist (temp (vc-p4--diff-task-temps task))
                                             (delete-file temp))
                                           (setf (vc-p4--diff-task-temps task) nil
                                                 (vc-p4--diff-task-worker task) nil
                                                 (vc-p4--diff-task-remaining task)
                                                 (cdr (vc-p4--diff-task-remaining task)))
                                           (vc-p4--diff-step task))
                                       (setq vc-p4-last-error
                                             (format "Local diff failed: %s" result))
                                       (vc-p4--diff-finish task))))
                                 (append (if (stringp switches) (list switches) switches)
                                         (list "--label" (concat file " (base)")
                                               "--label" file a b)))))))))))
        (error (setq vc-p4-last-error (error-message-string err))
               (vc-p4--diff-finish task))))))

(defun vc-p4--diff-async (files rev1 rev2 buffer &optional snapshot)
  "Start an asynchronous diff into BUFFER, optionally using buffer SNAPSHOT."
  (let* ((files (mapcar #'expand-file-name files))
         (destination (get-buffer-create (or buffer "*vc-diff*")))
         (source (when (equal buffer-file-name (car files)) (current-buffer)))
         (tick (when source (buffer-chars-modified-tick)))
         (existing (cl-find destination vc-p4--diff-tasks
                            :key #'vc-p4--diff-task-destination)))
    (if (and existing (vc-p4--diff-valid-p existing)
             (equal files (vc-p4--diff-task-files existing))
             (equal rev1 (vc-p4--diff-task-rev1 existing))
             (equal rev2 (vc-p4--diff-task-rev2 existing))
             (equal snapshot (vc-p4--diff-task-snapshot existing)))
        1
      (when existing (vc-p4--diff-finish existing nil t))
      (with-current-buffer destination
        (let ((inhibit-read-only t)) (erase-buffer))
        (when (and vc-p4--diff-failed-until (> vc-p4--diff-failed-until (float-time)))
          (when source
            (with-current-buffer source
              (setq vc-p4-status 'error)
              (vc-mode-line buffer-file-name 'P4)))
          (signal 'vc-p4-error '("Local diff failed recently; retry after the backoff interval"))))
      (when (>= (length vc-p4--diff-tasks) (max 1 vc-p4-max-pending-diffs))
        (signal 'vc-p4-error '("P4 diff queue is full; retry after pending work finishes")))
      (when source
        (setq vc-p4-status 'pending)
        (vc-mode-line (car files) 'P4))
      (let* ((gate (make-process :name "vc-p4-diff" :buffer destination
                                 :command '("cat") :connection-type 'pipe
                                 :noquery t :sentinel #'ignore))
             (task (vc-p4--make-diff-task
                    :files files :remaining files :rev1 rev1 :rev2 rev2
                    :source source :tick tick :destination destination :gate gate
                    :contexts (mapcar #'vc-p4--context files)
                    :stamps (mapcar #'vc-p4--file-stamp files)
                    :generation vc-p4--generation :snapshot snapshot
                    :switches (or (vc-switches 'P4 'diff) '("-u"))
                    :deadline (+ (float-time) (* 4 vc-p4-command-timeout)))))
        (push task vc-p4--diff-tasks)
        (with-current-buffer destination (setq vc-p4--diff-owner-task task))
        (set-process-sentinel gate
                              (lambda (process _event)
                                (when (memq (process-status process) '(exit signal failed))
                                  (vc-p4--diff-finish task nil t))))
        (setf (vc-p4--diff-task-timer task)
              (run-at-time 0 nil #'vc-p4--diff-step task)))
      1)))

(defvar diff-hl-timer)
(defvar diff-hl-update-async)
(defvar diff-hl-async-inhibit-functions)
(defvar diff-hl-reference-revision)
(declare-function diff-hl-update "diff-hl")
(declare-function vc-p4-gutter--update "vc-p4-gutter")
(declare-function diff-hl-remove-overlays "diff-hl")

(defvar-local vc-p4--buffer-context nil)
(defvar-local vc-p4--disk-stamp nil)
(defvar-local vc-p4--gutter-buffers nil)

(defun vc-p4--cancel-file-work (file)
  "Cancel pending requests for FILE without invalidating other files."
  (dolist (table (list vc-p4--metadata vc-p4--contents))
    (let (entries)
      (maphash (lambda (key entry)
                 (when (and (vc-p4--entry-p entry)
                            (equal (file-truename (nth 1 key)) (file-truename file))
                            (vc-p4--entry-job entry))
                   (push (cons key (vc-p4--entry-job entry)) entries))) table)
      (dolist (entry entries)
        (remhash (car entry) table)
        (vc-p4--cancel (cdr entry))))))

(defun vc-p4--buffer-cleanup ()
  "Release work owned by the current source or destination buffer."
  (when vc-p4--notice-timer
    (cancel-timer vc-p4--notice-timer)
    (setq vc-p4--notice-timer nil))
  (dolist (task (copy-sequence vc-p4--diff-tasks))
    (when (or (eq (current-buffer) (vc-p4--diff-task-source task))
              (eq (current-buffer) (vc-p4--diff-task-destination task)))
      (vc-p4--diff-finish task nil t)))
  (when buffer-file-name (vc-p4--cancel-file-work buffer-file-name))
  (let ((buffers vc-p4--gutter-buffers))
    (setq vc-p4--gutter-buffers nil)
    (dolist (buffer buffers)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun vc-p4--ensure-context ()
  "Invalidate obsolete VC properties when the workspace or disk file changes."
  (when (and buffer-file-name (not (file-remote-p buffer-file-name)))
    (let ((context (vc-p4--context buffer-file-name))
          (stamp (vc-p4--file-stamp buffer-file-name)))
      (when (and vc-p4--buffer-context
                 (not (equal context vc-p4--buffer-context))
                 (bound-and-true-p diff-hl-mode))
        (diff-hl-remove-overlays))
      (when (or (and vc-p4--buffer-context (not (equal context vc-p4--buffer-context)))
                (and vc-p4--disk-stamp (not (equal stamp vc-p4--disk-stamp))))
        (vc-p4--buffer-cleanup)
        (vc-file-clearprops buffer-file-name)
        (let (keys)
          (maphash (lambda (key _)
                     (when (equal (nth 1 key) buffer-file-name) (push key keys)))
                   vc-p4--metadata)
          (mapc (lambda (key) (remhash key vc-p4--metadata)) keys)))
      (setq vc-p4--buffer-context context vc-p4--disk-stamp stamp))))

(defun vc-p4--after-revert ()
  "Recheck P4 state after a local file revert without waiting."
  (when (and buffer-file-name
             (or vc-p4--buffer-context
                 (eq (vc-file-getprop buffer-file-name 'vc-backend) 'P4)))
    (vc-p4--ensure-context)
    (vc-p4--notify buffer-file-name (vc-p4--context buffer-file-name))))

(add-hook 'kill-buffer-hook #'vc-p4--buffer-cleanup)
(add-hook 'after-revert-hook #'vc-p4--after-revert)

(defun vc-p4--gutter-update (original &rest args)
  "Update P4 gutters without clearing existing markers for pending data.
Call ORIGINAL with ARGS once state is known; its asynchronous diff replaces
markers on completion.  The mode line continues to identify pending work."
  (let ((p4-buffer (and buffer-file-name
                        (or vc-p4--buffer-context
                            (eq (vc-file-getprop buffer-file-name 'vc-backend) 'P4)))))
    (when p4-buffer
      (setq vc-p4-status nil diff-hl-timer nil)
      (vc-p4--ensure-context)
      ;; VC caches negative discovery while our request is pending.  Recheck
      ;; the backend cache so repeated updates retain the pending status.
      (when (and (memq (vc-file-getprop buffer-file-name 'vc-backend) '(nil none))
                 (vc-p4-registered buffer-file-name))
        (vc-file-setprop buffer-file-name 'vc-backend 'P4)))
    (cond
     ((and buffer-file-name (eq (vc-backend buffer-file-name) 'P4))
      (let ((diff-hl-update-async t)
            (diff-hl-async-inhibit-functions nil))
        (setq vc-p4-status nil diff-hl-timer nil)
        (vc-file-setprop buffer-file-name 'vc-state (vc-p4-state buffer-file-name))
        (vc-mode-line buffer-file-name 'P4)
        ;; diff-hl treats unknown state as no changes and removes overlays.
        ;; Preserve the last display until a replacement can be computed.
        (unless (memq vc-p4-status '(pending error))
          (condition-case err
              (vc-p4-gutter--update)
            (vc-p4-error
             (setq vc-p4-status (if (eq (car err) 'vc-p4-pending) 'pending 'error)
                   vc-p4-last-error (error-message-string err))
             (vc-mode-line buffer-file-name 'P4)
             nil)))))
     ;; A saved file's changed disk stamp invalidates discovery too.
     ((and p4-buffer vc-p4-status)
      (setq vc-mode (if (eq vc-p4-status 'pending) " P4?" " P4!"))
      nil)
     (t (apply original args)))))

(defun vc-p4--gutter-destination (buffer)
  "Give BUFFER a name unique to the visiting buffer."
  (let* ((name (format "%s<p4:%s>" (if (bufferp buffer) (buffer-name buffer) buffer)
                       (buffer-name)))
         (output (get-buffer-create name)))
    (cl-pushnew output vc-p4--gutter-buffers)
    name))

(defun vc-p4--gutter-changes (original file backend &optional revision buffer)
  "Use a separate P4 output buffer for ORIGINAL's FILE and REVISION."
  (funcall original file backend revision
           (if (eq backend 'P4)
               (vc-p4--gutter-destination (or buffer " *diff-hl* ")) buffer)))

(defun vc-p4--gutter-buffer-diff (original file &optional destination backend context)
  "Diff unsaved P4 contents asynchronously; otherwise call ORIGINAL."
  (if (eq (or backend (vc-backend file)) 'P4)
      (let* ((destination (get-buffer-create
                           (vc-p4--gutter-destination
                            (or destination " *diff-hl-buffer*"))))
             (vc-diff-switches (list (format "-U%d" (or context 0)) "--strip-trailing-cr"))
             (snapshot (save-restriction
                         (widen)
                         (encode-coding-string (buffer-substring-no-properties (point-min) (point-max))
                                               buffer-file-coding-system))))
        (vc-p4--diff-async (list file) diff-hl-reference-revision nil destination snapshot)
        destination)
    (funcall original file destination backend context)))

(defun vc-p4--update-gutters ()
  "Refresh enabled gutters after P4 data becomes available."
  (if (bound-and-true-p diff-hl-mode)
      (diff-hl-update)
    ;; Reverting can reset minor-mode variables without running the mode's
    ;; disable body.  Its old overlays must not survive that transition.
    (when (and buffer-file-name
               (eq (vc-file-getprop buffer-file-name 'vc-backend) 'P4))
      (diff-hl-remove-overlays))))

(with-eval-after-load 'diff-hl
  (advice-add 'diff-hl-update :around #'vc-p4--gutter-update)
  (require 'vc-p4-gutter)
  ;; Remove the older global completion advice when reloading this library.
  (advice-remove 'diff-hl--resolve 'vc-p4--gutter-resolve)
  (advice-add 'diff-hl-changes-buffer :around #'vc-p4--gutter-changes)
  (advice-add 'diff-hl-diff-buffer-with-reference :around #'vc-p4--gutter-buffer-diff)
  (add-hook 'vc-p4-update-hook #'vc-p4--update-gutters)
  (add-hook 'flycheck-mode-hook #'vc-p4--update-gutters))

(defun vc-p4--require-base (file revision)
  "Return cached bytes for FILE at REVISION or fail without waiting."
  (or (vc-p4--base file revision)
      (signal 'vc-p4-pending (list file revision))))

(defun vc-p4-diff (files &optional rev1 rev2 buffer async)
  "Insert unified differences for FILES from REV1 to REV2 into BUFFER.
Nil revisions mean have revision and working contents respectively.
ASYNC uses background retrieval and local diff.  Synchronous callers require
cached baselines and may run local diff; automatic gutters always use ASYNC."
  (if async (vc-p4--diff-async files rev1 rev2 buffer)
    (let ((destination (get-buffer-create (or buffer "*vc-diff*")))
        (inhibit-read-only t)
        (result 0))
    ;; Consumers reuse their diff buffer.  Clear it once per fileset so a
    ;; later clean result cannot leave old gutter hunks behind.
    (with-current-buffer destination (erase-buffer))
    (dolist (file files)
      (let ((old (make-temp-file "vc-p4-old-")) (new (make-temp-file "vc-p4-new-")))
        (unwind-protect
            (let ((coding-system-for-write 'no-conversion)
                  (coding-system-for-read 'utf-8-unix))
              (write-region (vc-p4--require-base file (or rev1 (if rev2 "0" (vc-p4-working-revision file)))) nil old nil 'silent)
              (write-region (if rev2 (vc-p4--require-base file rev2) (vc-p4--local-bytes file)) nil new nil 'silent)
              (let* ((switches (or (vc-switches 'P4 'diff) '("-u")))
                     (status (apply #'call-process vc-p4-diff-program nil destination nil
                                    (append (if (stringp switches) (list switches) switches)
                                            (list "--label" (concat file " (base)")
                                                  "--label" file old new)))))
                (unless (memq status '(0 1)) (signal 'vc-p4-error '("Local diff failed")))
                (setq result (max result status))))
          (delete-file old) (delete-file new))))
    result)))

(defun vc-p4-mode-line-string (file)
  "Show pending or failed retrieval explicitly for FILE."
  (let ((status (cond ((vc-p4--operation-for file) 'pending)
                      (vc-p4--operation-error 'error)
                      (t vc-p4-status))))
    (if status
        (propertize (if (eq status 'error) "P4!" "P4?")
                    'help-echo (if (eq status 'error)
                                   (or vc-p4--operation-error vc-p4-last-error
                                       "P4 retrieval failed")
                                 "P4 operation or retrieval pending"))
      (vc-default-mode-line-string 'P4 file))))

(defun vc-p4-refresh ()
  "Invalidate P4 caches and schedule new discovery without waiting."
  (interactive)
  (cl-incf vc-p4--generation)
  (mapc (lambda (task) (vc-p4--diff-finish task nil t))
        (copy-sequence vc-p4--diff-tasks))
  (let (jobs)
    (dolist (table (list vc-p4--metadata vc-p4--contents))
      (maphash (lambda (_ entry)
                 (when (and (vc-p4--entry-p entry) (vc-p4--entry-job entry))
                   (push (vc-p4--entry-job entry) jobs))) table)
      (clrhash table))
    (mapc #'vc-p4--cancel jobs))
  (let ((target (current-buffer)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and buffer-file-name
                 (or (eq buffer target)
                     (eq (vc-file-getprop buffer-file-name 'vc-backend) 'P4)))
        (vc-file-setprop buffer-file-name 'vc-state nil)
        (vc-file-setprop buffer-file-name 'vc-working-revision nil)
        (setq vc-p4-status 'pending vc-mode " P4?")
        (vc-p4--notify buffer-file-name (vc-p4--context buffer-file-name)))))))

;; VC's mutation frontends assume synchronous completion.  These narrow P4
;; adapters defer their buffer-side effects until the command has succeeded.
(cl-defstruct (vc-p4--operation (:constructor vc-p4--make-operation))
  name files contexts job result error success stamps buffers destructive recovery)
(defvar vc-p4--operations (make-hash-table :test #'equal))
(defvar vc-p4-last-operation nil "Most recently started P4 mutation, for diagnostics.")

(defun vc-p4--operation-for (file)
  "Return the pending mutation of local FILE, if any."
  (when (and file (not (file-remote-p file)))
    (gethash (file-truename file) vc-p4--operations)))

(defun vc-p4--invalidate-file (file &optional keep-properties)
  "Invalidate FILE's metadata and cancel obsolete reads, preserving other files."
  (vc-p4--cancel-file-work file)
  (let (keys)
    (maphash (lambda (key _)
               (when (equal (file-truename (nth 1 key)) (file-truename file))
                 (push key keys))) vc-p4--metadata)
    (dolist (key keys) (remhash key vc-p4--metadata)))
  (unless keep-properties (vc-file-clearprops file)))

(defun vc-p4--check-saved (files)
  "Reject unsaved buffers visiting FILES before a destructive operation."
  (dolist (file files)
    (when-let* ((buffer (get-file-buffer file)))
      (when (buffer-modified-p buffer)
        (user-error "Save or undo buffer changes before operating on %s" file)))))

(defun vc-p4--operation-prepare (operation)
  "Recheck OPERATION at dispatch and save recoverable copies before changing files."
  (let ((files (vc-p4--operation-files operation)))
    (unless (equal (vc-p4--operation-contexts operation) (mapcar #'vc-p4--context files))
      (user-error "P4 configuration changed before operation started"))
    (when (vc-p4--operation-destructive operation)
      (vc-p4--check-saved files)
      (unless (equal (vc-p4--operation-stamps operation) (mapcar #'vc-p4--file-stamp files))
        (user-error "Files changed before P4 operation started"))
      (let ((directory (make-temp-file "vc-p4-recovery-" t)) (index 0) manifest)
        (setf (vc-p4--operation-recovery operation) directory)
        (dolist (file files)
          (when (file-exists-p file)
            (let ((copy (expand-file-name (number-to-string (cl-incf index)) directory)))
              (copy-file file copy nil t nil t)
              (push (cons file copy) manifest))))
        (with-temp-file (expand-file-name "files.el" directory)
          (prin1 (nreverse manifest) (current-buffer)))))))

(defun vc-p4--operation-resynch (operation file)
  "Reload FILE after OPERATION only if its original buffer remains unchanged."
  (when-let* ((snapshot (assoc file (vc-p4--operation-buffers operation)))
              (buffer (nth 1 snapshot)))
    (when (and (buffer-live-p buffer)
               (equal (buffer-local-value 'buffer-file-name buffer) file)
               (equal (vc-p4--context file)
                      (nth (cl-position file (vc-p4--operation-files operation) :test #'equal)
                           (vc-p4--operation-contexts operation))))
      (with-current-buffer buffer
        (if (or (buffer-modified-p) (/= (buffer-chars-modified-tick) (nth 2 snapshot)))
            (message "P4 finished; kept newer buffer text in %s" (buffer-name))
          (if (file-exists-p file)
              (progn (revert-buffer t t t)
                     (read-only-mode (if (file-writable-p file) -1 1)))
            ;; Keep the visiting buffer available for undo/recovery after delete.
            (clear-visited-file-modtime)
            (read-only-mode 1)))))))

(defun vc-p4--check-operation-save (&rest _)
  "Prevent a save racing a destructive P4 command; typing remains available."
  (when-let* ((operation (vc-p4--operation-for buffer-file-name)))
    (when (vc-p4--operation-destructive operation)
      (user-error "P4 %s is pending; wait or cancel before saving"
                  (vc-p4--operation-name operation)))))

(advice-add 'basic-save-buffer :before #'vc-p4--check-operation-save)

(defun vc-p4--check-operation-result (result)
  "Require a confirmed file action in RESULT, preserving server diagnostics."
  (unless (eq (plist-get result :status) 'success)
    (signal 'vc-p4-error
            (list (format "%s: %s%s%s" (plist-get result :status)
                          (or (plist-get result :detail) "")
                          (or (plist-get result :stderr) "")
                          (or (plist-get result :stdout) "")))))
  (let ((records (vc-p4--parse-json (plist-get result :stdout))))
    (unless (cl-some (lambda (record) (alist-get 'action record)) records)
      (signal 'vc-p4-error
              (list (or (cl-some (lambda (record) (alist-get 'data record)) records)
                        "No file action confirmed"))))))

(defun vc-p4--operation-note-error (operation error)
  "Record ERROR on OPERATION without masking an earlier failure."
  (unless (vc-p4--operation-error operation)
    (setf (vc-p4--operation-error operation) (error-message-string error)))
  (setq vc-p4-last-error (vc-p4--operation-error operation)))

(defun vc-p4--operation-finish (operation result)
  "Publish RESULT for OPERATION and release files even if UI or cleanup fails."
  (setf (vc-p4--operation-result operation) result)
  (unwind-protect
      (condition-case err
          (progn
            (vc-p4--check-operation-result result)
            (when (vc-p4--operation-success operation)
              (funcall (vc-p4--operation-success operation) operation)))
        ((error quit) (vc-p4--operation-note-error operation err)))
    (dolist (file (vc-p4--operation-files operation))
      (remhash (file-truename file) vc-p4--operations)))
  (when (and (vc-p4--operation-recovery operation)
             (not (vc-p4--operation-error operation)))
    (condition-case err
        (progn
          (delete-directory (vc-p4--operation-recovery operation) t)
          (setf (vc-p4--operation-recovery operation) nil))
      (error (vc-p4--operation-note-error operation err))))
  (cl-mapc
   (lambda (file context)
     (condition-case err
         (progn
           (vc-p4--invalidate-file
            file (or (not (equal context (vc-p4--context file)))
                     (not (memq (vc-file-getprop file 'vc-backend) '(nil none P4)))))
           (when (equal context (vc-p4--context file))
             (when-let* ((buffer (get-file-buffer file)))
               (with-current-buffer buffer
                 (setq vc-p4--operation-error (vc-p4--operation-error operation))))
             (vc-p4--notify file context)))
       (error (vc-p4--operation-note-error operation err))))
   (vc-p4--operation-files operation) (vc-p4--operation-contexts operation))
  (message "P4 %s: %s%s" (vc-p4--operation-name operation)
           (or (vc-p4--operation-error operation) "done")
           (if (vc-p4--operation-recovery operation)
               (format "; recovery copies: %s" (vc-p4--operation-recovery operation)) "")))

(defun vc-p4--operate (name files args &optional success destructive)
  "Queue mutation NAME of FILES with ARGS and a SUCCESS completion function.
SUCCESS receives the completed operation.  DESTRUCTIVE enables disk recovery
copies and save protection.  Serialize overlapping files and never retry."
  (setq files (mapcar #'expand-file-name files))
  (dolist (file files)
    (when (or (file-remote-p file) (file-directory-p file))
      (user-error "P4 operations require individual local files"))
    (when (vc-p4--operation-for file)
      (user-error "A P4 operation is already pending for %s" file)))
  (when destructive (vc-p4--check-saved files))
  (let ((operation (vc-p4--make-operation
                    :name name :files files :contexts (mapcar #'vc-p4--context files)
                    :success success :destructive destructive
                    :stamps (mapcar #'vc-p4--file-stamp files)
                    :buffers (mapcar (lambda (file)
                                       (when-let* ((buffer (get-file-buffer file)))
                                         (list file buffer (with-current-buffer buffer
                                                             (buffer-chars-modified-tick))))) files))))
    (setq vc-p4-last-operation operation)
    (dolist (file files)
      (vc-p4--invalidate-file file t)
      (puthash (file-truename file) operation vc-p4--operations)
      (vc-file-setprop file 'vc-state nil)
      (when-let* ((buffer (get-file-buffer file)))
        (with-current-buffer buffer
          (setq vc-p4--operation-error nil vc-mode " P4?"))))
    (setf (vc-p4--operation-job operation)
          (apply #'vc-p4--run-async (file-name-directory (car files))
                 (lambda (result) (vc-p4--operation-finish operation result))
                 "-Mj" "-ztag" args))
    (setf (vc-p4--job-prepare (vc-p4--operation-job operation))
          (lambda () (vc-p4--operation-prepare operation)))
    operation))

(defun vc-p4-cancel-operation ()
  "Cancel this file's pending P4 operation and refresh its actual state.
A running command may already have changed the workspace or server."
  (interactive)
  (if-let* ((operation (vc-p4--operation-for buffer-file-name)))
      (vc-p4--cancel (vc-p4--operation-job operation))
    (user-error "No P4 operation is pending for this file")))

(defun vc-p4-checkout (file &optional revision)
  "Open FILE for edit asynchronously, preserving its HAVE revision and text.
Changing to REVISION is a sync operation and is not implemented here."
  (when revision (user-error "Use p4 sync to change revisions"))
  (let ((file (expand-file-name file))
        (context (vc-p4--context file)))
    (vc-p4--operate
     "edit" (list file) (list "edit" (vc-p4--escape file))
     (lambda (_operation)
       (when (equal context (vc-p4--context file))
         (when-let* ((buffer (get-file-buffer file)))
           (with-current-buffer buffer
             ;; edit changes permissions, never buffer contents or undo history.
             (read-only-mode (if (file-writable-p file) -1 1))
             (run-hooks 'vc-checkout-hook))))))))

(defun vc-p4--vc-checkout (original file &optional revision)
  "Route P4 checkout through completion handling; delegate ORIGINAL otherwise."
  (if (eq (vc-backend file) 'P4)
      (vc-p4-checkout file revision)
    (funcall original file revision)))

(defun vc-p4-edit ()
  "Open the current file for edit, including in an allwrite workspace."
  (interactive)
  (vc-checkout (or buffer-file-name (user-error "This buffer visits no file"))))

(advice-add 'vc-checkout :around #'vc-p4--vc-checkout)

(defun vc-p4-register (files &optional _comment)
  "Open individual FILES for add asynchronously, preserving literal filenames."
  (setq files (mapcar #'expand-file-name (if (stringp files) (list files) files)))
  (dolist (file files)
    (when (or (file-remote-p file) (file-directory-p file) (not (file-exists-p file)))
      (user-error "Save each local file before adding it to P4"))
    (when (vc-p4--operation-for file)
      (user-error "A P4 operation is already pending for %s" file)))
  ;; add -f interprets raw names literally; escaping them would add the wrong
  ;; path.  One command per file also makes partial fileset failures explicit.
  (mapcar (lambda (file) (vc-p4--operate "add" (list file) (list "add" "-f" file)))
          files))

(defun vc-p4--vc-register (original &optional fileset comment)
  "Register P4 FILESET asynchronously, delegating ORIGINAL for other backends."
  (let ((fileset (or fileset (vc-deduce-fileset nil t))))
    (if (not (eq (car fileset) 'P4))
        (funcall original fileset comment)
      (dolist (file (cadr fileset))
        (when (vc-p4-registered file)
          (user-error "This file is already registered: %s" file))
        (when-let* ((buffer (get-file-buffer file)))
          (with-current-buffer buffer (vc-buffer-sync))))
      (vc-p4-register (cadr fileset) comment))))

(advice-add 'vc-register :around #'vc-p4--vc-register)

(defun vc-p4--require-stat (file)
  "Return FILE's metadata or request that the caller retry after retrieval."
  (or (vc-p4--stat file)
      (if (eq vc-p4-status 'error)
          (signal 'vc-p4-error (list vc-p4-last-error))
        (signal 'vc-p4-pending (list "Retry when P4 metadata is ready" file)))))

(defun vc-p4-revert (file &optional _contents-done)
  "Revert FILE to HAVE asynchronously, retaining copies if the operation fails."
  (setq file (expand-file-name file))
  (let* ((stat (vc-p4--require-stat file))
         (action (alist-get 'action stat)))
    (when (member action '("move/add" "move/delete"))
      (user-error "Use p4 revert for moved files until move handling is available"))
    (unless (or action (alist-get 'haveRev stat))
      (user-error "No working revision to restore"))
    (vc-p4--operate
     "revert" (list file)
     (if action (list "revert" (vc-p4--escape file))
       (list "sync" "-f" (concat (vc-p4--escape file) "#" (alist-get 'haveRev stat))))
     (lambda (operation) (vc-p4--operation-resynch operation file)) t)))

(defun vc-p4--vc-revert-file (original file)
  "Defer P4 buffer reload until revert completes, otherwise call ORIGINAL."
  (if (eq (vc-backend file) 'P4) (vc-p4-revert file) (funcall original file)))

(defun vc-p4--vc-revert (original)
  "Confirm P4 revert without a synchronous preview; delegate ORIGINAL otherwise."
  (let ((fileset (vc-deduce-fileset)))
    (if (not (eq (car fileset) 'P4)) (funcall original)
      (let ((files (cadr fileset)))
        (vc-p4--check-saved files)
        ;; Validate the whole selection before starting any mutation.
        (mapc #'vc-p4--require-stat files)
        (unless (yes-or-no-p (format "Discard saved changes in %s? " (vc-delistify files)))
          (user-error "Revert canceled"))
        (mapcar #'vc-p4-revert files)))))

(defun vc-p4-delete-file (file)
  "Open FILE for deletion asynchronously, keeping a recovery copy on failure."
  (setq file (expand-file-name file))
  (vc-p4--require-stat file)
  (let ((state (vc-p4-state file)))
    (unless (memq state '(up-to-date needs-update missing))
      (if (null state) (signal 'vc-p4-pending (list file))
        (user-error "Revert local changes before deleting %s" file))))
  (vc-p4--operate "delete" (list file) (list "delete" (vc-p4--escape file))
                  (lambda (operation) (vc-p4--operation-resynch operation file)) t))

(defun vc-p4--vc-delete-file (original file)
  "Confirm and schedule P4 deletion; delegate ORIGINAL for other backends."
  (if (not (eq (vc-backend file) 'P4)) (funcall original file)
    (vc-p4--check-saved (list file))
    (unless (y-or-n-p (format "Really want to delete %s? " (file-name-nondirectory file)))
      (user-error "Delete canceled"))
    (vc-p4-delete-file file)))

(advice-add 'vc-revert-file :around #'vc-p4--vc-revert-file)
(advice-add 'vc-revert :around #'vc-p4--vc-revert)
(advice-add 'vc-delete-file :around #'vc-p4--vc-delete-file)

;; Deliberately fail unsupported mutations rather than invoking generic fallbacks.
(defun vc-p4-checkin (&rest _args) "Submit is not implemented yet." (user-error "P4 submit is not implemented yet"))
;;;###autoload
(add-to-list 'vc-handled-backends 'P4 t)
(provide 'vc-p4)
;;; vc-p4.el ends here
