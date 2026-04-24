;;; 07-error-without-live.el --- Test error display without live preview -*- lexical-binding: t; -*-

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
  (expand-file-name "07-error-without-live-results.txt"
                    (file-name-directory load-file-name)))
(defvar test--lines nil)
(defvar test--errors 0)

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

(let ((test-file (make-temp-file "tip-errtest-" nil ".typ")))
  (with-temp-file test-file
    (insert "Hello world\n"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 1)
  (accept-process-output tip--server-process 2)

  ;; Disable live preview
  (tip-live-teardown)

  (test--log "=== Error display without live preview ===")
  (test--log "tip-live--timer: %S" tip-live--timer)

  ;; Type $xxxxx$ and move out
  (goto-char (point-max))
  (let ((this-command 'self-insert-command))
    (run-hooks 'pre-command-hook))
  (insert "$xxxxx$")
  (let ((this-command 'self-insert-command))
    (run-hooks 'post-command-hook))
  (redisplay t)
  (sleep-for 0.3)

  ;; Move back inside the math
  (backward-char 1)
  (let ((this-command 'backward-char))
    (run-hooks 'pre-command-hook))
  (backward-char 1)
  (let ((this-command 'backward-char))
    (run-hooks 'post-command-hook))
  (redisplay t)
  (sleep-for 0.2)

  (test--log "point: %d, bounds: %S"
             (point) (tip--get-bounds-of-math-at-point (point)))

  ;; Now move out (forward past closing $)
  (let ((this-command 'forward-char))
    (run-hooks 'pre-command-hook))
  (goto-char (point-max))
  (let ((this-command 'forward-char))
    (run-hooks 'post-command-hook))
  (redisplay t)

  ;; Wait for async compile
  (accept-process-output tip--server-process 5)
  (sleep-for 1)
  (redisplay t)

  ;; Check messages buffer for error
  (let* ((msgs (with-current-buffer (messages-buffer)
                 (buffer-substring-no-properties
                  (max (point-min) (- (point-max) 1000))
                  (point-max))))
         (has-tip-error (string-match-p "TIP error\\|unknown variable" msgs))
         (has-compile-msg (string-match-p "compile_fragments" msgs)))
    (test--log "messages tail: %S"
               (substring msgs (max 0 (- (length msgs) 300))))
    (test--log "has TIP error in messages: %S" has-tip-error)
    (test--log "has compile request in debug: %S" has-compile-msg)
    (test--check "error message appeared in *Messages*"
                 has-tip-error))

  ;; Also check overlays
  (let ((ovs (seq-filter (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
                         (overlays-in (point-min) (point-max)))))
    (test--log "tip overlays: %d" (length ovs))
    (test--check "no overlay for bad math" (= (length ovs) 0)))

  (test--log "")
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
