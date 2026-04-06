;;; test-scaling.el --- Measure Emacs SVG display scaling -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --init-directory .../emacs-sandbox -l .../test-scaling.el

(require 'package)
(package-initialize)
(setq create-lockfiles nil make-backup-files nil auto-save-default nil)

(defvar test--log-file
  (expand-file-name "55-scaling-results.txt"
                    (file-name-directory load-file-name)))
(defvar test--lines nil)

(defun test--log (fmt &rest args)
  (let ((line (apply #'format fmt args)))
    (push line test--lines)))

(defun test--write-log ()
  (with-temp-file test--log-file
    (dolist (line (nreverse test--lines))
      (insert line "\n"))))

;; === Measure display parameters ===

(test--log "=== Emacs SVG Display Scaling Study ===")
(test--log "")

;; Font info
(let* ((font (face-attribute 'default :font))
       (height-10pt (face-attribute 'default :height))
       (font-pt (if (numberp height-10pt) (/ height-10pt 10.0) nil))
       (char-h (frame-char-height))
       (char-w (frame-char-width))
       (pixel-h (frame-pixel-height))
       (pixel-w (frame-pixel-width)))
  (test--log "Font: %S" font)
  (test--log "Font :height (1/10pt): %S" height-10pt)
  (test--log "Font size (pt): %S" font-pt)
  (test--log "frame-char-height (pixels): %d" char-h)
  (test--log "frame-char-width (pixels): %d" char-w)
  (test--log "frame pixel size: %dx%d" pixel-w pixel-h)

  ;; What does (1.0 . em) mean in pixels?
  ;; From Emacs manual: (N . em) = N * frame-char-height pixels
  (test--log "")
  (test--log "1 em = %d pixels (frame-char-height)" char-h)
  (when font-pt
    (test--log "1 pt = %.2f pixels (char-h / font-pt)" (/ (float char-h) font-pt))
    (test--log "")
    (test--log "--- Correct scaling formula ---")
    (test--log "SVG is rendered at Typst text size (default 11pt)")
    (test--log "SVG height in pt needs to display at correct physical size")
    (test--log "")
    (test--log "Option A: match Typst text to Emacs text")
    (test--log "  Tell server to render at %.1fpt instead of 11pt" font-pt)
    (test--log "  Then :height = (svg_height_pt / %.1f . em)" font-pt)
    (test--log "  No tip-scale needed")
    (test--log "")
    (test--log "Option B: scale after the fact")
    (test--log "  SVG rendered at 11pt Typst")
    (test--log "  Display: :height = (svg_height_pt / 11.0 * (%.1f / frame_char_h_pt) . em)" font-pt)
    (test--log "  Or simpler: :height = (svg_height_pt / %.1f . em)" font-pt)
    (test--log "  Because 1em = frame-char-height pixels ≈ font-pt in points")
    (test--log "")
    (test--log "--- Key insight ---")
    (test--log "Emacs (N . em) means N * frame-char-height pixels")
    (test--log "frame-char-height ≈ font size in pixels at screen DPI")
    (test--log "So (svg_pt / font_pt . em) gives correct physical size")
    (test--log "")
    (test--log "For font %.1fpt: divisor should be %.1f (not 11.0 or 18.8516)" font-pt font-pt)
    (test--log "tip-scale of 1.0 should be correct with this divisor")))

(test--write-log)
(message "Results in %s" test--log-file)
(sleep-for 1)
(kill-emacs 0)
