;;; test-scale-slider.el --- Interactive scale tuning -*- lexical-binding: t; -*-

;;; Code:

(require 'package)
(package-initialize)
(setq create-lockfiles nil make-backup-files nil auto-save-default nil)

(unless (package-installed-p 'typst-ts-mode)
  (package-vc-install
   '(typst-ts-mode :url "https://codeberg.org/meow_king/typst-ts-mode")))
(require 'typst-ts-mode)
(unless (treesit-language-available-p 'typst)
  (setq treesit-language-source-alist
        '((typst "https://github.com/uben0/tree-sitter-typst")))
  (treesit-install-language-grammar 'typst))

(let ((base (file-name-directory load-file-name)))
  (setq tip-server-executable
        (expand-file-name "../../tip-server/target/release/tip-server" base))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base)))

(setq tip-enable-debug nil)

;; Open baseline test file
(let ((base (file-name-directory load-file-name)))
  (find-file (expand-file-name
              "../../tip-server/crates/tip-core/tests/fixtures/baseline_stress.typ"
              base)))
(typst-ts-mode)
(tip-mode 1)

;; Wait for initial render
(run-with-timer 1.5 nil
  (lambda ()
    (tip-send-all)
    (message "TIP: rendered. Use C-c + / C-c - to adjust scale. Current: %.2f" tip-scale)))

;; Scale adjustment keybindings
(defun tip-scale-up ()
  "Increase tip-scale by 0.05 and re-render."
  (interactive)
  (setq tip-scale (+ tip-scale 0.05))
  (tip-clear-buffer)
  (tip-send-all)
  (message "tip-scale: %.2f" tip-scale))

(defun tip-scale-down ()
  "Decrease tip-scale by 0.05 and re-render."
  (interactive)
  (setq tip-scale (max 0.1 (- tip-scale 0.05)))
  (tip-clear-buffer)
  (tip-send-all)
  (message "tip-scale: %.2f" tip-scale))

(defun tip-scale-set (val)
  "Set tip-scale to VAL and re-render."
  (interactive "nScale: ")
  (setq tip-scale val)
  (tip-clear-buffer)
  (tip-send-all)
  (message "tip-scale: %.2f" tip-scale))

(defun tip-scale-report ()
  "Report current scale and font info."
  (interactive)
  (message "tip-scale=%.2f font-pt=%.1f char-height=%dpx 1em=%dpx"
           tip-scale (tip--font-size-pt) (frame-char-height) (frame-char-height)))

(defun tip-baseline-up ()
  "Shift math down (increase baseline offset)."
  (interactive)
  (setq tip-baseline-offset (+ tip-baseline-offset 1))
  (tip-clear-buffer)
  (tip-send-all)
  (message "tip-baseline-offset: %d (scale: %.2f)" tip-baseline-offset tip-scale))

(defun tip-baseline-down ()
  "Shift math up (decrease baseline offset)."
  (interactive)
  (setq tip-baseline-offset (- tip-baseline-offset 1))
  (tip-clear-buffer)
  (tip-send-all)
  (message "tip-baseline-offset: %d (scale: %.2f)" tip-baseline-offset tip-scale))

(define-key typst-ts-mode-map (kbd "C-c =") #'tip-scale-up)
(define-key typst-ts-mode-map (kbd "C-c -") #'tip-scale-down)
(define-key typst-ts-mode-map (kbd "C-c [") #'tip-baseline-down)
(define-key typst-ts-mode-map (kbd "C-c ]") #'tip-baseline-up)
(define-key typst-ts-mode-map (kbd "C-c 0") #'tip-scale-report)
(define-key typst-ts-mode-map (kbd "C-c s") #'tip-scale-set)

(message "C-c =/- scale | C-c [/] baseline offset | C-c 0 report | C-c s set")
