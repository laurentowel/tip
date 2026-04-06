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

(defcustom tip-calibrate-scale-params '(:min 0.85 :max 1.15 :step 0.05)
  "Range for tip-scale in the calibration grid.
Plist with :min, :max, :step."
  :type '(plist :key-type keyword :value-type float)
  :group 'tip)

(defcustom tip-calibrate-offset-params '(:min -5.0 :max -1.5 :step 0.5)
  "Range for tip-baseline-offset in the calibration grid.
Plist with :min, :max, :step."
  :type '(plist :key-type keyword :value-type float)
  :group 'tip)

(defun tip-calibrate--range (params)
  "Generate a list of values from PARAMS plist (:min :max :step)."
  (let ((min (plist-get params :min))
        (max (plist-get params :max))
        (step (plist-get params :step))
        (result nil))
    (let ((v min))
      (while (<= v (+ max 1e-9))
        (push (/ (round (* v 100)) 100.0) result)
        (setq v (+ v step))))
    (nreverse result)))

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

(defun tip-calibrate--bar ()
  "Insert a full-height 1-pixel separator bar (valign technique)."
  (let ((beg (point)))
    (insert " ")
    (let ((ov (make-overlay beg (point))))
      (overlay-put ov 'display '(space :width (1)))
      (overlay-put ov 'face '(:inverse-video t)))))

(defun tip-calibrate--insert-grid (svg-a h-a d-a svg-fx h-fx d-fx)
  "Insert calibration grid with overlays."
  (let* ((inhibit-read-only t)
         (scales (tip-calibrate--range tip-calibrate-scale-params))
         (offsets (tip-calibrate--range tip-calibrate-offset-params))
         (label-px 100)
         (col-px tip-calibrate--col-width))
    (erase-buffer)
    ;; Title
    (insert (propertize "TIP Calibration\n" 'face 'bold))
    (insert (format "Current: tip-scale=%.2f  tip-baseline-offset=%.1f\n\n"
                    tip-scale tip-baseline-offset))
    ;; Header row
    (insert (propertize "scale\\offset" 'face 'bold))
    (dotimes (j (length offsets))
      (tip-calibrate--align-to (+ label-px (* j col-px)))
      (tip-calibrate--bar)
      (insert (format " %.1f" (nth j offsets))))
    (insert "\n")
    ;; Horizontal rule
    (let ((total-px (+ label-px (* (length offsets) col-px))))
      (let ((beg (point)))
        (insert " ")
        (put-text-property beg (point) 'display
                           `(space :width (,total-px) :height (1)))
        (put-text-property beg (point) 'face '(:strike-through t)))
      (insert "\n"))
    ;; Grid rows
    (dolist (sc scales)
      (insert (format "%.2f" sc))
      (dotimes (j (length offsets))
        (let ((off (nth j offsets)))
          (tip-calibrate--align-to (+ label-px (* j col-px)))
          (tip-calibrate--bar)
          (insert " ")
          ;; Mark current settings
          (when (and (= sc tip-scale) (= off tip-baseline-offset))
            (insert (propertize ">" 'face '(:foreground "red"))))
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
             'display (tip-calibrate--make-spec svg-fx h-fx d-fx sc off)))))
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
