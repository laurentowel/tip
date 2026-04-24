;;; visual-test.el --- Self-contained visual test for TIP -*- lexical-binding: t; -*-

;;; Commentary:
;; Fully self-contained: installs deps into sandboxed --init-directory.
;; Run with:
;;   emacs -Q --init-directory /workspace/tip-improve/tip-server/test-output/emacs-sandbox -l /workspace/tip-improve/tip-server/test-output/visual-test.el
;;
;; The sandbox caches tree-sitter grammars and installed packages
;; across runs. Delete emacs-sandbox/ to start fresh.

;;; Code:

(require 'package)
(package-initialize)

;; No littering
(setq create-lockfiles nil)
(setq make-backup-files nil)
(setq auto-save-default nil)

;; --- Bootstrap: install typst-ts-mode ---

(unless (package-installed-p 'typst-ts-mode)
  (message "TIP-TEST: Installing typst-ts-mode...")
  (package-vc-install
   '(typst-ts-mode
     :url "https://codeberg.org/meow_king/typst-ts-mode"))
  (message "TIP-TEST: typst-ts-mode installed."))

(require 'typst-ts-mode)

;; --- Bootstrap: install tree-sitter grammar ---

(unless (treesit-language-available-p 'typst)
  (message "TIP-TEST: Installing typst tree-sitter grammar...")
  (setq treesit-language-source-alist
        '((typst "https://github.com/uben0/tree-sitter-typst")))
  (treesit-install-language-grammar 'typst)
  (message "TIP-TEST: Typst grammar installed."))

;; --- Configure tip ---

(let ((base (file-name-directory load-file-name)))
  (setq tip-server-executable
        (expand-file-name "../tip-server/target/release/tip-server" base))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base)))

(setq tip-enable-debug nil)

;; Auto-enable tip-mode (it handles everything: render visible, live preview, cursor tracking)
(add-hook 'typst-ts-mode-hook #'tip-mode)

;; --- Open test file ---

(let ((base (file-name-directory load-file-name)))
  (find-file (expand-file-name
              "../tip-server/crates/tip-core-typst/tests/fixtures/diagrams.typ"
              base)))

(message "TIP-TEST: ready. Fragments compile in ~1.5s.")
(message "TIP-TEST: sandbox at %s" user-emacs-directory)
