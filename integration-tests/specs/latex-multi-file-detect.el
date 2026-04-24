;;; latex-multi-file-detect.el --- Fragments collected from \input / \include buffers  -*- lexical-binding: t; -*-

;; Multi-file LaTeX (\input / \include / \subimport) now renders:
;; the server walks the project graph and assembles the preamble.
;; Client-side fragment detection no longer refuses these buffers.
;;
;; Ported from legacy `latex-include-refusal.el' — test polarity
;; flipped to match the new behavior.

(tip-test-deftest latex-buffer-with-input-still-collects-fragments
  :doc "A .tex buffer containing \\input now emits fragments."
  :tags (latex multi-file)
  (tip-test-with-fresh-latex-buffer
   (concat "\\documentclass{article}\n"
           "\\usepackage{amsmath}\n"
           "\\input{other}\n"
           "\\begin{document}\n"
           "$a + b$\n"
           "\\end{document}\n")
    (should (= 1 (length (tip-latex-collect-fragments (point-min) (point-max)))))))

(tip-test-deftest latex-buffer-with-include-still-collects-fragments
  :doc "\\include in a .tex file no longer short-circuits detection."
  :tags (latex multi-file)
  (tip-test-with-fresh-latex-buffer
   (concat "\\documentclass{article}\n"
           "\\include{chapter1}\n"
           "\\begin{document}\n"
           "$x^2$\n"
           "\\end{document}\n")
    (should (= 1 (length (tip-latex-collect-fragments (point-min) (point-max)))))))

(tip-test-deftest latex-clean-file-still-emits-fragments
  :doc "Sanity: without \\input/\\include, fragment detection is unchanged."
  :tags (latex)
  (tip-test-with-fresh-latex-buffer
   (concat "\\documentclass{article}\n"
           "\\begin{document}\n"
           "$a + b$ and $x^2$\n"
           "\\end{document}\n")
    (should (= 2 (length (tip-latex-collect-fragments (point-min) (point-max)))))))
