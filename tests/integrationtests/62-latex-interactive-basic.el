;;; 62-latex-interactive-basic.el --- Basic GUI visual test for tip-latex -*- lexical-binding: t; -*-

;;; Commentary:
;; Opens a small hand-crafted LaTeX buffer with varied math fragments
;; (inline $...$, \(...\), display \[...\], named env, multi-line align)
;; and renders them as overlays.  The Emacs window stays open so you
;; can:
;;   - click / cursor onto a fragment → source is revealed (preview-toggle)
;;   - cursor away → overlay reappears
;;   - C-c ' → tip-edit indirect edit buffer
;;   - C-x C-c to quit
;;
;; Run:
;;   emacs -Q -l tests/62-latex-interactive-basic.el
;;
;; Requirements on PATH: `latex', `dvisvgm'.
;; Expects tip-server built at tip-server/target/release/tip-server.

;;; Code:

(setq create-lockfiles nil
      make-backup-files nil
      auto-save-default nil)

(let ((base (file-name-directory (or load-file-name "."))))
  (add-to-list 'load-path (expand-file-name "../.." base))
  (load (expand-file-name "../../tip.el" base))
  ;; Point explicitly at the built binary so we don't prompt.
  (setq tip-server-executable
        (expand-file-name "../../tip-server/target/release/tip-server" base)))

(setq tip-enable-debug nil)

;; Auto-enable tip-mode when entering latex-mode.
(add-hook 'latex-mode-hook #'tip-mode)

;; Open a fresh temp file.  Use .tex extension so auto-mode dispatches
;; to latex-mode.
(let ((tmp (make-temp-file "tip-latex-visual-" nil ".tex")))
  (with-temp-file tmp
    (insert "\\documentclass{article}\n"
            "\\usepackage{amsmath,amssymb}\n"
            "\\begin{document}\n"
            "\n"
            "Hello!  Inline math: $a + b = c$ and $\\alpha \\beta \\gamma$\n"
            "and $\\int_0^1 f(x)\\, dx$ and $\\sum_{i=1}^{n} x_i^2$.\n"
            "\n"
            "Inline-escape form: \\( e^{i\\pi} + 1 = 0 \\).\n"
            "\n"
            "Display with \\[...\\]:\n"
            "\\[ \\frac{d}{dx}\\left( \\int_a^x f(t)\\,dt \\right) = f(x) \\]\n"
            "\n"
            "A named equation environment:\n"
            "\\begin{equation}\n"
            "  E = m c^2\n"
            "\\end{equation}\n"
            "\n"
            "Multi-line align:\n"
            "\\begin{align*}\n"
            "  (a + b)^2 &= a^2 + 2ab + b^2 \\\\\n"
            "  (a - b)^2 &= a^2 - 2ab + b^2\n"
            "\\end{align*}\n"
            "\n"
            "Verbatim \\$ should stay text: price = \\$3.14\n"
            "\n"
            "\\end{document}\n"))
  (find-file tmp))

(goto-char (point-min))
(search-forward "Hello" nil t)

(message "TIP-LATEX-VISUAL: buffer opened.  Overlays appear in ~1 second.")
(message "TIP-LATEX-VISUAL: cursor onto a fragment reveals source; cursor away recompiles.")
(message "TIP-LATEX-VISUAL: C-c ' opens a dedicated edit buffer.")

;;; 62-latex-interactive-basic.el ends here
