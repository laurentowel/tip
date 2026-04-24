;;; daemon-init.el --- Entry point for the integration-test daemon  -*- lexical-binding: t; -*-

;;; Commentary:
;; Loaded when the test daemon starts.  Sets up load-path, loads
;; tip.el + the typst-ts-mode environment, then the tip-test
;; framework.  Spec files under integration-tests/specs/ are loaded
;; on demand by the runner (not here) so source edits during
;; development can be picked up without daemon restart.

;;; Code:

(setq inhibit-startup-screen t
      make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      ;; No lingering messages buffer spam from package setup.
      inhibit-message nil)

;; Locate the repo root + specs dir.  The nix wrapper sets TIP_REPO
;; and TIP_IT_DIR to absolute store paths since daemon-init's own
;; file path ends up inside the nix store and can't be used for
;; sibling lookup.  Outside nix we self-locate.
(let* ((this-file (or load-file-name buffer-file-name))
       (lib-dir (file-name-directory this-file))
       (default-it-dir (file-name-directory (directory-file-name lib-dir)))
       (default-repo-root (file-name-directory
                           (directory-file-name default-it-dir)))
       (repo-root (or (getenv "TIP_REPO") default-repo-root))
       (it-dir (or (getenv "TIP_IT_DIR") default-it-dir)))
  (setq tip-test--repo-root repo-root)
  (setq tip-test--specs-dir (expand-file-name "specs" it-dir))
  (setq tip-test--lib-dir (expand-file-name "lib" it-dir))
  (add-to-list 'load-path repo-root)
  (add-to-list 'load-path lib-dir)
  ;; Optional: typst tree-sitter grammar path (set by the nix app).
  ;; Outside nix the grammar is expected to be on the user's default
  ;; `treesit-extra-load-path' or installed via `treesit-install-
  ;; language-grammar'.
  (let ((gp (getenv "TIP_IT_GRAMMAR_PATH")))
    (when (and gp (file-directory-p gp))
      (add-to-list 'treesit-extra-load-path (file-name-as-directory gp))))
  (load (expand-file-name "tip.el" repo-root) nil t)
  (require 'tip-test))

(defvar tip-test--repo-root nil)
(defvar tip-test--specs-dir nil)
(defvar tip-test--lib-dir nil)

;; Pick up the eyeball-pace from the env so run.sh can pass it in.
(let ((v (getenv "TIP_IT_SLEEP")))
  (when (and v (not (string-empty-p v)))
    (setq tip-test--inter-test-sleep
          (condition-case _ (string-to-number v) (error 0)))))

;; Turn on debug spray so failures have breadcrumbs — the echo area
;; mirrors into *Messages* and, under run.sh, into stderr via our
;; `message' advice.
(setq tip-enable-debug t)
(setq tip-verbose t)

(defun tip-test-daemon-run ()
  "Load every spec in the specs/ dir, run all tests, return summary string."
  (setq tip-test--tests nil)
  (tip-test-load-specs tip-test--specs-dir)
  (tip-test-format-summary (tip-test-run-all)))

(message "tip-test daemon ready — specs=%s" tip-test--specs-dir)

;;; daemon-init.el ends here
