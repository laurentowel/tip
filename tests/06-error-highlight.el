;;; 06-error-highlight.el --- Test error fragment highlighting -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests that fragments which fail to compile get highlighted:
;; 1. Bad math gets a tip overlay with error face after explicit compile
;; 2. Good math still renders normally alongside errors
;; 3. Entering an error fragment clears the highlight
;; 4. Rapid error/fix cycles don't leak overlays
;; 5. Multiple error fragments all get highlighted

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
  (expand-file-name "06-error-highlight-results.txt"
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
(defun test--move (target)
  (let ((this-command 'forward-char))
    (run-hooks 'pre-command-hook))
  (goto-char target)
  (let ((this-command 'forward-char))
    (run-hooks 'post-command-hook))
  (redisplay t))
(defun test--type-string (str)
  (dotimes (i (length str))
    (let ((this-command 'self-insert-command))
      (run-hooks 'pre-command-hook))
    (insert (substring str i (1+ i)))
    (let ((this-command 'self-insert-command))
      (run-hooks 'post-command-hook))
    (redisplay t)))

(defun test--tip-overlays ()
  "All tip overlays in buffer."
  (seq-filter (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
              (overlays-in (point-min) (point-max))))
(defun test--error-overlays ()
  "Tip overlays that have the error face (no display image)."
  (seq-filter (lambda (ov)
                (and (eq (overlay-get ov 'tip) 'tip)
                     (eq (overlay-get ov 'face) 'tip-error-face)))
              (overlays-in (point-min) (point-max))))
(defun test--rendered-overlays ()
  "Tip overlays that have a display image."
  (seq-filter (lambda (ov)
                (and (eq (overlay-get ov 'tip) 'tip)
                     (overlay-get ov 'display)))
              (overlays-in (point-min) (point-max))))

;; === Tests ===

(let ((test-file (make-temp-file "tip-errhighlight-" nil ".typ")))
  (with-temp-file test-file
    (insert "Good math $a + b$ here.\n\n"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (tip-live-teardown)
  (sleep-for 1)
  (test--drain 3)

  (test--log "=== Error Highlight Test ===")

  ;; --- Test 1: bad math gets error highlight after explicit compile ---
  (test--log "")
  (test--log "--- Test 1: bad math gets error highlight ---")
  (goto-char (point-max))
  (test--type-string "$xxxxx$ ")
  ;; Explicitly compile all fragments
  (tip-send-all)
  (test--drain 3)
  (redisplay t)
  (let ((errs (test--error-overlays))
        (all (test--tip-overlays)))
    (test--log "  error overlays: %d, total tip overlays: %d"
               (length errs) (length all))
    (test--check "bad fragment has error highlight" (> (length errs) 0)))

  ;; --- Test 2: good math renders alongside errors ---
  (test--log "")
  (test--log "--- Test 2: good math alongside bad ---")
  (let ((rendered (test--rendered-overlays))
        (errs (test--error-overlays)))
    (test--log "  rendered: %d, errors: %d" (length rendered) (length errs))
    (test--check "good math has rendered overlay" (> (length rendered) 0)))

  ;; --- Test 3: entering error fragment clears highlight ---
  (test--log "")
  (test--log "--- Test 3: entering error fragment opens it ---")
  ;; Move outside first, find target without moving, then enter
  (test--move (point-min))
  (let ((target (save-excursion
                  (goto-char (point-min))
                  (when (search-forward "$xxxxx" nil t)
                    (1+ (match-beginning 0))))))
    (when target
      (test--move target)
      (redisplay t)
      (sleep-for 0.2)))
  (let ((ov-at-point (seq-find
                      (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
                      (overlays-at (point)))))
    (test--log "  overlay at point: %S, face: %S"
               (and ov-at-point t)
               (and ov-at-point (overlay-get ov-at-point 'face)))
    (test--check "error face cleared on enter"
                 (or (null ov-at-point)
                     (null (overlay-get ov-at-point 'face)))))

  ;; --- Test 4: rapid error/fix cycles ---
  (test--log "")
  (test--log "--- Test 4: rapid error/fix cycles ---")
  (erase-buffer)
  (insert "Start\n")
  (dotimes (i 5)
    (goto-char (point-max))
    (test--type-string (format "$badvar%d$ " i))
    (tip-send-all)
    (test--drain 1)
    ;; Fix by deleting bad math and replacing with good
    (goto-char (point-min))
    (when (search-forward (format "$badvar%d$" i) nil t)
      (delete-region (match-beginning 0) (match-end 0))
      (test--type-string (format "$a + %d$" i)))
    (tip-send-all)
    (test--drain 1))
  (let ((errs (test--error-overlays)))
    (test--log "  error overlays after 5 fix cycles: %d" (length errs))
    (test--check "no stale error overlays after fix cycles" (= (length errs) 0)))

  ;; --- Test 5: many errors at once ---
  (test--log "")
  (test--log "--- Test 5: many errors at once ---")
  (erase-buffer)
  (insert "Start\n")
  (dotimes (i 8)
    (goto-char (point-max))
    (test--type-string (format "$undefined%d$ " i)))
  (tip-send-all)
  (test--drain 5)
  (redisplay t)
  (let ((errs (test--error-overlays)))
    (test--log "  error highlights for 8 bad fragments: %d" (length errs))
    (test--check "multiple error highlights shown" (> (length errs) 3)))

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
