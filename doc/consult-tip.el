;;; consult-tip.el --- Consult + Marginalia integration for TIP -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.
;; Requires: consult, tip
;; Optional: marginalia (for source text annotation column)

;;; Commentary:
;; Navigate math/diagram fragments via consult with:
;; - Rendered math as candidates (compact SVG, cropped to line height)
;; - Source text as marginalia annotation (right column)
;; - Live preview: jumps to fragment as you browse
;; - Content search: narrow by typing fragment source text
;;
;; Usage:
;;   (require 'consult-tip)
;;   M-x consult-tip-fragment
;;
;; For marginalia annotations:
;;   (with-eval-after-load 'marginalia
;;     (add-to-list 'marginalia-annotators
;;                  '(tip-fragment marginalia-annotate-tip-fragment)))

;;; Code:

(require 'consult)
(require 'tip)

(defcustom consult-tip-image-height 1.2
  "Height of rendered SVG in candidates, in units of frame-char-height.
Smaller values make candidates more compact."
  :type 'float
  :group 'tip)

(defcustom consult-tip-image-max-width 300
  "Maximum pixel width of rendered SVG in candidates.
Wider images (display math, diagrams) are scaled down to fit."
  :type 'integer
  :group 'tip)

(defun consult-tip--get-svg-image (beg end)
  "Get a compact SVG image spec from a tip overlay in BEG..END, or nil."
  (let ((ov (seq-find (lambda (ov)
                        (and (eq (overlay-get ov 'tip) 'tip)
                             (overlay-get ov 'display)))
                      (overlays-in beg end))))
    (when ov
      (let ((img (car-safe (overlay-get ov 'display))))
        ;; Compact copy: constrain height to line, constrain width for display math
        (when (and img (eq (car img) 'image))
          (list 'image
                :type 'svg
                :data (plist-get (cdr img) :data)
                :height (round (* consult-tip-image-height (frame-char-height)))
                :max-width consult-tip-image-max-width
                :ascent 'center))))))

(defun consult-tip--candidates ()
  "Collect fragments as `consult-location' candidates."
  (consult--forbid-minibuffer)
  (let ((ranges (treesit-query-range 'typst "((math) @math)"))
        (candidates nil)
        (idx 0))
    ;; Add diagram ranges
    (when tip-diagram-functions
      (let ((root (treesit-buffer-root-node 'typst)))
        (when root
          (setq ranges
                (append ranges
                        (tip--collect-diagram-ranges
                         root (point-min) (point-max) nil))))))
    ;; Filter nested
    (let ((outer nil))
      (dolist (r ranges)
        (unless (cl-some (lambda (o)
                           (and (not (equal o r))
                                (<= (car o) (car r))
                                (>= (cdr o) (cdr r))))
                         ranges)
          (push r outer)))
      (setq ranges (sort (nreverse outer) (lambda (a b) (< (car a) (car b))))))
    ;; Build candidates
    (save-excursion
      (dolist (r ranges)
        (let* ((beg (car r))
               (end (cdr r))
               (line (line-number-at-pos beg consult-line-numbers-widen))
               (marker (copy-marker beg))
               (img (consult-tip--get-svg-image beg end))
               ;; Main display: rendered SVG (compact) or truncated source
               (source (replace-regexp-in-string
                        "[\n\t ]+" " "
                        (buffer-substring-no-properties beg (min (+ beg 50) end))))
               ;; Candidate: rendered SVG + invisible source for filtering
               (display (concat
                         (if img
                             (propertize " " 'display img)
                           "")
                         (propertize source 'invisible (when img t))))
               (cand (consult--location-candidate
                      display marker line idx)))
          ;; Stash source for marginalia and filtering
          (put-text-property 0 1 'consult-tip--source
                             (truncate-string-to-width source 80) cand)
          (cl-incf idx)
          (push cand candidates))))
    (unless candidates
      (user-error "No fragments found"))
    (nreverse candidates)))

;;;###autoload
(defun consult-tip-fragment ()
  "Select a math/diagram fragment via consult and jump to it.
Shows rendered SVGs as candidates.  With marginalia, source text
appears as annotation in a right column."
  (interactive)
  (unless (derived-mode-p 'typst-ts-mode)
    (user-error "Not in a typst-ts-mode buffer"))
  (let ((candidates (consult--slow-operation "Collecting fragments..."
                      (consult-tip--candidates))))
    (consult--read
     candidates
     :prompt "Fragment: "
     :annotate (consult--line-fontify)
     :category 'tip-fragment
     :sort nil
     :require-match t
     :lookup #'consult--lookup-location
     :history '(:input consult--line-history)
     :add-history (thing-at-point 'symbol)
     :state (consult--location-state candidates))))

;;; * marginalia annotator

(defun marginalia-annotate-tip-fragment (cand)
  "Annotate tip fragment CAND with its source text."
  (when-let* ((source (get-text-property 0 'consult-tip--source cand)))
    (marginalia--fields
     (source :truncate 0.6 :face 'marginalia-documentation))))

(provide 'consult-tip)

;;; consult-tip.el ends here
