;;; 08-theme-change.el --- Test theme change recompilation -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests that switching Emacs themes triggers recompilation of tip overlays
;; with updated colors. Cycles through built-in themes with 2-second pauses.
;;
;; Interactive (see color changes):
;;   emacs -Q -l tests/08-theme-change.el
;; Batch (verify overlays survive theme switches):
;;   emacs -Q --batch -l tests/08-theme-change.el

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
        (expand-file-name "../tip-server/target/release/tip-server" base))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base)))

(setq tip-enable-debug nil)

(defvar test--log-file
  (expand-file-name "08-theme-change-results.txt"
                    (file-name-directory load-file-name)))
(defvar test--lines nil)
(defvar test--errors 0)
(defvar test--recompile-count 0)

(defun test--log (fmt &rest args)
  (push (apply #'format fmt args) test--lines))
(defun test--check (label condition)
  (if condition
      (test--log "  PASS: %s" label)
    (test--log "  FAIL: %s" label)
    (cl-incf test--errors)))
(defun test--write-log ()
  (with-temp-file test--log-file
    (dolist (line (nreverse test--lines))
      (insert line "\n"))))
(defun test--drain (&optional timeout)
  (let ((deadline (+ (float-time) (or timeout 3))))
    (while (and (< (float-time) deadline)
                tip--server-process
                (process-live-p tip--server-process))
      (accept-process-output tip--server-process 0.05)
      (redisplay t))))

(defun test--count-tip-overlays ()
  (length (seq-filter (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                                        (overlay-get ov 'display)))
                      (overlays-in (point-min) (point-max)))))

;; Advice to count how many times tip--on-theme-change fires
(advice-add 'tip--on-theme-change :before
            (lambda (&rest _) (cl-incf test--recompile-count)))

;; === Test ===

(let ((test-file (make-temp-file "tip-theme-" nil ".typ")))
  (with-temp-file test-file
    (insert "\
Inline $a + b$ and $x^2 + y^2 = z^2$ formulas.

Displayed:
$ integral_0^1 f(x) dif x $
"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (tip-live-teardown)
  (sleep-for 1)

  ;; Explicit initial compile (don't rely on timer + window)
  (tip-render-all)
  (test--drain 5)
  (sleep-for 2)
  (redisplay t)

  (test--log "=== Theme Change Test ===")
  (let ((initial-count (test--count-tip-overlays)))
    (test--log "  initial overlays: %d" initial-count)
    (test--check "initial render produced overlays" (>= initial-count 2))

    ;; --- Test 1: follow-theme-mode is active ---
    (test--log "")
    (test--log "--- Test 1: follow-theme-mode ---")
    (test--check "tip-follow-theme-mode is on" tip-follow-theme-mode)
    (test--check "enable-theme-functions has tip handler"
                 (memq #'tip--on-theme-change enable-theme-functions))

    ;; --- Test 2: cycle through themes, verify overlays survive ---
    (test--log "")
    (test--log "--- Test 2: theme cycling ---")
    (let ((themes '(wombat tango nil)))
      (dolist (theme themes)
        (let ((before-count test--recompile-count))
          (test--log "")
          (test--log "  switching to: %S" (or theme 'default))

          ;; Switch theme
          (mapc #'disable-theme custom-enabled-themes)
          (when theme
            (load-theme theme t))
          (redisplay t)
          (test--drain 3)
          (sleep-for 2) ;; visual confirmation pause
          (redisplay t)

          (let ((ov-count (test--count-tip-overlays))
                (fired (> test--recompile-count before-count)))
            (test--log "  overlays: %d, hook fired: %S, fg: %s bg: %s"
                       ov-count fired
                       (tip--color-to-hex (face-attribute 'default :foreground))
                       (tip--color-to-hex (face-attribute 'default :background)))
            (test--check (format "%S: hook fired" (or theme 'default)) fired)
            (test--check (format "%S: overlays exist" (or theme 'default))
                         (>= ov-count 2))))))

    ;; --- Test 3: disabling tip-mode removes hooks ---
    (test--log "")
    (test--log "--- Test 3: teardown removes hooks ---")
    (tip-mode -1)
    (test--check "tip-follow-theme-mode is off" (not tip-follow-theme-mode))
    (test--check "enable-theme-functions cleared"
                 (not (memq #'tip--on-theme-change enable-theme-functions))))

  ;; --- Summary ---
  (test--log "")
  (test--log "=== SUMMARY ===")
  (test--log "Total recompiles: %d" test--recompile-count)
  (test--log "Errors: %d" test--errors)
  (if (= test--errors 0)
      (test--log "ALL PASS")
    (test--log "FAILURES: %d" test--errors))

  (test--write-log)
  (when tip--server-process (tip-shutdown))
  (sleep-for 0.5)
  (kill-buffer)
  (delete-file test-file)
  (kill-emacs (if (= test--errors 0) 0 1)))
