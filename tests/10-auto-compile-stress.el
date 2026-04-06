;;; 10-auto-compile-stress.el --- Stress test tip-auto-mode -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests that tip-auto-mode:
;; 1. Compiles visible fragments on idle
;; 2. Timer starts and stops cleanly
;; 3. Survives rapid scrolling (many timer fires)
;; 4. Doesn't compile fragments at point (uses tip-send-nbd)
;; 5. Doesn't leak timers on toggle

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
  (expand-file-name "10-auto-compile-stress-results.txt"
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
(defun test--count-rendered ()
  (length (seq-filter (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                                        (overlay-get ov 'display)))
                      (overlays-in (point-min) (point-max)))))

;; === Tests ===

(let ((test-file (make-temp-file "tip-auto-stress-" nil ".typ")))
  (with-temp-file test-file
    (dotimes (i 30)
      (insert (format "Fragment %d: $a_%d + b_%d$ text.\n" i i i))))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (tip-live-teardown)
  (sleep-for 1)
  (test--drain 3)

  (test--log "=== Auto-Compile Stress Test ===")

  ;; --- Test 1: timer starts ---
  (test--log "")
  (test--log "--- Test 1: timer lifecycle ---")
  (test--check "auto-mode initially off" (not tip-auto-mode))
  (test--check "no timer initially" (null tip-auto--timer))
  (tip-auto-mode 1)
  (test--check "auto-mode on" tip-auto-mode)
  (test--check "timer created" (timerp tip-auto--timer))

  ;; --- Test 2: tip-send-nbd compiles visible fragments ---
  (test--log "")
  (test--log "--- Test 2: send-nbd compile ---")
  ;; Clear all overlays first
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (eq (overlay-get ov 'tip) 'tip)
      (delete-overlay ov)))
  (test--check "overlays cleared" (= (test--count-rendered) 0))
  ;; Directly call what the timer calls
  (goto-char (point-min))
  (tip-send-nbd)
  (test--drain 5)
  (let ((count (test--count-rendered)))
    (test--log "  rendered after send-nbd: %d" count)
    (test--check "send-nbd rendered fragments" (> count 0)))

  ;; --- Test 3: send-nbd avoids fragment at point ---
  (test--log "")
  (test--log "--- Test 3: avoids fragment at point ---")
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (eq (overlay-get ov 'tip) 'tip)
      (delete-overlay ov)))
  (let* ((ranges (treesit-query-range 'typst "((math) @math)"))
         (frag (car ranges))
         (inside (and frag (1+ (car frag)))))
    (when inside
      (goto-char inside)
      (tip-send-nbd)
      (test--drain 5)
      (let ((ov-at (seq-find (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                                               (overlay-get ov 'display)))
                             (overlays-at inside))))
        (test--log "  cursor at %d (frag %S), overlay at point: %S"
                   inside frag (not (null ov-at)))
        (test--check "no overlay at cursor position" (null ov-at)))
      (let ((others (test--count-rendered)))
        (test--log "  other rendered overlays: %d" others)
        (test--check "other fragments compiled" (> others 0)))))

  ;; --- Test 4: rapid toggle doesn't leak timers ---
  (test--log "")
  (test--log "--- Test 4: rapid toggle ---")
  (dotimes (_ 20)
    (tip-auto-mode 1)
    (tip-auto-mode -1))
  (test--check "timer nil after toggles" (null tip-auto--timer))
  (test--check "auto-mode off after toggles" (not tip-auto-mode))
  ;; Turn on once more, confirm only one timer
  (tip-auto-mode 1)
  (let ((tip-timers (seq-filter (lambda (t)
                                  (and (timerp t)
                                       (eq (timer--function t)
                                           (timer--function tip-auto--timer))))
                                timer-idle-list)))
    (test--log "  active auto-compile timers: %d" (length tip-timers))
    (test--check "exactly one timer" (= (length tip-timers) 1)))

  ;; --- Test 5: rapid send-nbd calls don't crash ---
  (test--log "")
  (test--log "--- Test 5: rapid compile calls ---")
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (eq (overlay-get ov 'tip) 'tip)
      (delete-overlay ov)))
  ;; Fire 20 rapid compile requests from different positions
  (dotimes (_ 20)
    (goto-char (1+ (random (1- (point-max)))))
    (tip-send-nbd))
  (test--drain 10)
  (let ((count (test--count-rendered)))
    (test--log "  rendered after 20 rapid calls: %d" count)
    (test--check "fragments compiled" (> count 0))
    (test--check "server still alive"
                 (and tip--server-process (process-live-p tip--server-process))))

  ;; --- Test 6: clean shutdown ---
  (test--log "")
  (test--log "--- Test 6: clean shutdown ---")
  (tip-auto-mode -1)
  (test--check "timer cancelled" (null tip-auto--timer))
  (tip-mode -1)
  (test--check "no tip overlays after tip-mode off"
               (= (test--count-rendered) 0))

  ;; --- Summary ---
  (test--log "")
  (test--log "=== SUMMARY ===")
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
