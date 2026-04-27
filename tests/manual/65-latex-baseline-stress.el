;;; 65-latex-baseline-stress.el --- Visual baseline stress test for LaTeX -*- lexical-binding: t; -*-

;;; Commentary:
;; Opens tests/fixtures/latex_baseline_stress.tex — 12 groups of hard
;; baseline cases ported from the Typst baseline_stress fixture plus
;; real-world math (functional analysis, probability, Maxwell).  ~90
;; rendered fragments.  Use as a regression check when touching the
;; baseline / scale / color pipelines.
;;
;; Run:
;;   emacs -Q -l tests/65-latex-baseline-stress.el
;;
;; Needs `latex' + `dvisvgm' on PATH and the tip-server binary
;; built (cargo build --release -p tip-server).

;;; Code:

(setq create-lockfiles nil
      make-backup-files nil
      auto-save-default nil)

(load (expand-file-name "../setup.el" (file-name-directory load-file-name)))
(load (expand-file-name "tip.el" tip-test-lisp-dir))
(setq tip-server-executable
      (expand-file-name "tip-server/target/release/tip-server"
                        tip-test-repo-root))
(add-hook 'latex-mode-hook #'tip-mode)
(find-file (expand-file-name "fixtures/latex_baseline_stress.tex"
                             (file-name-directory load-file-name)))

(goto-char (point-min))
(message "TIP-LATEX-STRESS: ~90 fragments across 12 groups.  Watch for baseline drift, color, and scale.")

;;; 65-latex-baseline-stress.el ends here
