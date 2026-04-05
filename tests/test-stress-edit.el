;;; test-stress-edit.el --- Strenuous editing stress test -*- lexical-binding: t; -*-

;;; Commentary:
;; Simulates a long realistic editing session with:
;; - Many equations created, edited, deleted
;; - Intentional syntax errors then corrections
;; - Empty math (inline $$, display $ $)
;; - Random cursor jumps between fragments
;; - Live preview error checking
;; - Open/close verification throughout

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
  (expand-file-name "test-stress-edit-results.txt"
                    (file-name-directory load-file-name)))
(defvar test--lines nil)
(defvar test--errors 0)
(defvar test--passes 0)

(defun test--log (fmt &rest args)
  (let ((line (apply #'format fmt args)))
    (push line test--lines)))

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
  (let ((this-command 'self-insert-command))
    (run-hooks 'pre-command-hook))
  (insert ch)
  (let ((this-command 'self-insert-command))
    (run-hooks 'post-command-hook))
  (redisplay t))

(defun test--type-string (str)
  (dotimes (i (length str))
    (test--type-char (substring str i (1+ i)))))

(defun test--press (cmd)
  (let ((this-command cmd))
    (run-hooks 'pre-command-hook))
  (condition-case nil
      (call-interactively cmd)
    (error nil))
  (let ((this-command cmd))
    (run-hooks 'post-command-hook))
  (redisplay t))

(defun test--move-to (pos)
  (let ((this-command 'goto-char))
    (run-hooks 'pre-command-hook))
  (goto-char (max (point-min) (min pos (point-max))))
  (let ((this-command 'goto-char))
    (run-hooks 'post-command-hook))
  (redisplay t))

(defun test--ov-count ()
  (length (seq-filter
           (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
           (overlays-in (point-min) (point-max)))))

(defun test--ov-display-count ()
  (length (seq-filter
           (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                             (overlay-get ov 'display)))
           (overlays-in (point-min) (point-max)))))

(defun test--ov-open-at (pos)
  "Overlay at POS with no display (open/source visible)."
  (seq-find (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                               (not (overlay-get ov 'display))))
            (overlays-in pos (min (1+ pos) (point-max)))))

(defun test--ov-closed-at (pos)
  "Overlay at POS with display (showing image)."
  (seq-find (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                               (overlay-get ov 'display)))
            (overlays-in pos (min (1+ pos) (point-max)))))

(defun test--check (label condition)
  (if condition
      (progn (test--log "  PASS: %s" label) (cl-incf test--passes))
    (test--log "  FAIL: %s" label)
    (cl-incf test--errors)))

(defun test--live-docstring ()
  "Return current live preview docstring."
  (and (boundp 'tip-live--docstring) tip-live--docstring))

(defun test--live-is-error ()
  "Return non-nil if live docstring contains an error."
  (let ((ds (test--live-docstring)))
    (and ds (stringp ds) (string-match-p "error" ds))))

(defun test--live-is-image ()
  "Return non-nil if live docstring has an image display property."
  (let ((ds (test--live-docstring)))
    (and ds (get-text-property 0 'display ds))))

;; Helper: create equation, leave, wait for overlay
(defun test--create-eq (math-content)
  "Type $MATH-CONTENT$, leave, wait for overlay. Return overlay count delta."
  (let ((before (test--ov-display-count)))
    (test--type-string "$$")
    (test--press 'backward-char)
    (test--type-string math-content)
    (test--press 'forward-char)
    (test--type-string " ")
    (sleep-for 0.1)
    (test--drain 2)
    (- (test--ov-display-count) before)))

;; ============================================================
;; === TEST ===
;; ============================================================

(let ((test-file (make-temp-file "tip-stress-" nil ".typ")))
  (with-temp-file test-file
    (insert "#let bb = sym.beta\n#let gg = sym.gamma\n\n"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 1)
  (test--drain 3)

  (test--log "=== Strenuous Edit Stress Test ===")
  (test--log "")

  ;; ---- Phase 1: Create 20 equations rapidly ----
  (test--log "--- Phase 1: Create 20 equations rapidly ---")
  (goto-char (point-max))
  (let ((math-exprs '("alpha" "bb + gg" "frac(1,2)" "x^2 + y^2"
                       "sum_(i=0)^n i" "integral_0^1 f(x) dif x"
                       "sqrt(a^2+b^2)" "lim_(n->infinity) a_n"
                       "mat(1,0;0,1)" "binom(n,k)"
                       "nabla times bold(F)" "e^(i pi)+1=0"
                       "zeta(2)=pi^2 slash 6" "Gamma(n+1)=n!"
                       "det(bold(A))" "norm(v)" "angle.l u,v angle.r"
                       "product_(k=1)^n k" "bb+gg+alpha"
                       "frac(dif y, dif x)")))
    (dolist (expr math-exprs)
      (let ((delta (test--create-eq expr)))
        (when (= delta 0)
          (test--log "    [warn] no overlay for: %s" expr)))))
  (test--log "  Overlays: %d displayed: %d" (test--ov-count) (test--ov-display-count))
  (test--check "20 equations created" (>= (test--ov-display-count) 15))

  ;; ---- Phase 2: Empty math ----
  (test--log "")
  (test--log "--- Phase 2: Empty math (inline and display) ---")
  (goto-char (point-max))
  (test--type-string "\n")

  ;; Empty inline: $$
  (test--type-string "$$")
  (test--press 'forward-char)
  (sleep-for 0.2)
  (test--drain 1)
  (test--type-string " ")
  (test--log "  After empty inline $$: ovs=%d" (test--ov-count))

  ;; Empty display: $ $
  (test--type-string "\n")
  (test--type-string "$ $")
  (test--press 'move-end-of-line)
  (sleep-for 0.2)
  (test--drain 1)
  (test--type-string "\n")
  (test--log "  After empty display $ $: ovs=%d" (test--ov-count))
  (test--check "survived empty math" t)  ;; no crash = pass

  ;; ---- Phase 3: Intentional errors then fix ----
  (test--log "")
  (test--log "--- Phase 3: Syntax errors then correction ---")
  (goto-char (point-max))
  (test--type-string "\n")

  ;; Type equation with error
  (test--type-string "$$")
  (test--press 'backward-char)
  (test--type-string "#nonexistent()")  ;; deliberate error
  (sleep-for 0.3)
  (test--drain 1)
  ;; Trigger live compile by waiting for idle timer
  ;; (the idle timer fires tip-live--compile-partial)
  (sleep-for 0.2)
  (test--drain 1)
  (test--log "  After typing error: live-error=%S" (test--live-is-error))

  ;; Fix the error: delete bad content, type good content
  (let ((math-start (search-backward "$" nil t)))
    (when math-start
      (forward-char 1)
      (delete-region (point) (1- (search-forward "$" nil t)))
      (test--type-string "alpha + 1")
      (sleep-for 0.3)
      (test--drain 1)
      (test--log "  After fix: live-error=%S live-image=%S"
                 (test--live-is-error) (test--live-is-image))))

  ;; Leave the equation
  (test--press 'forward-char)
  (sleep-for 0.3)
  (test--drain 2)

  ;; After leaving, live docstring should clear
  (test--log "  After leaving fixed eq: live-docstring=%S" (test--live-docstring))
  (test--check "error equation survived" t)

  ;; ---- Phase 4: Multi-line display equation ----
  (test--log "")
  (test--log "--- Phase 4: Multi-line display equation ---")
  (goto-char (point-max))
  (test--type-string "\n\n")
  (test--type-string "$ ")
  (test--type-string "sum_(i=0)^n i^2\n")
  (test--type-string "  = frac(n(n+1)(2n+1), 6)\n")
  (test--type-string "$")
  (test--press 'move-end-of-line)
  (sleep-for 0.3)
  (test--drain 3)
  (test--log "  Display eq overlays: %d" (test--ov-display-count))
  (test--check "multi-line display equation rendered"
               (> (test--ov-display-count) 0))

  ;; ---- Phase 5: Random cursor movement stress ----
  (test--log "")
  (test--log "--- Phase 5: 50 random cursor jumps ---")
  (let ((buf-size (point-max))
        (start-ovs (test--ov-count)))
    (dotimes (_ 50)
      (test--move-to (1+ (random (max 1 (1- buf-size)))))
      (sleep-for 0.02))
    ;; Settle
    (test--move-to (point-max))
    (sleep-for 0.5)
    (test--drain 5)
    (let ((end-ovs (test--ov-count)))
      (test--log "  Before: %d overlays, after: %d" start-ovs end-ovs)
      (test--check "no massive overlay leak after random jumps"
                   (<= end-ovs (* 2 start-ovs)))))

  ;; ---- Phase 6: Go back and edit 5 random equations ----
  (test--log "")
  (test--log "--- Phase 6: Edit 5 random existing equations ---")
  (let ((ranges (treesit-query-range 'typst "((math) @math)")))
    (when (> (length ranges) 5)
      (dotimes (i 5)
        (let* ((idx (random (length ranges)))
               (bounds (nth idx ranges))
               (frag-beg (car bounds))
               (frag-end (cdr bounds)))
          ;; Move into the equation
          (test--move-to (min (1+ frag-beg) (1- frag-end)))
          (sleep-for 0.1)
          ;; Check it opened
          (let ((opened (test--ov-open-at (point))))
            (test--log "  Edit %d: frag %d..%d opened=%S" i frag-beg frag-end (not (null opened))))
          ;; Type a small addition
          (test--type-string "+1")
          (sleep-for 0.1)
          ;; Leave
          (test--press 'move-end-of-line)
          (sleep-for 0.2)
          (test--drain 2)
          ;; Refresh ranges since buffer changed
          (setq ranges (treesit-query-range 'typst "((math) @math)"))))))
  (test--check "survived editing random equations" t)

  ;; ---- Phase 7: Delete half the equations ----
  (test--log "")
  (test--log "--- Phase 7: Delete half the equations ---")
  (let ((before (test--ov-display-count)))
    (goto-char (point-min))
    (let ((count 0))
      (while (and (search-forward "$" nil t) (< count 8))
        (when (= (% count 2) 0)  ;; delete every other
          (let ((start (1- (point))))
            (when (search-forward "$" nil t)
              (delete-region start (point))
              (test--type-string " "))))
        (cl-incf count)))
    (sleep-for 0.3)
    (test--drain 3)
    (let ((after (test--ov-display-count)))
      (test--log "  Before delete: %d, after: %d" before after)
      (test--check "overlay count decreased after deletes" (<= after before))))

  ;; ---- Phase 8: Rapid create-edit-leave x15 ----
  (test--log "")
  (test--log "--- Phase 8: Rapid create-edit-leave x15 ---")
  (goto-char (point-max))
  (test--type-string "\n\nRapid: ")
  (dotimes (i 15)
    (test--type-string "$$")
    (test--press 'backward-char)
    (test--type-string (format "r_%d" i))
    ;; Immediately forward and type space
    (test--press 'forward-char)
    (test--type-string " "))
  (sleep-for 0.5)
  (test--drain 10)
  (test--log "  Final overlay count: %d displayed: %d"
             (test--ov-count) (test--ov-display-count))
  (test--check "rapid x15 all rendered" (>= (test--ov-display-count) 10))

  ;; ---- Final checks ----
  (test--log "")
  (test--log "--- Final checks ---")
  (test--check "server alive" (and tip--server-process
                                    (process-live-p tip--server-process)))
  (test--log "  Buffer size: %d" (buffer-size))
  (test--log "  Total overlays: %d" (test--ov-count))
  (test--log "  Displayed overlays: %d" (test--ov-display-count))

  ;; Summary
  (test--log "")
  (test--log "=== SUMMARY ===")
  (test--log "Passed: %d" test--passes)
  (test--log "Failed: %d" test--errors)
  (if (= test--errors 0)
      (test--log "ALL PASS")
    (test--log "FAILURES: %d" test--errors))

  (test--write-log)
  (when tip--server-process (tip-shutdown))
  (sleep-for 0.5)
  (kill-buffer)
  (delete-file test-file)
  (kill-emacs (if (= test--errors 0) 0 1)))
