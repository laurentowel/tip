;;; latex-live-render.el --- End-to-end LaTeX: tip-mode compiles to SVG  -*- lexical-binding: t; -*-

;; Ported from legacy 61-latex-live-render.el.  The full emacs↔server
;; pipeline against a real latex + dvisvgm install:
;;
;;   1. Fragments are collected (two of them in this doc).
;;   2. tip-mode uses the LaTeX backend.
;;   3. `tip-render-all' produces image overlays on both fragments.
;;
;; Skipped silently when latex/dvisvgm aren't on PATH — the test
;; isolates client-side wiring, but it can't do end-to-end without
;; the actual compile pipeline.

(defun tip-test--latex-tools-available-p ()
  (and (executable-find "latex") (executable-find "dvisvgm")))

(tip-test-deftest latex-active-backend-detected
  :doc "A `.tex' buffer in latex-mode activates the LaTeX backend."
  :tags (latex)
  (tip-test-with-fresh-latex-buffer
   (concat "\\documentclass{article}\n"
           "\\usepackage{amsmath}\n"
           "\\begin{document}\n"
           "$a+b$\n"
           "\\end{document}\n")
    (let ((b (tip-active-backend)))
      (should (and b (eq (tip-backend-name b) 'latex))))))

(tip-test-deftest latex-collect-two-fragments
  :doc "Client-side fragment detection finds both inline fragments."
  :tags (latex)
  (tip-test-with-fresh-latex-buffer
   (concat "\\documentclass{article}\n"
           "\\usepackage{amsmath}\n"
           "\\begin{document}\n"
           "Text $a+b$ more $x^2$.\n"
           "\\end{document}\n")
    (should (= 2 (length (tip-collect-fragments (point-min) (point-max)))))))

(tip-test-deftest latex-render-produces-image-overlays
  :doc "Real latex + dvisvgm compile — overlays carry SVG display specs."
  :tags (latex render)
  (require 'ert)
  (unless (tip-test--latex-tools-available-p)
    (ert-skip "latex or dvisvgm not on PATH"))
  (tip-test-with-fresh-latex-buffer
   (concat "\\documentclass{article}\n"
           "\\usepackage{amsmath}\n"
           "\\begin{document}\n"
           "Text $a+b$ more $x^2$.\n"
           "\\end{document}\n")
    (tip-render-all)
    (tip-test-wait-for-pending 60)  ; LaTeX compile is slower than Typst
    ;; Both fragments should get image overlays.
    (let* ((frags (tip-latex-collect-fragments (point-min) (point-max)))
           (rendered 0))
      (dolist (f frags)
        (let* ((start (alist-get "start" f nil nil #'equal))
               (pos (byte-to-position (1+ start))))
          (when (tip-test-overlay-showing-image-p (1+ pos))
            (cl-incf rendered))))
      (should (= (length frags) rendered)))))
