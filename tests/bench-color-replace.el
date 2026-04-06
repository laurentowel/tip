;;; bench-color-replace.el --- Benchmark SVG color replacement in elisp -*- lexical-binding: t; -*-

;;; Commentary:
;; Measures time to do string replacement on SVG data for 1000 overlays.

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
  (load (expand-file-name "../tip.el" base))
  (load (expand-file-name "test-harness.el" base)))

(setq tip-enable-debug nil)

(defvar bench--log-file
  (expand-file-name "bench-color-replace-results.txt"
                    (file-name-directory load-file-name)))

(test-harness-run
 "bench-color-replace"
 (lambda ()
   (let ((test-file (make-temp-file "tip-bench-color-" nil ".typ")))
     (unwind-protect
         (progn
           (find-file test-file)
           (switch-to-buffer (current-buffer))
           (dotimes (i 50)
             (insert (format "Eq %d: $a_%d + b_%d + integral_0^1 f_%d (x) dif x$ text.\n" i i i i)))
           (save-buffer)
           (typst-ts-mode)
           (tip-mode 1)
           (tip-live-teardown)
           (sleep-for 1)
           (tip-render-all)

           ;; Wait for compilation
           (let ((deadline (+ (float-time) 20)))
             (while (and (< (float-time) deadline)
                         tip--server-process
                         (process-live-p tip--server-process)
                         (> (hash-table-count tip--pending-callbacks) 0))
               (accept-process-output tip--server-process 0.1)
               (redisplay t)))

           ;; Extract SVGs from overlays
           (let* ((real-svgs
                   (delq nil
                         (mapcar (lambda (ov)
                                   (when (eq (overlay-get ov 'tip) 'tip)
                                     (let ((disp (overlay-get ov 'display)))
                                       (when disp
                                         ;; display is ((image :type svg :data ...))
                                         (plist-get (cdr (car-safe disp)) :data)))))
                                 (overlays-in (point-min) (point-max)))))
                  (svg-count (length real-svgs))
                  (results nil))

             (push "=== SVG Color Replacement Benchmark ===" results)
             (push (format "Real SVGs collected: %d" svg-count) results)
             (when real-svgs
               (push (format "Avg SVG size: %d bytes"
                             (/ (apply #'+ (mapcar #'length real-svgs)) svg-count))
                     results))

             ;; Scale to 1000
             (let ((svgs-1000 nil))
               (when (> svg-count 0)
                 (dotimes (i 1000)
                   (push (nth (% i svg-count) real-svgs) svgs-1000))
                 (setq svgs-1000 (nreverse svgs-1000)))

               (let* ((old-fg (tip--color-to-hex (face-attribute 'default :foreground)))
                      (new-fg "#ffffff")
                      (old-bg (tip--color-to-hex (face-attribute 'default :background)))
                      (new-bg "#1d2021")
                      (n (max 1 (length svgs-1000))))

                 ;; Bench 1: string-replace only
                 (push "" results)
                 (push (format "--- Elisp string-replace: %d SVGs ---" n) results)
                 (let* ((t0 (float-time))
                        (_replaced
                         (mapcar (lambda (svg)
                                   (string-replace old-bg new-bg
                                                   (string-replace old-fg new-fg svg)))
                                 svgs-1000))
                        (elapsed-ms (* 1000 (- (float-time) t0))))
                   (push (format "  Time: %.1fms (%.3fms/svg)" elapsed-ms (/ elapsed-ms (float n)))
                         results)
                   (push (format "  Total bytes: %d"
                                 (apply #'+ (mapcar #'length svgs-1000)))
                         results))

                 ;; Bench 2: replace + rebuild image spec
                 (push "" results)
                 (push (format "--- Elisp replace + image spec rebuild: %d ---" n) results)
                 (let* ((t0 (float-time))
                        (_specs
                         (mapcar (lambda (svg)
                                   (let ((new-svg (string-replace old-bg new-bg
                                                                  (string-replace old-fg new-fg svg))))
                                     (list (list 'image
                                                 :type 'svg
                                                 :data new-svg
                                                 :height '(10.0 . em)
                                                 :ascent 85
                                                 :pointer 'hand))))
                                 svgs-1000))
                        (elapsed-ms (* 1000 (- (float-time) t0))))
                   (push (format "  Time: %.1fms (%.3fms/svg)" elapsed-ms (/ elapsed-ms (float n)))
                         results))))

             ;; Write results
             (with-temp-file bench--log-file
               (dolist (line (nreverse results))
                 (insert line "\n")))
             (print (format "BENCH: results written to %s" bench--log-file)
                    #'external-debugging-output))

           (when tip--server-process (tip-shutdown))
           (sleep-for 0.3)
           (kill-buffer))
       (when (file-exists-p test-file)
         (delete-file test-file))))))
