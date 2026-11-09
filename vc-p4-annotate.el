;;; vc-p4-annotate.el --- Asynchronous native P4 attribution -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))

;;; Commentary:
;; Tagged annotate -I exposes both an originating changelist and an indexed
;; source-file/revision chain.  Keep those identities distinct for navigation.

;;; Code:
(require 'vc-p4-history)
(require 'vc-annotate)
(defvar-local vc-p4-annotate--snapshot nil)
(put 'vc-p4-annotate--snapshot 'permanent-local t)

(defun vc-p4-annotate--restore-settings ()
  "Retain P4 settings when native annotation initializes a pending P4 view."
  (when (cl-find (current-buffer) vc-p4-history--tasks
                 :key #'vc-p4-history--task-destination)
    (vc-p4-history--restore-settings)))
(add-hook 'vc-annotate-mode-hook #'vc-p4-annotate--restore-settings)

(defun vc-p4-annotate--origin (record)
  "Return RECORD's deepest explicit source revision, or signal invalid data."
  (let ((index 0) depot revision)
    (while (vc-p4-history--field record "depotFile" index)
      (setq depot (vc-p4-history--field record "depotFile" index)
            revision (vc-p4-history--field record "lower" index))
      (cl-incf index))
    (unless (and depot revision (string-match-p "\\`[1-9][0-9]*\\'" revision))
      (signal 'vc-p4-error '("P4 annotate did not identify the source file revision")))
    (concat depot "#" revision)))

(defun vc-p4-annotate--render (file target history rows dos &optional parent)
  "Render FILE at TARGET with HISTORY and attributed ROWS; decode DOS endings."
  (vc-p4-history--restore-settings)
  (setq-local vc-p4-history--file file
              vc-p4-history--entries history
              vc-buffer-revision target
              vc-buffer-overriding-fileset (list 'P4 (list file))
              vc-annotate-backend 'P4
              vc-parent-buffer parent
              vc-annotate-parent-file file
              vc-annotate-parent-rev target
              vc-p4-annotate--snapshot (list :file file :context (vc-p4--context file) :history history))
  (let* ((columns
          (mapcar (lambda (row)
                    (list (replace-regexp-in-string "\\`.*\\(#[0-9]+\\)\\'" "\\1"
                                                    (plist-get row :identity))
                          (concat "@" (plist-get row :change))
                          (plist-get row :user))) rows))
         (formats
          (mapcar (lambda (index)
                    (format "%%-%ds"
                            (apply #'max 1 (mapcar (lambda (fields) (string-width (nth index fields)))
                                                   columns)))) '(0 1 2))))
    (cl-loop for row in rows for fields in columns do
             (let* ((beginning (point))
                    (identity (plist-get row :identity))
                    (change (plist-get row :change))
                    (metadata (plist-get row :metadata))
                    (time (string-to-number (plist-get metadata :time)))
                    (body (plist-get row :data)))
               (insert (propertize (format (nth 0 formats) (nth 0 fields)) 'help-echo identity) " ")
               (insert-text-button (format (nth 1 formats) (nth 1 fields)) 'follow-link t
                                   'action (lambda (_) (vc-p4-describe-change change file)))
               (insert " " (format (nth 2 formats) (nth 2 fields)) " "
                       (format-time-string "%Y-%m-%d" time t) " | ")
               (let ((prefix-end (point)))
                 (insert (if (and dos (string-suffix-p "\r\n" body))
                             (concat (substring body 0 -2) "\n") body))
                 (add-text-properties beginning (point)
                                      (list 'vc-p4-annotation
                                            (list :identity identity :change change :file file
                                                  :time time :prefix-end prefix-end)))))))
  (vc-p4-annotation-mode 1))

(defun vc-p4-annotate-command (file buffer &optional revision)
  "Annotate FILE at REVISION asynchronously; nil means its HAVE revision."
  ;; Native reannotation resets local variables in the reused output buffer
  ;; before calling this backend.  Preserve the displayed ancestry and context.
  (unless (local-variable-p 'vc-p4-program) (vc-p4-history--restore-settings))
  (let* ((file (expand-file-name file))
         (parent (or (get-file-buffer file) vc-parent-buffer (current-buffer)))
         (revision (or revision ""))
         (dos (eq (coding-system-eol-type (or coding-system-for-read buffer-file-coding-system)) 1))
         (depot (when (string-match-p "\\`//[^\n\r]+#[0-9]+\\'" revision)
                  (replace-regexp-in-string "#[0-9]+\\'" "" revision)))
         (metadata (make-hash-table :test #'equal))
         (snapshot (buffer-local-value 'vc-p4-annotate--snapshot (get-buffer-create buffer)))
         (previous (or vc-p4-history--entries
                       (when (and (equal file (plist-get snapshot :file))
                                  (equal (vc-p4--context file) (plist-get snapshot :context)))
                         (plist-get snapshot :history))))
         (history (when (cl-find revision previous
                                 :key (lambda (row) (plist-get row :identity)) :test #'equal)
                    previous)) target records)
    (vc-p4-history--start
     (list file) buffer
     (lambda ()
       (unless history
         (setq history (vc-p4-history--entries file nil nil depot)))
       (unless history (user-error "No P4 history is available for annotation"))
       (when (zerop (hash-table-count metadata))
         (dolist (row history) (puthash (plist-get row :identity) row metadata)))
       (unless target (setq target (vc-p4-history--target file revision history)))
       (unless records
         (setq records (vc-p4-history--records file (list "annotate" "-I" "-u" target))))
       (when (string-prefix-p "binary" (or (alist-get 'type (car records)) ""))
         (user-error "P4 annotation is unavailable for binary files"))
       (let (rows)
         (dolist (record records)
           (when (and (alist-get 'data record) (alist-get 'lower record))
             (let* ((identity (vc-p4-annotate--origin record))
                    (origin (or (gethash identity metadata)
                                (car (vc-p4-history--entries file identity 1)))))
               (unless origin (user-error "No history metadata for %s" identity))
               (puthash identity origin metadata)
               (push (list :identity identity :change (alist-get 'lower record)
                           :user (alist-get 'user record) :data (alist-get 'data record)
                           :metadata origin) rows))))
         (unless (or rows (and (alist-get 'depotFile (car records))
                               (not (cl-some (lambda (record) (alist-get 'data record)) records))))
           (user-error "P4 returned no textual line attribution"))
         (nreverse rows)))
     (lambda (rows) (vc-p4-annotate--render file target history rows dos parent)))))

(defun vc-p4-annotate-time ()
  "Return the current annotation's age basis, leaving point after its prefix."
  (when-let* ((row (get-text-property (point) 'vc-p4-annotation)))
    (goto-char (plist-get row :prefix-end))
    (vc-annotate-convert-time (plist-get row :time))))

(defun vc-p4-annotate-extract-revision-at-line ()
  "Return the exact source revision and workspace context file at point."
  (when-let* ((row (get-text-property (line-beginning-position) 'vc-p4-annotation)))
    (cons (plist-get row :identity) (plist-get row :file))))

(defun vc-p4-annotate-describe-change ()
  "Describe the submitted changelist that introduced the current line."
  (interactive)
  (let ((row (get-text-property (line-beginning-position) 'vc-p4-annotation)))
    (unless row (user-error "No P4 attribution on this line"))
    (vc-p4-describe-change (plist-get row :change) (plist-get row :file))))

(define-minor-mode vc-p4-annotation-mode
  "Add P4 changelist navigation to native line annotation."
  :lighter nil
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-d") #'vc-p4-annotate-describe-change)
            map))

(provide 'vc-p4-annotate)
;;; vc-p4-annotate.el ends here
