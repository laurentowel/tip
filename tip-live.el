;;; tip-live.el --- Live preview (childframe) + echo-area error feedback -*- lexical-binding: t; -*-

;;; Commentary:

;; Two small subsystems that sit on top of the compile pipeline:
;;
;; - tip-echo--compile-partial: while `tip-echo-errors' is on and the
;;   cursor is inside a fragment, recompile on idle and mirror any
;;   compilation error to the echo area.  Does not show successful
;;   renders (the overlay pipeline handles those).
;;
;; - tip-live-mode: compile the fragment at point and show the SVG in
;;   a floating childframe (see tip-childframe.el).  Opt-in minor mode.
;;
;; Both subsystems call into the backend via `tip--send-request' and
;; use `tip--get-bounds-of-math-at-point' / `tip--build-preamble' from
;; the Typst backend today.  When the tip-backend struct lands (task
;; #7) those calls will route through the active backend.

;;; Code:

(require 'tip-childframe)
(require 'tip-server-proc)
(require 'tip-backend)

;; Forward-declares from tip / tip-typst.
(defvar tip-echo-errors)
(defvar tip-mode)
(declare-function tip--color-to-hex "tip" (color))
(declare-function tip-edit-indirect--live-preview "tip-edit-indirect" ())
(defvar tip-edit-indirect-mode)

;;; * echo-area error feedback

(defvar-local tip-echo--content-cache ""
  "Cache of the last echo-error-checked fragment content.")

(defvar-local tip-echo--timer nil
  "Idle timer for echo-area error checking.")

(defun tip-echo--handle-result (result)
  "Show compilation errors in the echo area, ignore success."
  (let* ((err (alist-get 'error result))
         (frags (alist-get 'fragments result))
         (frag (and frags (> (length frags) 0) (aref frags 0)))
         (frag-err (and frag (alist-get 'error frag))))
    (cond
     (err (message "TIP: %s" err))
     (frag-err (message "TIP: %s" frag-err)))))

(defun tip-echo--compile-partial ()
  "Compile fragment at point and echo errors."
  (when (and tip-echo-errors
             tip-mode
             (eq major-mode 'typst-ts-mode)
             (eq (current-buffer) (window-buffer))
             (not (bound-and-true-p tip-live-mode)))
    (if-let* ((bound (tip-bounds-at-point (point)))
              (content (buffer-substring-no-properties (car bound) (cdr bound))))
        (unless (string-equal tip-echo--content-cache content)
          (setq tip-echo--content-cache content)
          (let ((fg (tip--color-to-hex (face-attribute 'default :foreground)))
                (byte-start (1- (position-bytes (car bound))))
                (byte-end (1- (position-bytes (cdr bound)))))
            (tip--sync-buffer)
            (tip--send-request
             "compile_fragments"
             `(("uri" . ,(tip--current-uri))
               ("fragments" . ,(vector `(("start" . ,byte-start)
                                         ("end" . ,byte-end))))
               ("color" . ,fg)
               ("preamble" . ,(tip-build-preamble)))
             #'tip-echo--handle-result)))
      (setq tip-echo--content-cache ""))))

;;; * live childframe preview

(defvar-local tip-live--content-cache ""
  "Cache of the last live-previewed fragment content.")

(defvar-local tip-live--timer nil
  "Idle timer for live preview.")

(defun tip-live--handle-result (result)
  "Handle compilation RESULT — show SVG or error in childframe.
Errors are shown both in the childframe and echoed to the message area."
  (let* ((err (alist-get 'error result))
         (frags (alist-get 'fragments result))
         (frag (and frags (> (length frags) 0) (aref frags 0)))
         (frag-err (and frag (alist-get 'error frag)))
         (svg (and frag (alist-get 'svg frag)))
         (h (and frag (alist-get 'height_pt frag))))
    (cond
     (err
      (tip-childframe-show-text err 'error)
      (message "TIP: %s" err))
     (frag-err
      (tip-childframe-show-text frag-err 'error)
      (message "TIP: %s" frag-err))
     ((and svg (> (length svg) 0) h (> h 0))
      (tip-childframe-show svg))
     (t (tip-childframe-hide)))))

(defun tip-live--compile-partial ()
  "Compile the math fragment at point for live preview.
Works in both normal typst-ts-mode and tip-edit-indirect buffers."
  (cond
   ;; In tip-edit-indirect buffer: delegate to the edit preview.
   ((bound-and-true-p tip-edit-indirect-mode)
    (tip-edit-indirect--live-preview))
   ;; In typst-ts-mode: compile fragment at point.
   ((eq major-mode 'typst-ts-mode)
    (if-let* ((bound (tip-bounds-at-point (point)))
              (content (buffer-substring-no-properties (car bound) (cdr bound))))
        (unless (string-equal tip-live--content-cache content)
          (setq tip-live--content-cache content)
          (let ((fg (tip--color-to-hex (face-attribute 'default :foreground)))
                (byte-start (1- (position-bytes (car bound))))
                (byte-end (1- (position-bytes (cdr bound)))))
            (tip--sync-buffer)
            (tip--send-request
             "compile_fragments"
             `(("uri" . ,(tip--current-uri))
               ("fragments" . ,(vector `(("start" . ,byte-start)
                                         ("end" . ,byte-end))))
               ("color" . ,fg)
               ("preamble" . ,(tip-build-preamble)))
             (lambda (result)
               (tip-live--handle-result result)))))
      (tip-childframe-hide)
      (setq tip-live--content-cache "")))))

(defun tip-live--on-buffer-change (&rest _)
  "Hide childframe when switching away from a tip-mode buffer."
  (unless (and (eq major-mode 'typst-ts-mode)
               (bound-and-true-p tip-mode)
               (bound-and-true-p tip-live-mode))
    (tip-childframe-hide)))

(defun tip-live--on-buffer-kill ()
  "Hide childframe when a tip-mode buffer is killed."
  (when (bound-and-true-p tip-live-mode)
    (tip-childframe-hide)))

;;;###autoload
(define-minor-mode tip-live-mode
  "Live preview of the math fragment at point in a childframe.
Compiles the fragment under cursor on idle and shows the result in a
floating childframe.  Opt-in — enable with M-x tip-live-mode."
  :init-value nil
  :lighter " TIP-live"
  (if tip-live-mode
      (progn
        (setq tip-live--timer
              (run-with-idle-timer 0.3 t #'tip-live--compile-partial))
        (add-hook 'window-buffer-change-functions #'tip-live--on-buffer-change)
        (add-hook 'kill-buffer-hook #'tip-live--on-buffer-kill nil t))
    (when tip-live--timer
      (cancel-timer tip-live--timer)
      (setq tip-live--timer nil))
    (remove-hook 'window-buffer-change-functions #'tip-live--on-buffer-change)
    (remove-hook 'kill-buffer-hook #'tip-live--on-buffer-kill t)
    (tip-childframe-hide)
    (setq tip-live--content-cache "")))

(provide 'tip-live)

;;; tip-live.el ends here
