;;; multiline-open-close-katex.el --- Multi-line display-math cursor transitions (KaTeX/markdown) -*- lexical-binding: t; -*-

;; Markdown / KaTeX port of `multiline-open-close.el'.  Uses `$$...$$'
;; spanning three lines so `next-line' / `previous-line' actually has
;; a line of prose to land on outside the fragment.

(tip-test-deftest katex-display-math-closes-on-next-line
  :doc "Exiting a KaTeX display-math fragment via C-n re-renders the image."
  :tags (render open-close katex)
  (tip-test-with-fresh-markdown-buffer
   "before\n$$\n  a + b + c\n$$\nafter\n"
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

(tip-test-deftest katex-display-math-closes-on-previous-line
  :doc "Exiting a KaTeX display-math fragment via C-p re-renders the image."
  :tags (render open-close katex)
  (tip-test-with-fresh-markdown-buffer
   "before\n$$\n  a + b + c\n$$\nafter\n"
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
