;;; test-c-b-into-overlay.el --- Test C-b into rendered overlays -*- lexical-binding: t; -*-

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

(setq tip-enable-debug t)

(defvar test--log-file
  (expand-file-name "test-c-b-results.txt" (file-name-directory load-file-name)))
(defvar test--lines nil)

(defun test--log (fmt &rest args)
  (let ((line (apply #'format fmt args)))
    (push line test--lines)
    (message "TEST: %s" line)))

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

(defvar test--messages nil)
(defun test--capture-messages (fn &rest args)
  (let ((msg (apply fn args)))
    (push msg test--messages)
    msg))

(defun test--move-with-hooks (target)
  "Simulate real cursor movement to TARGET."
  (setq test--messages nil)
  (advice-add 'message :before
              (lambda (&rest args) (push (apply #'format args) test--messages))
              '((name . test-msg-capture)))
  (let ((this-command 'backward-char))
    (run-hooks 'pre-command-hook))
  (goto-char target)
  (let ((this-command 'backward-char))
    (run-hooks 'post-command-hook))
  (advice-remove 'message 'test-msg-capture)
  (dolist (m (nreverse test--messages))
    (test--log "    [msg] %s" m))
  (redisplay t))

(defun test--overlay-has-display-at (pos)
  (seq-find (lambda (ov)
              (and (eq (overlay-get ov 'tip) 'tip)
                   (overlay-get ov 'display)))
            (overlays-in pos (min (1+ pos) (point-max)))))

(defun test--overlay-is-open-at (pos)
  "Overlay exists but display is nil (source visible)."
  (seq-find (lambda (ov)
              (and (eq (overlay-get ov 'tip) 'tip)
                   (not (overlay-get ov 'display))))
            (overlays-in pos (min (1+ pos) (point-max)))))

;; === Test ===

(let ((test-file (make-temp-file "tip-cb-" nil ".typ")))
  (with-temp-file test-file
    (insert "before text $a + b$ after text\n"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 1)
  (test--drain 5)
  (sleep-for 0.5)

  (let ((ranges (treesit-query-range 'typst "((math) @math)")))
    (test--log "Buffer: %S" (buffer-substring-no-properties (point-min) (point-max)))
    (test--log "Math ranges: %S" ranges)

    (when-let* ((frag (car ranges)))
      (let ((frag-beg (car frag))
            (frag-end (cdr frag)))

        ;; Check initial state: overlay rendered
        (test--log "")
        (test--log "=== Initial: overlay rendered? ===")
        (test--log "  overlay with display at %d: %S"
                   frag-beg (not (null (test--overlay-has-display-at frag-beg))))
        (test--log "  overlay with display at %d: %S"
                   (1+ frag-beg) (not (null (test--overlay-has-display-at (1+ frag-beg)))))
        (test--log "  all overlays at %d: %S" frag-beg
                   (mapcar (lambda (ov) (list (overlay-start ov) (overlay-end ov)
                                              (overlay-get ov 'tip)
                                              (not (null (overlay-get ov 'display)))))
                           (overlays-at frag-beg)))
        (test--log "  all overlays-in %d..%d: %S" frag-beg frag-end
                   (mapcar (lambda (ov) (list (overlay-start ov) (overlay-end ov)
                                              (overlay-get ov 'tip)
                                              (not (null (overlay-get ov 'display)))))
                           (overlays-in frag-beg frag-end)))

        ;; Test 1: Position cursor after the fragment, then C-b into it
        (test--log "")
        (test--log "=== Test 1: C-b from after $a + b$ ===")
        (goto-char frag-end)
        (redisplay t)
        (sleep-for 0.3)
        (test--log "  Starting at point=%d (frag-end)" (point))

        ;; C-b one character at a time
        (let ((opened nil))
          (dotimes (i 3)
            (test--move-with-hooks (- (point) 1))
            (test--drain 0.5)
            (test--log "  C-b step %d: point=%d open=%S display=%S"
                       (1+ i) (point)
                       (not (null (test--overlay-is-open-at (point))))
                       (not (null (test--overlay-has-display-at (point)))))
            (when (test--overlay-is-open-at (point))
              (setq opened t)))

          (if opened
              (test--log "  PASS: overlay opened during C-b")
            (test--log "  FAIL: overlay never opened")))

        ;; Test 2: C-b from well after the fragment
        (test--log "")
        (test--log "=== Test 2: C-b from 'after text' into $a + b$ ===")

        ;; First, close any open overlay by moving far away
        (test--move-with-hooks (point-max))
        (test--drain 2)

        ;; Now position after fragment
        (goto-char (+ frag-end 3))
        (redisplay t)
        (sleep-for 0.3)
        (test--log "  Starting at point=%d" (point))

        (let ((opened nil))
          (dotimes (i 8)
            (when (> (point) (point-min))
              (test--move-with-hooks (1- (point)))
              (test--drain 0.3)
              (let ((at-pt (point))
                    (is-open (test--overlay-is-open-at (point)))
                    (has-disp (test--overlay-has-display-at (point))))
                (test--log "  C-b step %d: point=%d in-frag=%S open=%S display=%S"
                           (1+ i) at-pt
                           (and (>= at-pt frag-beg) (< at-pt frag-end))
                           (not (null is-open))
                           (not (null has-disp)))
                (when is-open (setq opened t)))))

          (if opened
              (test--log "  PASS: overlay opened during C-b approach")
            (test--log "  FAIL: overlay never opened"))))))

  (test--log "")
  (let ((passes (length (seq-filter (lambda (l) (string-match-p "PASS" l)) test--lines)))
        (fails (length (seq-filter (lambda (l) (string-match-p "FAIL" l)) test--lines))))
    (test--log "Results: %d PASS, %d FAIL" passes fails))

  (test--write-log)
  (when tip--server-process (tip-shutdown))
  (sleep-for 0.5)
  (kill-buffer)
  (delete-file test-file)
  (kill-emacs (if (= (length (seq-filter (lambda (l) (string-match-p "FAIL" l)) test--lines)) 0) 0 1)))
