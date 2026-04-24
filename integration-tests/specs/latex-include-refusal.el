;;; latex-include-refusal.el --- tip-latex v1 refuses \input / \include  -*- lexical-binding: t; -*-

;; LaTeX multi-file support is v2 work; v1 explicitly refuses files
;; containing `\input', `\include', or `\subimport' and collects zero
;; fragments from them.  Regression: a document with a lone `\input'
;; line must yield an empty fragment list.

(tip-test-deftest latex-buffer-with-input-yields-no-fragments
  :doc "A .tex buffer containing \\input produces zero tip fragments."
  :tags (latex refusal)
  (tip-test-with-fresh-latex-buffer
   (concat "\\documentclass{article}\n"
           "\\usepackage{amsmath}\n"
           "\\input{other}\n"
           "\\begin{document}\n"
           "$a + b$\n"
           "\\end{document}\n")
    (should (null (tip-latex-collect-fragments (point-min) (point-max))))))

(tip-test-deftest latex-buffer-with-include-yields-no-fragments
  :doc "\\include in a .tex file is likewise refused."
  :tags (latex refusal)
  (tip-test-with-fresh-latex-buffer
   (concat "\\documentclass{article}\n"
           "\\include{chapter1}\n"
           "\\begin{document}\n"
           "$x^2$\n"
           "\\end{document}\n")
    (should (null (tip-latex-collect-fragments (point-min) (point-max))))))

(tip-test-deftest latex-clean-file-does-emit-fragments
  :doc "Sanity: without \\input/\\include, fragments ARE collected."
  :tags (latex)
  (tip-test-with-fresh-latex-buffer
   (concat "\\documentclass{article}\n"
           "\\begin{document}\n"
           "$a + b$ and $x^2$\n"
           "\\end{document}\n")
    (should (= 2 (length (tip-latex-collect-fragments (point-min) (point-max)))))))
