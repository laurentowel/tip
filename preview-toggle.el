;;; preview-toggle.el --- Generic auto-toggle for inline preview overlays -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A reusable framework for inline preview overlays that auto-toggle
;; between source and image display as the cursor moves.
;;
;; See PREVIEW-TOGGLE.md for flow diagrams and API docs.

;;; Code:

(defvar preview-toggle-ignored-commands
  '(pixel-scroll-precision scroll-up-command scroll-down-command)
  "Commands that should not trigger overlay open/close.")

;;; * buffer-local configuration

(defvar-local preview-toggle-type nil
  "Symbol identifying this preview system's overlays.")

(defvar-local preview-toggle-region-at-point-fn nil
  "Function to detect if point is inside a previewable region.
Called with one argument (POS).  Returns (BEG . END) or nil.")

(defvar-local preview-toggle-compile-region-fn nil
  "Function to compile a region after cursor leaves.
Called with two arguments (BEG END).  Should async create overlay.")

;;; * internal state

(defvar-local preview-toggle--was-inside nil
  "Non-nil if cursor was inside a previewable region before the command.")

(defvar-local preview-toggle--marker nil
  "Marker recording cursor position before the command.")

;;; * overlay operations

(defun preview-toggle--overlay-at (pos)
  "Return the preview overlay at POS, or nil."
  (when preview-toggle-type
    (let ((pred (lambda (ov)
                  (eq (overlay-get ov preview-toggle-type)
                      preview-toggle-type))))
      (or (seq-find pred (overlays-at pos))
          (seq-find pred (overlays-in pos (min (1+ pos) (point-max))))))))

(defun preview-toggle--inside-p ()
  "Return non-nil if point is inside a preview overlay or previewable region."
  (or (preview-toggle--overlay-at (point))
      (and preview-toggle-region-at-point-fn
           (funcall preview-toggle-region-at-point-fn (point)))))

(defun preview-toggle-open-at-point ()
  "Reveal the source text by removing the overlay's display property."
  (let ((ov (preview-toggle--overlay-at (point))))
    (when (and ov (not (memq this-command preview-toggle-ignored-commands)))
      (overlay-put ov 'display nil))))

(defun preview-toggle--close-at-marker ()
  "Recompile the region at the saved marker position."
  (when-let* ((pos (marker-position preview-toggle--marker))
              (region-fn preview-toggle-region-at-point-fn)
              (bounds (funcall region-fn pos))
              (compile-fn preview-toggle-compile-region-fn))
    (dolist (ov (overlays-in (car bounds) (cdr bounds)))
      (when (eq (overlay-get ov preview-toggle-type) preview-toggle-type)
        (delete-overlay ov)))
    (funcall compile-fn (car bounds) (cdr bounds))))

;;; * command hooks

(defun preview-toggle--pre-command ()
  "Pre-command hook: record whether cursor is inside a previewable region."
  (when (and preview-toggle-type
             (not (memq this-command preview-toggle-ignored-commands)))
    (setq preview-toggle--was-inside (not (null (preview-toggle--inside-p))))
    (set-marker preview-toggle--marker (point))))

(defun preview-toggle--post-command ()
  "Post-command hook: open/close overlays based on cursor transition."
  (when (and preview-toggle-type
             (not (memq this-command preview-toggle-ignored-commands)))
    (let ((now-inside (preview-toggle--inside-p)))
      (cond
       ((and now-inside (not preview-toggle--was-inside))
        (preview-toggle-open-at-point))
       ((and (not now-inside) preview-toggle--was-inside)
        (preview-toggle--close-at-marker))
       ((and now-inside preview-toggle--was-inside
             (not (eq (preview-toggle--overlay-at (point))
                      (preview-toggle--overlay-at
                       (marker-position preview-toggle--marker)))))
        (preview-toggle--close-at-marker)
        (preview-toggle-open-at-point))))))

;;; * minor mode

(defun preview-toggle-clear-buffer ()
  "Remove all preview overlays in the current buffer."
  (when preview-toggle-type
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (eq (overlay-get ov preview-toggle-type) preview-toggle-type)
        (delete-overlay ov)))))

;;;###autoload
(define-minor-mode preview-toggle-mode
  "Generic minor mode for auto-toggling inline preview overlays."
  :init-value nil
  :lighter ""
  (if preview-toggle-mode
      (progn
        (unless preview-toggle--marker
          (setq preview-toggle--marker (make-marker)))
        (add-hook 'pre-command-hook #'preview-toggle--pre-command nil 'local)
        (add-hook 'post-command-hook #'preview-toggle--post-command nil 'local))
    (remove-hook 'pre-command-hook #'preview-toggle--pre-command 'local)
    (remove-hook 'post-command-hook #'preview-toggle--post-command 'local)
    (preview-toggle-clear-buffer)))

(provide 'preview-toggle)

;;; preview-toggle.el ends here
