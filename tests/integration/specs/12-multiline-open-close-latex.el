;;; multiline-open-close-latex.el --- Multi-line display-math cursor transitions (LaTeX) -*- lexical-binding: t; -*-

;; LaTeX port of `multiline-open-close.el'.  The display math uses
;; `\begin{equation} ... \end{equation}' instead of `$...$' so it
;; genuinely spans three lines.  Tests both exit directions.

(tip-test-deftest latex-display-math-closes-on-next-line
  :doc "Exiting a LaTeX display-math fragment via C-n re-renders the image."
  :tags (render open-close latex)
  (tip-test-with-fresh-latex-buffer
   "before\n\\begin{equation}\n  a + b + c\n\\end{equation}\nafter\n"
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

(tip-test-deftest latex-display-math-closes-on-previous-line
  :doc "Exiting a LaTeX display-math fragment via C-p re-renders the image."
  :tags (render open-close latex)
  (tip-test-with-fresh-latex-buffer
   "before\n\\begin{equation}\n  a + b + c\n\\end{equation}\nafter\n"
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
