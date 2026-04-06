;;; test-childframe.el --- Automated test for tip-childframe -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests childframe show/hide/position lifecycle.
;; Run: emacs -Q --init-directory tests/emacs-sandbox --debug-init -l tests/test-childframe.el

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
  (expand-file-name "test-childframe-results.txt"
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

;; === Tests ===

(let ((test-file (make-temp-file "tip-cf-" nil ".typ")))
  (with-temp-file test-file
    (insert "Hello $alpha + beta$ world $x^2$ end\n"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 1)
  (test--drain 3)

  (test--log "=== Childframe Tests ===")

  ;; --- Test 1: childframe initially hidden ---
  (test--log "")
  (test--log "--- Test 1: childframe initially hidden ---")
  (test--check "frame nil or invisible"
               (or (null tip-childframe--frame)
                   (not (frame-live-p tip-childframe--frame))
                   (not (frame-visible-p tip-childframe--frame))))

  ;; --- Test 2: show SVG manually ---
  (test--log "")
  (test--log "--- Test 2: show SVG ---")
  (let ((test-svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\"><rect width=\"100\" height=\"50\" fill=\"#ddf\"/><text x=\"10\" y=\"30\">test</text></svg>"))
    (tip-childframe-show test-svg)
    (redisplay t)
    (sleep-for 0.3)
    (test--check "frame exists" (frame-live-p tip-childframe--frame))
    (test--check "frame visible" (frame-visible-p tip-childframe--frame))
    (test--check "buffer has content"
                 (> (buffer-size (tip-childframe--ensure-buffer)) 0)))

  ;; --- Test 3: hide ---
  (test--log "")
  (test--log "--- Test 3: hide ---")
  (tip-childframe-hide)
  (redisplay t)
  (sleep-for 0.2)
  (test--check "frame hidden"
               (not (frame-visible-p tip-childframe--frame)))

  ;; --- Test 4: show text (error) ---
  (test--log "")
  (test--log "--- Test 4: show error text ---")
  (tip-childframe-show-text "unknown variable: foo" 'error)
  (redisplay t)
  (sleep-for 0.3)
  (test--check "frame visible for error"
               (frame-visible-p tip-childframe--frame))
  (test--check "buffer contains error text"
               (with-current-buffer (tip-childframe--ensure-buffer)
                 (string-match-p "unknown variable"
                                 (buffer-substring-no-properties
                                  (point-min) (point-max)))))
  (tip-childframe-hide)

  ;; --- Test 5: live preview triggers on cursor in math ---
  (test--log "")
  (test--log "--- Test 5: live preview on idle in math ---")
  (goto-char (point-min))
  (search-forward "$alpha")
  (backward-char 3) ;; inside $alpha + beta$
  (redisplay t)
  ;; Manually trigger the idle compile
  (tip-live--compile-partial)
  (test--drain 5)
  (sleep-for 0.5)
  (redisplay t)
  (test--check "childframe visible after live compile"
               (and (frame-live-p tip-childframe--frame)
                    (frame-visible-p tip-childframe--frame)))
  (test--check "buffer has SVG content"
               (with-current-buffer (tip-childframe--ensure-buffer)
                 (let ((content (buffer-substring-no-properties
                                 (point-min) (point-max))))
                   ;; The buffer should have an image (display property)
                   (or (get-text-property (point-min) 'display
                                          (tip-childframe--ensure-buffer))
                       (> (length content) 0)))))

  ;; --- Test 6: childframe hides when cursor leaves math ---
  (test--log "")
  (test--log "--- Test 6: hide on leaving math ---")
  (goto-char (point-min)) ;; outside math
  (tip-live--compile-partial)
  (redisplay t)
  (sleep-for 0.3)
  (test--check "childframe hidden outside math"
               (or (null tip-childframe--frame)
                   (not (frame-visible-p tip-childframe--frame))))

  ;; --- Test 7: position modes ---
  (test--log "")
  (test--log "--- Test 7: position modes ---")
  ;; at-point
  (setq tip-childframe-position 'at-point)
  (tip-childframe-show "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50\" height=\"30\"><rect width=\"50\" height=\"30\" fill=\"#dfd\"/></svg>")
  (redisplay t)
  (sleep-for 0.2)
  (let ((pos-at (frame-position tip-childframe--frame)))
    (test--log "  at-point position: %S" pos-at)
    (test--check "at-point has valid position"
                 (and (numberp (car pos-at)) (numberp (cdr pos-at)))))
  (tip-childframe-hide)

  ;; all corner modes
  (let ((test-svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50\" height=\"30\"><rect width=\"50\" height=\"30\" fill=\"#fdd\"/></svg>"))
    (dolist (mode '(top-right top-left bottom-right bottom-left))
      (setq tip-childframe-position mode)
      (tip-childframe-show test-svg)
      (redisplay t)
      (sleep-for 0.2)
      (let ((pos (frame-position tip-childframe--frame)))
        (test--log "  %s position: %S" mode pos)
        (test--check (format "%s has valid position" mode)
                     (and (numberp (car pos)) (numberp (cdr pos))
                          (>= (car pos) 0) (>= (cdr pos) 0))))
      (tip-childframe-hide)))
  (setq tip-childframe-position 'top-right) ;; restore default

  ;; at-point follows cursor
  (test--log "")
  (test--log "--- Test 7b: at-point follows cursor ---")
  (setq tip-childframe-position 'at-point)
  (goto-char (point-min))
  (tip-childframe-show "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50\" height=\"30\"><rect width=\"50\" height=\"30\" fill=\"#ddf\"/></svg>")
  (redisplay t)
  (sleep-for 0.2)
  (let ((pos1 (cons (car (frame-position tip-childframe--frame))
                     (cdr (frame-position tip-childframe--frame)))))
    (goto-char (point-max))
    (tip-childframe-show "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50\" height=\"30\"><rect width=\"50\" height=\"30\" fill=\"#ddf\"/></svg>")
    (redisplay t)
    (sleep-for 0.2)
    (let ((pos2 (frame-position tip-childframe--frame)))
      (test--log "  pos at point-min: %S" pos1)
      (test--log "  pos at point-max: %S" pos2)
      (test--check "at-point position changes with cursor"
                   (not (equal pos1 pos2)))))
  (tip-childframe-hide)
  (setq tip-childframe-position 'top-right)

  ;; --- Test 8: cleanup ---
  (test--log "")
  (test--log "--- Test 8: cleanup ---")
  (tip-childframe-cleanup)
  (test--check "frame destroyed" (null tip-childframe--frame))
  (test--check "buffer destroyed" (null tip-childframe--buffer))

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
