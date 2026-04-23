;;; tip-errors.el --- Error presentation, navigation, eldoc, Flymake -*- lexical-binding: t; -*-

;;; Commentary:

;; Backend-agnostic error UX.  Consumes the `tip-error-severity',
;; `tip-error-message', `tip-error-hint', `tip-error-line',
;; `tip-error-detail', `tip-frag-beg', `tip-frag-end' overlay
;; properties populated by `tip--apply-fragment-results' in
;; `tip-render.el'.
;;
;; Surfaces errors through four independent UIs (all coexist):
;;
;;   1. Inline overlay: `tip-error-face' / `tip-warning-face'.
;;      Red / amber wavy underline on the hint region, ⚠ / ⚑ glyph
;;      prefix.  The rendering pipeline sets this directly; this
;;      file just owns the faces.
;;
;;   2. Navigation: `tip-next-error' / `tip-prev-error' (autoload).
;;      Zero deps, works regardless of Flymake.
;;
;;   3. Eldoc: `tip--eldoc-error', added to
;;      `eldoc-documentation-functions' locally when `tip-mode' is
;;      on.  Composes with other eldoc providers.
;;
;;   4. Flymake: `tip-flymake-mode' (minor mode, on by default from
;;      `tip-mode' when Flymake is available).  Full Flymake
;;      integration — gutter bitmaps, goto-next-error, diagnostics
;;      list, eldoc bridge.
;;
;; This file depends on nothing tip-specific except the overlay
;; property conventions.  `tip-mode' wires (3) and (4) on/off; (2)
;; is always callable; (1) is painted by the render pipeline.

;;; Code:

(require 'seq)
(require 'subr-x)

(declare-function flymake-make-diagnostic "flymake" (buffer beg end type text))
(declare-function flymake-mode "flymake" (&optional arg))
(declare-function flymake-start "flymake" (&optional force no-wait))

;;; * faces

(defface tip-error-face
  '((((background light))
     :underline (:style wave :color "#d63939"))
    (((background dark))
     :underline (:style wave :color "#f87171")))
  "Face for fragments that failed to compile.
Red wavy underline, matching Flymake's error style.  Source text
stays visible so the user can fix in-place."
  :group 'tip)

(defface tip-warning-face
  '((((background light)) :underline (:style wave :color "#d97706"))
    (((background dark))  :underline (:style wave :color "#f59e0b")))
  "Face for fragments that compiled with a warning.
Wavy underline in amber.  Overrides `tip-error-face' when the
fragment's `error_detail.severity' is `warning'."
  :group 'tip)

;;; * overlay enumeration

(defun tip--error-overlays (&optional buffer)
  "Return tip error overlays in BUFFER (default current), sorted by start.
Picks up both error- and warning-severity overlays."
  (with-current-buffer (or buffer (current-buffer))
    (sort (seq-filter
           (lambda (o)
             (and (eq (overlay-get o 'tip) 'tip)
                  (overlay-get o 'tip-error-severity)))
           (overlays-in (point-min) (point-max)))
          (lambda (a b) (< (overlay-start a) (overlay-start b))))))

(defun tip--error-overlay-at (pos)
  "Return the tip error overlay covering POS, or nil."
  (seq-find
   (lambda (o)
     (and (eq (overlay-get o 'tip) 'tip)
          (overlay-get o 'tip-error-severity)
          (<= (overlay-start o) pos)
          (<= pos (overlay-end o))))
   (overlays-in (max (point-min) (1- pos))
                (min (point-max) (1+ pos)))))

(defun tip--error-echo (ov &optional wrapped)
  "Echo OV's error in the minibuffer.  WRAPPED tags a wrap-around jump."
  (message "TIP [%s]: %s%s"
           (overlay-get ov 'tip-error-severity)
           (overlay-get ov 'tip-error-message)
           (if wrapped " (wrapped)" "")))

;;; * navigation

;;;###autoload
(defun tip-next-error (&optional no-wrap)
  "Jump to the next tip error overlay after point.
With a prefix arg (NO-WRAP non-nil), don't wrap around."
  (interactive "P")
  (let* ((ovs (tip--error-overlays))
         (next (seq-find (lambda (o) (> (overlay-start o) (point))) ovs)))
    (cond
     (next
      (goto-char (overlay-start next))
      (tip--error-echo next))
     ((and (not no-wrap) ovs)
      (goto-char (overlay-start (car ovs)))
      (tip--error-echo (car ovs) t))
     (t (user-error "No tip errors in buffer")))))

;;;###autoload
(defun tip-prev-error (&optional no-wrap)
  "Jump to the previous tip error overlay before point.
With a prefix arg (NO-WRAP non-nil), don't wrap around."
  (interactive "P")
  (let* ((ovs (nreverse (tip--error-overlays)))
         (prev (seq-find (lambda (o) (< (overlay-start o) (point))) ovs)))
    (cond
     (prev
      (goto-char (overlay-start prev))
      (tip--error-echo prev))
     ((and (not no-wrap) ovs)
      (goto-char (overlay-start (car ovs)))
      (tip--error-echo (car ovs) t))
     (t (user-error "No tip errors in buffer")))))

;;; * eldoc

(defun tip--eldoc-error (callback &rest _ignored)
  "Eldoc documentation function: report a tip error at point if present.
Added to `eldoc-documentation-functions' locally when `tip-mode'
is on.  Returns nil when point isn't on an error overlay so
other eldoc providers (flymake, etc.) can still contribute."
  (when-let* ((ov (tip--error-overlay-at (point)))
              (msg (overlay-get ov 'tip-error-message))
              (sev (overlay-get ov 'tip-error-severity)))
    (funcall callback
             (propertize (format "TIP [%s]: %s" sev msg)
                         'face (overlay-get ov 'face))
             :thing 'tip-error
             :face (overlay-get ov 'face))))

;;; * Flymake backend

(defun tip--flymake-backend (report-fn &rest _args)
  "Flymake diagnostic backend that surfaces tip compile errors.
Walks the tip error overlays in the buffer, converts each to a
`flymake-diagnostic', reports them in one batch."
  (funcall
   report-fn
   (mapcar
    (lambda (ov)
      (let* ((beg (or (overlay-get ov 'tip-frag-beg) (overlay-start ov)))
             (end (or (overlay-get ov 'tip-frag-end) (overlay-end ov)))
             (msg (or (overlay-get ov 'tip-error-message) "tip compile error"))
             (sev (overlay-get ov 'tip-error-severity))
             (type (if (eq sev 'warning) :warning :error))
             (hint (overlay-get ov 'tip-error-hint))
             (text (if hint (format "%s [%s]" msg hint) msg)))
        (flymake-make-diagnostic (current-buffer) beg end type text)))
    (tip--error-overlays))))

(defun tip--flymake-refresh ()
  "Ask Flymake to re-run backends in this buffer.
Called by the render pipeline after a compile response updates
error overlays so Flymake's diagnostic list stays in sync."
  (when (and (bound-and-true-p tip-flymake-mode)
             (bound-and-true-p flymake-mode))
    (ignore-errors (flymake-start))))

;;;###autoload
(define-minor-mode tip-flymake-mode
  "Publish tip compile errors as Flymake diagnostics.
When enabled, errors from `tip-server-*' back-ends become standard
Flymake diagnostics: gutter bitmaps, `M-x flymake-goto-next-error',
`M-x flymake-show-buffer-diagnostics', eldoc integration.

Enabled by default when `tip-mode' turns on.  Users who prefer not
to load Flymake can opt out:

  (add-hook \\='tip-mode-hook (lambda () (tip-flymake-mode -1)))

The standalone `tip-next-error' / `tip-prev-error' commands keep
working regardless."
  :init-value nil
  :lighter ""
  (if tip-flymake-mode
      (progn
        (require 'flymake)
        (add-hook 'flymake-diagnostic-functions #'tip--flymake-backend nil t)
        (unless (bound-and-true-p flymake-mode)
          (flymake-mode 1))
        (tip--flymake-refresh))
    (remove-hook 'flymake-diagnostic-functions #'tip--flymake-backend t)
    (tip--flymake-refresh)))

(provide 'tip-errors)

;;; tip-errors.el ends here
