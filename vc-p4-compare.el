;;; vc-p4-compare.el --- Read-only P4 comparisons and Ediff -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))

;;; Commentary:
;; Reuse native diff completion with immutable snapshots of visiting buffers.
;; Prepare Ediff operands asynchronously; launch only for the current request.

;;; Code:
(require 'vc-p4-history)
(require 'diff-mode)
(declare-function ediff-buffers "ediff")
(defvar vc-buffer-overriding-fileset nil)
(defvar-local vc-p4-compare--ediff-serial 0)
(defvar-local vc-p4-compare--ediff-control nil)
(defvar-local vc-p4-compare--operands nil)

(defun vc-p4-compare--files (files)
  "Normalize explicit FILES and reject directories."
  (when (stringp files) (setq files (list files)))
  (unless files (user-error "Select at least one P4 file"))
  (mapcar (lambda (file)
            (when (or (file-remote-p file) (file-directory-p file))
              (user-error "P4 comparisons require individual local files"))
            (if-let* ((buffer (get-file-buffer file)))
                (buffer-local-value 'buffer-file-name buffer)
              (expand-file-name file))) files))

(defun vc-p4-compare--snapshots (files)
  "Capture complete visiting-buffer contents of FILES under one P4 configuration."
  (delq nil
        (mapcar
         (lambda (file)
           (let ((context (vc-p4--context file)))
             (when-let* ((buffer (get-file-buffer file)))
               (with-current-buffer buffer
                 (unless (equal context (vc-p4--context file))
                   (user-error "Compare files with different buffer-local P4 settings separately"))
                 (cons file
                       (list :buffer buffer :tick (buffer-chars-modified-tick)
                             :coding buffer-file-coding-system :context context
                             :bytes (save-restriction
                                      (widen)
                                      (encode-coding-string
                                       (buffer-substring-no-properties (point-min) (point-max))
                                       buffer-file-coding-system)))))))) files)))

(defun vc-p4-compare--read-revisions (files)
  "Read comparison operands for FILES; an empty target means working text."
  (list (let ((value (vc-read-revision "From revision (empty for HAVE): " files 'P4)))
          (unless (equal value "") value))
        (let ((value (vc-read-revision "To revision (empty for working text): " files 'P4)))
          (unless (equal value "") value))))

(defun vc-p4-compare--label (revision default)
  "Label file REVISION distinctly from a changelist, or return DEFAULT."
  (cond ((null revision) default)
        ((string-match-p "\\`[0-9]+\\'" revision) (concat "#" revision))
        (t revision)))

;;;###autoload
(defun vc-p4-compare (files &optional revision1 revision2 buffer)
  "Compare FILES from REVISION1 to REVISION2 asynchronously.
Nil operands mean per-file HAVE and working text, including unsaved buffers.
BUFFER defaults to *P4 comparison*.  Directories are not expanded."
  (interactive
   (let* ((fileset (vc-deduce-fileset t)) (files (cadr fileset)))
     (unless (eq (car fileset) 'P4) (user-error "Select P4 files to compare"))
     (cons files (vc-p4-compare--read-revisions files))))
  (when (equal revision1 "") (setq revision1 nil))
  (when (equal revision2 "") (setq revision2 nil))
  (let* ((files (vc-p4-compare--files files))
         (snapshots (unless revision2 (vc-p4-compare--snapshots files)))
         (settings (cl-loop for variable in '(vc-p4-program vc-p4-diff-program process-environment exec-path
                                                            vc-diff-switches vc-p4-diff-switches)
                            when (boundp variable) collect (cons variable (copy-tree (symbol-value variable)))))
         (output (get-buffer-create (or buffer "*P4 comparison*"))))
    ;; Emacs 30 initializes diff mode after the backend call; Emacs 31 does it
    ;; before.  Capture settings explicitly instead of depending on that order.
    (let ((vc-p4--comparison-snapshots snapshots)
          (vc-p4--comparison-settings settings) (vc-diff-added-files nil))
      (vc-diff-internal t (list 'P4 files) revision1 revision2 nil output))
    (with-current-buffer output
      (setq-local vc-p4-history--settings settings)
      (vc-p4-history--restore-settings)
      (setq-local header-line-format (format "P4: %s → %s" (vc-p4-compare--label revision1 "HAVE")
                                             (vc-p4-compare--label revision2 "working text"))
                  revert-buffer-function
                  (lambda (&rest _) (vc-p4-compare files revision1 revision2 output)))
      (let* ((task (cl-find output vc-p4--diff-tasks :key #'vc-p4--diff-task-destination))
             (gate (and task (vc-p4--diff-task-gate task))))
        (setq vc-p4--diff-owner-task task)
        (when (process-live-p gate)
          (let ((sentinel (process-sentinel gate)))
            (set-process-sentinel
             gate
             (lambda (process event)
               (funcall sentinel process event)
               (when (and (buffer-live-p output)
                          (eq (buffer-local-value 'vc-p4--diff-owner-task output) task)
                          (eq (process-status process) 'signal))
                 (with-current-buffer output
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert "P4 comparison changed or failed; run the comparison again.\n")
                     (setq header-line-format "P4 comparison incomplete")
                     (set-buffer-modified-p nil))))))))))
    output))

(defun vc-p4-compare--content (file revision history)
  "Return FILE's immutable bytes, identity and type for REVISION in HISTORY."
  (let* ((target (vc-p4-history--target file (or revision "") history))
         (row (unless (equal target "0")
                (or (cl-find target history :key (lambda (entry) (plist-get entry :identity)) :test #'equal)
                    (car (vc-p4-history--entries file target 1))))))
    (list :bytes (vc-p4-history--bytes file target) :label target :type (plist-get row :type))))

(defun vc-p4-compare--text-p (content)
  "Whether CONTENT is suitable for a decoded Ediff buffer."
  (let ((bytes (plist-get content :bytes)))
    (and (not (string-prefix-p "binary" (or (plist-get content :type) "")))
         (or (not (string-match-p "\0" bytes))
             (string-prefix-p (unibyte-string #xff #xfe) bytes)
             (string-prefix-p (unibyte-string #xfe #xff) bytes)))))

(defun vc-p4-compare--working-content (file snapshots)
  "Return FILE's captured working text and current P4 file type."
  (let* ((vc-p4-status nil) (stat (vc-p4--stat file)))
    (pcase vc-p4-status
      ('pending (signal 'vc-p4-pending (list file)))
      ('error (signal 'vc-p4-error (list vc-p4-last-error))))
    (let ((revision (vc-p4-working-revision file)))
      (unless revision (user-error "No P4 working revision is available"))
      (list :bytes (or (plist-get (alist-get file snapshots nil nil #'equal) :bytes)
                       (vc-p4--local-bytes file))
            :label "working text" :working-revision revision
            :type (or (alist-get 'type stat) (alist-get 'headType stat))))))

(defun vc-p4-compare--ediff-buffers (file operands)
  "Launch native Ediff on decoded FILE OPERANDS, retaining edited snapshots."
  (require 'ediff)
  (unless (cl-every #'vc-p4-compare--text-p operands)
    (user-error "P4 Ediff requires text; use vc-p4-compare for binary differences"))
  (let (buffers ticks control)
    (unwind-protect
        (progn
          (dolist (operand operands)
            (let ((buffer (generate-new-buffer
                           (format "*P4 %s %s*" (file-name-nondirectory file) (plist-get operand :label)))))
              (push buffer buffers)
              (with-current-buffer buffer
                (vc-p4-history--insert-bytes (plist-get operand :bytes) file)
                (set-buffer-modified-p nil)
                (read-only-mode 1)
                (push (cons buffer (buffer-chars-modified-tick)) ticks))))
          (setq buffers (nreverse buffers))
          (setq control
                (ediff-buffers
                 (car buffers) (cadr buffers)
                 (list (lambda ()
                         (setq-local ediff-keep-variants t)
                         (add-hook
                          'ediff-after-quit-hook-internal
                          (lambda ()
                            (dolist (pair ticks)
                              (when (buffer-live-p (car pair))
                                (with-current-buffer (car pair)
                                  (if (= (buffer-chars-modified-tick) (cdr pair))
                                      (kill-buffer (current-buffer))
                                    (message "Kept edited P4 comparison buffer %s" (buffer-name)))))))
                          nil t)))))
          control)
      (unless control
        (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer)))))))

;;;###autoload
(defun vc-p4-ediff (file &optional revision1 revision2)
  "Prepare FILE's REVISION1 and REVISION2 asynchronously, then start Ediff.
Nil operands mean HAVE and a snapshot of working text.  The working file and
its visiting buffer are never used as editable Ediff variants."
  (interactive
   (let ((file (vc-p4-history--source-file)))
     (cons file (vc-p4-compare--read-revisions (list file)))))
  (when (equal revision1 "") (setq revision1 nil))
  (when (equal revision2 "") (setq revision2 nil))
  (let* ((file (car (vc-p4-compare--files (list file))))
         (source (current-buffer)) (window (selected-window)) (position (point))
         (serial (cl-incf vc-p4-compare--ediff-serial))
         (snapshots (unless revision2 (vc-p4-compare--snapshots (list file))))
         (stamp (vc-p4--file-stamp file))
         (request (generate-new-buffer " *P4 Ediff preparation*"))
         history history-known working gate)
    (condition-case err
        (setq gate
              (vc-p4-history--start
               (list file) request
               (lambda ()
                 (unless (or revision2 working)
                   (setq working (vc-p4-compare--working-content file snapshots)))
                 (unless history-known
                   (unless (and (member revision1 '(nil "" "#have" "0" "#0"))
                                (equal (plist-get working :working-revision) "0"))
                     (setq history (vc-p4-history--entries file)))
                   (setq history-known t))
                 (list (vc-p4-compare--content file revision1 history)
                       (if revision2 (vc-p4-compare--content file revision2 history)
                         working)))
               (lambda (operands) (setq-local vc-p4-compare--operands operands))))
      (error (kill-buffer request) (signal (car err) (cdr err))))
    (let ((sentinel (process-sentinel gate)))
      (set-process-sentinel
       gate
       (lambda (process event)
         (funcall sentinel process event)
         (when (and (memq (process-status process) '(exit signal failed))
                    (buffer-live-p request))
           (unwind-protect
               (condition-case failure
                   (if (and (eq (process-status process) 'exit) (zerop (process-exit-status process)))
                       (progn
                         (unless (and (buffer-live-p source) (window-live-p window)
                                      (eq window (selected-window))
                                      (eq (window-buffer window) source)
                                      (with-current-buffer source
                                        (and (= serial vc-p4-compare--ediff-serial)
                                             (= position (point))
                                             (vc-p4--diff-snapshots-valid-p snapshots)
                                             (or revision2 (equal stamp (vc-p4--file-stamp file))))))
                           (user-error "P4 Ediff cancelled: source or focus changed"))
                         (let ((operands (buffer-local-value 'vc-p4-compare--operands request)))
                           (with-current-buffer source
                             (setq vc-p4-compare--ediff-control
                                   (vc-p4-compare--ediff-buffers file operands)))))
                     (message "%s" (with-current-buffer request (buffer-string))))
                 (error (setq vc-p4-last-error (error-message-string failure))
                        (message "%s" vc-p4-last-error)))
             (kill-buffer request))))))
    (message "Preparing P4 Ediff…")
    request))

(defun vc-p4-compare--vc-version-ediff (original files revision1 revision2)
  "Route native P4 historical Ediff through preparation; otherwise use ORIGINAL."
  (if (not (eq (or (car vc-buffer-overriding-fileset)
                   (and files (vc-backend (car files)))) 'P4))
      (funcall original files revision1 revision2)
    (unless (= (length files) 1) (user-error "Ediff compares one P4 file at a time"))
    (vc-p4-ediff (car files) revision1 revision2)))

(defun vc-p4-compare--vc-ediff (original historic &optional not-essential)
  "Prepare native P4 Ediff without saving buffers; delegate others to ORIGINAL."
  (let ((fileset (vc-deduce-fileset)))
    (if (not (eq (car fileset) 'P4)) (funcall original historic not-essential)
      (unless (= (length (cadr fileset)) 1) (user-error "Ediff compares one P4 file at a time"))
      (if historic
          (apply #'vc-p4-ediff (car (cadr fileset)) (vc-p4-compare--read-revisions (cadr fileset)))
        (vc-p4-ediff (car (cadr fileset)))))))

(provide 'vc-p4-compare)
;;; vc-p4-compare.el ends here
