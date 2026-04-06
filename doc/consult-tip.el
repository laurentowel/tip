;;; consult-tip.el --- Consult integration for TIP -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.
;; Requires: consult, tip

;;; Commentary:
;; Navigate math/diagram fragments via consult's completing-read interface.
;; Each candidate shows the fragment source text. Selecting jumps to it.
;;
;; Usage:
;;   (require 'consult-tip)
;;   M-x consult-tip-fragment

;;; Code:

(require 'consult)
(require 'tip)

(defun consult-tip--candidates ()
  "Collect math and diagram fragments as consult candidates.
Each candidate is a string (fragment source text) with `consult--candidate'
property holding (BEG . END)."
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
    ;; Build candidates
    (dolist (r ranges)
      (let* ((beg (car r))
             (end (cdr r))
             (text (buffer-substring-no-properties beg (min (+ beg 80) end)))
             (line (line-number-at-pos beg))
             (display (format "%4d: %s%s"
                              line
                              (replace-regexp-in-string "\n" " " text)
                              (if (> (- end beg) 80) "..." ""))))
        (push (propertize display 'consult--candidate (cons beg end))
              candidates)))
    (nreverse candidates)))

;;;###autoload
(defun consult-tip-fragment ()
  "Select a math/diagram fragment via consult and jump to it."
  (interactive)
  (unless (derived-mode-p 'typst-ts-mode)
    (user-error "Not in a typst-ts-mode buffer"))
  (let* ((candidates (consult-tip--candidates))
         (selected (consult--read
                    candidates
                    :prompt "Fragment: "
                    :sort nil
                    :require-match t
                    :category 'tip-fragment
                    :state (consult--jump-state)
                    :lookup (lambda (selected cands &rest _)
                              (when-let* ((cand (car (member selected cands)))
                                          (pos (get-text-property 0 'consult--candidate cand)))
                                pos)))))
    (when selected
      (goto-char (car selected)))))

(provide 'consult-tip)

;;; consult-tip.el ends here
