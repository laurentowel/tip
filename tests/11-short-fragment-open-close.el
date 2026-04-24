;;; 11-short-fragment-open-close.el --- Short fragments: open/close/jump -*- lexical-binding: t; -*-

;;; Commentary:
;; Renders a buffer with 4 short inline fragments and drives the
;; cursor through every open/close path:
;;   - Forward exit via C-f
;;   - Backward exit via C-b
;;   - Fragment-to-fragment jump
;; Verifies the previous overlay closes on each transition.
;;
;; Self-contained: locates the repo root via `load-file-name' so
;; running from any checkout works.  Errors go to
;; tests/11-short-fragment-open-close-error.txt with a backtrace.
;;
;; Run: emacs -Q --init-directory tests/emacs-sandbox \
;;             -l tests/11-short-fragment-open-close.el

;;; Code:

(let* ((this-file (or load-file-name buffer-file-name))
       (base (file-name-directory (directory-file-name
                                   (file-name-directory this-file))))
       (name (file-name-base this-file))
       (error-file (expand-file-name (format "%s-error.txt" name)
                                     (file-name-directory this-file))))
  (add-to-list 'load-path base)
  (load (expand-file-name "tip.el" base))

  ;; Mirror messages to stderr so the terminal sees progress.
  (advice-add 'message :after
              (lambda (&rest _)
                (let ((msg (current-message)))
                  (when msg (print msg #'external-debugging-output)))))

  (condition-case err
      (progn
        (require 'package) (package-initialize) (require 'typst-ts-mode)
        (let ((file (make-temp-file "tip-short-" nil ".typ"))
              (p #'external-debugging-output))
          (find-file file)
          (insert "Text $a$ then $b$ then $g$ then $d$ end.\n")
          (save-buffer)
          (typst-ts-mode)
          (tip-mode 1)
          (tip-live-teardown)
          (sleep-for 1)
          (tip-render-all)
          (let ((deadline (+ (float-time) 10)))
            (while (and (< (float-time) deadline)
                        tip--server-process (process-live-p tip--server-process)
                        (> (hash-table-count tip--pending-callbacks) 0))
              (accept-process-output tip--server-process 0.1)
              (redisplay t)))

          (let ((ovs (length (seq-filter (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                                                           (overlay-get ov 'display)))
                                         (overlays-in (point-min) (point-max)))))
                (ranges (treesit-query-range 'typst "((math) @math)")))
            (print (format "overlays: %d fragments: %d" ovs (length ranges)) p)

            (print "=== Forward exit ===" p)
            (dolist (r ranges)
              (let ((inside (1+ (car r)))
                    (after (min (1+ (cdr r)) (point-max))))
                (let ((this-command 'forward-char)) (run-hooks 'pre-command-hook))
                (goto-char (point-min))
                (let ((this-command 'forward-char)) (run-hooks 'post-command-hook))
                (redisplay t)
                (let ((this-command 'forward-char)) (run-hooks 'pre-command-hook))
                (goto-char inside)
                (let ((this-command 'forward-char)) (run-hooks 'post-command-hook))
                (redisplay t)
                (let ((this-command 'forward-char)) (run-hooks 'pre-command-hook))
                (goto-char after)
                (let ((this-command 'forward-char)) (run-hooks 'post-command-hook))
                (redisplay t)
                (let ((deadline (+ (float-time) 3)))
                  (while (and (< (float-time) deadline)
                              tip--server-process (process-live-p tip--server-process)
                              (> (hash-table-count tip--pending-callbacks) 0))
                    (accept-process-output tip--server-process 0.1)
                    (redisplay t)))
                (let ((closed (seq-find (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                                                          (overlay-get ov 'display)))
                                        (overlays-at inside))))
                  (print (format "  %S: %s" r (if closed "OK" "FAIL")) p))))

            (print "=== Backward exit ===" p)
            (dolist (r ranges)
              (let ((inside (1+ (car r)))
                    (before (max (1- (car r)) (point-min))))
                (let ((this-command 'forward-char)) (run-hooks 'pre-command-hook))
                (goto-char (point-max))
                (let ((this-command 'forward-char)) (run-hooks 'post-command-hook))
                (redisplay t)
                (let ((this-command 'backward-char)) (run-hooks 'pre-command-hook))
                (goto-char inside)
                (let ((this-command 'backward-char)) (run-hooks 'post-command-hook))
                (redisplay t)
                (let ((this-command 'backward-char)) (run-hooks 'pre-command-hook))
                (goto-char before)
                (let ((this-command 'backward-char)) (run-hooks 'post-command-hook))
                (redisplay t)
                (let ((deadline (+ (float-time) 3)))
                  (while (and (< (float-time) deadline)
                              tip--server-process (process-live-p tip--server-process)
                              (> (hash-table-count tip--pending-callbacks) 0))
                    (accept-process-output tip--server-process 0.1)
                    (redisplay t)))
                (let ((closed (seq-find (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                                                          (overlay-get ov 'display)))
                                        (overlays-at inside))))
                  (print (format "  %S: %s" r (if closed "OK" "FAIL")) p))))

            (print "=== Fragment-to-fragment ===" p)
            (let ((prev-inside nil))
              (dolist (r ranges)
                (let ((inside (1+ (car r))))
                  (let ((this-command 'forward-char)) (run-hooks 'pre-command-hook))
                  (goto-char inside)
                  (let ((this-command 'forward-char)) (run-hooks 'post-command-hook))
                  (redisplay t)
                  (let ((deadline (+ (float-time) 3)))
                    (while (and (< (float-time) deadline)
                                tip--server-process (process-live-p tip--server-process)
                                (> (hash-table-count tip--pending-callbacks) 0))
                      (accept-process-output tip--server-process 0.1)
                      (redisplay t)))
                  (when prev-inside
                    (let ((closed (seq-find (lambda (ov) (and (eq (overlay-get ov 'tip) 'tip)
                                                              (overlay-get ov 'display)))
                                            (overlays-at prev-inside))))
                      (print (format "  prev@%d: %s" prev-inside (if closed "OK" "FAIL")) p)))
                  (setq prev-inside inside)))))

          (when tip--server-process (tip-shutdown))
          (sleep-for 0.3)
          (kill-buffer)
          (delete-file file))
        (when (file-exists-p error-file) (delete-file error-file))
        (kill-emacs 0))
    (error
     (let ((backtrace (with-temp-buffer
                        (insert (format "Error: %S\n\n" err))
                        (insert "Backtrace:\n")
                        (let ((standard-output (current-buffer)))
                          (backtrace))
                        (buffer-string))))
       (with-temp-file error-file (insert backtrace))
       (print (format "TEST ERROR: %S (see %s)" err error-file)
              #'external-debugging-output)
       (kill-emacs 1)))))

;;; 11-short-fragment-open-close.el ends here
