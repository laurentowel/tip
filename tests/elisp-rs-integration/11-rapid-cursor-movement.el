;;; test-rapid-movement.el --- Stress test rapid cursor movement -*- lexical-binding: t; -*-

;;; Commentary:
;; Simulates rapid cursor movement through many fragments.
;; Tests that overlays don't leak, pile up, or cause errors.

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
  (add-to-list 'load-path (expand-file-name "../.." base))
  (load (expand-file-name "../../tip.el" base)))

(setq tip-enable-debug nil)

(defvar test--log-file
  (expand-file-name "11-rapid-movement-results.txt"
                    (file-name-directory load-file-name)))
(defvar test--lines nil)
(defvar test--errors 0)

(defun test--log (fmt &rest args)
  (let ((line (apply #'format fmt args)))
    (push line test--lines)
    (message "TEST: %s" line)))

(defun test--write-log ()
  (with-temp-file test--log-file
    (dolist (line (nreverse test--lines))
      (insert line "\n"))))

(defun test--tip-overlay-count ()
  (length (seq-filter
           (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
           (overlays-in (point-min) (point-max)))))

(defun test--tip-overlays-with-display ()
  (length (seq-filter
           (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                             (overlay-get ov 'display)))
           (overlays-in (point-min) (point-max)))))

(defun test--move (target)
  "Move cursor to TARGET with hooks, no sleep."
  (let ((this-command 'forward-char))
    (run-hooks 'pre-command-hook))
  (goto-char target)
  (let ((this-command 'forward-char))
    (run-hooks 'post-command-hook))
  (redisplay t))

(defun test--drain (&optional timeout)
  "Accept pending async responses."
  (let ((deadline (+ (float-time) (or timeout 2))))
    (while (and (< (float-time) deadline)
                tip--server-process
                (process-live-p tip--server-process))
      (accept-process-output tip--server-process 0.05)
      (redisplay t))))

;; === Generate test file ===

(let* ((test-file (make-temp-file "tip-rapid-" nil ".typ")))
  ;; 20 fragments with text between
  (with-temp-file test-file
    (dotimes (i 20)
      (insert (format "text%d $alpha_%d + beta_%d$ " i i i))
      (when (= (% i 4) 3) (insert "\n"))))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)

  ;; Wait for initial render
  (sleep-for 1)
  (test--drain 5)
  (sleep-for 0.5)

  (let* ((ranges (treesit-query-range 'typst "((math) @math)"))
         (n-frags (length ranges)))
    (test--log "=== Initial state ===")
    (test--log "Fragments: %d" n-frags)
    (test--log "Overlays: %d (with display: %d)"
               (test--tip-overlay-count)
               (test--tip-overlays-with-display))

    ;; === Test 1: Rapid forward scan through all fragments ===
    (test--log "")
    (test--log "=== Test 1: Rapid forward scan (enter+leave each fragment) ===")
    (goto-char (point-min))
    (let ((start-time (float-time)))
      (dolist (bounds ranges)
        ;; Enter fragment
        (test--move (1+ (car bounds)))
        ;; Immediately leave
        (test--move (1+ (cdr bounds))))
      (test--log "  Scan time: %.1fms (no waiting for responses)"
                 (* 1000.0 (- (float-time) start-time))))

    ;; Now wait for all async responses
    (test--log "  Waiting for async responses...")
    (test--drain 10)
    (test--log "  After drain: overlays=%d with-display=%d"
               (test--tip-overlay-count)
               (test--tip-overlays-with-display))

    ;; === Test 2: Rapid backward scan ===
    (test--log "")
    (test--log "=== Test 2: Rapid backward scan ===")
    (goto-char (point-max))
    (let ((start-time (float-time)))
      (dolist (bounds (reverse ranges))
        (test--move (1+ (car bounds)))
        (test--move (max (point-min) (1- (car bounds)))))
      (test--log "  Scan time: %.1fms"
                 (* 1000.0 (- (float-time) start-time))))
    (test--drain 10)
    (test--log "  After drain: overlays=%d with-display=%d"
               (test--tip-overlay-count)
               (test--tip-overlays-with-display))

    ;; === Test 3: Random bouncing between fragments (100 moves) ===
    (test--log "")
    (test--log "=== Test 3: 100 random jumps between fragments ===")
    (let ((start-time (float-time))
          (n-moves 100))
      (dotimes (_ n-moves)
        (let* ((idx (random n-frags))
               (bounds (nth idx ranges))
               (inside (+ (car bounds) 1 (random (max 1 (- (cdr bounds) (car bounds) 1))))))
          ;; Jump into random fragment
          (test--move inside)
          ;; Sometimes immediately jump out
          (when (= (random 3) 0)
            (test--move (1+ (cdr bounds))))))
      (test--log "  %d moves in %.1fms"
                 n-moves (* 1000.0 (- (float-time) start-time))))
    (test--drain 10)
    (test--log "  After drain: overlays=%d with-display=%d"
               (test--tip-overlay-count)
               (test--tip-overlays-with-display))

    ;; === Test 4: Character-by-character walk through entire buffer ===
    (test--log "")
    (test--log "=== Test 4: Walk entire buffer char-by-char ===")
    (goto-char (point-min))
    (let ((start-time (float-time))
          (n-chars 0))
      (while (< (point) (point-max))
        (test--move (1+ (point)))
        (cl-incf n-chars))
      (test--log "  %d char moves in %.1fms"
                 n-chars (* 1000.0 (- (float-time) start-time))))
    (test--drain 10)
    (test--log "  After drain: overlays=%d with-display=%d"
               (test--tip-overlay-count)
               (test--tip-overlays-with-display))

    ;; === Test 5: Overlay leak check ===
    (test--log "")
    (test--log "=== Test 5: Overlay leak check ===")
    ;; Move to outside-math position and wait
    (test--move (point-min))
    (test--drain 5)
    (let ((total-ovs (test--tip-overlay-count))
          (display-ovs (test--tip-overlays-with-display)))
      (test--log "  Total tip overlays: %d" total-ovs)
      (test--log "  With display: %d" display-ovs)
      (test--log "  Fragments: %d" n-frags)
      ;; Should not have more overlays than fragments
      (if (<= total-ovs (* 2 n-frags))
          (test--log "  PASS: no excessive overlay leak (ovs=%d frags=%d)"
                     total-ovs n-frags)
        (progn
          (test--log "  FAIL: overlay leak! %d overlays for %d fragments"
                     total-ovs n-frags)
          (cl-incf test--errors))))

    ;; === Test 6: Server still alive? ===
    (test--log "")
    (test--log "=== Test 6: Server health ===")
    (if (and tip--server-process (process-live-p tip--server-process))
        (test--log "  PASS: server still alive after stress")
      (progn
        (test--log "  FAIL: server died during stress test")
        (cl-incf test--errors))))

  ;; Summary
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
