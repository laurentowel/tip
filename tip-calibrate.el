;;; tip-calibrate.el --- Visual calibration for tip-scale and tip-baseline-offset -*- lexical-binding: t; -*-

;;; Commentary:
;; Opens a .typ file with a grid of a$a$ f(x)$f(x)$ cells.
;; Compiles $a$ and $f(x)$ once, then programmatically creates
;; overlays with different scale/offset per cell.
;;
;; Usage: M-x tip-calibrate

;;; Code:

(require 'tip)

(defvar tip-calibrate-scales '(0.90 0.95 1.00 1.05 1.10)
  "Scale values for calibration rows.")

(defvar tip-calibrate-offsets '(-3.0 -2.5 -2.0 -1.5 -1.0 -0.5 0.0)
  "Baseline offset values for calibration columns.")

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

(defun tip-calibrate--insert-grid (buf svg-a h-a d-a svg-fx h-fx d-fx)
  "Insert calibration grid into BUF with overlays using the compiled SVGs."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      ;; Header
      (insert (format "// TIP Calibration — current: scale=%.2f offset=%.1f\n"
                      tip-scale tip-baseline-offset))
      (insert "// The * marks your current settings.\n\n")
      (insert (format "%-14s" "scale\\offset"))
      (dolist (off tip-calibrate-offsets)
        (insert (format "│ %-14.1f" off)))
      (insert "\n")
      (insert (make-string 14 ?─))
      (dotimes (_ (length tip-calibrate-offsets))
        (insert "┼" (make-string 15 ?─)))
      (insert "\n")
      ;; Grid
      (dolist (sc tip-calibrate-scales)
        (insert (format "%-14.2f" sc))
        (dolist (off tip-calibrate-offsets)
          (insert "│ ")
          ;; Current settings marker
          (let ((marker (if (and (= sc tip-scale)
                                (= off tip-baseline-offset))
                           "*" " ")))
            ;; "a" with overlay
            (let ((beg (point)))
              (insert "a")
              (let ((ov (make-overlay beg (point))))
                (overlay-put ov 'display
                             (tip-calibrate--make-spec svg-a h-a d-a sc off))
                (overlay-put ov 'tip-cal t)))
            (insert " ")
            ;; "f(x)" with overlay
            (let ((beg (point)))
              (insert "f(x)")
              (let ((ov (make-overlay beg (point))))
                (overlay-put ov 'display
                             (tip-calibrate--make-spec svg-fx h-fx d-fx sc off))
                (overlay-put ov 'tip-cal t)))
            (insert marker)))
        (insert "\n"))
      ;; Instructions
      (insert "\n// Apply:  M-x tip-calibrate-apply  scale  offset\n")
      (insert "// Then:   M-x tip-render-all  in your document\n")
      (goto-char (point-min)))))

;;;###autoload
(defun tip-calibrate ()
  "Open a calibration grid to tune tip-scale and tip-baseline-offset.
Compiles $a$ and $f(x)$ once, then creates overlays with every
scale/offset combination for visual comparison."
  (interactive)
  (tip-ensure)
  (let ((tmp (make-temp-file "tip-cal-" nil ".typ"))
        (cal-buf (get-buffer-create "*tip-calibrate*")))
    ;; Compile two reference fragments
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
              (let ((inhibit-read-only t))
                (erase-buffer))
              (tip-calibrate--insert-grid
               cal-buf
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
  (message "tip-scale=%.2f tip-baseline-offset=%.1f — run M-x tip-render-all"
           scale offset))

(provide 'tip-calibrate)

;;; tip-calibrate.el ends here
