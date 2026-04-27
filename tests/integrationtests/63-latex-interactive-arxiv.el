;;; 63-latex-interactive-arxiv.el --- GUI visual test against arXiv sources -*- lexical-binding: t; -*-

;;; Commentary:
;; Opens training.tex from the Transformer paper (arXiv:1706.03762,
;; 8 math fragments including one \begin{equation}) and renders them.
;;
;; Run:
;;   emacs -Q -l tests/63-latex-interactive-arxiv.el

;;; Code:

(setq create-lockfiles nil
      make-backup-files nil
      auto-save-default nil)

(let ((base (file-name-directory (or load-file-name "."))))
  (add-to-list 'load-path (expand-file-name "../.." base))
  (load (expand-file-name "../../tip.el" base))
  (setq tip-server-executable
        (expand-file-name "../../tip-server/target/release/tip-server" base)))

(setq tip-enable-debug nil)
(add-hook 'latex-mode-hook #'tip-mode)

;; Copy training.tex into a temp dir along with a minimal wrapper, so
;; our detector sees a \begin{document} and a complete preamble (the
;; real arxiv file is just a section).
(let* ((base (file-name-directory (or load-file-name ".")))
       (src (expand-file-name
             "../.ref/arxiv-samples/1706.03762/training.tex" base))
       (tmp-dir (make-temp-file "tip-latex-arxiv-" t))
       (dest (expand-file-name "doc.tex" tmp-dir)))
  (unless (file-exists-p src)
    (error "training.tex not found at %s -- is the arxiv corpus downloaded?" src))
  (with-temp-file dest
    (insert "\\documentclass{article}\n")
    (insert "\\usepackage{amsmath,amssymb}\n")
    ;; The paper uses \dmodel — define a stub so the preview compiles.
    (insert "\\newcommand{\\dmodel}{d_{\\text{model}}}\n")
    (insert "\\begin{document}\n")
    (insert-file-contents src)
    (goto-char (point-max))
    (insert "\n\\end{document}\n"))
  (find-file dest))

(goto-char (point-min))

(message "TIP-LATEX-ARXIV: opened training.tex wrapper.  ~8 fragments; first render takes ~450ms.")

;;; 63-latex-interactive-arxiv.el ends here
