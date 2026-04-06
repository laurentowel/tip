;;; tip-spinner.el --- Typst logo indicator for TIP -*- lexical-binding: t; -*-

;;; Commentary:
;; Shows a Typst "t" logo in the mode line of typst-ts-mode buffers.
;; Static when idle, spins while tip-server is processing requests.
;; No persistent timer — animation starts on demand and self-cancels.
;;
;; Usage: (add-hook 'typst-ts-mode-hook #'tip-spinner-mode)

;;; Code:

(defvar tip-spinner--frames nil
  "Vector of SVG strings for spinner animation frames.")

(defvar-local tip-spinner--index 0
  "Current frame index.")

(defvar tip-spinner--timer nil
  "Shared animation timer. Runs only while server is busy.")

(defvar tip-spinner--active-count 0
  "Number of buffers with tip-spinner-mode active.")

(defun tip-spinner--load-frames ()
  "Load spinner SVG frames from the spinner/ directory."
  (unless tip-spinner--frames
    (let* ((dir (expand-file-name "spinner"
                                   (file-name-directory
                                    (or load-file-name buffer-file-name
                                        (locate-library "tip-spinner")))))
           (files (and (file-directory-p dir)
                       (sort (directory-files dir t "^spinner-[0-9]+\\.svg$")
                             #'string<))))
      (when files
        (setq tip-spinner--frames
              (vconcat (mapcar (lambda (f)
                                 (with-temp-buffer
                                   (insert-file-contents f)
                                   (buffer-string)))
                               files))))))
  tip-spinner--frames)

(defun tip-spinner--image ()
  "Return the current spinner frame as a propertized string for mode-line."
  (let ((frames (tip-spinner--load-frames)))
    (when (and frames (eq major-mode 'typst-ts-mode))
      (propertize " "
                  'display
                  (list 'image
                        :type 'svg
                        :data (aref frames (% tip-spinner--index
                                             (length frames)))
                        :ascent 'center
                        :height (frame-char-height))))))

(defun tip-spinner--busy-p ()
  "Return non-nil if tip-server has pending requests."
  (and (boundp 'tip--pending-callbacks)
       tip--pending-callbacks
       (> (hash-table-count tip--pending-callbacks) 0)))

(defun tip-spinner--tick ()
  "Advance animation if busy, stop timer if idle."
  (if (tip-spinner--busy-p)
      (progn
        (setq tip-spinner--index (1+ tip-spinner--index))
        (force-mode-line-update t))
    ;; Idle — reset to frame 0 and cancel timer
    (setq tip-spinner--index 0)
    (when tip-spinner--timer
      (cancel-timer tip-spinner--timer)
      (setq tip-spinner--timer nil))
    (force-mode-line-update t)))

(defun tip-spinner--maybe-start ()
  "Start animation timer if not already running and server is busy."
  (when (and (> tip-spinner--active-count 0)
             (tip-spinner--busy-p)
             (not tip-spinner--timer))
    (setq tip-spinner--timer
          (run-with-timer 0 0.15 #'tip-spinner--tick))))

;; Hook into tip--send-request to trigger animation on demand
(defun tip-spinner--on-request (&rest _)
  "Advice: start spinner when a request is sent."
  (tip-spinner--maybe-start))

;;;###autoload
(define-minor-mode tip-spinner-mode
  "Show a Typst logo in the mode line.
Spins while tip-server is processing, static when idle.
Only visible in typst-ts-mode buffers."
  :init-value nil
  :lighter (:eval (tip-spinner--image))
  (if tip-spinner-mode
      (progn
        (tip-spinner--load-frames)
        (cl-incf tip-spinner--active-count)
        (advice-add 'tip--send-request :after #'tip-spinner--on-request))
    (cl-decf tip-spinner--active-count)
    (when (<= tip-spinner--active-count 0)
      (setq tip-spinner--active-count 0)
      (advice-remove 'tip--send-request #'tip-spinner--on-request)
      (when tip-spinner--timer
        (cancel-timer tip-spinner--timer)
        (setq tip-spinner--timer nil)))))

;;;###autoload
(defun tip-spinner-setup ()
  "Enable tip-spinner-mode in typst-ts-mode buffers.
Add to your config: (add-hook \\='typst-ts-mode-hook #\\='tip-spinner-setup)"
  (when (derived-mode-p 'typst-ts-mode)
    (tip-spinner-mode 1)))

(provide 'tip-spinner)

;;; tip-spinner.el ends here
