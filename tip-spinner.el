;;; tip-spinner.el --- Typst logo indicator for TIP -*- lexical-binding: t; -*-

;;; Commentary:
;; Shows a Typst "t" logo in the mode line of typst-ts-mode buffers.
;; Teal (#239dad) when OK, vermillion (#cc3300) when errors exist.
;; Spins on server response, duration proportional to fragment count.
;;
;; Usage: (add-hook 'typst-ts-mode-hook #'tip-spinner-mode)

;;; Code:

(defvar tip-spinner--frames nil
  "Vector of SVG strings for normal (teal) spinner frames.")

(defvar tip-spinner--error-frames nil
  "Vector of SVG strings for error (vermillion) spinner frames.")

(defvar tip-spinner--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory where tip-spinner.el lives, captured at load time.")

(defvar tip-spinner--index 0
  "Current animation frame index.")

(defvar tip-spinner--timer nil
  "Animation timer.  Nil when not spinning.")

(defvar tip-spinner--remaining 0
  "Animation frames remaining before stopping.")

(defvar-local tip-spinner--has-errors nil
  "Buffer-local: non-nil if the last compilation had errors.")

(defun tip-spinner--load-svg-files (pattern)
  "Load SVG files matching PATTERN from the spinner/ directory."
  (let* ((dir (expand-file-name "spinner" tip-spinner--directory))
         (files (and (file-directory-p dir)
                     (sort (directory-files dir t pattern) #'string<))))
    (when files
      (vconcat (mapcar (lambda (f)
                         (with-temp-buffer
                           (insert-file-contents f)
                           (buffer-string)))
                       files)))))

(defun tip-spinner--load-frames ()
  "Load both normal and error spinner frames."
  (unless tip-spinner--frames
    (setq tip-spinner--frames
          (tip-spinner--load-svg-files "^spinner-[0-9]+\\.svg$")))
  (unless tip-spinner--error-frames
    (setq tip-spinner--error-frames
          (tip-spinner--load-svg-files "^error-[0-9]+\\.svg$")))
  tip-spinner--frames)

(defun tip-spinner--current-frames ()
  "Return the active frame set based on buffer error state."
  (if tip-spinner--has-errors
      (or tip-spinner--error-frames tip-spinner--frames)
    tip-spinner--frames))

(defun tip-spinner--image ()
  "Return the current frame as a propertized string for mode-line."
  (let ((frames (tip-spinner--current-frames)))
    (when frames
      (propertize " "
                  'display
                  (list 'image
                        :type 'svg
                        :data (aref frames (% tip-spinner--index
                                             (length frames)))
                        :ascent 'center
                        :height (frame-char-height))))))

(defun tip-spinner--tick ()
  "Advance one frame.  Stop when remaining hits zero."
  (if (> tip-spinner--remaining 0)
      (progn
        (cl-decf tip-spinner--remaining)
        (cl-incf tip-spinner--index)
        (force-mode-line-update t))
    (when tip-spinner--timer
      (cancel-timer tip-spinner--timer)
      (setq tip-spinner--timer nil))
    (setq tip-spinner--index 0)
    (force-mode-line-update t)))

(defun tip-spinner--on-response (result)
  "Hook: spin on response, track errors per-buffer."
  (let* ((frags (alist-get 'fragments result))
         (has-err (and (vectorp frags)
                       (seq-some (lambda (f) (alist-get 'error f)) frags))))
    (setq tip-spinner--has-errors has-err)
    (when tip-spinner--timer
      (cancel-timer tip-spinner--timer)
      (setq tip-spinner--timer nil))
    ;; Always spin exactly 2 full rotations (16 frames)
    (setq tip-spinner--remaining 16)
    (setq tip-spinner--timer
          (run-at-time 0 0.1 #'tip-spinner--tick))))

;;;###autoload
(define-minor-mode tip-spinner-mode
  "Show a Typst logo in the mode line of typst-ts-mode buffers.
Teal when OK, vermillion when errors exist.  Spins on server response."
  :init-value nil
  :lighter (:eval (when (derived-mode-p 'typst-ts-mode)
                    (tip-spinner--image)))
  (if tip-spinner-mode
      (progn
        (tip-spinner--load-frames)
        (add-hook 'tip-server-response-functions #'tip-spinner--on-response))
    (remove-hook 'tip-server-response-functions #'tip-spinner--on-response)
    (when tip-spinner--timer
      (cancel-timer tip-spinner--timer)
      (setq tip-spinner--timer nil))
    (setq tip-spinner--index 0)
    (setq tip-spinner--has-errors nil)
    (force-mode-line-update t)))

;;;###autoload
(defun tip-spinner-demo ()
  "Spin the logo (simulates a 50-fragment response)."
  (interactive)
  (unless tip-spinner-mode (tip-spinner-mode 1))
  (tip-spinner--on-response '((fragments . [1]))))

;;;###autoload
(defun tip-spinner-demo-error ()
  "Spin the angry logo (simulates a response with errors)."
  (interactive)
  (unless tip-spinner-mode (tip-spinner-mode 1))
  (tip-spinner--on-response
   '((fragments . [((error . "unknown variable: foo"))]))))

(provide 'tip-spinner)

;;; tip-spinner.el ends here
