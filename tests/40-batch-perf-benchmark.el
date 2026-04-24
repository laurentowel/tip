;;; perf-test.el --- Performance benchmark for TIP -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with (non-batch, needs display for real rendering):
;;   emacs -Q --init-directory /workspace/tip-improve/tip-server/test-output/emacs-sandbox -l /workspace/tip-improve/tip-server/test-output/perf-test.el
;;
;; Results logged to 40-perf-results.txt in the same directory.
;; Emacs exits automatically when done.

;;; Code:

(require 'package)
(package-initialize)

(setq create-lockfiles nil)
(setq make-backup-files nil)
(setq auto-save-default nil)

;; Install deps if needed
(unless (package-installed-p 'typst-ts-mode)
  (package-vc-install
   '(typst-ts-mode :url "https://codeberg.org/meow_king/typst-ts-mode")))
(require 'typst-ts-mode)

(unless (treesit-language-available-p 'typst)
  (setq treesit-language-source-alist
        '((typst "https://github.com/uben0/tree-sitter-typst")))
  (treesit-install-language-grammar 'typst))

;; Load tip
(let ((base (file-name-directory load-file-name)))
  (setq tip-server-executable
        (expand-file-name "../tip-server/target/release/tip-server" base))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base)))

;; Log file
(defvar perf--log-file
  (expand-file-name "40-perf-results.txt" (file-name-directory load-file-name)))

(defvar perf--log-lines nil)

(defun perf--log (fmt &rest args)
  (let ((line (apply #'format fmt args)))
    (push line perf--log-lines)
    (message "PERF: %s" line)))

(defun perf--write-log ()
  (with-temp-file perf--log-file
    (dolist (line (nreverse perf--log-lines))
      (insert line "\n"))))

;; Timing helper
(defmacro perf--time (&rest body)
  "Execute BODY and return (elapsed-seconds . result)."
  (let ((start (make-symbol "start")))
    `(let ((,start (float-time)))
       (let ((result (progn ,@body)))
         (cons (- (float-time) ,start) result)))))

;; Benchmark: compile all fragments in a file
(defun perf--bench-file (filepath label)
  "Open FILEPATH, enable tip-mode, compile all, measure time."
  (perf--log "")
  (perf--log "=== %s ===" label)
  (find-file filepath)
  (switch-to-buffer (current-buffer)) ;; make visible
  (typst-ts-mode)
  (tip-mode 1)
  (redisplay t) ;; force display
  (sleep-for 0.5) ;; let server start

  ;; Count fragments
  (let* ((ranges (treesit-query-range 'typst "((math) @math)"))
         (n-frags (length ranges)))
    (perf--log "File: %s (%d lines, %d bytes, %d math fragments)"
               (file-name-nondirectory filepath)
               (count-lines (point-min) (point-max))
               (buffer-size)
               n-frags)

    ;; Measure: sync buffer
    (let ((timing (perf--time (tip--sync-buffer))))
      (perf--log "Sync buffer: %.3fs" (car timing)))
    (sleep-for 0.2)
    (accept-process-output tip--server-process 1)

    ;; Measure: compile all fragments
    (let* ((compile-done nil)
           (start-time (float-time))
           (fg (tip--color-to-hex (face-attribute 'default :foreground)))
           (preamble (tip--build-preamble))
           (frag-locs (tip-collect-fragment-locations (point-min) (point-max))))
      (perf--log "Fragments to compile: %d" (length frag-locs))
      (tip--send-request
       "compile_fragments"
       `(("uri" . ,(buffer-file-name))
         ("fragments" . ,(vconcat frag-locs))
         ("color" . ,fg)
         ("preamble" . ,preamble))
       (lambda (result)
         (let* ((elapsed (- (float-time) start-time))
                (frags (alist-get 'fragments result))
                (n-ok (seq-count (lambda (f) (> (length (alist-get 'svg f)) 0)) frags)))
           (perf--log "Batch compile: %.3fs total, %d/%d succeeded"
                      elapsed n-ok (length frags))
           (when (> n-ok 0)
             (perf--log "  Per-fragment avg: %.1fms" (* 1000.0 (/ elapsed n-ok))))
           ;; Apply overlays and measure
           (let ((overlay-start (float-time)))
             (tip--apply-fragment-results frags)
             (redisplay t)
             (perf--log "  Overlay creation + redisplay: %.3fs"
                        (- (float-time) overlay-start)))
           (setq compile-done t))))

      ;; Wait for completion
      (let ((deadline (+ (float-time) 120)))
        (while (and (not compile-done)
                    (< (float-time) deadline)
                    tip--server-process
                    (process-live-p tip--server-process))
          (accept-process-output tip--server-process 0.1)))

      (unless compile-done
        (perf--log "TIMEOUT waiting for compilation")))

    ;; Measure: single fragment edit + recompile latency
    ;; Uses real cursor movement with redisplay and sleeps for visibility
    (perf--log "")
    (perf--log "--- Single fragment edit latency ---")
    (tip-clear-buffer)
    (redisplay t)
    (sleep-for 0.3)

    ;; Pick a fragment in the middle (not first/last)
    (let* ((frag-idx (min 5 (1- (length ranges))))
           (bounds (nth frag-idx ranges)))
      (when bounds
        ;; Move cursor visibly to inside the fragment
        (goto-char (1+ (car bounds)))
        (redisplay t)
        (sleep-for 0.5)

        (perf--log "  Cursor inside fragment %d at %d..%d"
                   frag-idx (car bounds) (cdr bounds))

        (let* ((recompile-done nil)
               (start-time nil))

          ;; Run pre-command hook (cursor is inside math)
          (let ((this-command 'forward-char))
            (run-hooks 'pre-command-hook))
          (redisplay t)
          (sleep-for 0.2)

          ;; Actually move cursor past end of fragment
          (goto-char (1+ (cdr bounds)))
          (redisplay t)
          (sleep-for 0.2)

          ;; START TIMING: capture right before post-command triggers compile
          (advice-add 'tip--send-request :before
                      (lambda (method &rest _)
                        (when (string= method "compile_fragments")
                          (setq start-time (float-time))))
                      '((name . perf-timer)))

          ;; Run post-command hook (cursor left math → triggers recompile)
          (let ((this-command 'forward-char))
            (run-hooks 'post-command-hook))
          (redisplay t)

          ;; Wait for overlay to appear
          (let ((deadline (+ (float-time) 10)))
            (while (and (not recompile-done)
                        (< (float-time) deadline)
                        tip--server-process
                        (process-live-p tip--server-process))
              (accept-process-output tip--server-process 0.01)
              (redisplay t)
              (when (seq-find
                     (lambda (ov)
                       (and (eq (overlay-get ov 'tip) 'tip)
                            (overlay-get ov 'display)))
                     (overlays-in (car bounds) (cdr bounds)))
                (setq recompile-done t))))

          ;; Show the overlay
          (redisplay t)
          (sleep-for 0.5)

          (advice-remove 'tip--send-request 'perf-timer)

          (if (and recompile-done start-time)
              (perf--log "Single fragment recompile: %.1fms"
                         (* 1000.0 (- (float-time) start-time)))
            (perf--log "Single fragment recompile: DID NOT COMPLETE")))))

    ;; Don't kill — keep buffer with overlays for inspection
    (redisplay t)))

;; Run benchmarks
(perf--log "TIP Performance Benchmark")
(perf--log "Date: %s" (format-time-string "%Y-%m-%d %H:%M:%S"))
(perf--log "Emacs: %s" emacs-version)
(perf--log "tip-server: %s" tip-server-executable)

(let ((base (file-name-directory load-file-name)))
  (perf--bench-file (expand-file-name "bench_50.typ" base) "50 fragments")
  (perf--bench-file (expand-file-name "bench_200.typ" base) "200 fragments")
  (perf--bench-file (expand-file-name "bench_1000.typ" base) "1000 fragments"))

;; Write results
(perf--write-log)
(message "PERF: Results written to %s" perf--log-file)

;; Show final buffer with overlays, pause for visual check, then exit
(let ((base (file-name-directory load-file-name)))
  (find-file (expand-file-name "bench_200.typ" base))
  (switch-to-buffer (current-buffer))
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 0.5)
  (accept-process-output tip--server-process 0.5)
  (tip-send-all)
  ;; Wait for overlays
  (let ((deadline (+ (float-time) 15)))
    (while (and (< (float-time) deadline)
                tip--server-process
                (process-live-p tip--server-process))
      (accept-process-output tip--server-process 0.1)
      (redisplay t)))
  (goto-char (point-min))
  (redisplay t)
  (sleep-for 1)
  (tip-shutdown)
  (sleep-for 0.5)
  (kill-emacs 0))
