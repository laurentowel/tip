;;; daemon-init.el --- Entry point for the integration-test daemon  -*- lexical-binding: t; -*-

;;; Commentary:
;; Loaded when the test daemon starts.  Sets up load-path, loads
;; tip.el, then the tip-test framework.  Spec files under
;; integration-tests/specs/ are loaded on demand by the runner
;; (not here) so source edits during development can be picked
;; up without daemon restart.
;;
;; This init is TEST-only.  Showcase-specific setup (fullscreen,
;; themes, font scaling, i18n, demo-it) lives in showcase/lib/
;; daemon-init.el and does not pollute the test harness.

;;; Code:

(setq inhibit-startup-screen t
      make-backup-files nil
      auto-save-default nil
      create-lockfiles nil)

;; Hide UI chrome for cleaner test framing.
(menu-bar-mode -1)
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars . nil) default-frame-alist)

;; Keep the echo area to a single line (verbose tip messages
;; otherwise grow the minibuffer window).
(setq resize-mini-windows nil
      max-mini-window-height 1)

;; Locate repo root + specs dir.  Env vars override (set by the
;; nix wrapper which absolute-paths into the store).
(defvar tip-test--repo-root nil)
(defvar tip-test--specs-dir nil)
(defvar tip-test--lib-dir nil)

(let* ((this-file (or load-file-name buffer-file-name))
       (lib-dir (file-name-directory this-file))
       (default-it-dir (file-name-directory (directory-file-name lib-dir)))
       (default-repo-root (file-name-directory
                           (directory-file-name default-it-dir)))
       (repo-root (or (getenv "TIP_REPO") default-repo-root))
       (it-dir (or (getenv "TIP_IT_DIR") default-it-dir))
       (specs-override (getenv "TIP_IT_SPECS")))
  (setq tip-test--repo-root repo-root
        tip-test--specs-dir (or specs-override
                                (expand-file-name "specs" it-dir))
        tip-test--lib-dir (expand-file-name "lib" it-dir))
  (add-to-list 'load-path repo-root)
  (add-to-list 'load-path lib-dir)
  (let ((gp (getenv "TIP_IT_GRAMMAR_PATH")))
    (when (and gp (file-directory-p gp))
      (add-to-list 'treesit-extra-load-path (file-name-as-directory gp))))
  ;; Optional second grammar dir (markdown for katex tests).  Separate
  ;; env var so callers can provide just one or both.
  (let ((mp (getenv "TIP_IT_MARKDOWN_GRAMMAR_PATH")))
    (when (and mp (file-directory-p mp))
      (add-to-list 'treesit-extra-load-path (file-name-as-directory mp))))
  (load (expand-file-name "tip.el" repo-root) nil t)
  (require 'tip-test))

;; Inter-test sleep for eye-balling results.
(let ((v (getenv "TIP_IT_SLEEP")))
  (when (and v (not (string-empty-p v)))
    (setq tip-test--inter-test-sleep
          (condition-case _ (string-to-number v) (error 0)))))

;; Optional name-substring filter: TIP_IT_TEST=katex runs only tests
;; whose name contains "katex".  Matches `regexp-quote' literal.
(let ((v (getenv "TIP_IT_TEST")))
  (when (and v (not (string-empty-p v)))
    (setq tip-test-filter v)))

;; Debug + verbose ON for the test harness — failures need breadcrumbs.
(setq tip-enable-debug t
      tip-verbose t)

;; Optional showcase extensions.  When SHOWCASE_INIT is set, load a
;; supplemental init file (typically showcase/lib/daemon-init.el) that
;; adds the demo-it + i18n + fullscreen + recorder bracket.  Tests
;; without SHOWCASE_INIT keep a minimal surface.
(let ((extra (getenv "TIP_SHOWCASE_INIT")))
  (when (and extra (file-readable-p extra))
    (load extra nil t)))

(defun tip-test-daemon-run ()
  "Load every spec in the specs/ dir, run all tests, return summary string."
  (setq tip-test--tests nil)
  (tip-test-load-specs tip-test--specs-dir)
  (tip-test-format-summary (tip-test-run-all)))

(message "tip-test daemon ready — specs=%s" tip-test--specs-dir)

;;; daemon-init.el ends here
