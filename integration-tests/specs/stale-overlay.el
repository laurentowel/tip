;;; stale-overlay.el --- Display-math D-indicator cleanup on delete  -*- lexical-binding: t; -*-

;; Regression for bug 2 of legacy 03-error-and-stale-overlay.el:
;; deleting a display-math fragment must also remove its D-indicator
;; overlay (the `before-string' "𝐃" glyph).  Before the fix, the
;; indicator lingered where the math used to be.

(defun tip-test--d-indicator-overlays ()
  "Overlays at POS that carry a `before-string' (the D-indicator)."
  (seq-filter (lambda (ov)
                (and (eq (overlay-get ov 'tip) 'tip)
                     (overlay-get ov 'before-string)))
              (overlays-in (point-min) (point-max))))

(tip-test-deftest display-math-D-indicator-cleared-on-delete
  :doc "Deleting a display-math fragment removes its D-indicator."
  :tags (render stale)
  (tip-test-with-fresh-typst-buffer
   "before text\n$ integral f dif x $\nafter text\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (should (> (length (tip-test--d-indicator-overlays)) 0))
    ;; Remove the display fragment.
    (goto-char (point-min))
    (search-forward "$ integral f dif x $")
    (let ((end (point)) (beg (match-beginning 0)))
      (delete-region beg end))
    ;; Give cleanup hooks a moment.
    (tip-test-simulate-command 'self-insert-command (point))
    (tip-test-wait-for-pending 3)
    (sit-for 0.2)
    (should (= 0 (length (tip-test--d-indicator-overlays))))))
