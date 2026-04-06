;;; consult-tip.el --- Consult integration for TIP -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.
;; Requires: consult, tip

;;; Commentary:
;; Navigate math/diagram fragments via consult with:
;; - Live preview: jumps to fragment as you browse candidates
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
  "Collect fragments as candidates with rendered math in display."
  (let ((ranges (treesit-query-range 'typst "((math) @math)"))
        (candidates nil))
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
    (dolist (r ranges)
      (let* ((beg (car r))
             (end (cdr r))
             (source (buffer-substring-no-properties beg (min (+ beg 60) end)))
             (source-flat (replace-regexp-in-string "[\n\t ]+" " " source))
             (truncated (if (> (- end beg) 60)
                            (concat source-flat "...")
                          source-flat))
             (line (line-number-at-pos beg))
             (img (consult-tip--get-svg-image beg end))
             ;; Build display: line number + rendered math (or source text)
             (rendered (if img
                          (propertize " " 'display img)
                        ""))
             (display (concat (propertize (format "%4d " line)
                                         'face 'consult-line-number)
                              rendered
                              (unless img truncated))))
        (push (propertize (or display truncated)
                          'consult-tip--pos beg
                          ;; Hidden searchable text for filtering
                          'consult-tip--source truncated)
              candidates)))
    (nreverse candidates)))

(defun consult-tip--state ()
  "State function for live preview: jump to fragment on selection."
  (let ((saved-pos (point))
        (saved-window-start (window-start)))
    (lambda (action cand)
      (pcase action
        ('preview
         (when cand
           (let ((pos (get-text-property 0 'consult-tip--pos cand)))
             (when pos
               (goto-char pos)
               (recenter)))))
        ('return
         (when cand
           (let ((pos (get-text-property 0 'consult-tip--pos cand)))
             (when pos (goto-char pos)))))
        ('exit
         ;; Restore on abort
         (unless cand
           (goto-char saved-pos)
           (set-window-start nil saved-window-start)))))))

(defun consult-tip--match (input candidates)
  "Filter CANDIDATES by INPUT against their source text."
  (let ((pattern (regexp-quote input)))
    (seq-filter (lambda (c)
                  (let ((source (get-text-property 0 'consult-tip--source c)))
                    (or (null source)
                        (string-match-p pattern source))))
                candidates)))

;;;###autoload
(defun consult-tip-fragment ()
  "Select a math/diagram fragment via consult and jump to it.
Shows rendered SVGs in the candidate list.  Live-previews by
jumping to fragments as you browse."
  (interactive)
  (unless (derived-mode-p 'typst-ts-mode)
    (user-error "Not in a typst-ts-mode buffer"))
  (let ((candidates (consult-tip--candidates)))
    (unless candidates
      (user-error "No fragments found"))
    (consult--read
     candidates
     :prompt "Fragment: "
     :sort nil
     :require-match t
     :category 'tip-fragment
     :state (consult-tip--state)
     :lookup (lambda (selected cands &rest _)
               (when-let* ((match (car (member selected cands))))
                 match)))))

(provide 'consult-tip)

;;; consult-tip.el ends here
