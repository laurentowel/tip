;;; test-bugs.el --- Reproduce and verify bug fixes -*- lexical-binding: t; -*-

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
        (expand-file-name "../tip-server/target/release/tip-server-typst" base))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base)))

(setq tip-enable-debug nil)

(defvar test--log-file
  (expand-file-name "03-bugs-results.txt"
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

(defun test--drain (&optional timeout)
  (let ((deadline (+ (float-time) (or timeout 3))))
    (while (and (< (float-time) deadline)
                tip--server-process
                (process-live-p tip--server-process))
      (accept-process-output tip--server-process 0.05)
      (redisplay t))))

(defun test--type-string (str)
  (dotimes (i (length str))
    (let ((this-command 'self-insert-command))
      (run-hooks 'pre-command-hook))
    (insert (substring str i (1+ i)))
    (let ((this-command 'self-insert-command))
      (run-hooks 'post-command-hook))
    (redisplay t)))

(defun test--press (cmd)
  (let ((this-command cmd))
    (run-hooks 'pre-command-hook))
  (condition-case nil (call-interactively cmd) (error nil))
  (let ((this-command cmd))
    (run-hooks 'post-command-hook))
  (redisplay t))

(defun test--tip-overlays ()
  (seq-filter (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
              (overlays-in (point-min) (point-max))))

(defun test--overlays-with-before-string ()
  "Find overlays that have a non-nil before-string property."
  (seq-filter (lambda (ov) (overlay-get ov 'before-string))
              (overlays-in (point-min) (point-max))))

;; === Bug 1: Errors not showing ===

(let ((test-file (make-temp-file "tip-bug1-" nil ".typ")))
  (with-temp-file test-file
    (insert "Text $#nonexistent_func()$ more\n"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 1)
  (test--drain 3)

  (test--log "=== Bug 1: Error display ===")

  ;; Move into the bad math
  (goto-char (point-min))
  (search-forward "$#non")
  (redisplay t)

  ;; Trigger live compile manually
  (tip-live--compile-partial)
  (test--drain 5)
  (sleep-for 0.5)
  (redisplay t)

  ;; Check: childframe should show error OR message should contain error
  (let* ((cf-buf (and tip-childframe--buffer
                      (buffer-live-p tip-childframe--buffer)
                      tip-childframe--buffer))
         (cf-text (and cf-buf
                       (with-current-buffer cf-buf
                         (buffer-substring-no-properties (point-min) (point-max)))))
         (cf-visible (and (frame-live-p tip-childframe--frame)
                          (frame-visible-p tip-childframe--frame))))
    (test--log "  childframe visible: %S" cf-visible)
    (test--log "  childframe text: %S" (and cf-text (truncate-string-to-width cf-text 60)))
    (test--check "childframe shows error or is visible"
                 (or cf-visible
                     (and cf-text (string-match-p "error\\|unknown\\|not found" cf-text)))))

  ;; Also check: compile the bad fragment via tip-send-region
  (test--log "")
  (test--log "--- Compile bad fragment via send-region ---")
  (let ((messages-before (with-current-buffer (messages-buffer)
                           (buffer-substring-no-properties
                            (max (point-min) (- (point-max) 500))
                            (point-max)))))
    (tip-send-region (point-min) (point-max))
    (test--drain 5)
    (sleep-for 0.5)
    (let ((messages-after (with-current-buffer (messages-buffer)
                            (buffer-substring-no-properties
                             (max (point-min) (- (point-max) 500))
                             (point-max)))))
      ;; Check if the overlay for the bad fragment has empty SVG
      (let* ((ovs (test--tip-overlays))
             (has-display (seq-find (lambda (ov) (overlay-get ov 'display)) ovs)))
        (test--log "  overlays after compile: %d" (length ovs))
        (test--log "  any with display: %S" (not (null has-display)))
        ;; Bad math should either: no overlay, or overlay without display
        (test--check "bad math doesn't produce visible overlay"
                     (or (= (length ovs) 0)
                         (null has-display))))))

  (tip-mode -1)
  (kill-buffer)
  (delete-file test-file))

;; === Bug 2: D indicator survives deletion ===

(test--log "")
(test--log "=== Bug 2: D indicator persists after deletion ===")

(let ((test-file (make-temp-file "tip-bug2-" nil ".typ")))
  (with-temp-file test-file
    (insert "before text\n$ integral f dif x $\nafter text\n"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 1)
  (test--drain 5)
  (sleep-for 0.5)

  ;; Check: overlay with D indicator exists
  (let ((d-ovs (test--overlays-with-before-string)))
    (test--log "  D overlays before deletion: %d" (length d-ovs))
    (test--check "D indicator overlay exists initially"
                 (> (length d-ovs) 0)))

  ;; Now delete the display math line with backspace
  (goto-char (point-min))
  (search-forward "$ integral f dif x $")
  ;; Select the whole thing and delete
  (let ((end (point))
        (beg (match-beginning 0)))
    (delete-region beg end)
    (redisplay t)
    (sleep-for 0.3))

  ;; Check: no D indicator overlays should remain
  (let ((d-ovs-after (test--overlays-with-before-string))
        (tip-ovs-after (test--tip-overlays)))
    (test--log "  D overlays after deletion: %d" (length d-ovs-after))
    (test--log "  tip overlays after deletion: %d" (length tip-ovs-after))
    (test--check "no D indicator overlays after deletion"
                 (= (length d-ovs-after) 0))
    (test--check "no tip overlays after deletion"
                 (= (length tip-ovs-after) 0)))

  ;; Also test: type display math, render, then backspace character by character
  (test--log "")
  (test--log "--- Backspace deletion char by char ---")
  (goto-char (point-max))
  (test--type-string "$ integral f $")
  (test--press 'move-end-of-line)
  (test--drain 3)
  (sleep-for 0.5)

  (let ((ovs-before (test--tip-overlays))
        (d-before (test--overlays-with-before-string)))
    (test--log "  overlays before backspace: tip=%d D=%d"
               (length ovs-before) (length d-before))

    ;; Backspace the whole thing
    (goto-char (point-min))
    (when (search-forward "$ integral f $" nil t)
      (let ((end (point)))
        (dotimes (_ (- end (match-beginning 0)))
          (test--press 'delete-backward-char))))
    (redisplay t)
    (sleep-for 0.3)

    (let ((ovs-after (test--tip-overlays))
          (d-after (test--overlays-with-before-string)))
      (test--log "  overlays after backspace: tip=%d D=%d"
                 (length ovs-after) (length d-after))
      (test--check "no stale overlays after backspace"
                   (= (length ovs-after) 0))
      (test--check "no stale D indicators after backspace"
                   (= (length d-after) 0))))

  (tip-mode -1)
  (kill-buffer)
  (delete-file test-file))

;; === Summary ===

(test--log "")
(test--log "=== SUMMARY ===")
(test--log "Errors: %d" test--errors)
(if (= test--errors 0)
    (test--log "ALL PASS")
  (test--log "FAILURES: %d" test--errors))

(test--write-log)
(when (and tip--server-process (process-live-p tip--server-process))
  (tip-shutdown))
(sleep-for 0.5)
(kill-emacs (if (= test--errors 0) 0 1))
