;;; vc-p4-history.el --- Read-only asynchronous Perforce history -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))

;;; Commentary:
;; File revisions carry their depot path across moves and integrations.  Native
;; VC receives a completion process while the shared runner acquires the data.

;;; Code:
(require 'vc-p4)
(require 'log-view)
(require 'button)
(defvar vc-buffer-revision)

(defcustom vc-p4-max-pending-views 32
  "Maximum number of pending P4 history and revision views."
  :type 'natnum :group 'vc-p4)
(defcustom vc-p4-changes-limit 100
  "Maximum submitted changelists to show for a file."
  :type 'natnum :group 'vc-p4)
(defvar vc-p4-history--tasks nil)
(defvar-local vc-p4-history--entries nil)
(defvar-local vc-p4-history--file nil)
(defvar-local vc-p4-history--depot nil)
(defvar-local vc-p4-history--ready nil)
(defvar-local vc-p4-history--settings nil)
(put 'vc-p4-history--settings 'permanent-local t)
(cl-defstruct (vc-p4-history--task (:constructor vc-p4-history--make-task))
  files owner contexts destination gate reader writer timer deadline done)

(defun vc-p4-history--restore-settings ()
  "Restore the invoking workspace settings after a view changes major mode."
  (dolist (setting vc-p4-history--settings)
    (set (make-local-variable (car setting)) (copy-tree (cdr setting)))))

(defun vc-p4-history--finish (task &optional error-text)
  "Release TASK and finish its native VC notification with ERROR-TEXT if any."
  (unless (vc-p4-history--task-done task)
    (setf (vc-p4-history--task-done task) t)
    (when (timerp (vc-p4-history--task-timer task))
      (cancel-timer (vc-p4-history--task-timer task)))
    (setq vc-p4-history--tasks (delq task vc-p4-history--tasks))
    (when (buffer-live-p (vc-p4-history--task-destination task))
      (with-current-buffer (vc-p4-history--task-destination task)
        (setq mode-line-process (when error-text " P4!"))
        (when error-text
          (let ((inhibit-read-only t))
            (erase-buffer) (insert error-text "\n")
            (set-buffer-modified-p nil)))))
    (let ((gate (vc-p4-history--task-gate task)))
      (when (process-live-p gate)
        (if error-text (delete-process gate) (process-send-eof gate))))))

(defun vc-p4-history--step (task)
  "Advance TASK using cached data; never wait for a worker."
  (unless (vc-p4-history--task-done task)
    (condition-case err
        (progn
          (unless (and (buffer-live-p (vc-p4-history--task-owner task))
                       (buffer-live-p (vc-p4-history--task-destination task)))
            (user-error "P4 view cancelled: its source or output closed"))
          (with-current-buffer (vc-p4-history--task-owner task)
            (unless (equal (vc-p4-history--task-contexts task)
                           (mapcar #'vc-p4--context (vc-p4-history--task-files task)))
              (user-error "P4 view cancelled: workspace configuration changed"))
            (when (> (float-time) (vc-p4-history--task-deadline task))
              (user-error "P4 history retrieval timed out"))
            (let ((data (funcall (vc-p4-history--task-reader task))))
              (with-current-buffer (vc-p4-history--task-destination task)
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (funcall (vc-p4-history--task-writer task) data)
                  ;; Revert/navigation commands run from the resulting view.
                  ;; Retain the invoking workspace's buffer-local settings.
                  (vc-p4-history--restore-settings)
                  (goto-char (point-min))
                  (set-buffer-modified-p nil)))
              (vc-p4-history--finish task))))
      (vc-p4-pending
       (setf (vc-p4-history--task-timer task)
             (run-at-time 0.05 nil #'vc-p4-history--step task)))
      (error
       (setq vc-p4-last-error (error-message-string err))
       (vc-p4-history--finish task vc-p4-last-error)))))

(defun vc-p4-history--start (files destination reader writer)
  "Acquire FILES with READER and publish through WRITER into DESTINATION."
  (let ((destination (get-buffer-create destination))
        (settings (mapcar (lambda (variable) (cons variable (copy-tree (symbol-value variable))))
                          '(vc-p4-program vc-p4-diff-program process-environment exec-path))))
    (dolist (task (copy-sequence vc-p4-history--tasks))
      (when (eq destination (vc-p4-history--task-destination task))
        (vc-p4-history--finish task "P4 view superseded")))
    (when (>= (length vc-p4-history--tasks) (max 1 vc-p4-max-pending-views))
      (user-error "P4 view queue is full"))
    (with-current-buffer destination
      (setq-local vc-p4-history--settings settings)
      (vc-p4-history--restore-settings)
      (let ((inhibit-read-only t)) (erase-buffer))
      (setq mode-line-process " P4?"))
    (let* ((gate (make-process :name "vc-p4-history" :buffer destination
                               :command '("cat") :connection-type 'pipe
                               :noquery t :sentinel #'ignore))
           (task (vc-p4-history--make-task
                  :files files :owner (current-buffer)
                  :contexts (mapcar #'vc-p4--context files)
                  :destination destination :gate gate :reader reader :writer writer
                  :deadline (+ (float-time)
                               (* 4 (max 1 (length files)) vc-p4-command-timeout)))))
      (push task vc-p4-history--tasks)
      (set-process-sentinel
       gate (lambda (process _event)
              (unless (vc-p4-history--task-done task)
                (when (memq (process-status process) '(exit signal failed))
                  (vc-p4-history--finish task "P4 view cancelled")))))
      (setf (vc-p4-history--task-timer task)
            (run-at-time 0 nil #'vc-p4-history--step task))
      gate)))

(defun vc-p4-history--cleanup ()
  "Cancel views owned by or publishing into the current buffer."
  (dolist (task (copy-sequence vc-p4-history--tasks))
    (when (memq (current-buffer) (list (vc-p4-history--task-owner task)
                                       (vc-p4-history--task-destination task)))
      (vc-p4-history--finish task "P4 view cancelled: buffer closed"))))
(add-hook 'kill-buffer-hook #'vc-p4-history--cleanup)

(defun vc-p4-history--field (record name index &optional integration)
  "Read indexed NAME from P4 RECORD at INDEX and optional INTEGRATION."
  (alist-get (intern (format "%s%d%s" name index
                             (if integration (format ",%d" integration) ""))) record))

(defun vc-p4-history--parse (records)
  "Convert indexed filelog RECORDS into ordered, fully identified revisions."
  (let (entries)
    (dolist (record records)
      (let ((depot (alist-get 'depotFile record)) (index 0))
        (while (vc-p4-history--field record "rev" index)
          (let ((revision (vc-p4-history--field record "rev" index))
                (integration 0) links)
            (while (vc-p4-history--field record "how" index integration)
              (push (list :how (vc-p4-history--field record "how" index integration)
                          :file (vc-p4-history--field record "file" index integration)
                          :start (vc-p4-history--field record "srev" index integration)
                          :end (vc-p4-history--field record "erev" index integration)) links)
              (cl-incf integration))
            (push (list :depot depot :revision revision
                        :identity (concat depot "#" revision)
                        :change (vc-p4-history--field record "change" index)
                        :action (vc-p4-history--field record "action" index)
                        :user (vc-p4-history--field record "user" index)
                        :time (vc-p4-history--field record "time" index)
                        :description (vc-p4-history--field record "desc" index)
                        :links (nreverse links)) entries))
          (cl-incf index))))
    (cl-delete-duplicates (nreverse entries) :key (lambda (row) (plist-get row :identity))
                          :test #'equal :from-end t)))

(defun vc-p4-history--records (file args)
  "Return cached P4 records for FILE and ARGS, or signal pending/failure."
  (let* ((vc-p4-status nil)
         (records (vc-p4--cached file args)))
    (pcase vc-p4-status
      ('pending (signal 'vc-p4-pending (list file)))
      ('error (signal 'vc-p4-error (list vc-p4-last-error))))
    records))

(defun vc-p4-history--entries (file &optional start limit depot)
  "Return FILE's cached history at START, bounded by LIMIT, or signal pending."
  (let* ((spec (if (and start (string-match-p "\\`//[^\n\r]+#[0-9]+\\'" start)) start
                 (concat (or depot (vc-p4--escape file))
                         (when start (vc-p4--revision-spec start)))))
         (records (vc-p4-history--records
                   file (append '("filelog" "-i" "-l")
                                (when (numberp limit) (list "-m" (number-to-string limit)))
                                (list spec)))))
    (vc-p4-history--parse records)))

(defun vc-p4-history--render (groups)
  "Insert history GROUPS, retaining original file and revision identities."
  (setq vc-p4-history--entries (apply #'append (mapcar #'cdr groups)))
  (dolist (group groups)
    (insert "File: " (car group) "\n\n")
    (dolist (row (cdr group))
      (insert "Revision: " (plist-get row :identity) "\nChangelist: ")
      (let ((change (plist-get row :change)) (file (car group)))
        (insert-text-button (concat "@" change) 'follow-link t
                            'action (lambda (_) (vc-p4-describe-change change file))))
      (insert "\nAuthor: " (plist-get row :user) "\n"
              "Date: " (format-time-string "%Y-%m-%d %H:%M:%S UTC"
                                           (string-to-number (plist-get row :time)) t) "\n"
              "Action: " (plist-get row :action) "\n")
      (dolist (link (plist-get row :links))
        (insert "  " (plist-get link :how) " " (plist-get link :file)
                (plist-get link :start) "," (plist-get link :end) "\n"))
      (dolist (line (split-string (or (plist-get row :description) "") "\n"))
        (insert "    " line "\n"))
      (insert "\n"))))

(defun vc-p4-print-log (files buffer &optional _shortlog start-revision limit)
  "Print FILES' history asynchronously into BUFFER, starting at START-REVISION."
  (unless (and files (cl-every (lambda (file) (not (file-directory-p file))) files))
    (user-error "P4 history currently requires an explicit file list"))
  (when (and limit (not (and (integerp limit) (> limit 0))))
    (user-error "P4 history limit must be a positive entry count"))
  (let ((files (mapcar #'expand-file-name files))
        (depot (when (bound-and-true-p vc-p4-revision-mode) vc-p4-history--depot))
        (acquired (make-hash-table :test #'equal)))
    (vc-p4-history--start
     files buffer
     (lambda () (mapcar (lambda (file)
                          (or (gethash file acquired)
                              (puthash file
                                       (cons file (vc-p4-history--entries file start-revision limit depot))
                                       acquired))) files))
     #'vc-p4-history--render)))

(define-derived-mode vc-p4-log-view-mode log-view-mode "P4-Log"
  "Browse per-file P4 revisions, with changelists labeled separately."
  (vc-p4-history--restore-settings)
  (setq-local log-view-file-re "^File: \\(.+\\)$"
              log-view-message-re "^Revision: \\(//.+#[0-9]+\\)$"
              log-view-per-file-logs t))

(defun vc-p4-show-log-entry (revision)
  "Position the log at REVISION without confusing it with a changelist."
  (goto-char (point-min))
  (let ((pattern (if (string-prefix-p "//" revision)
                     (concat "^Revision: " (regexp-quote revision) "$")
                   (concat "^Revision: .+#" (regexp-quote (string-remove-prefix "#" revision)) "$"))))
    (when (re-search-forward pattern nil t) (beginning-of-line))))

(defun vc-p4-history--adjacent (file revision offset)
  "Return FILE's displayed ancestor next to REVISION by OFFSET."
  (let* ((rows (if file (vc-p4-history--entries file) vc-p4-history--entries))
         (identity (if (string-prefix-p "//" revision) revision
                     (concat (plist-get (car rows) :depot) "#"
                             (string-remove-prefix "#" revision))))
         (index (cl-position identity rows :key (lambda (row) (plist-get row :identity))
                             :test #'equal)))
    (when index
      (setq index (+ index offset))
      (while (and (>= index 0) (< index (length rows))
                  (member (plist-get (nth index rows) :action) '("delete" "move/delete" "purge")))
        (setq index (+ index offset)))
      (when (>= index 0) (plist-get (nth index rows) :identity)))))

(defun vc-p4-previous-revision (file revision)
  "Return the older content revision for FILE and REVISION, including ancestry."
  (vc-p4-history--adjacent file revision 1))
(defun vc-p4-next-revision (file revision)
  "Return the newer content revision for FILE and REVISION, including ancestry."
  (vc-p4-history--adjacent file revision -1))

(defun vc-p4-revision-completion-table (files)
  "Return a non-blocking revision completion table for FILES."
  (let ((owner (current-buffer)))
    (lambda (string predicate action)
      (if (eq action 'metadata) '(metadata (category . revision))
        (let (candidates)
          (when (buffer-live-p owner)
            (with-current-buffer owner
              (dolist (file files)
                (condition-case nil
                    (let* ((rows (vc-p4-history--entries file))
                           (primary (plist-get (car rows) :depot)))
                      (dolist (row rows)
                        (push (plist-get row :identity) candidates)
                        (push (concat "@" (plist-get row :change)) candidates)
                        (when (equal primary (plist-get row :depot))
                          (push (plist-get row :revision) candidates)
                          (push (concat "#" (plist-get row :revision)) candidates))))
                  (vc-p4-pending nil)))))
          (complete-with-action action candidates string predicate))))))

(define-minor-mode vc-p4-revision-mode
  "Navigate a read-only P4 revision without changing the workspace."
  :lighter " P4-Revision"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-p") #'vc-p4-revision-previous)
            (define-key map (kbd "C-c C-n") #'vc-p4-revision-next)
            map))

(defun vc-p4-history--revision-step (offset)
  "Visit the adjacent revision at OFFSET in the current history snapshot."
  (let ((target (vc-p4-history--adjacent nil vc-buffer-revision offset)))
    (unless target (user-error "No %s revision" (if (> offset 0) "older" "newer")))
    (switch-to-buffer (vc-find-revision vc-p4-history--file target 'P4))))
(defun vc-p4-revision-previous ()
  "Visit the older P4 content revision, following displayed ancestry."
  (interactive) (vc-p4-history--revision-step 1))
(defun vc-p4-revision-next ()
  "Visit the newer P4 content revision, following displayed ancestry."
  (interactive) (vc-p4-history--revision-step -1))

(defun vc-p4-history--target (file revision rows)
  "Resolve REVISION of FILE to an exact depot revision using history ROWS."
  (cond
   ((string-match-p "\\`//[^\n\r]+#[0-9]+\\'" revision) revision)
   ((or (equal revision "") (equal revision "#have"))
    (vc-p4-history--target file (or (vc-p4-working-revision file)
                                    (signal 'vc-p4-pending (list file))) rows))
   ((equal revision "#head") (plist-get (car rows) :identity))
   ((string-prefix-p "@" revision)
    (plist-get (car (vc-p4-history--entries file revision 1)) :identity))
   ((string-match-p "\\`#?[0-9]+\\'" revision)
    (if (member revision '("0" "#0")) "0"
      (concat (plist-get (car rows) :depot) "#" (string-remove-prefix "#" revision))))
   (t (user-error "Use a file revision, //depot/path#revision or @changelist"))))

(defun vc-p4-history--bytes (file revision)
  "Read FILE at REVISION, preserving a failure rather than reporting pending."
  (let* ((vc-p4-status nil) (bytes (vc-p4--base file revision)))
    (when (eq vc-p4-status 'error) (signal 'vc-p4-error (list vc-p4-last-error)))
    (or bytes (signal 'vc-p4-pending (list file revision)))))

(defun vc-p4-history--find-revision (original file revision &optional backend)
  "Return an asynchronous P4 revision buffer, or call ORIGINAL for BACKEND."
  (if (not (eq (or backend (vc-backend file)) 'P4))
      (funcall original file revision backend)
    (let* ((file (expand-file-name file))
           (owner (current-buffer))
           (immutable (string-match-p "\\`\\(?:#?[0-9]+\\|//[^\n\r]+#[0-9]+\\)\\'" revision))
           (name (format "*P4 %s %s <%s>*" (file-name-nondirectory file) revision
                         (substring (secure-hash 'sha256
                                                 (prin1-to-string (list (vc-p4--context file) file
                                                                        vc-p4--generation))) 0 12)))
           (buffer (and immutable (get-buffer name)))
           (depot (when (string-match-p "\\`//[^\n\r]+#[0-9]+\\'" revision)
                    (replace-regexp-in-string "#[0-9]+\\'" "" revision)))
           (rows (when (cl-find revision vc-p4-history--entries
                                :key (lambda (row) (plist-get row :identity)) :test #'equal)
                   vc-p4-history--entries)))
      (unless (and buffer (or (buffer-local-value 'vc-p4-history--ready buffer)
                              (cl-find buffer vc-p4-history--tasks
                                       :key #'vc-p4-history--task-destination)))
        (unless buffer (setq buffer (generate-new-buffer name)))
        (with-current-buffer buffer
          (setq default-directory (file-name-directory file))
          (special-mode))
        (vc-p4-history--start
         (list file) buffer
         (lambda ()
           (unless rows (setq rows (vc-p4-history--entries file nil nil depot)))
           (unless rows (user-error "No P4 history is available for this file"))
           (let ((target (vc-p4-history--target file revision rows)))
             (unless target (user-error "No content revision matches %s" revision))
             (when (and (not (equal target "0"))
                        (not (cl-find target rows :key (lambda (row) (plist-get row :identity)) :test #'equal)))
               (setq rows (vc-p4-history--entries file nil nil
                                                  (replace-regexp-in-string "#[0-9]+\\'" "" target))))
             (list (vc-p4-history--bytes file target) rows target)))
         (lambda (data)
           (insert (car data))
           (decode-coding-inserted-region (point-min) (point-max) file)
           (after-insert-file-set-coding (buffer-size))
           (let ((buffer-file-name file) (enable-local-variables nil))
             (delay-mode-hooks (set-auto-mode)))
           (setq-local vc-p4-history--file file
                       vc-p4-history--entries (cadr data)
                       vc-p4-history--depot (plist-get (car (cadr data)) :depot)
                       vc-p4-history--ready t
                       vc-parent-buffer owner
                       vc-buffer-overriding-fileset (list 'P4 (list file))
                       vc-buffer-revision (nth 2 data))
           (read-only-mode 1)
           (vc-p4-revision-mode 1))))
      buffer)))

(defun vc-p4-history--source-file ()
  "Return the local file anchoring the current P4 history view."
  (or vc-p4-history--file buffer-file-name
      (when (derived-mode-p 'vc-p4-log-view-mode) (log-view-current-file))
      (user-error "Visit a P4 file or its history first")))

(defun vc-p4-history--view-name (label file)
  "Return a view name for LABEL scoped to FILE's workspace."
  (format "*P4 %s <%s>*" label
          (substring (secure-hash 'sha256 (prin1-to-string (list (vc-p4--context file) file))) 0 12)))

(define-derived-mode vc-p4-changes-mode special-mode "P4-Changes"
  "Browse submitted P4 changelists and their affected files.
Use TAB and RET to follow changelist and file-revision links.  Revert with g.")

(defun vc-p4-history--change-number (change)
  "Validate CHANGE and return its numbered changelist string."
  (let ((number (string-remove-prefix "@" (format "%s" change))))
    (unless (and (string-match-p "\\`[0-9]+\\'" number) (> (string-to-number number) 0))
      (user-error "Use a numbered submitted changelist"))
    number))

;;;###autoload
(defun vc-p4-changes (&optional file limit)
  "Show submitted changelists affecting FILE, bounded by LIMIT."
  (interactive)
  (let* ((file (expand-file-name (or file (vc-p4-history--source-file))))
         (limit (or limit vc-p4-changes-limit))
         (buffer (get-buffer-create (vc-p4-history--view-name "changes" file))))
    (unless (and (integerp limit) (> limit 0)) (user-error "Use a positive changelist limit"))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vc-p4-changes-mode) (vc-p4-changes-mode)))
    (vc-p4-history--start
     (list file) buffer
     (lambda () (vc-p4-history--records
                 file (list "changes" "-i" "-l" "-s" "submitted" "-m" (number-to-string limit)
                            (vc-p4--escape file))))
     (lambda (records)
       (setq-local vc-p4-history--file file
                   revert-buffer-function (lambda (&rest _) (vc-p4-changes file limit)))
       (insert "Submitted changelists for " file "\n\n")
       (unless records (insert "No submitted changelists.\n"))
       (dolist (record records)
         (let ((change (alist-get 'change record)))
           (insert-text-button (concat "@" change) 'follow-link t
                               'action (lambda (_) (vc-p4-describe-change change file)))
           (insert "  " (alist-get 'user record) "  "
                   (format-time-string "%Y-%m-%d %H:%M:%S UTC"
                                       (string-to-number (alist-get 'time record)) t) "\n")
           (dolist (line (split-string (or (alist-get 'desc record) "") "\n"))
             (insert "    " line "\n"))
           (insert "\n")))))
    (pop-to-buffer buffer)))

;;;###autoload
(defun vc-p4-describe-change (change &optional file)
  "Show submitted CHANGE and exact affected revisions in FILE's context."
  (interactive (list (read-string "Submitted changelist (@number): ")))
  (let* ((change (vc-p4-history--change-number change))
         (file (expand-file-name (or file (vc-p4-history--source-file))))
         (buffer (get-buffer-create (vc-p4-history--view-name (concat "changelist @" change) file))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vc-p4-changes-mode) (vc-p4-changes-mode)))
    (vc-p4-history--start
     (list file) buffer
     (lambda ()
       (let ((record (car (vc-p4-history--records file (list "describe" "-s" change)))))
         (unless (and record (equal (alist-get 'status record) "submitted"))
           (user-error "Changelist @%s is not a submitted changelist" change))
         record))
     (lambda (record)
       (setq-local vc-p4-history--file file
                   revert-buffer-function (lambda (&rest _) (vc-p4-describe-change change file)))
       (insert "Submitted changelist @" (alist-get 'change record) "\n"
               "Author: " (alist-get 'user record) "\n"
               "Date: " (format-time-string "%Y-%m-%d %H:%M:%S UTC"
                                            (string-to-number (alist-get 'time record)) t) "\n\n")
       (dolist (line (split-string (or (alist-get 'desc record) "") "\n"))
         (insert "    " line "\n"))
       (insert "\nAffected files:\n")
       (let ((index 0))
         (while (vc-p4-history--field record "depotFile" index)
           (let* ((depot (vc-p4-history--field record "depotFile" index))
                  (revision (vc-p4-history--field record "rev" index))
                  (identity (concat depot "#" revision))
                  (action (vc-p4-history--field record "action" index)))
             (insert "  " action "  ")
             (if (member action '("delete" "move/delete" "purge"))
                 (insert identity " (no content)")
               (insert-text-button identity 'follow-link t
                                   'action (lambda (_) (pop-to-buffer (vc-find-revision file identity 'P4)))))
             (insert "\n"))
           (cl-incf index)))))
    (pop-to-buffer buffer)))

(provide 'vc-p4-history)
;;; vc-p4-history.el ends here
