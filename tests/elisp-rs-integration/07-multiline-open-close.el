;;; 07-multiline-open-close.el --- Test open/close for all fragment types and directions -*- lexical-binding: t; -*-

;;; Commentary:
;; Comprehensive open/close test covering:
;; - Fragment types: inline math, multi-line displayed math, CeTZ diagrams, Fletcher diagrams
;; - Exit directions: C-f, C-b, C-n, C-p, M-f, M-b, goto-char
;; - Edge case: # prefix on diagrams (overlay includes # but treesit call node starts after it)

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
  (expand-file-name "07-multiline-open-close-results.txt"
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

(defun test--move (target command)
  "Simulate moving to TARGET with COMMAND as this-command."
  (let ((this-command command))
    (run-hooks 'pre-command-hook))
  (goto-char target)
  (let ((this-command command))
    (run-hooks 'post-command-hook))
  (redisplay t))

(defun test--exec (command)
  "Execute COMMAND interactively with proper hooks."
  (let ((this-command command))
    (run-hooks 'pre-command-hook))
  (call-interactively command)
  (let ((this-command command))
    (run-hooks 'post-command-hook))
  (redisplay t))

(defun test--tip-overlay-at (pos)
  "Return tip overlay at POS or nil."
  (or (seq-find (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
                (overlays-at pos))
      (seq-find (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
                (overlays-in pos (min (1+ pos) (point-max))))))

(defun test--overlay-is-closed (pos)
  "Non-nil if tip overlay at POS has display (showing SVG)."
  (let ((ov (test--tip-overlay-at pos)))
    (and ov (overlay-get ov 'display))))

(defun test--overlay-is-open (pos)
  "Non-nil if tip overlay at POS exists but has no display."
  (let ((ov (test--tip-overlay-at pos)))
    (and ov (not (overlay-get ov 'display)))))

(defun test--enter-then-exit (frag-inside exit-pos command label)
  "Enter fragment at FRAG-INSIDE, exit to EXIT-POS via COMMAND, check close."
  (test--move (point-min) 'forward-char)
  (redisplay t)
  (test--move frag-inside 'forward-char)
  (test--drain 0.5)
  (let ((opened (test--overlay-is-open frag-inside)))
    (unless opened
      (test--log "    WARNING: overlay didn't open at %d" frag-inside)))
  (test--move exit-pos command)
  (test--drain 1)
  (sleep-for 0.2)
  (let ((closed (test--overlay-is-closed frag-inside)))
    (test--log "    %s: enter@%d exit@%d → closed=%S"
               label frag-inside exit-pos (not (null closed)))
    (test--check (format "%s: closes" label) closed)))

(defun test--enter-then-exec-until-exit (frag-inside frag-beg command label)
  "Enter fragment, then call COMMAND repeatedly until point < FRAG-BEG."
  (test--move (point-min) 'forward-char)
  (redisplay t)
  (test--move frag-inside 'forward-char)
  (test--drain 0.5)
  (let ((max-steps 200) (steps 0))
    (while (and (< steps max-steps) (>= (point) frag-beg))
      (test--exec command)
      (cl-incf steps))
    (test--drain 1)
    (sleep-for 0.2)
    (let ((closed (test--overlay-is-closed frag-inside)))
      (test--log "    %s: %d steps, point=%d (beg=%d) → closed=%S"
                 label steps (point) frag-beg (not (null closed)))
      (test--check (format "%s: closes" label) closed))))

;; === Tests ===

(let ((test-file (make-temp-file "tip-multiline-" nil ".typ")))
  (with-temp-file test-file
    (insert "\
#import \"@preview/cetz:0.4.2\"
#import \"@preview/fletcher:0.5.8\" as fletcher: diagram, node, edge

Inline math: $a + b$ here.

Multi-line displayed:
$
  a + b + c
$

CeTZ diagram:
#cetz.canvas({
  import cetz.draw: *
  circle((0, 0), radius: 1)
})

Fletcher diagram:
#diagram(
  node((0, 0), $A$),
  edge(\"->\" ),
  node((1, 0), $B$),
)

End.
"))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (tip-live-teardown)
  (sleep-for 1)
  (tip-send-all)
  (test--drain 5)
  (sleep-for 0.5)

  (test--log "=== Comprehensive Open/Close Test ===")

  ;; Gather all fragment overlays
  (let* ((all-ovs (seq-filter (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
                              (overlays-in (point-min) (point-max))))
         (ov-info (mapcar (lambda (ov)
                            (list (overlay-start ov) (overlay-end ov)
                                  (buffer-substring-no-properties
                                   (overlay-start ov)
                                   (min (+ (overlay-start ov) 20)
                                        (overlay-end ov)))))
                          all-ovs)))
    (test--log "  compiled overlays: %d" (length all-ovs))
    (dolist (info ov-info)
      (test--log "    [%d-%d] %S..." (nth 0 info) (nth 1 info) (nth 2 info))))

  ;; Find fragments by type
  (let* ((math-ranges (treesit-query-range 'typst "((math) @math)"))
         (inline-frag (seq-find
                       (lambda (r) (= (line-number-at-pos (car r))
                                      (line-number-at-pos (cdr r))))
                       math-ranges))
         (multiline-frag (seq-find
                          (lambda (r) (not (= (line-number-at-pos (car r))
                                              (line-number-at-pos (cdr r)))))
                          math-ranges))
         ;; Find diagram overlays (start with #)
         (diagram-ovs (seq-filter
                       (lambda (ov)
                         (and (eq (overlay-get ov 'tip) 'tip)
                              (eq (char-after (overlay-start ov)) ?#)
                              ;; Not an import
                              (> (- (overlay-end ov) (overlay-start ov)) 10)))
                       (overlays-in (point-min) (point-max))))
         (cetz-ov (seq-find
                   (lambda (ov)
                     (string-match-p "canvas"
                                     (buffer-substring-no-properties
                                      (overlay-start ov)
                                      (min (+ (overlay-start ov) 30)
                                           (overlay-end ov)))))
                   diagram-ovs))
         (fletcher-ov (seq-find
                       (lambda (ov)
                         (string-match-p "diagram"
                                         (buffer-substring-no-properties
                                          (overlay-start ov)
                                          (min (+ (overlay-start ov) 30)
                                               (overlay-end ov)))))
                       diagram-ovs)))

    ;; ==========================================
    ;; Test Group 1: Inline math (single line)
    ;; ==========================================
    (when inline-frag
      (test--log "")
      (test--log "--- Inline math: %S ---" inline-frag)
      (let* ((beg (car inline-frag))
             (end (cdr inline-frag))
             (inside (1+ beg))
             (before (max (1- beg) (point-min)))
             (after (min (1+ end) (point-max))))
        (test--enter-then-exit inside after 'forward-char "C-f out")
        (test--enter-then-exit inside before 'backward-char "C-b out")
        ;; goto-char (simulates avy/isearch jump)
        (test--enter-then-exit inside after 'goto-char "goto-char fwd")
        (test--enter-then-exit inside before 'goto-char "goto-char bkw")))

    ;; ==========================================
    ;; Test Group 2: Multi-line displayed equation
    ;; ==========================================
    (when multiline-frag
      (test--log "")
      (test--log "--- Multi-line displayed math: %S ---" multiline-frag)
      (let* ((beg (car multiline-frag))
             (end (cdr multiline-frag))
             (inside (/ (+ beg end) 2))
             (before (max (1- beg) (point-min)))
             (after (min (1+ end) (point-max)))
             (line-above (save-excursion (goto-char beg) (forward-line -1) (point)))
             (line-below (save-excursion (goto-char end) (forward-line 1) (point))))
        (test--enter-then-exit inside after 'forward-char "C-f out")
        (test--enter-then-exit inside before 'backward-char "C-b out")
        (test--enter-then-exit inside line-below 'next-line "C-n out")
        (test--enter-then-exit inside line-above 'previous-line "C-p out")
        ;; Real repeated movement commands
        (test--enter-then-exec-until-exit inside beg 'backward-char "real C-b repeated")
        (test--enter-then-exec-until-exit inside beg 'previous-line "real C-p repeated")))

    ;; ==========================================
    ;; Test Group 3: CeTZ diagram
    ;; ==========================================
    (when cetz-ov
      (test--log "")
      (let* ((beg (overlay-start cetz-ov))
             (end (overlay-end cetz-ov))
             (inside (+ beg 5))  ;; past the #cetz
             (at-hash beg)       ;; the # character itself
             (before (max (1- beg) (point-min)))
             (after (min (1+ end) (point-max)))
             (line-above (save-excursion (goto-char beg) (forward-line -1) (point)))
             (line-below (save-excursion (goto-char end) (forward-line 1) (point))))
        (test--log "--- CeTZ diagram: [%d-%d] ---" beg end)

        ;; Basic directions
        (test--enter-then-exit inside after 'forward-char "C-f out")
        (test--enter-then-exit inside before 'backward-char "C-b out")
        (test--enter-then-exit inside line-below 'next-line "C-n out")
        (test--enter-then-exit inside line-above 'previous-line "C-p out")
        ;; Word movement
        (test--enter-then-exit inside after 'forward-word "M-f out")
        (test--enter-then-exit inside before 'backward-word "M-b out")
        ;; goto-char
        (test--enter-then-exit inside before 'goto-char "goto-char out")

        ;; KEY BUG TEST: cursor at # position
        (test--log "")
        (test--log "  # prefix edge cases:")
        ;; Enter at #, then exit backward
        (test--enter-then-exit at-hash before 'backward-char "C-b from #")
        ;; Enter at #, then exit up
        (test--enter-then-exit at-hash line-above 'previous-line "C-p from #")
        ;; Enter just past #, C-b to #, then C-b out
        (test--enter-then-exec-until-exit (1+ at-hash) beg 'backward-char
                                          "real C-b through # and out")))

    ;; ==========================================
    ;; Test Group 4: Fletcher diagram
    ;; ==========================================
    (when fletcher-ov
      (test--log "")
      (let* ((beg (overlay-start fletcher-ov))
             (end (overlay-end fletcher-ov))
             (inside (+ beg 5))
             (at-hash beg)
             (before (max (1- beg) (point-min)))
             (after (min (1+ end) (point-max)))
             (line-above (save-excursion (goto-char beg) (forward-line -1) (point)))
             (line-below (save-excursion (goto-char end) (forward-line 1) (point))))
        (test--log "--- Fletcher diagram: [%d-%d] ---" beg end)

        (test--enter-then-exit inside after 'forward-char "C-f out")
        (test--enter-then-exit inside before 'backward-char "C-b out")
        (test--enter-then-exit inside line-below 'next-line "C-n out")
        (test--enter-then-exit inside line-above 'previous-line "C-p out")
        ;; # prefix
        (test--enter-then-exit at-hash before 'backward-char "C-b from #")
        (test--enter-then-exec-until-exit (1+ at-hash) beg 'backward-char
                                          "real C-b through # and out"))))

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
