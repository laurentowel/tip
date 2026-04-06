;;; test-open-close.el --- Test overlay open/close cycle -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests: render → move into overlay (opens) → move out (closes/recompiles)
;; Run with:
;;   emacs -Q --init-directory .../emacs-sandbox -l .../test-open-close.el

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
  (expand-file-name "test-open-close-results.txt"
                    (file-name-directory load-file-name)))
(defvar test--lines nil)

(defun test--log (fmt &rest args)
  (let ((line (apply #'format fmt args)))
    (push line test--lines)
    (message "TEST: %s" line)))

(defun test--write-log ()
  (with-temp-file test--log-file
    (dolist (line (nreverse test--lines))
      (insert line "\n"))))

(defun test--count-tip-overlays ()
  (length (seq-filter
           (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
           (overlays-in (point-min) (point-max)))))

(defun test--overlay-at-has-display (pos)
  "Check if there's a tip overlay at POS with a non-nil display property."
  (seq-find (lambda (ov)
              (and (eq (overlay-get ov 'tip) 'tip)
                   (overlay-get ov 'display)))
            (overlays-at pos)))

(defun test--overlay-at-is-open (pos)
  "Check if tip overlay at POS is open (source visible, no display)."
  (seq-find (lambda (ov)
              (and (eq (overlay-get ov 'tip) 'tip)
                   (not (overlay-get ov 'display))))
            (overlays-at pos)))

(defun test--simulate-move-to (target)
  "Simulate an interactive cursor move to TARGET with hooks."
  (let ((this-command 'forward-char))
    (run-hooks 'pre-command-hook))
  (goto-char target)
  (redisplay t)
  (let ((this-command 'forward-char))
    (run-hooks 'post-command-hook))
  (redisplay t)
  ;; Let async responses arrive
  (when (and tip--server-process (process-live-p tip--server-process))
    (accept-process-output tip--server-process 2))
  (redisplay t))

;; === Test ===

(let* ((test-file (make-temp-file "tip-openclose-" nil ".typ")))
  (with-temp-file test-file
    (insert "before $a + b$ middle $x^2$ after\n"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 1)

  ;; Wait for initial render
  (when (and tip--server-process (process-live-p tip--server-process))
    (accept-process-output tip--server-process 3))
  (redisplay t)
  (sleep-for 0.5)

  (test--log "=== Initial state ===")
  (test--log "Buffer: %S" (buffer-substring-no-properties (point-min) (point-max)))
  (test--log "Tip overlays: %d" (test--count-tip-overlays))

  ;; Find fragment positions
  (let* ((ranges (treesit-query-range 'typst "((math) @math)"))
         (frag1 (nth 0 ranges))  ;; $a + b$
         (frag2 (nth 1 ranges))) ;; $x^2$
    (test--log "Fragment 1: %S" frag1)
    (test--log "Fragment 2: %S" frag2)

    (when (and frag1 frag2)
      ;; Start outside math
      (goto-char (point-min))
      (redisplay t)
      (sleep-for 0.3)

      ;; --- Test 1: Move into first fragment (should OPEN) ---
      (test--log "")
      (test--log "=== Test 1: Move into $a + b$ ===")
      (let ((inside-pos (1+ (car frag1))))
        (test--simulate-move-to inside-pos)
        (sleep-for 0.3)
        (let ((has-display (test--overlay-at-has-display inside-pos))
              (is-open (test--overlay-at-is-open inside-pos)))
          (test--log "  Point: %d (inside frag1)" (point))
          (test--log "  Overlay has display (closed): %S" (not (null has-display)))
          (test--log "  Overlay is open (source): %S" (not (null is-open)))
          (if is-open
              (test--log "  PASS: overlay opened on enter")
            (if has-display
                (test--log "  FAIL: overlay still showing image (didn't open)")
              (test--log "  FAIL: no tip overlay found")))))

      ;; --- Test 2: Move out of first fragment (should CLOSE/recompile) ---
      (test--log "")
      (test--log "=== Test 2: Move out of $a + b$ ===")
      (let ((outside-pos (1+ (cdr frag1))))
        (test--simulate-move-to outside-pos)
        (sleep-for 0.5)
        ;; Check overlay reappeared with display
        (let ((has-display (test--overlay-at-has-display (1+ (car frag1)))))
          (test--log "  Point: %d (outside frag1)" (point))
          (test--log "  Frag1 overlay has display (recompiled): %S" (not (null has-display)))
          (if has-display
              (test--log "  PASS: overlay closed (recompiled) on leave")
            (test--log "  FAIL: overlay did not recompile"))))

      ;; --- Test 3: Move into second fragment ---
      (test--log "")
      (test--log "=== Test 3: Move into $x^2$ ===")
      (let ((inside-pos (1+ (car frag2))))
        (test--simulate-move-to inside-pos)
        (sleep-for 0.3)
        (let ((is-open (test--overlay-at-is-open inside-pos)))
          (test--log "  Point: %d (inside frag2)" (point))
          (test--log "  Overlay is open: %S" (not (null is-open)))
          (if is-open
              (test--log "  PASS: second overlay opened on enter")
            (test--log "  FAIL: second overlay didn't open"))))

      ;; --- Test 4: Move from frag2 directly to frag1 ---
      (test--log "")
      (test--log "=== Test 4: Move from $x^2$ to $a + b$ ===")
      (let ((frag1-inside (1+ (car frag1))))
        (test--simulate-move-to frag1-inside)
        (sleep-for 0.5)
        (let ((frag1-open (test--overlay-at-is-open frag1-inside))
              (frag2-closed (test--overlay-at-has-display (1+ (car frag2)))))
          (test--log "  Frag1 open: %S" (not (null frag1-open)))
          (test--log "  Frag2 closed (recompiled): %S" (not (null frag2-closed)))
          (if (and frag1-open frag2-closed)
              (test--log "  PASS: switched between fragments")
            (test--log "  FAIL: fragment switch didn't work"))))))

  ;; Summary
  (test--log "")
  (test--log "=== DONE ===")
  (let ((passes (length (seq-filter (lambda (l) (string-match-p "PASS" l)) test--lines)))
        (fails (length (seq-filter (lambda (l) (string-match-p "FAIL" l)) test--lines))))
    (test--log "Results: %d PASS, %d FAIL" passes fails))

  (test--write-log)

  (tip-shutdown)
  (sleep-for 0.5)
  (kill-buffer)
  (delete-file test-file)
  (kill-emacs 0))
