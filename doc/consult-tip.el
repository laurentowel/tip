;;; consult-tip.el --- Consult integration for TIP -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.
;; Requires: consult, tip

;;; Commentary:
;; Navigate math/diagram fragments via consult with:
;; - Live preview: jumps to fragment as you browse (consult--location-state)
;; - Rendered math: candidates show SVG overlays in the minibuffer
;; - Content search: narrow by typing fragment source text
;;
;; Usage:
;;   (require 'consult-tip)
;;   M-x consult-tip-fragment

;;; Code:

(require 'consult)
(require 'tip)

(defun consult-tip--get-svg-image (beg end)
  "Get the SVG image spec from a tip overlay in BEG..END, or nil."
  (let ((ov (seq-find (lambda (ov)
                        (and (eq (overlay-get ov 'tip) 'tip)
                             (overlay-get ov 'display)))
                      (overlays-in beg end))))
    (when ov
      (car-safe (overlay-get ov 'display)))))

(defun consult-tip--candidates ()
  "Collect fragments as `consult-location' candidates with rendered math."
  (consult--forbid-minibuffer)
  (let ((ranges (treesit-query-range 'typst "((math) @math)"))
        (candidates nil)
        (idx 0)
        (width (length (number-to-string (line-number-at-pos
                                          (point-max)
                                          consult-line-numbers-widen)))))
    ;; Add diagram ranges
    (when tip-diagram-functions
      (let ((root (treesit-buffer-root-node 'typst)))
        (when root
          (setq ranges
                (append ranges
                        (tip--collect-diagram-ranges
                         root (point-min) (point-max) nil))))))
    ;; Filter nested (keep outermost only)
    (let ((outer nil))
      (dolist (r ranges)
        (unless (cl-some (lambda (o)
                           (and (not (equal o r))
                                (<= (car o) (car r))
                                (>= (cdr o) (cdr r))))
                         ranges)
          (push r outer)))
      (setq ranges (sort (nreverse outer) (lambda (a b) (< (car a) (car b))))))
    ;; Build candidates using consult's location protocol
    (save-excursion
      (dolist (r ranges)
        (let* ((beg (car r))
               (end (cdr r))
               (line (line-number-at-pos beg consult-line-numbers-widen))
               (marker (copy-marker beg))
               (source (buffer-substring-no-properties beg (min (+ beg 60) end)))
               (source-flat (replace-regexp-in-string "[\n\t ]+" " " source))
               (truncated (if (> (- end beg) 60)
                              (concat source-flat "...")
                            source-flat))
               (img (consult-tip--get-svg-image beg end))
               ;; Display: line number + rendered SVG or source text
               (rendered (if img
                             (concat " " (propertize " " 'display img) " ")
                           ""))
               (display (concat rendered truncated))
               ;; Build consult-location candidate
               (cand (consult--location-candidate
                      display marker line idx)))
          (cl-incf idx)
          (push cand candidates))))
    (unless candidates
      (user-error "No fragments found"))
    (nreverse candidates)))

;;;###autoload
(defun consult-tip-fragment ()
  "Select a math/diagram fragment via consult and jump to it.
Shows rendered SVGs in the candidate list.  Live-previews by
jumping to fragments as you browse."
  (interactive)
  (unless (derived-mode-p 'typst-ts-mode)
    (user-error "Not in a typst-ts-mode buffer"))
  (consult--read
   (consult--slow-operation "Collecting fragments..."
     (consult-tip--candidates))
   :prompt "Fragment: "
   :annotate (consult--line-fontify)
   :category 'consult-location
   :sort nil
   :require-match t
   :lookup #'consult--lookup-location
   :history '(:input consult--line-history)
   :add-history (thing-at-point 'symbol)
   :state (consult--location-state (consult-tip--candidates))))

(provide 'consult-tip)

;;; consult-tip.el ends here
