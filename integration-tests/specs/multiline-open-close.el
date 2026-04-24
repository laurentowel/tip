;;; multiline-open-close.el --- Open/close cycle for multi-line display math  -*- lexical-binding: t; -*-

;; Ported from legacy 07-multiline-open-close.el (multi-line subset).
;; The existing `open-close.el' covers inline `$a+b$' with forward-
;; char — this one exercises a multi-line `$ ... $' display fragment
;; exited via `next-line' / `previous-line', which is the actual user
;; motion that used to leak overlays open.

(tip-test-deftest display-math-closes-on-next-line
  :doc "Exiting a multi-line display fragment via C-n re-renders the image."
  :tags (render open-close)
  (tip-test-with-fresh-typst-buffer
   "before\n$\n  a + b + c\n$\nafter\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let* ((ranges (tip-test-fragment-ranges))
           (frag   (car ranges))
           (inside (/ (+ (car frag) (cdr frag)) 2))
           (below  (save-excursion (goto-char (cdr frag))
                                   (forward-line 1) (point))))
      (tip-test-simulate-command 'forward-char inside)
      (should-not (tip-test-overlay-showing-image-p inside))
      (tip-test-simulate-command 'next-line below)
      (tip-test-wait-for-pending 5)
      (should (tip-test-overlay-showing-image-p inside)))))

(tip-test-deftest display-math-closes-on-previous-line
  :doc "Exiting a multi-line display fragment via C-p re-renders the image."
  :tags (render open-close)
  (tip-test-with-fresh-typst-buffer
   "before\n$\n  a + b + c\n$\nafter\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let* ((ranges (tip-test-fragment-ranges))
           (frag   (car ranges))
           (inside (/ (+ (car frag) (cdr frag)) 2))
           (above  (save-excursion (goto-char (car frag))
                                   (forward-line -1) (point))))
      (tip-test-simulate-command 'forward-char inside)
      (should-not (tip-test-overlay-showing-image-p inside))
      (tip-test-simulate-command 'previous-line above)
      (tip-test-wait-for-pending 5)
      (should (tip-test-overlay-showing-image-p inside)))))
