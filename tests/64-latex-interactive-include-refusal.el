;;; 64-latex-interactive-include-refusal.el --- Show include-refusal behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; Opens a LaTeX file that contains \input — tip-latex v1 refuses to
;; preview such files and emits a one-time warning in *Messages*.  No
;; overlays should appear.  Good for verifying the guard visually.
;;
;; Run:
;;   emacs -Q -l tests/64-latex-interactive-include-refusal.el

;;; Code:

(setq create-lockfiles nil
      make-backup-files nil
      auto-save-default nil)

(let ((base (file-name-directory (or load-file-name "."))))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base))
  (setq tip-server-executable
        (expand-file-name "../tip-server/target/release/tip-server-latex" base)))

(setq tip-enable-debug nil)
(add-hook 'latex-mode-hook #'tip-mode)

(let ((tmp (make-temp-file "tip-latex-refusal-" nil ".tex")))
  (with-temp-file tmp
    (insert "\\documentclass{article}\n"
            "\\usepackage{amsmath}\n"
            "\\input{macros}  %% ← this line disables previews (v1)\n"
            "\\begin{document}\n"
            "\n"
            "This buffer has a \\textbackslash{}input in the preamble, so tip-latex\n"
            "refuses to preview any fragment below.  Look at *Messages*:\n"
            "  \"tip-latex: buffer contains \\\\input/\\\\include/\\\\subimport...\"\n"
            "\n"
            "$a + b = c$ — should NOT render.\n"
            "$\\int_0^1 f\\,dx$ — should NOT render.\n"
            "\n"
            "Delete the \\textbackslash{}input line, then M-x revert-buffer (or\n"
            "re-enable tip-mode) and the fragments should appear.\n"
            "\n"
            "\\end{document}\n"))
  (find-file tmp))

(goto-char (point-min))

(message "TIP-LATEX-REFUSAL: previews should NOT appear. Check *Messages* for the warning.")

;;; 64-latex-interactive-include-refusal.el ends here
