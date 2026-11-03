;;; vc-p4-gutter.el --- Incremental P4 gutter presentation -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep acquisition separate from presentation: resolve a complete, current
;; diff, then reconcile its line markers and navigation hunks in one pass.
;; Unchanged overlays are never deleted, moved, or assigned new properties.

;;; Code:
(require 'cl-lib)
(defvar vc-p4--generation)
(defvar diff-hl-mode)
(defvar diff-hl-side)
(defvar diff-hl-draw-borders)
(defvar diff-hl-highlight-function)
(defvar diff-hl-highlight-reference-function)
(defvar diff-hl-fringe-face-function)
(defvar diff-hl-fringe-reference-face-function)
(defvar diff-hl-fringe-bmp-function)
(defvar flycheck-indication-mode)
(declare-function vc-p4--context "vc-p4")
(declare-function vc-p4--file-stamp "vc-p4")
(declare-function vc-p4--diff-valid-p "vc-p4")
(declare-function diff-hl-changes "diff-hl")
(declare-function diff-hl--resolve "diff-hl")
(declare-function diff-hl-adjust-changes "diff-hl")
(declare-function diff-hl--autohide-margin "diff-hl")

(defcustom vc-p4-gutter-side 'auto
  "Side for P4 markers.
Auto follows `diff-hl-side', except when Flycheck uses that side; then use
the opposite side.  Placement depends on the enabled diagnostic mode, never
on whether an individual diagnostic is currently visible."
  :type '(choice (const auto) (const left) (const right)) :group 'vc-p4)
(defvar-local vc-p4-gutter--serial 0)

(defun vc-p4-gutter--side ()
  "Choose a stable display side independent of diagnostic arrivals."
  (if (not (eq vc-p4-gutter-side 'auto)) vc-p4-gutter-side
    (let ((diagnostic-side
           (when (bound-and-true-p flycheck-mode)
             (pcase (and (boundp 'flycheck-indication-mode) flycheck-indication-mode)
               ((or 'auto 'left-fringe 'left-margin) 'left)
               ((or 'right-fringe 'right-margin) 'right)))))
      (if (eq diagnostic-side diff-hl-side)
          (if (eq diff-hl-side 'left) 'right 'left)
        diff-hl-side))))

(defun vc-p4-gutter--plan (working reference)
  "Describe the desired line and hunk overlays for WORKING and REFERENCE.
Each descriptor is (START END KIND TYPE SHAPE STYLE).  Working line markers
win where reference and working changes overlap, as in diff-hl."
  (let ((lines (make-hash-table :test #'eql)) hunks)
    (save-excursion
      (save-restriction
        (widen)
        (dolist (layer (list (cons 'reference reference) (cons 'working working)))
          (let* ((ref (eq (car layer) 'reference))
                 (style (list (if ref diff-hl-highlight-reference-function diff-hl-highlight-function)
                              (if ref diff-hl-fringe-reference-face-function diff-hl-fringe-face-function)
                              diff-hl-fringe-bmp-function (vc-p4-gutter--side))))
            (when (car style)
              (goto-char (point-min))
              (let ((line 1))
                (dolist (hunk (cdr layer))
                  (pcase-let ((`(,start ,inserts ,_deletes ,type) hunk))
                    (forward-line (- start line))
                    (setq line start)
                    (let ((beg (point)) (count (if (eq type 'delete) 1 inserts)))
                      (dotimes (i count)
                        (let ((shape (cond ((not diff-hl-draw-borders) 'empty)
                                           ((= count 1) 'single) ((= i 0) 'top)
                                           ((= i (1- count)) 'bottom) (t 'middle))))
                          (puthash (point) (list (point) (point) 'line type shape style) lines))
                        (forward-line 1)
                        (cl-incf line))
                      (push (list beg (point) 'hunk type nil (car layer)) hunks)))))))))
      (nconc (hash-table-values lines) hunks))))

(defun vc-p4-gutter--reconcile (working reference)
  "Apply WORKING and REFERENCE changes without rewriting unchanged overlays."
  (let ((desired (vc-p4-gutter--plan working reference))
        (existing (make-hash-table :test #'equal)) obsolete
        (inhibit-redisplay t))
    (dolist (overlay (append (car (overlay-lists)) (cdr (overlay-lists))))
      (when (overlay-get overlay 'diff-hl)
        (let ((spec (overlay-get overlay 'vc-p4-gutter)))
          (if (not spec) (push overlay obsolete)
            (let ((key (append (list (overlay-start overlay) (overlay-end overlay)) spec)))
              (if (gethash key existing) (push overlay obsolete)
                (puthash key overlay existing)))))))
    (dolist (item desired)
      (if (gethash item existing)
          (remhash item existing)
        (pcase-let ((`(,beg ,end ,kind ,type ,shape ,style) item))
          (let ((overlay (make-overlay beg end)))
            (overlay-put overlay 'diff-hl t)
            (overlay-put overlay 'vc-p4-gutter (cddr item))
            (if (eq kind 'hunk)
                (progn
                  ;; Navigation metadata follows edits naturally.  Do not use
                  ;; diff-hl's eager hook that deletes every marker in a hunk
                  ;; when only one of its lines is edited.
                  (overlay-put overlay 'diff-hl-hunk t)
                  (overlay-put overlay 'diff-hl-hunk-type type))
              (let ((diff-hl-fringe-face-function (nth 1 style))
                    (diff-hl-fringe-bmp-function (nth 2 style))
                    (diff-hl-side (nth 3 style)))
                (funcall (car style) overlay type shape)))))))
    (maphash (lambda (_ overlay) (push overlay obsolete)) existing)
    (mapc #'delete-overlay obsolete)
    (when (and (null desired) obsolete)
      (let ((diff-hl-side (vc-p4-gutter--side))) (diff-hl--autohide-margin)))))

(defun vc-p4-gutter--update ()
  "Resolve a current diff and commit it once through the incremental renderer."
  (let* ((source (current-buffer))
         (serial (cl-incf vc-p4-gutter--serial))
         (file buffer-file-name)
         (tick (buffer-chars-modified-tick))
         (context (vc-p4--context file))
         (stamp (vc-p4--file-stamp file))
         (generation vc-p4--generation)
         (changes (diff-hl-changes))
         (working (alist-get :working changes))
         (reference (alist-get :reference changes))
         (tasks (delq nil
                      (mapcar (lambda (value)
                                (when-let* ((buffer (and (not (listp value)) (get-buffer value))))
                                  (buffer-local-value 'vc-p4--diff-owner-task buffer)))
                              (list working reference)))))
    (diff-hl--resolve
     working
     (lambda (work)
       (diff-hl--resolve
        reference
        (lambda (ref)
          (when (buffer-live-p source)
            (with-current-buffer source
              (when (and diff-hl-mode (= serial vc-p4-gutter--serial)
                         (equal file buffer-file-name)
                         (= tick (buffer-chars-modified-tick))
                         (= generation vc-p4--generation)
                         (equal context (vc-p4--context file))
                         (equal stamp (vc-p4--file-stamp file))
                         (cl-every #'vc-p4--diff-valid-p tasks))
                (let ((adjusted (diff-hl-adjust-changes ref work))
                      (base (or (buffer-base-buffer source) source)))
                  (dolist (buffer (buffer-list))
                    (when (and (eq (or (buffer-base-buffer buffer) buffer) base)
                               (buffer-local-value 'diff-hl-mode buffer))
                      (with-current-buffer buffer
                        (vc-p4-gutter--reconcile work adjusted))))))))))))))

(provide 'vc-p4-gutter)
;;; vc-p4-gutter.el ends here
