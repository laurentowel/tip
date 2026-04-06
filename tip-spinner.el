;;; tip-spinner.el --- Typst logo indicator for TIP -*- lexical-binding: t; -*-

;;; Commentary:
;; Shows a Typst "t" logo in the mode line of typst-ts-mode buffers.
;; Spins when tip-server responds, velocity reflects fragment count.
;; Uses tip-server-response-functions hook — no polling, no advice.
;;
;; Animation: nyan-mode style — a single run-at-time timer advances
;; the frame and calls force-mode-line-update.  The :eval lighter
;; picks up the new frame on redisplay.
;;
;; Usage: (add-hook 'typst-ts-mode-hook #'tip-spinner-mode)

;;; Code:

(defvar tip-spinner--frames nil
  "Vector of SVG strings for spinner animation frames.")

(defvar tip-spinner--index 0
  "Current animation frame index (global, shared across buffers).")

(defvar tip-spinner--timer nil
  "Animation timer.  Nil when not spinning.")

(defvar tip-spinner--remaining 0
  "Animation frames remaining before stopping.")

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
  "Return the current frame as a propertized string for mode-line.
Only shows in typst-ts-mode buffers."
  (let ((frames (tip-spinner--load-frames)))
    (when (and frames (derived-mode-p 'typst-ts-mode))
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
    ;; Done — cancel timer, reset to frame 0
    (when tip-spinner--timer
      (cancel-timer tip-spinner--timer)
      (setq tip-spinner--timer nil))
    (setq tip-spinner--index 0)
    (force-mode-line-update t)))

(defun tip-spinner--on-response (result)
  "Hook: spin based on how many fragments were in the response."
  (let* ((frags (alist-get 'fragments result))
         (n (if (vectorp frags) (length frags) 1))
         ;; More fragments = more spin.  At least 1 full rotation (8 frames).
         (frames (max 8 (* n 2))))
    ;; Cancel any existing animation, start fresh
    (when tip-spinner--timer
      (cancel-timer tip-spinner--timer)
      (setq tip-spinner--timer nil))
    (setq tip-spinner--remaining frames)
    ;; Faster spin for more fragments: base 0.1s, min 0.05s for big batches
    (let ((interval (max 0.05 (/ 0.8 (float (max 1 n))))))
      (setq tip-spinner--timer
            (run-at-time 0 interval #'tip-spinner--tick)))))

;;;###autoload
(define-minor-mode tip-spinner-mode
  "Show a Typst logo in the mode line of typst-ts-mode buffers.
Spins when tip-server responds.  Speed reflects fragment count."
  :init-value nil
  :lighter (:eval (tip-spinner--image))
  (if tip-spinner-mode
      (progn
        (tip-spinner--load-frames)
        (add-hook 'tip-server-response-functions #'tip-spinner--on-response))
    (remove-hook 'tip-server-response-functions #'tip-spinner--on-response)
    (when tip-spinner--timer
      (cancel-timer tip-spinner--timer)
      (setq tip-spinner--timer nil))
    (setq tip-spinner--index 0)
    (force-mode-line-update t)))

;;;###autoload
(defun tip-spinner-demo ()
  "Spin the logo for a few seconds (simulates a 50-fragment response)."
  (interactive)
  (unless tip-spinner-mode (tip-spinner-mode 1))
  (tip-spinner--on-response '((fragments . [1 2 3 4 5 6 7 8 9 10
                                            11 12 13 14 15 16 17 18 19 20
                                            21 22 23 24 25 26 27 28 29 30
                                            31 32 33 34 35 36 37 38 39 40
                                            41 42 43 44 45 46 47 48 49 50]))))

(provide 'tip-spinner)

;;; tip-spinner.el ends here
