;;; 09-theme-perf-1000.el --- Benchmark theme-change recompilation with 1000 fragments -*- lexical-binding: t; -*-

;;; Commentary:
;; Generates a .typ file with ~1000 distinct math fragments,
;; compiles them all, then measures recompilation time.
;; GUI-friendly: uses timers instead of blocking loops.
;;
;; Run with GUI:  emacs -Q -l tests/09-theme-perf-1000.el

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

(defvar perf--results nil)
(defvar perf--log-file
  (expand-file-name "09-theme-perf-1000-results.txt"
                    (file-name-directory load-file-name)))

(defun perf--log (fmt &rest args)
  (let ((line (apply #'format fmt args)))
    (push line perf--results)
    (message "PERF: %s" line)))

(defun perf--write-log ()
  (with-temp-file perf--log-file
    (dolist (line (nreverse perf--results))
      (insert line "\n"))))

(defun perf--count-overlays ()
  (length (seq-filter (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                                        (overlay-get ov 'display)))
                      (overlays-in (point-min) (point-max)))))

(defvar perf--pending-id nil)
(defvar perf--start-time nil)

(defun perf--wait-for-compile (callback &optional label)
  "Poll until no pending callbacks remain, then call CALLBACK.
Non-blocking — yields to event loop between checks."
  (let ((check-fn nil)
        (timeout 60)
        (start (float-time)))
    (setq check-fn
          (lambda ()
            (if (or (= 0 (hash-table-count tip--pending-callbacks))
                    (> (- (float-time) start) timeout))
                (progn
                  (when label
                    (let* ((elapsed (* 1000 (- (float-time) perf--start-time)))
                           (count (perf--count-overlays)))
                      (perf--log "  %s: %d overlays, %.0fms total, %.1fms/frag"
                                 label count elapsed
                                 (if (> count 0) (/ elapsed count) 0))))
                  (funcall callback))
              (run-with-timer 0.1 nil check-fn))))
    (run-with-timer 0.1 nil check-fn)))

;; === Generate file and run benchmark ===

(let ((test-file (make-temp-file "tip-perf1k-" nil ".typ")))
  (with-temp-file test-file
    (dotimes (i 1000)
      (let ((variant (% i 10)))
        (insert
         (pcase variant
           (0 (format "Line %d: $a_%d + b_%d$\n" i i i))
           (1 (format "Line %d: $x^%d + y^%d = z^%d$\n" i (1+ i) (1+ i) (1+ i)))
           (2 (format "Line %d: $integral_%d^%d f(t) dif t$\n" i i (+ i 10)))
           (3 (format "Line %d: $sum_(k=%d)^%d k^2$\n" i i (+ i 100)))
           (4 (format "Line %d: $frac(%d, %d)$\n" i (1+ i) (+ i 2)))
           (5 (format "Line %d: $sqrt(%d)$\n" i (1+ (* i i))))
           (6 (format "Line %d: $alpha_%d + beta_%d$\n" i i i))
           (7 (format "Line %d: $lim_(n -> infinity) %d / n$\n" i (1+ i)))
           (8 (format "Line %d: $mat(%d, %d; %d, %d)$\n" i i (1+ i) (+ i 2) (+ i 3)))
           (9 (format "Line %d: $arrow.r.double quad %d$\n" i i)))))))

  (find-file test-file)
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (tip-live-teardown)

  (perf--log "=== Theme Change Performance: 1000 Fragments ===")
  (let ((n (length (treesit-query-range 'typst "((math) @math)"))))
    (perf--log "Fragments detected: %d" n))

  ;; Step 1: initial compile
  (run-with-timer
   1.5 nil
   (lambda ()
     (perf--log "")
     (perf--log "--- Step 1: Initial compile ---")
     (setq perf--start-time (float-time))
     (tip-render-all)
     (perf--wait-for-compile
      (lambda ()
        ;; Step 2: actual theme change → dark
        (perf--log "")
        (perf--log "--- Step 2: Theme change to modus-vivendi (dark) ---")
        (setq perf--start-time (float-time))
        (load-theme 'modus-vivendi t)
        (perf--wait-for-compile
         (lambda ()
           ;; Step 3: theme change → light
           (perf--log "")
           (perf--log "--- Step 3: Theme change to modus-operandi (light) ---")
           (setq perf--start-time (float-time))
           (load-theme 'modus-operandi t)
           (perf--wait-for-compile
            (lambda ()
              ;; Step 4: visible-only for comparison
              (perf--log "")
              (perf--log "--- Step 4: Visible-only recompile ---")
              (goto-char (point-min))
              (redisplay t)
              (setq perf--start-time (float-time))
              (tip-send-nbd)
              (perf--wait-for-compile
               (lambda ()
                 (perf--log "")
                 (perf--log "=== DONE ===")
                 (perf--write-log)
                 (message "Results written to %s" perf--log-file))
               "visible-only"))
            "modus-operandi"))
         "modus-vivendi"))
      "initial compile"))))
