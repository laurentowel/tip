;;; latex-preamble-newcommand.el --- Preamble \newcommand reaches fragments  -*- lexical-binding: t; -*-

;; End-to-end verification that a \newcommand declared in the preamble
;; is actually available when compiling a math fragment.  This is what
;; the "Undefined control sequence" bug was hiding — the client
;; extracted the preamble fine but the server's strip_begin_document
;; truncated it at a \begin{document} inside a comment.

(tip-test-deftest preamble-newcommand-resolves-in-fragment
  :doc "\\newcommand in preamble is applied to fragments that use it."
  (tip-test-with-fresh-latex-buffer
   (concat
    "\\documentclass{article}\n"
    "\\usepackage{amsmath}\n"
    "\\newcommand{\\mycmd}[1]{\\mathbf{#1}}\n"
    "\\begin{document}\n"
    "Inline: $\\mycmd{x}$\n"
    "\\end{document}\n")
    (tip-render-all)
    (tip-test-wait-for-pending 20)
    ;; Find the single fragment via tip's own range scan.
    (let* ((frags (tip-latex-collect-fragments (point-min) (point-max)))
           (pos (and frags
                     (byte-to-position
                      (1+ (alist-get "start" (car frags) nil nil #'equal))))))
      (should pos)
      ;; Look for a TIP overlay with an actual rendered image (no error).
      (should (tip-test-overlay-showing-image-p (1+ pos))))))

(tip-test-deftest preamble-comment-with-begin-document-does-not-truncate
  :doc "A preamble comment mentioning `\\begin{document}' must not eat following \\newcommand declarations."
  (tip-test-with-fresh-latex-buffer
   (concat
    "\\documentclass{article}\n"
    "\\usepackage{amsmath}\n"
    "% macros between \\documentclass and \\begin{document}\n"
    "\\newcommand{\\mycmd}[1]{\\mathbf{#1}}\n"
    "\\begin{document}\n"
    "$\\mycmd{y}$\n"
    "\\end{document}\n")
    (tip-render-all)
    (tip-test-wait-for-pending 20)
    (let* ((frags (tip-latex-collect-fragments (point-min) (point-max)))
           (pos (and frags
                     (byte-to-position
                      (1+ (alist-get "start" (car frags) nil nil #'equal))))))
      (should pos)
      (should (tip-test-overlay-showing-image-p (1+ pos))))))
