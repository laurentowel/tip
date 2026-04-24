;;; init.el --- Entry point for the tip showcase  -*- lexical-binding: t; -*-

;; emacs -Q -l showcase/init.el
;; Load packages + appearance tweaks, load the script (show.el),
;; then wait.  User drives manually:
;;   M-x tip-showcase-start  →  begin recording + demo-it (F12 advances)
;;   M-x tip-showcase-end    →  stop recording + end demo

;;; Code:

(setq inhibit-startup-screen t
      make-backup-files nil auto-save-default nil create-lockfiles nil
      resize-mini-windows nil max-mini-window-height 1)

(menu-bar-mode -1)
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(dolist (p '((menu-bar-lines . 0) (tool-bar-lines . 0)
             (vertical-scroll-bars . nil)))
  (push p default-frame-alist))

(when (equal (getenv "TIP_FULLSCREEN") "1")
  (push '(fullscreen . fullboth) default-frame-alist)
  (add-hook 'after-make-frame-functions
            (lambda (f) (set-frame-parameter f 'fullscreen 'fullboth))))

(set-face-attribute 'default nil
                    :height (string-to-number
                             (or (getenv "TIP_FONT_HEIGHT") "200")))

(let* ((this-dir (file-name-directory (or load-file-name buffer-file-name)))
       (repo-root (or (getenv "TIP_REPO")
                      (file-name-directory (directory-file-name this-dir)))))
  (add-to-list 'load-path repo-root)
  (let ((gp (getenv "TIP_IT_GRAMMAR_PATH")))
    (when (and gp (file-directory-p gp))
      (add-to-list 'treesit-extra-load-path (file-name-as-directory gp))))
  (load (expand-file-name "tip.el" repo-root) nil t)
  (require 'demo-it)
  (require 'typst-ts-mode)

  (let ((v (getenv "TIP_SHOWCASE_THEME")))
    (when (and v (not (string-empty-p v)))
      (require 'ef-themes nil t)
      (ignore-errors (load-theme (intern v) t))))

  (when (require 'spacious-padding nil t)
    (setq spacious-padding-subtle-mode-line nil)
    (spacious-padding-mode 1))

  (when (require 'keycast nil t)
    (keycast-mode-line-mode 1))

  (setq tip-verbose nil tip-enable-debug nil)

  (load (expand-file-name "show.el" this-dir) nil t))

;; ---- user-driven start/end ----

(defvar tip-showcase--rec nil)

(defun tip-showcase-start (&optional out-file)
  "Begin the recording + demo.  With prefix arg, prompt for the
output path; otherwise use TIP_RECORD_OUT env (or nothing, skip
recording).  Demo advances with <F12> (demo-it-start's default)."
  (interactive
   (list (when current-prefix-arg
           (read-file-name "Record to: " nil nil nil
                           (format-time-string "tip-showcase-%Y%m%d-%H%M%S.mp4")))))
  (let ((out (or out-file
                 (let ((v (getenv "TIP_RECORD_OUT")))
                   (and v (not (string-empty-p v)) v)))))
    (when out
      (setq tip-showcase--rec
            (start-process "tip-showcase-wf" " *wf*"
                           (or (executable-find "wf-recorder") "wf-recorder")
                           "-c" "libx264" "-f" out))
      (sit-for 0.4)
      (message "recording → %s" out)))
  (demo-it-start tip-showcase-steps t))

(defun tip-showcase-end ()
  "Stop the demo, stop the recording, flush the mp4."
  (interactive)
  (ignore-errors (demo-it-end))
  (when (and tip-showcase--rec (process-live-p tip-showcase--rec))
    (interrupt-process tip-showcase--rec)
    (let ((deadline (+ (float-time) 8)))
      (while (and (process-live-p tip-showcase--rec)
                  (< (float-time) deadline))
        (accept-process-output tip-showcase--rec 0.2))))
  (setq tip-showcase--rec nil)
  (message "showcase ended"))

;;; init.el ends here
