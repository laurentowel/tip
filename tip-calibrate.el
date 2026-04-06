;;; tip-calibrate.el --- Visual calibration for tip-scale and tip-baseline-offset -*- lexical-binding: t; -*-

;;; Commentary:
;; Opens a buffer with a grid showing inline math at various
;; tip-scale and tip-baseline-offset combinations.
;; Each cell: a$a$ f(x)$f(x)$ — judge baseline alignment and sizing.
;;
;; Usage: M-x tip-calibrate
;; Then: M-x tip-calibrate-apply to set chosen values.

;;; Code:

(require 'tip)

(defvar tip-calibrate-scales '(0.90 0.95 1.00 1.05 1.10)
  "Scale values to display in the calibration grid.")

(defvar tip-calibrate-offsets '(-3.0 -2.5 -2.0 -1.5 -1.0 -0.5 0.0)
  "Baseline offset values to display in the calibration grid.")

(defvar-local tip-calibrate--svg-a nil "Cached SVG data for $a$.")
(defvar-local tip-calibrate--svg-fx nil "Cached SVG data for $f(x)$.")
(defvar-local tip-calibrate--height-a nil)
(defvar-local tip-calibrate--depth-a nil)
(defvar-local tip-calibrate--height-fx nil)
(defvar-local tip-calibrate--depth-fx nil)

(defun tip-calibrate--make-spec (svg height depth scale offset)
  "Build an image spec for SVG with given SCALE and baseline OFFSET."
  (let* ((font-pt (tip--font-size-pt))
         (height-em (* scale (/ height font-pt)))
         (raw (if (> height 0)
                  (* 100.0 (/ (- height depth) height))
                85.0))
         (ascent (max 0 (min 100 (round (- raw offset))))))
    (list (list 'image
                :type 'svg
                :data svg
                :height (cons height-em 'em)
                :ascent ascent))))

(defun tip-calibrate--insert-grid ()
  "Insert the calibration grid using cached SVG data."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "TIP Calibration Grid\n" 'face 'bold))
    (insert "Pick the row/column where a and f(x) sit on the text baseline.\n")
    (insert (format "Current: tip-scale=%.2f  tip-baseline-offset=%.1f\n\n"
                    tip-scale tip-baseline-offset))
    ;; Header
    (insert (format "%-14s" ""))
    (dolist (off tip-calibrate-offsets)
      (insert (format "│ offset=%-5.1f   " off)))
    (insert "\n")
    (insert (make-string 14 ?─))
    (dotimes (_ (length tip-calibrate-offsets))
      (insert "┼" (make-string 16 ?─)))
    (insert "\n")
    ;; Rows
    (dolist (sc tip-calibrate-scales)
      (insert (format "scale=%-8.2f" sc))
      (dolist (off tip-calibrate-offsets)
        (insert "│ ")
        ;; a with overlay
        (let ((start (point)))
          (insert "a")
          (let ((ov (make-overlay start (point))))
            (overlay-put ov 'display
                         (tip-calibrate--make-spec
                          tip-calibrate--svg-a
                          tip-calibrate--height-a
                          tip-calibrate--depth-a
                          sc off))
            (overlay-put ov 'tip-cal t)))
        (insert " ")
        ;; f(x) with overlay
        (let ((start (point)))
          (insert "f(x)")
          (let ((ov (make-overlay start (point))))
            (overlay-put ov 'display
                         (tip-calibrate--make-spec
                          tip-calibrate--svg-fx
                          tip-calibrate--height-fx
                          tip-calibrate--depth-fx
                          sc off))
            (overlay-put ov 'tip-cal t)))
        (insert " "))
      (insert "\n"))
    (insert "\n")
    (insert "Use M-x tip-calibrate-apply to set values, e.g.:\n")
    (insert "  (tip-calibrate-apply 1.0 -2.0)\n")
    (goto-char (point-min))))

;;;###autoload
(defun tip-calibrate ()
  "Open a calibration grid to tune tip-scale and tip-baseline-offset."
  (interactive)
  (tip-ensure)
  ;; Compile $a$ and $f(x)$ to get SVG data
  (let ((buf (current-buffer)))
    (tip--sync-buffer)
    (tip--send-request
     "compile_fragments"
     `(("uri" . ,(or (buffer-file-name) "/tmp/cal.typ"))
       ("fragments" . ,(vector `(("start" . 0) ("end" . 1))))
       ("color" . ,(tip--color-to-hex (face-attribute 'default :foreground)))
       ("preamble" . ,(tip--build-preamble)))
     (lambda (_) nil)))
  ;; Use a temp file to compile our two test fragments
  (let ((tmp (make-temp-file "tip-cal-" nil ".typ")))
    (with-temp-file tmp (insert "$a$ $f(x)$"))
    (tip--send-request
     "sync"
     `(("uri" . ,tmp) ("content" . "$a$ $f(x)$"))
     (lambda (_)
       (tip--send-request
        "compile_fragments"
        `(("uri" . ,tmp)
          ("fragments" . ,(vector '(("start" . 0) ("end" . 3))
                                  '(("start" . 4) ("end" . 10))))
          ("color" . ,(tip--color-to-hex (face-attribute 'default :foreground)))
          ("preamble" . ,(tip--build-preamble)))
        (lambda (result)
          (let* ((frags (alist-get 'fragments result))
                 (f1 (aref frags 0))
                 (f2 (aref frags 1))
                 (cal-buf (get-buffer-create "*tip-calibrate*")))
            (with-current-buffer cal-buf
              (setq tip-calibrate--svg-a (alist-get 'svg f1))
              (setq tip-calibrate--height-a (alist-get 'height_pt f1))
              (setq tip-calibrate--depth-a (alist-get 'depth_pt f1))
              (setq tip-calibrate--svg-fx (alist-get 'svg f2))
              (setq tip-calibrate--height-fx (alist-get 'height_pt f2))
              (setq tip-calibrate--depth-fx (alist-get 'depth_pt f2))
              (tip-calibrate--insert-grid))
            (switch-to-buffer cal-buf)
            (delete-file tmp))))))))

;;;###autoload
(defun tip-calibrate-apply (scale offset)
  "Set tip-scale to SCALE and tip-baseline-offset to OFFSET globally."
  (interactive "nScale (e.g. 1.0): \nnBaseline offset (e.g. -2.0): ")
  (setq tip-scale scale)
  (setq tip-baseline-offset offset)
  (message "Set tip-scale=%.2f tip-baseline-offset=%.1f. Run M-x tip-render-all to see changes."
           scale offset))

(provide 'tip-calibrate)

;;; tip-calibrate.el ends here
