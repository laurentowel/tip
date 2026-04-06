;;; tip-calibrate.el --- Visual calibration for tip-scale and tip-baseline-offset -*- lexical-binding: t; -*-

;;; Commentary:
;; Opens a buffer with a grid showing text next to rendered math:
;;   a[rendered $a$] f(x)[rendered $f(x)$]
;; at various scale and baseline-offset combinations.
;; Columns aligned with (space :align-to) pixel display (valign trick).
;;
;; Usage: M-x tip-calibrate

;;; Code:

(require 'tip)

(defvar tip-calibrate-scales '(0.90 0.95 1.00 1.05 1.10)
  "Scale values for calibration rows.")

(defvar tip-calibrate-offsets '(-3.0 -2.5 -2.0 -1.5 -1.0 -0.5 0.0)
  "Baseline offset values for calibration columns.")

(defvar tip-calibrate--col-width 120
  "Pixel width per column.")

(defun tip-calibrate--make-spec (svg height depth scale offset)
  "Build image display spec for SVG with SCALE and baseline OFFSET."
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
                :ascent ascent
                :pointer 'hand))))

(defun tip-calibrate--align-to (px)
  "Insert a space that stretches to pixel column PX."
  (let ((beg (point)))
    (insert " ")
    (put-text-property beg (point) 'display `(space :align-to (,px)))))

(defun tip-calibrate--insert-grid (svg-a h-a d-a svg-fx h-fx d-fx)
  "Insert calibration grid with overlays."
  (let* ((inhibit-read-only t)
         (label-px 100)  ;; pixel width for row label
         (col-px tip-calibrate--col-width))
    (erase-buffer)
    ;; Title
    (insert (propertize "TIP Calibration\n" 'face 'bold))
    (insert (format "Current: tip-scale=%.2f  tip-baseline-offset=%.1f\n\n"
                    tip-scale tip-baseline-offset))
    ;; Header row
    (insert "scale\\offset")
    (dotimes (j (length tip-calibrate-offsets))
      (tip-calibrate--align-to (+ label-px (* j col-px)))
      (insert (format "%.1f" (nth j tip-calibrate-offsets))))
    (insert "\n")
    ;; Grid rows
    (dolist (sc tip-calibrate-scales)
      (let ((current-row-p nil))
        (insert (format "%.2f" sc))
        (dotimes (j (length tip-calibrate-offsets))
          (let ((off (nth j tip-calibrate-offsets)))
            (tip-calibrate--align-to (+ label-px (* j col-px)))
            ;; Mark current settings
            (when (and (= sc tip-scale) (= off tip-baseline-offset))
              (setq current-row-p t)
              (insert (propertize "*" 'face 'bold)))
            ;; "a" then rendered $a$
            (insert "a")
            (let ((beg (point)))
              (insert "$a$")
              (overlay-put
               (make-overlay beg (point))
               'display (tip-calibrate--make-spec svg-a h-a d-a sc off)))
            (insert " f(x)")
            (let ((beg (point)))
              (insert "$f(x)$")
              (overlay-put
               (make-overlay beg (point))
               'display (tip-calibrate--make-spec svg-fx h-fx d-fx sc off))))))
      (insert "\n"))
    ;; Footer
    (insert (format "\n  M-x tip-calibrate-apply %.2f %.1f\n"
                    tip-scale tip-baseline-offset))
    (goto-char (point-min))))

;;;###autoload
(defun tip-calibrate ()
  "Open a calibration grid to tune tip-scale and tip-baseline-offset.
Compiles $a$ and $f(x)$ once, then shows every scale/offset combo
with text next to rendered math for baseline comparison."
  (interactive)
  (tip-ensure)
  (let ((tmp (make-temp-file "tip-cal-" nil ".typ"))
        (cal-buf (get-buffer-create "*tip-calibrate*")))
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
                 (f2 (aref frags 1)))
            (with-current-buffer cal-buf
              (tip-calibrate--insert-grid
               (alist-get 'svg f1) (alist-get 'height_pt f1) (alist-get 'depth_pt f1)
               (alist-get 'svg f2) (alist-get 'height_pt f2) (alist-get 'depth_pt f2)))
            (switch-to-buffer cal-buf)
            (delete-file tmp))))))))

;;;###autoload
(defun tip-calibrate-apply (scale offset)
  "Set tip-scale to SCALE and tip-baseline-offset to OFFSET."
  (interactive "nScale (e.g. 1.0): \nnBaseline offset (e.g. -2.0): ")
  (setq tip-scale scale)
  (setq tip-baseline-offset offset)
  (message "tip-scale=%.2f tip-baseline-offset=%.1f — M-x tip-render-all to apply"
           scale offset))

(provide 'tip-calibrate)

;;; tip-calibrate.el ends here
