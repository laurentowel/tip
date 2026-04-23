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

;;; * in-buffer compile cache (LRU)

(defvar-local tip--compile-cache nil
  "Buffer-local hash-table mapping cache-key → plist.
Key:   (CONTENT . FG-COLOR) cons.
Value: plist with :svg :height-pt :depth-pt :width-pt :font-size-pt :ts .
:ts is an integer access timestamp used for LRU eviction.

In-memory only; not persisted across Emacs restarts.  See
`tip-cache-max-entries' for eviction behaviour.  Populated by
`tip--apply-fragment-results', consulted by callers before sending
requests to the server so moving the cursor through an unchanged
fragment costs no compile.")

(defvar-local tip--compile-cache-clock 0
  "Monotonic counter used to order cache entries by access recency.")

(defvar tip-cache-max-entries)

(defun tip--compile-cache ()
  "Ensure the buffer-local cache is initialised and return it."
  (or tip--compile-cache
      (setq tip--compile-cache (make-hash-table :test 'equal))))

(defun tip--cache-key (content fg)
  (cons content fg))

(defun tip--cache-next-ts ()
  (cl-incf tip--compile-cache-clock))

(defun tip--cache-evict-lru ()
  "Drop the single least-recently-used entry from the cache."
  (when tip--compile-cache
    (let (min-ts min-key)
      (maphash (lambda (k v)
                 (let ((ts (plist-get v :ts)))
                   (when (or (null min-ts) (< ts min-ts))
                     (setq min-ts ts min-key k))))
               tip--compile-cache)
      (when min-key (remhash min-key tip--compile-cache)))))

(defun tip--cache-put (content fg plist)
  "Insert PLIST for (CONTENT . FG) into the cache.
Stamps the entry with the current clock, then enforces
`tip-cache-max-entries' by evicting the LRU entry when exceeded."
  (let ((cache (tip--compile-cache)))
    (puthash (tip--cache-key content fg)
             (plist-put (copy-sequence plist) :ts (tip--cache-next-ts))
             cache)
    (when (and (bound-and-true-p tip-cache-max-entries)
               (> (hash-table-count cache) tip-cache-max-entries))
      (tip--cache-evict-lru))))

(defun tip--cache-get (content fg)
  "Return cached plist for (CONTENT . FG), or nil.
On hit, bumps the entry's timestamp so it survives eviction longer."
  (when tip--compile-cache
    (when-let* ((entry (gethash (tip--cache-key content fg)
                                tip--compile-cache)))
      ;; Touch: update :ts in place.
      (plist-put entry :ts (tip--cache-next-ts))
      entry)))

;;;###autoload
(defun tip-clear-compile-cache ()
  "Clear this buffer's in-memory compile cache.
Next render request will go to the server even for previously-seen
fragments.  Useful after preamble edits that don't change fragment
text (e.g. swapping a custom command definition)."
  (interactive)
  (when tip--compile-cache
    (clrhash tip--compile-cache))
  (setq tip--compile-cache-clock 0)
  (message "tip: compile cache cleared"))

(defun tip--apply-cached-fragment (frag-beg frag-end cached)
  "Create an overlay for cached PLIST at buffer FRAG-BEG..FRAG-END.
Returns non-nil on success.  Equivalent to one iteration of
`tip--apply-fragment-results' but skips the server round-trip."
  (when (and frag-beg frag-end cached)
    (dolist (ov (overlays-in frag-beg frag-end))
      (when (eq (overlay-get ov 'tip) 'tip)
        (delete-overlay ov)))
    (let* ((svg-data (plist-get cached :svg))
           (height-pt (plist-get cached :height-pt))
           (depth-pt (plist-get cached :depth-pt))
           (width-pt (plist-get cached :width-pt))
           (font-size-pt (plist-get cached :font-size-pt))
           (frag-text (buffer-substring-no-properties frag-beg frag-end))
           (class (tip-classify-fragment frag-text))
           (is-single-line-display (eq class 'display-single))
           (is-display (memq class '(display-single display-multi block)))
           (img-spec (tip--make-image-spec svg-data height-pt depth-pt
                                           is-display font-size-pt))
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
      (overlay-put ov 'display img-spec)
      (overlay-put ov 'modification-hooks
                   (list #'tip--invalidate-on-modification))
      (when (and is-single-line-display tip-display-indicator)
        (overlay-put ov 'before-string tip-display-indicator))
      t)))

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

(defvar tip-display-math-width)

(defun tip--pad-svg-viewbox (svg-data padding)
  "Expand SVG-DATA viewBox by PADDING pt above and below.
Returns (SVG-STRING . ADDED-HEIGHT-PT)."
  (if (and (> padding 0)
           (string-match
            "viewBox=[\"']\\([^ \"']+\\) \\([^ \"']+\\) \\([^ \"']+\\) \\([^ \"']+\\)[\"']"
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
             (result (if (string-match "height=[\"'][^\"']+[\"']" result)
                         (replace-match
                          (format "height=\"%spt\"" new-vh) t t result)
                       result)))
        (cons result (* 2.0 padding)))
    (cons svg-data 0.0)))

(defun tip--resolve-display-width-em ()
  "Return the configured display-math target width in em, or nil.
Reads `tip-display-math-width' — a number uses it directly, a plist
selects by active backend name (falling back to `:default').
The resolved value is sent to the server so display math is laid out
at textwidth = NNem by LaTeX itself (centering happens naturally)."
  (when (boundp 'tip-display-math-width)
    (let ((raw tip-display-math-width))
      (cond
       ((null raw) nil)
       ((numberp raw) raw)
       ((and (listp raw) (keywordp (car raw)))
        (let* ((backend (when (fboundp 'tip-active-backend)
                          (let ((b (tip-active-backend)))
                            (and b (tip-backend-name b)))))
               (key (and backend (intern (concat ":" (symbol-name backend)))))
               (per-backend (and key (plist-get raw key)))
               (default (plist-get raw :default)))
          (or per-backend default)))
       (t nil)))))

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

;;; * error-overlay helpers

(defun tip--locate-error-hint (frag-beg frag-end hint &optional line-in-fragment)
  "Search for HINT (a substring) inside (FRAG-BEG..FRAG-END) and return
\(BEG . END) of the first match, or nil if HINT is nil/empty/not found.

LINE-IN-FRAGMENT, when a non-negative integer, biases the search to the
Nth line of the fragment so that repeated tokens (`$', `x', …) don't
yield the first occurrence in a multi-line fragment.  Exact line
position isn't always reliable (LaTeX's `l.N' sometimes points at a
recovery artifact), so we fall back to a plain first-match search."
  (when (and hint (> (length hint) 0))
    (save-excursion
      (save-restriction
        (narrow-to-region frag-beg frag-end)
        (let ((search-start
               (if (and (integerp line-in-fragment)
                        (> line-in-fragment 0))
                   (save-excursion
                     (goto-char (point-min))
                     (forward-line line-in-fragment)
                     (point))
                 (point-min))))
          (goto-char search-start)
          (or (search-forward hint nil t)
              (progn (goto-char (point-min))
                     (search-forward hint nil t)))
          (when (match-beginning 0)
            (cons (match-beginning 0) (match-end 0))))))))

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
height_pt, depth_pt, width_pt, optional error, and optional
error_detail (severity, message, hint, line_in_fragment, detail).
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
             (err (alist-get 'error frag))
             (err-detail (alist-get 'error_detail frag))
             (err-severity (alist-get 'severity err-detail))
             (err-message (alist-get 'message err-detail))
             (err-hint (alist-get 'hint err-detail))
             (err-line (alist-get 'line_in_fragment err-detail))
             (err-full (alist-get 'detail err-detail)))
        ;; Failed fragment path: err OR err-detail present.  Show the
        ;; source text with an inline marker + error-face underline on
        ;; the hint region (if we can locate it).  preview.sty often
        ;; produces a partial SVG even on error — we intentionally do
        ;; NOT display that garbled image; user needs to see the source
        ;; to fix it.
        (when (and frag-beg frag-end (or err err-detail))
          (when tip-echo-errors
            (message "TIP [%s]: %s" (or err-severity "error")
                     (or err-message err "compile failed")))
          (dolist (ov (overlays-in frag-beg frag-end))
            (when (eq (overlay-get ov 'tip) 'tip)
              (delete-overlay ov)))
          (let* ((hint-range (tip--locate-error-hint frag-beg frag-end
                                                     err-hint err-line))
                 (face (if (eq err-severity 'warning)
                           'tip-warning-face
                         'tip-error-face))
                 (marker (cond ((eq err-severity 'warning) "⚑ ")
                               (t "⚠ ")))
                 ;; Underline overlay: whole fragment if hint can't be
                 ;; located, else just the hint region.
                 (under-beg (or (car hint-range) frag-beg))
                 (under-end (or (cdr hint-range) frag-end))
                 (ov (make-overlay under-beg under-end)))
            (overlay-put ov 'tip 'tip)
            (overlay-put ov 'face face)
            (overlay-put ov 'before-string
                         (propertize marker 'face face))
            (overlay-put ov 'help-echo
                         (if err-full
                             (format "%s\n\n%s"
                                     (or err-message err) err-full)
                           (or err-message err "compile failed")))
            (overlay-put ov 'tip-error-severity err-severity)
            (overlay-put ov 'tip-error-message err-message)
            (overlay-put ov 'tip-error-hint err-hint)
            (overlay-put ov 'tip-error-line err-line)
            (overlay-put ov 'tip-error-detail err-full)
            ;; Remember the fragment range for next-error navigation even
            ;; when the underline covers a smaller span.
            (overlay-put ov 'tip-frag-beg frag-beg)
            (overlay-put ov 'tip-frag-end frag-end)))
        ;; Success path — only when we have a valid SVG AND no error_detail.
        (when (and frag-beg frag-end (> (length svg-data) 0)
                   (> (or height-pt 0) 0.01)
                   (> (or width-pt 0) 0.01)
                   (not err-detail)
                   (not err)
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
            ;; Populate the compile cache so moving the cursor through
            ;; this fragment (without editing) won't cost a round-trip.
            (tip--cache-put
             frag-text
             (tip--color-to-hex (face-attribute 'default :foreground))
             (list :svg svg-data :height-pt height-pt :depth-pt depth-pt
                   :width-pt (or width-pt 0) :font-size-pt font-size-pt))
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
