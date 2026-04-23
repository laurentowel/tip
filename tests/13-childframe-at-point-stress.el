;;; test-childframe-stress.el --- Stress test childframe at-point following -*- lexical-binding: t; -*-

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
(setq tip-childframe-position 'at-point)

(defvar test--log-file
  (expand-file-name "13-childframe-stress-results.txt"
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

(defun test--cf-pos ()
  "Return childframe position or nil."
  (when (and (frame-live-p tip-childframe--frame)
             (frame-visible-p tip-childframe--frame))
    (frame-position tip-childframe--frame)))

(defun test--cf-visible-p ()
  (and (frame-live-p tip-childframe--frame)
       (frame-visible-p tip-childframe--frame)))

;; === Setup: file with many math fragments across lines ===

(let ((test-file (make-temp-file "tip-cfstress-" nil ".typ")))
  (with-temp-file test-file
    (dotimes (i 20)
      (insert (format "Line %d: text $alpha_%d + beta_%d$ more text $x^%d$ end\n" i i i i))))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 1)
  (test--drain 5)
  (sleep-for 0.5)

  (test--log "=== Childframe At-Point Stress Test ===")
  (test--log "Buffer: 20 lines, ~40 math fragments")

  ;; --- Test 1: rapid show at different positions ---
  (test--log "")
  (test--log "--- Test 1: 50 rapid shows at random positions ---")
  (let ((positions nil)
        (test-svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"30\"><rect width=\"80\" height=\"30\" fill=\"#ddf\"/></svg>"))
    (dotimes (_ 50)
      (goto-char (1+ (random (1- (point-max)))))
      (tip-childframe-show test-svg)
      (redisplay t)
      (let ((pos (test--cf-pos)))
        (when pos (push pos positions))))
    (let ((unique (delete-dups (copy-sequence positions))))
      (test--log "  total positions recorded: %d" (length positions))
      (test--log "  unique positions: %d" (length unique))
      (test--check "childframe moved to multiple positions"
                   (> (length unique) 10))
      (test--check "childframe still alive after rapid repositioning"
                   (test--cf-visible-p))))
  (tip-childframe-hide)

  ;; --- Test 2: show/hide/show rapid cycle ---
  (test--log "")
  (test--log "--- Test 2: 100 show/hide cycles ---")
  (let ((test-svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"20\"><rect width=\"60\" height=\"20\" fill=\"#fdf\"/></svg>")
        (show-count 0)
        (hide-count 0))
    (dotimes (_ 100)
      (goto-char (1+ (random (1- (point-max)))))
      (if (= (random 3) 0)
          (progn (tip-childframe-hide) (cl-incf hide-count))
        (tip-childframe-show test-svg) (cl-incf show-count))
      (redisplay t))
    (test--log "  shows: %d, hides: %d" show-count hide-count)
    (test--check "survived 100 show/hide cycles"
                 (frame-live-p tip-childframe--frame)))
  (tip-childframe-hide)

  ;; --- Test 3: at-point tracks cursor position precisely ---
  (test--log "")
  (test--log "--- Test 3: at-point tracks cursor precisely ---")
  (let ((test-svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"30\"><rect width=\"80\" height=\"30\" fill=\"#ddf\"/></svg>")
        (prev-pos nil)
        (moved-count 0)
        (same-count 0))
    ;; Move to 10 distinct lines and verify childframe follows
    (goto-char (point-min))
    (dotimes (i 10)
      (forward-line 2) ;; skip 2 lines each time
      (tip-childframe-show test-svg)
      (redisplay t)
      (let ((pos (test--cf-pos)))
        (when pos
          (if (and prev-pos (not (equal (cdr prev-pos) (cdr pos))))
              (cl-incf moved-count)
            (when prev-pos (cl-incf same-count)))
          (setq prev-pos pos))))
    (test--log "  cursor moved to 10 lines")
    (test--log "  childframe Y changed: %d times" moved-count)
    (test--log "  childframe Y unchanged: %d times" same-count)
    (test--check "childframe Y follows cursor across lines"
                 (>= moved-count 7)))
  (tip-childframe-hide)

  ;; --- Test 3b: at-point X tracks horizontal cursor ---
  (test--log "")
  (test--log "--- Test 3b: at-point X tracks horizontal position ---")
  (let ((test-svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"><rect width=\"40\" height=\"20\" fill=\"#fdf\"/></svg>")
        (positions nil))
    (goto-char (point-min))
    (dotimes (_ 5)
      (forward-char 10)
      (tip-childframe-show test-svg)
      (redisplay t)
      (push (test--cf-pos) positions))
    (let ((xs (mapcar #'car (delq nil positions))))
      (test--log "  X positions: %S" xs)
      (test--check "childframe X varies with cursor column"
                   (> (length (delete-dups xs)) 2))))
  (tip-childframe-hide)

  ;; --- Test 3c: overlay open/close with hooks (fast, no compile) ---
  (test--log "")
  (test--log "--- Test 3c: overlay open/close with cursor hooks ---")
  (let ((opened 0) (closed 0) (steps 40))
    (goto-char (point-min))
    (dotimes (_ steps)
      (when (< (point) (point-max))
        (let ((this-command 'forward-char))
          (run-hooks 'pre-command-hook))
        (forward-char 1)
        (let ((this-command 'forward-char))
          (run-hooks 'post-command-hook))
        (redisplay t)
        ;; Check overlay state at point
        (let ((ov (seq-find (lambda (o) (eq (overlay-get o 'tip) 'tip))
                            (overlays-at (point)))))
          (when (and ov (not (overlay-get ov 'display)))
            (cl-incf opened)))))
    (test--log "  steps: %d, overlays opened: %d" steps opened)
    (test--check "overlays open during cursor walk"
                 (> opened 0)))

  ;; --- Test 4: at-point stays within frame bounds ---
  (test--log "")
  (test--log "--- Test 4: childframe stays within frame bounds ---")
  (let ((test-svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"100\"><rect width=\"200\" height=\"100\" fill=\"#dfd\"/></svg>")
        (frame-w (frame-pixel-width))
        (frame-h (frame-pixel-height))
        (out-of-bounds 0))
    ;; Show at various positions including edges
    (dolist (pos (list (point-min) (point-max)
                       (/ (point-max) 2)
                       (/ (point-max) 4)
                       (* 3 (/ (point-max) 4))))
      (goto-char (min pos (point-max)))
      (tip-childframe-show test-svg)
      (redisplay t)
      (when-let* ((fpos (test--cf-pos)))
        (when (or (< (car fpos) 0)
                  (< (cdr fpos) 0)
                  (> (car fpos) frame-w)
                  (> (cdr fpos) frame-h))
          (test--log "  OUT OF BOUNDS at point %d: %S" pos fpos)
          (cl-incf out-of-bounds))))
    (test--check "childframe never goes out of frame bounds"
                 (= out-of-bounds 0)))
  (tip-childframe-hide)

  ;; --- Test 5: error then SVG then error rapidly ---
  (test--log "")
  (test--log "--- Test 5: rapid error/SVG alternation ---")
  (let ((test-svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"20\"><rect width=\"60\" height=\"20\" fill=\"#ddf\"/></svg>"))
    (dotimes (_ 30)
      (if (= (random 2) 0)
          (tip-childframe-show test-svg)
        (tip-childframe-show-text "test error message" 'error))
      (redisplay t))
    (test--check "survived rapid error/SVG alternation"
                 (frame-live-p tip-childframe--frame)))

  ;; --- Summary ---
  (test--log "")
  (test--log "=== SUMMARY ===")
  (test--log "Errors: %d" test--errors)
  (if (= test--errors 0)
      (test--log "ALL PASS")
    (test--log "FAILURES: %d" test--errors))

  (test--write-log)
  (tip-childframe-cleanup)
  (when tip--server-process (tip-shutdown))
  (sleep-for 0.5)
  (kill-buffer)
  (delete-file test-file)
  (kill-emacs (if (= test--errors 0) 0 1)))
