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
(require 'marginalia)
(require 'tip)

(defcustom consult-tip-image-height 1.2
  "Height of rendered SVG in candidates, in units of frame-char-height.
Smaller values make candidates more compact."
  :type 'float
  :group 'tip)

(defcustom consult-tip-image-max-width nil
  "Maximum pixel width of rendered SVG in candidates.
nil means ~40 characters worth of pixels (half a typical minibuffer)."
  :type '(choice (const :tag "Auto (~40 chars)" nil)
                 (integer :tag "Pixels"))
  :group 'tip)

(defun consult-tip--max-width ()
  "Compute max pixel width for SVG candidates."
  (or consult-tip-image-max-width
      (* 40 (frame-char-width))))

(defun consult-tip--crop-svg (data ink-w ink-h)
  "Crop SVG DATA to center on ink bounds of INK-W x INK-H.
Rewrites viewBox to show only the content region."
  (let* ((svg-w (and (string-match "width=\"\\([0-9.]+\\)" data)
                     (string-to-number (match-string 1 data))))
         (svg-h (and (string-match "height=\"\\([0-9.]+\\)" data)
                     (string-to-number (match-string 1 data)))))
    (if (and svg-w svg-h (> svg-w (* ink-w 1.5)))
        ;; Content is centered in the page — compute viewBox crop
        (let* ((pad 1.0)
               (cx (/ (- svg-w ink-w) 2.0))  ;; centered content x-start
               (vb-x (max 0 (- cx pad)))
               (vb-w (+ ink-w (* pad 2)))
               (result data))
          ;; Rewrite viewBox
          (when (string-match "viewBox=\"[^\"]*\"" result)
            (setq result (replace-match
                          (format "viewBox=\"%s 0 %s %s\"" vb-x vb-w svg-h)
                          t t result)))
          ;; Rewrite width
          (when (string-match "width=\"[^\"]*\"" result)
            (setq result (replace-match
                          (format "width=\"%spt\"" vb-w)
                          t t result)))
          result)
      data)))

(defun consult-tip--get-svg-image (beg end)
  "Get a compact SVG image spec from a tip overlay in BEG..END, or nil.
Crops display math to ink bounding box for compact minibuffer display."
  (let ((ov (seq-find (lambda (ov)
                        (and (eq (overlay-get ov 'tip) 'tip)
                             (overlay-get ov 'display)))
                      (overlays-in beg end))))
    (when ov
      (let ((img (car-safe (overlay-get ov 'display)))
            (ink-w (or (overlay-get ov 'tip-width-pt) 0))
            (ink-h (or (overlay-get ov 'tip-height-pt) 0)))
        (when (and img (eq (car img) 'image))
          (let* ((data (plist-get (cdr img) :data))
                 (line-h (round (* consult-tip-image-height (frame-char-height))))
                 ;; Crop display math SVG to ink bounds
                 (cropped (if (> ink-w 0)
                              (consult-tip--crop-svg data ink-w ink-h)
                            data)))
            ;; After cropping, just cap width — height follows naturally
            (list 'image :type 'svg :data cropped
                  :max-width (consult-tip--max-width)
                  :ascent 'center)))))))

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
               ;; Candidate: source text (filterable, highlightable by vertico)
               (cand (consult--location-candidate
                      source marker line idx)))
          ;; Stash SVG image for annotation
          (when img
            (put-text-property 0 1 'consult-tip--image img cand))
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
    (setq consult-tip--last-candidates candidates)
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

(defun consult-tip--annotate (cand)
  "Annotate tip fragment CAND with its rendered SVG."
  (when-let* ((found (car (member cand consult-tip--last-candidates)))
              (img (get-text-property 0 'consult-tip--image found)))
    (concat " " (propertize " " 'display img))))

(defvar consult-tip--last-candidates nil
  "Candidates from the last `consult-tip-fragment' call.
Needed because consult strips text properties from the selected string.")

;; Register with marginalia
(add-to-list 'marginalia-annotators
             '(tip-fragment consult-tip--annotate builtin none))

(provide 'consult-tip)

;;; consult-tip.el ends here
