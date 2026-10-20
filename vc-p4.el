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

(defun vc-p4--run (directory &rest args)
  "Run P4 with ARGS in DIRECTORY, returning stdout as bytes.
Use pipes and argument vectors, never a shell.  Enforce a deadline and
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
          (process-send-eof process)
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
      (when-let ((stderr-process (get-buffer-process err)))
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

(defun vc-p4--stat (file &optional fresh)
  "Return cached fstat metadata for FILE, bypassing cache when FRESH."
  (when (file-remote-p file) (user-error "P4 remote workspaces are not supported yet"))
  (let* ((key (list (vc-p4--context file) (expand-file-name file)))
         (entry (gethash key vc-p4--metadata)))
    (if (and (not fresh) entry (< (- (float-time) (car entry)) vc-p4-metadata-ttl))
        (cdr entry)
      (let ((record (car (vc-p4--query (file-name-directory (expand-file-name file))
                                     "fstat" (vc-p4--escape file)))))
        (puthash key (cons (float-time) record) vc-p4--metadata)
        record))))

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
(defun vc-p4-checkout-model (_files) "P4 normally requires explicit checkout." 'announce)
(defun vc-p4-working-revision (file)
  "Return the synced revision of FILE, or zero for an addition."
  (let ((stat (vc-p4--stat file)))
    (if (member (alist-get 'action stat) '("add" "move/add")) "0"
      (or (alist-get 'haveRev stat) (user-error "No have revision for %s" file)))))

(defun vc-p4-root (file)
  "Return the P4 workspace root for FILE if its mapping is valid."
  (unless (file-remote-p file)
    (condition-case nil
        (let* ((file (expand-file-name file))
               (directory (if (file-directory-p file) file (file-name-directory file)))
               (spec (concat (vc-p4--escape file)
                             (when (file-directory-p file)
                               (if (string-suffix-p "/" file) "..." "/..."))))
               (mappings (vc-p4--query directory "where" spec))
               (effective (make-hash-table :test #'equal))
               mapped)
          ;; Later mappings override the same path.  An excluded child does
          ;; not exclude the entire parent directory's wildcard mapping.
          (dolist (mapping mappings)
            (when-let* ((path (alist-get 'path mapping)))
              (puthash path (not (assq 'unmap mapping)) effective)))
          (maphash (lambda (_path included) (when included (setq mapped t))) effective)
          (when mapped
            (let ((root (alist-get 'clientRoot (car (vc-p4--query directory "info")))))
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
  "Return pristine bytes of FILE at REVISION."
  (if (equal revision "0") ""
    (let* ((stat (vc-p4--stat file))
           (depot (alist-get 'depotFile stat))
           (key (list (vc-p4--context file) depot revision))
           (cached (gethash key vc-p4--contents)))
      (or cached
          (let ((bytes (vc-p4--run (file-name-directory (expand-file-name file))
                                  "print" "-q" (concat depot (vc-p4--revision-spec revision)))))
            ;; Symbolic specifications can change without changing their name.
            (when (string-match-p "\\`[0-9]+\\'" revision)
              (puthash key bytes vc-p4--contents))
            bytes)))))

(defun vc-p4-find-revision (file revision buffer)
  "Insert FILE at REVISION into BUFFER."
  (let ((bytes (vc-p4--base file revision)))
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
    (cond ((member action '("add" "move/add")) 'added)
          ((member action '("delete" "move/delete")) 'removed)
          ((> (string-to-number (or (alist-get 'unresolved stat) "0")) 0) 'conflict)
          ((not (file-exists-p file)) 'missing)
          ((not (equal (vc-p4--local-bytes file)
                       (vc-p4--base file (vc-p4-working-revision file))))
           (if behind 'needs-merge 'edited))
          (behind 'needs-update)
          (t 'up-to-date))))

(defun vc-p4--diff-hl-modified-p (state)
  "Let diff-hl display P4 edits that also need a merge.
Some diff-hl versions only recognize edited/conflict.  Preserve accurate
VC states while extending that predicate narrowly for P4 buffers."
  (and (eq state 'needs-merge) buffer-file-name
       (eq (vc-backend buffer-file-name) 'P4)))

(with-eval-after-load 'diff-hl
  (advice-add 'diff-hl-modified-p :before-until #'vc-p4--diff-hl-modified-p))

(defun vc-p4-diff (files &optional rev1 rev2 buffer _async)
  "Insert unified differences for FILES from REV1 to REV2 into BUFFER.
Nil revisions mean have revision and working contents respectively.
This initial implementation is synchronous with bounded P4 retrieval."
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
              (write-region (vc-p4--base file (or rev1 (if rev2 "0" (vc-p4-working-revision file)))) nil old nil 'silent)
              (write-region (if rev2 (vc-p4--base file rev2) (vc-p4--local-bytes file)) nil new nil 'silent)
              (let* ((switches (or (vc-switches 'P4 'diff) '("-u")))
                     (status (apply #'call-process "diff" nil destination nil
                                    (append (if (stringp switches) (list switches) switches)
                                            (list "--label" (concat file " (base)")
                                                  "--label" file old new)))))
                (unless (memq status '(0 1)) (signal 'vc-p4-error '("Local diff failed")))
                (setq result (max result status))))
          (delete-file old) (delete-file new))))
    result))

(defun vc-p4-refresh ()
  "Discard P4 caches and refresh VC state for the current file."
  (interactive)
  (clrhash vc-p4--metadata)
  (clrhash vc-p4--contents)
  (when buffer-file-name
    (vc-file-clearprops buffer-file-name)
    (vc-refresh-state)))

;; Deliberately fail unsupported mutations rather than invoking generic fallbacks.
(defun vc-p4-checkout (&rest _args) "Checkout is not implemented yet." (user-error "Use p4 edit; VC checkout is not implemented yet"))
(defun vc-p4-checkin (&rest _args) "Submit is not implemented yet." (user-error "P4 submit is not implemented yet"))
(defun vc-p4-register (&rest _args) "Add is not implemented yet." (user-error "P4 add is not implemented yet"))
(defun vc-p4-revert (&rest _args) "Revert is not implemented yet." (user-error "P4 revert is not implemented yet"))
;;;###autoload
(add-to-list 'vc-handled-backends 'P4 t)
(provide 'vc-p4)
;;; vc-p4.el ends here
