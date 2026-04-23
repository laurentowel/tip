;;; tip-render.el --- SVG → overlay rendering + theme/font tracking -*- lexical-binding: t; -*-

;;; Commentary:

;; Backend-agnostic rendering pipeline: take a server response (SVG +
;; baseline metrics) and turn it into an Emacs overlay with a correctly
;; sized and positioned image.  Also handles fast post-compile updates
;; on theme/font change (SVG color substitution and image-spec rescaling,
;; no server round-trip).
;;
;; Nothing here depends on Typst syntax — the only language-specific bit
;; is `is-block-call' (fragment text starts with `#'), which a future
;; tip-backend struct will supply via a classify-fragment hook.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'tip-backend)

;; Customs and helpers that live in tip.el — forward-declared.
(defvar tip-scale)
(defvar tip-baseline-offset)
(defvar tip-display-math-padding)
(defvar tip-transparent-bg)
(defvar tip-display-indicator)
(defvar tip-echo-errors)
(defvar tip-mode)
(defvar tip-live--content-cache)
(defvar tip-echo--content-cache)
(declare-function tip--color-to-hex "tip" (color))

;;; * SVG utilities

(defun tip--pad-svg-viewbox (svg-data padding)
  "Expand SVG-DATA viewBox by PADDING pt above and below.
Returns (SVG-STRING . ADDED-HEIGHT-PT)."
  (if (and (> padding 0)
           (string-match
            "viewBox=\"\\([^ \"]+\\) \\([^ \"]+\\) \\([^ \"]+\\) \\([^ \"]+\\)\""
            svg-data))
      (let* ((vy (string-to-number (match-string 2 svg-data)))
             (vw (match-string 3 svg-data))
             (vh (string-to-number (match-string 4 svg-data)))
             (new-vy (- vy padding))
             (new-vh (+ vh (* 2 padding)))
             (new-vb (format "viewBox=\"%s %s %s %s\""
                             (match-string 1 svg-data)
                             new-vy vw new-vh))
             (result (replace-match new-vb t t svg-data))
             (result (if (string-match "height=\"[^\"]+\"" result)
                         (replace-match
                          (format "height=\"%spt\"" new-vh) t t result)
                       result)))
        (cons result (* 2.0 padding)))
    (cons svg-data 0.0)))

;;; * font metrics (used for ascent prediction and scaling)

(defun tip--font-size-pt ()
  "Return the default font size in points."
  (let ((h (face-attribute 'default :height)))
    (if (numberp h) (/ h 10.0) 11.0)))

(defun tip--effective-scale (&optional rendered-pt)
  "Return the effective scale factor.
When `tip-scale' is `auto', compute it so the rendered math (at
the backend's native font size) visually matches the Emacs buffer
font.  RENDERED-PT, if provided, is that native font size from the
backend — e.g. preview.sty's \"Preview: Fontsize Npt\" for LaTeX,
or Typst's fixed 11pt.  Defaults to 11.0 when absent."
  (if (eq tip-scale 'auto)
      (/ (tip--font-size-pt) (or rendered-pt 11.0))
    tip-scale))

(defun tip--font-pixel-size ()
  "Return the default font's pixel size.
Respects `face-remapping-alist' (e.g. `variable-pitch-mode')."
  (let ((font (face-attribute 'default :font)))
    (if font
        (let ((sz (font-get font :size)))
          (if (and (numberp sz) (> sz 0)) sz 15))
      15)))

(defun tip--font-metrics ()
  "Return (ASCENT . DESCENT) in pixels for the default face font.
Respects `face-remapping-alist'."
  (let* ((font (face-attribute 'default :font))
         (info (and font (font-info (font-xlfd-name font)))))
    (if (and info (> (length info) 9))
        (cons (aref info 8) (aref info 9))
      (let ((px (tip--font-pixel-size)))
        (cons (round (* px 0.8)) (round (* px 0.2)))))))

;;; * image spec

(defun tip--make-image-spec (svg-data height-pt depth-pt &optional display-p rendered-pt)
  "Create an image display spec from SVG-DATA with HEIGHT-PT and DEPTH-PT.
When DISPLAY-P is non-nil, use vertical centering (for display math).
RENDERED-PT is the backend's native render size (see
`tip--effective-scale').  Defaults to 11.0."
  (let* ((padded (if display-p
                     (tip--pad-svg-viewbox svg-data tip-display-math-padding)
                   (cons svg-data 0.0)))
         (svg-data (car padded))
         (height-pt (+ height-pt (cdr padded)))
         (font-pt (tip--font-size-pt))
         (height-em (* (tip--effective-scale rendered-pt) (/ height-pt font-pt)))
         (ascent (if display-p
                     'center
                   ;; Inline: compute ascent from pixel-level prediction.
                   ;;
                   ;; Emacs computes: height_px = ceil(height_em * pixel_size)
                   ;; then positions:  ascent_px = height_px * (pct / 100.0)
                   ;;
                   ;; We predict height_px, compute the desired ascent in
                   ;; pixels, and find the percentage that best matches.
                   ;; Accounts for ceil() rounding and integer %.
                   (let* ((pixel-size (tip--font-pixel-size))
                          (height-px (ceiling (* height-em pixel-size)))
                          (ascent-ratio (if (> height-pt 0)
                                            (/ (- height-pt depth-pt) height-pt)
                                          0.5))
                          (desired-ascent-px (round (* ascent-ratio height-px)))
                          (pct (if (> height-px 0)
                                   (round (* 100.0 (/ (float desired-ascent-px)
                                                      height-px)))
                                 50)))
                     (max 0 (min 100 (- pct tip-baseline-offset)))))))
    (list (cons 'image
                (list :type 'svg
                      :data svg-data
                      :height `(,height-em . em)
                      :ascent ascent
                      :pointer 'hand)))))

;;; * overlay application

(defun tip--invalidate-on-modification (ov after-p _beg _end &optional _len)
  "Delete OV when its covered text is edited, so stale previews don't linger.
The preview-toggle cursor-transition logic only fires when the cursor
enters/leaves a fragment; an edit that doesn't cross a boundary (e.g.
backspace from immediately after the closing `$') would otherwise leave
the image displayed over now-mismatched source."
  (when (and after-p (overlay-buffer ov))
    (delete-overlay ov)))

(defun tip--apply-fragment-results (fragment-results)
  "Apply compiled SVG results as overlays.
FRAGMENT-RESULTS is a vector of alists with start, end, svg,
height_pt, depth_pt, width_pt, and (optional) error keys.
Handles narrowed buffers: `byte-to-position' needs full buffer access."
  (save-restriction
    (widen)
    (seq-doseq (frag fragment-results)
      (let* ((byte-start (alist-get 'start frag))
             (byte-end (alist-get 'end frag))
             (frag-beg (byte-to-position (1+ byte-start)))
             (frag-end (byte-to-position (1+ byte-end)))
             (svg-data (alist-get 'svg frag))
             (height-pt (alist-get 'height_pt frag))
             (depth-pt (alist-get 'depth_pt frag))
             (width-pt (alist-get 'width_pt frag))
             (font-size-pt (alist-get 'font_size_pt frag))
             (err (alist-get 'error frag)))
        ;; Error fragment: highlight with error face, optionally log.
        (when (and err frag-beg frag-end (= (length svg-data) 0))
          (when tip-echo-errors
            (message "TIP: %s" err))
          (dolist (ov (overlays-in frag-beg frag-end))
            (when (eq (overlay-get ov 'tip) 'tip)
              (delete-overlay ov)))
          (let ((ov (make-overlay frag-beg frag-end)))
            (overlay-put ov 'tip 'tip)
            (overlay-put ov 'face 'tip-error-face)))
        (when (and frag-beg frag-end (> (length svg-data) 0)
                   (> (or height-pt 0) 0.01)
                   (> (or width-pt 0) 0.01)
                   (not (string-match-p "width=\"0pt\"" svg-data)))
          (dolist (ov (overlays-in frag-beg frag-end))
            (when (eq (overlay-get ov 'tip) 'tip)
              (delete-overlay ov)))
          (let* ((frag-text (buffer-substring-no-properties frag-beg frag-end))
                 (class (tip-classify-fragment frag-text))
                 (is-single-line-display (eq class 'display-single))
                 (is-display (memq class '(display-single display-multi block)))
                 (img-spec (tip--make-image-spec svg-data height-pt depth-pt
                                                 is-display font-size-pt))
                 (display img-spec)
                 ;; For display math, eat a preceding blank line so the
                 ;; overlay doesn't leave an orphan gap.
                 (ov-beg (if (and is-display
                                  (> frag-beg (point-min))
                                  (eq (char-before frag-beg) ?\n)
                                  (or (= (1- frag-beg) (point-min))
                                      (eq (char-before (1- frag-beg)) ?\n)))
                             (1- frag-beg)
                           frag-beg))
                 (ov (make-overlay ov-beg frag-end)))
            (overlay-put ov 'tip 'tip)
            (overlay-put ov 'view-text nil)
            (overlay-put ov 'tip-height-pt height-pt)
            (overlay-put ov 'tip-depth-pt depth-pt)
            (overlay-put ov 'tip-width-pt (or width-pt 0))
            (overlay-put ov 'tip-font-size-pt font-size-pt)
            (overlay-put ov 'tip-svg svg-data)
            (overlay-put ov 'tip-fg (tip--color-to-hex
                                     (face-attribute 'default :foreground)))
            (unless tip-transparent-bg
              (overlay-put ov 'tip-bg (tip--color-to-hex
                                       (face-attribute 'default :background))))
            (overlay-put ov 'display display)
            (overlay-put ov 'modification-hooks
                         (list #'tip--invalidate-on-modification))
            (when (and is-single-line-display tip-display-indicator)
              (overlay-put ov 'before-string tip-display-indicator))))))))

;;; * theme change: fast SVG color substitution

(defun tip--recolor-overlays ()
  "Update SVG colors in all tip overlays to match current theme.
Does string replacement on cached SVG data — no server round-trip."
  (let ((new-fg (tip--color-to-hex (face-attribute 'default :foreground)))
        (new-bg (unless tip-transparent-bg
                  (tip--color-to-hex (face-attribute 'default :background)))))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (eq (overlay-get ov 'tip) 'tip)
        (let ((old-fg (overlay-get ov 'tip-fg))
              (old-bg (overlay-get ov 'tip-bg))
              (disp (overlay-get ov 'display)))
          (when (and old-fg disp (not (string= old-fg new-fg)))
            (let* ((svg (plist-get (cdr disp) :data))
                   (new-svg (when svg
                              (let ((s (string-replace old-fg new-fg svg)))
                                (if (and old-bg new-bg)
                                    (string-replace old-bg new-bg s)
                                  s)))))
              (when new-svg
                (setcar (cdr (plist-member (cdr disp) :data)) new-svg)
                (overlay-put ov 'tip-fg new-fg)
                (when new-bg
                  (overlay-put ov 'tip-bg new-bg))))))))))

(defun tip--on-theme-change (&rest _)
  "Update all tip buffers after a theme change.
Uses fast SVG color substitution (~0.5ms/fragment) rather than
recompilation (~17ms/fragment)."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when tip-mode
        (tip--recolor-overlays)
        (setq tip-live--content-cache "")))))

;;; * font change: rescale image specs without recompile

(defun tip--rescale-overlays ()
  "Update image specs on all tip overlays for the current font.
Recomputes scale and ascent from the current font metrics without
recompiling SVGs — no server round-trip."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (and (eq (overlay-get ov 'tip) 'tip)
               (overlay-get ov 'display))
      (let ((svg (overlay-get ov 'tip-svg))
            (h (overlay-get ov 'tip-height-pt))
            (d (overlay-get ov 'tip-depth-pt))
            (fs (overlay-get ov 'tip-font-size-pt)))
        (when (and svg h (> h 0))
          (let* ((disp (overlay-get ov 'display))
                 (old-ascent (plist-get (cdr disp) :ascent))
                 (is-display (eq old-ascent 'center))
                 (new-spec (tip--make-image-spec svg h d is-display fs)))
            (overlay-put ov 'display (car new-spec))))))))

(defun tip--on-font-change (&rest _)
  "Update all tip buffers after a font change.
Rescales overlays using current font metrics — no recompilation."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when tip-mode
        (tip--rescale-overlays)
        (setq tip-live--content-cache "")
        (setq tip-echo--content-cache "")))))

;;; * minor mode

;;;###autoload
(define-minor-mode tip-follow-theme-mode
  "Automatically update tip overlays when the Emacs theme changes.
Replaces colors in cached SVGs instantly — no server round-trip."
  :init-value nil
  :lighter ""
  (if tip-follow-theme-mode
      (progn
        (add-hook 'enable-theme-functions #'tip--on-theme-change)
        (add-hook 'disable-theme-functions #'tip--on-theme-change)
        (add-hook 'buffer-face-mode-hook #'tip--on-font-change nil t))
    (remove-hook 'enable-theme-functions #'tip--on-theme-change)
    (remove-hook 'disable-theme-functions #'tip--on-theme-change)
    (remove-hook 'buffer-face-mode-hook #'tip--on-font-change t)))

(provide 'tip-render)

;;; tip-render.el ends here
