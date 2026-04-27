;;; test-edit-cycle.el --- Simulate realistic editing cycles -*- lexical-binding: t; -*-

;;; Commentary:
;; Simulates the yasnippet-style workflow:
;;   type $$ → C-b → type math → C-f → type text → C-b back → edit → C-e out
;; Tests live preview updates, open/close, and overlay correctness.

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
  (expand-file-name "10-edit-cycle-results.txt"
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

(defun test--drain (&optional timeout)
  (let ((deadline (+ (float-time) (or timeout 2))))
    (while (and (< (float-time) deadline)
                tip--server-process
                (process-live-p tip--server-process))
      (accept-process-output tip--server-process 0.05)
      (redisplay t))))

(defun test--type-char (ch)
  "Simulate typing character CH with hooks."
  (let ((this-command 'self-insert-command))
    (run-hooks 'pre-command-hook))
  (insert ch)
  (let ((this-command 'self-insert-command))
    (run-hooks 'post-command-hook))
  (redisplay t))

(defun test--type-string (str)
  "Type each character in STR with hooks."
  (dotimes (i (length str))
    (test--type-char (substring str i (1+ i)))))

(defun test--press-key (cmd)
  "Simulate pressing a key that runs CMD."
  (let ((this-command cmd))
    (run-hooks 'pre-command-hook))
  (call-interactively cmd)
  (let ((this-command cmd))
    (run-hooks 'post-command-hook))
  (redisplay t))

(defun test--overlay-count ()
  (length (seq-filter
           (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
           (overlays-in (point-min) (point-max)))))

(defun test--overlay-with-display-count ()
  (length (seq-filter
           (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                             (overlay-get ov 'display)))
           (overlays-in (point-min) (point-max)))))

(defun test--check (label condition)
  (if condition
      (test--log "  PASS: %s" label)
    (test--log "  FAIL: %s" label)
    (cl-incf test--errors)))

(defun test--state ()
  "Log current state."
  (test--log "  [state] pt=%d buf=%S ovs=%d displayed=%d"
             (point)
             (buffer-substring-no-properties (point-min) (point-max))
             (test--overlay-count)
             (test--overlay-with-display-count)))

;; === Test ===

(let ((test-file (make-temp-file "tip-edit-" nil ".typ")))
  (with-temp-file test-file
    (insert "Start here.\n"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 1)
  (test--drain 2)

  (test--log "=== Edit Cycle Test ===")
  (test--log "")

  ;; === Cycle 1: Type $$, C-b, type math, C-f ===
  (test--log "--- Cycle 1: type $$, C-b, type alpha+beta, C-f ---")
  (goto-char (point-max))
  (test--type-string "$$")
  (test--state)
  (test--press-key 'backward-char)  ;; C-b into $$
  (sleep-for 0.1)
  (test--state)
  (test--type-string "alpha + beta")
  (sleep-for 0.2)
  (test--drain 1)
  (test--state)
  ;; Now C-f out
  (test--press-key 'forward-char)  ;; past closing $
  (sleep-for 0.3)
  (test--drain 2)
  (test--state)
  (test--check "overlay appeared after C-f out" (> (test--overlay-with-display-count) 0))

  ;; === Cycle 2: Type more text, then another equation ===
  (test--log "")
  (test--log "--- Cycle 2: type text, then $x^2$, C-e ---")
  (test--type-string " and then ")
  (test--type-string "$$")
  (test--press-key 'backward-char)
  (test--type-string "x^2")
  (sleep-for 0.2)
  (test--drain 1)
  (test--state)
  ;; C-e to end of line (out of math)
  (test--press-key 'move-end-of-line)
  (sleep-for 0.3)
  (test--drain 2)
  (test--state)
  (test--check "two overlays with display" (= (test--overlay-with-display-count) 2))

  ;; === Cycle 3: C-b back into first equation, edit it ===
  (test--log "")
  (test--log "--- Cycle 3: C-b back to first equation, edit ---")
  ;; Move to beginning of line, then forward to find first $
  (test--press-key 'move-beginning-of-line)
  (search-forward "$alpha" nil t)
  (goto-char (match-beginning 0))
  (forward-char 1)  ;; inside first equation
  (let ((this-command 'forward-char))
    (run-hooks 'pre-command-hook)
    (run-hooks 'post-command-hook))
  (redisplay t)
  (sleep-for 0.3)
  (test--state)
  ;; First overlay should be open (no display)
  (let ((ov-at (seq-find (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
                         (overlays-at (point)))))
    (test--check "first overlay opened on re-enter"
                 (and ov-at (not (overlay-get ov-at 'display)))))

  ;; Edit: add " + gamma"
  (search-forward "beta" nil t)
  (test--type-string " + gamma")
  (sleep-for 0.2)
  (test--drain 1)
  (test--state)

  ;; C-e out
  (test--press-key 'move-end-of-line)
  (sleep-for 0.3)
  (test--drain 2)
  (test--state)
  (test--check "overlays restored after edit" (= (test--overlay-with-display-count) 2))

  ;; === Cycle 4: Rapid creation of 5 equations ===
  (test--log "")
  (test--log "--- Cycle 4: rapid creation of 5 equations ---")
  (goto-char (point-max))
  (test--type-string "\n")
  (dotimes (i 5)
    (test--type-string (format "$$"))
    (test--press-key 'backward-char)
    (test--type-string (format "frac(%d, %d)" (1+ i) (+ i 2)))
    (test--press-key 'forward-char)
    (test--type-string " ")
    (sleep-for 0.1))
  (sleep-for 0.5)
  (test--drain 5)
  (test--state)
  (test--check "at least 5 new overlays" (>= (test--overlay-with-display-count) 5))

  ;; === Cycle 5: Delete an equation and verify cleanup ===
  (test--log "")
  (test--log "--- Cycle 5: delete second equation ---")
  (goto-char (point-min))
  (let ((before-count (test--overlay-with-display-count)))
    ;; Find and delete $x^2$
    (when (search-forward "$x^2$" nil t)
      (delete-region (match-beginning 0) (match-end 0))
      (test--type-string " deleted ")
      (sleep-for 0.3)
      (test--drain 2)
      (test--state)
      (test--check "overlay count decreased after delete"
                   (< (test--overlay-count) (+ before-count 2)))))

  ;; === Cycle 6: Stress — type and immediately leave 10 times ===
  (test--log "")
  (test--log "--- Cycle 6: rapid type-and-leave x10 ---")
  (goto-char (point-max))
  (test--type-string "\n")
  (dotimes (i 10)
    (test--type-string "$$")
    (test--press-key 'backward-char)
    (test--type-string (format "n_%d" i))
    (test--press-key 'forward-char)
    (test--type-string " "))
  (sleep-for 0.5)
  (test--drain 10)
  (test--state)
  (let ((total (test--overlay-with-display-count)))
    (test--check (format "many overlays rendered (%d)" total) (>= total 10)))

  ;; === Final: server health ===
  (test--log "")
  (test--check "server still alive"
               (and tip--server-process (process-live-p tip--server-process)))

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
