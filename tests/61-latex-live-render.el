;;; 61-latex-live-render.el --- End-to-end test of tip-latex + tip-server -*- lexical-binding: t; -*-

;;; Commentary:
;; Opens a .tex file, enables tip-mode (LaTeX backend), sends a batch
;; compile request, and verifies overlays with SVG data appear on the
;; fragments.  Tests the full Emacs↔Rust pipeline.
;;
;; Skips silently if `latex' or `dvisvgm' are not on PATH, or if the
;; tip-server binary isn't built yet.
;;
;; Run: emacs --batch -l tests/61-latex-live-render.el

;;; Code:

(let ((base (file-name-directory (or load-file-name "."))))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base) nil t))

(setq tip-enable-debug nil)

(defun live-check (msg pred)
  (if pred (message "  ok   %s" msg)
    (message "  FAIL %s" msg)
    (kill-emacs 1)))

(defun tools-available-p ()
  (and (executable-find "latex")
       (executable-find "dvisvgm")))

(defun server-binary-p ()
  (let ((base (file-name-directory (or load-file-name "."))))
    (file-executable-p
     (expand-file-name "../tip-server/target/release/tip-server" base))))

(unless (tools-available-p)
  (message "SKIP: latex or dvisvgm not on PATH")
  (kill-emacs 0))

(unless (server-binary-p)
  (message "SKIP: tip-server binary not built")
  (kill-emacs 0))

;; Point the backend at the built binary explicitly.
(let ((base (file-name-directory (or load-file-name "."))))
  (setq tip-server-executable
        (expand-file-name "../tip-server/target/release/tip-server" base)))

(message "=== tip-latex end-to-end live test ===")

(with-temp-buffer
  ;; Use a file-backed buffer so the server gets a real URI with a valid
  ;; parent directory (dvisvgm writes SVGs in that dir's neighborhood).
  (let ((tmp (make-temp-file "tip-latex-live-" nil ".tex")))
    (unwind-protect
        (progn
          (write-region "" nil tmp)
          (find-file tmp)
          (delay-mode-hooks (latex-mode))
          (insert "\\documentclass{article}\n")
          (insert "\\usepackage{amsmath}\n")
          (insert "\\begin{document}\n")
          (insert "Text $a+b$ more $x^2$.\n")
          (insert "\\end{document}\n")
          (save-buffer)

          ;; Sanity: the backend recognizes this major mode.
          (let ((b (tip-active-backend)))
            (live-check "active backend is 'latex"
                        (and b (eq (tip-backend-name b) 'latex))))

          ;; Detection finds 2 fragments.
          (let ((frags (tip-collect-fragments (point-min) (point-max))))
            (live-check (format "detected 2 fragments (got %d)" (length frags))
                        (= 2 (length frags))))

          ;; Start the server directly — avoid tip-mode's after-0.5s
          ;; scheduled tip-send-nbd (which in batch mode runs into
          ;; window-start/end + face-attribute :font issues).
          (tip-ensure)

          ;; Send sync + compile_fragments explicitly with our own
          ;; callback, so any exception in downstream apply code doesn't
          ;; suppress our "got result" signal.
          (tip--sync-buffer)
          (let ((got-compile nil)
                (last-result nil))
            (let* ((frag-locs (tip-collect-fragments (point-min) (point-max))))
              (tip--send-request
               "compile_fragments"
               `(("uri" . ,(buffer-file-name))
                 ("fragments" . ,(vconcat frag-locs))
                 ("color" . "#000000")
                 ("preamble" . ,(tip-build-preamble)))
               (lambda (r) (setq got-compile t last-result r))))
            (with-timeout (30 (error "timed out waiting for server"))
              (while (not got-compile)
                (accept-process-output tip--server-process 0.1)))
            (live-check "received compile_fragments response" got-compile)

            ;; In batch mode, overlay creation fails because face-attribute
            ;; :font returns the sentinel symbol `unspecified', so
            ;; tip--font-pixel-size crashes.  Verify the response payload
            ;; instead — that's what the server and protocol produced.
            (let* ((frags (alist-get 'fragments last-result))
                   (vec (append frags nil)))
              (live-check (format "response has 2 fragments (got %d)"
                                  (length vec))
                          (= 2 (length vec)))
              (dolist (f vec)
                (let ((svg (alist-get 'svg f))
                      (h (alist-get 'height_pt f))
                      (w (alist-get 'width_pt f))
                      (err (alist-get 'error f)))
                  (live-check (format "fragment [%d,%d]: no error"
                                      (alist-get 'start f)
                                      (alist-get 'end f))
                              (null err))
                  (live-check "svg starts with <?xml or <svg"
                              (and svg
                                   (or (string-prefix-p "<?xml" svg)
                                       (string-prefix-p "<svg" svg))))
                  (live-check (format "height %.2fpt > 0" (or h 0.0)) (> h 0.0))
                  (live-check (format "width  %.2fpt > 0" (or w 0.0)) (> w 0.0)))))

            ;; Shut down cleanly.
            (tip-shutdown))

          (message "=== all live checks passed ==="))
      (when (file-exists-p tmp) (delete-file tmp)))))

(kill-emacs 0)

;;; 61-latex-live-render.el ends here
