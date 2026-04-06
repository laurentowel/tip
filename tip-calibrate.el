;;; tip-calibrate.el --- Visual calibration for tip-scale and tip-baseline-offset -*- lexical-binding: t; -*-

;;; Commentary:
;; Generates a .typ file with a grid of inline math at various
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

;;;###autoload
(defun tip-calibrate ()
  "Open a Typst calibration file to tune tip-scale and tip-baseline-offset.
Generates a grid where each row uses a different scale and each column
a different baseline offset.  Render with M-x tip-render-all and pick
the best combination."
  (interactive)
  (let ((file (expand-file-name
               (format "tip-calibrate-%s.typ"
                       (format-time-string "%H%M%S"))
               temporary-file-directory)))
    (with-temp-file file
      (insert "// TIP Calibration Grid\n")
      (insert (format "// Current: tip-scale=%.2f  tip-baseline-offset=%.1f\n"
                      tip-scale tip-baseline-offset))
      (insert "// Render with tip-render-all. Pick the row/column where\n")
      (insert "// a and f(x) sit best on the text baseline.\n\n")
      ;; Header
      (insert (format "%-16s" "scale \\\\ offset"))
      (dolist (off tip-calibrate-offsets)
        (insert (format "| %-6.1f  " off)))
      (insert "\n\n")
      ;; Rows
      (dolist (sc tip-calibrate-scales)
        (insert (format "scale=%-10.2f" sc))
        (dolist (_off tip-calibrate-offsets)
          (insert "| a$a$ f$f(x)$ "))
        (insert "\n\n")))
    (find-file file)
    (message "Calibration file opened. For each row, set tip-scale and tip-baseline-offset, then M-x tip-render-all.")))

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
