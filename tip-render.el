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
(require 'tip-log)

;; Customs and helpers that live in tip.el / tip-live.el — forward-declared.
(defvar tip-transparent-bg)
(defvar tip-display-indicator)
(defvar tip-scale)
(defvar tip-baseline-offset)
(defvar tip-display-math-padding)
(defvar tip-image-face)
(defvar tip-image-face-blocklist)
(defvar tip-mode)
(defvar tip-live--content-cache)
(defvar tip-echo--content-cache)
(declare-function tip--color-to-hex "tip" (color))

;;; * in-buffer compile cache (LRU)

(defcustom tip-cache-enabled t
  "If nil, skip the in-memory compile-result cache entirely.
Typst-mode buffers opt out automatically (see
`tip--caching-enabled-p') because `#let' scope changes aren't
reflected in the cache key."
  :type 'boolean :group 'tip :local t)

(defcustom tip-cache-clear-on-server-restart t
  "If non-nil, drop every buffer's compile cache when tip-server restarts.
The cache key is (content, fg) — it does NOT capture which backend
or which server binary produced an SVG.  When the server is
swapped (version bump, docker→native, crash+respawn) the old
entries can be stale or outright wrong (e.g. a Typst-compiled SVG
sitting in the cache for a LaTeX buffer).  Clearing on restart is
cheap and rules that class of bug out."
  :type 'boolean :group 'tip)

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

(defun tip-cache-clear (&optional all-buffers)
  "Drop this buffer's compile cache.
With prefix arg, or non-nil ALL-BUFFERS, clear every buffer's cache.
Useful after restarting tip-server or swapping its binary."
  (interactive "P")
  (if all-buffers
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when tip--compile-cache
            (setq tip--compile-cache nil
                  tip--compile-cache-clock 0))))
    (setq tip--compile-cache nil
          tip--compile-cache-clock 0))
  (when (called-interactively-p 'interactive)
    (message "tip cache cleared%s" (if all-buffers " (all buffers)" ""))))

(defun tip--cache-key (content &rest _)
  ;; Server-side currentColor rendering means the SAME content produces
  ;; the SAME SVG regardless of the requested fg.  So the key is just
  ;; the content; the historical FG arg is accepted-and-ignored for
  ;; callsite compatibility.
  content)

(defun tip--caching-enabled-p ()
  "Return non-nil if the compile-result cache is safe for the active backend.

Typst fragments depend on document-wide scope (`#let' / `#import'
/ `#show' / `#set') that the cache key — fragment text + fg — does
NOT capture.  A plain `$foo$' may resolve to different things at
different points in the same document.  Opt-out here instead of
trying to hash the whole scope skeleton per lookup.

LaTeX's preamble does participate in the request already, but the
fragment key doesn't include it either; however in a single
editing session the preamble is approximately stable so cache hits
are still mostly correct.  Flip `tip-cache-enabled' to nil per
buffer if you hit scope-sensitivity there too."
  (and tip-cache-enabled
       (let ((b (and (fboundp 'tip-active-backend) (tip-active-backend))))
         (not (eq (and b (tip-backend-name b)) 'typst)))))

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

(defun tip--cache-put (content _fg plist)
  "Insert PLIST for CONTENT into the cache.
Stamps the entry with the current clock, then enforces
`tip-cache-max-entries' by evicting the LRU entry when exceeded.
The historical FG arg is accepted-and-ignored — see `tip--cache-key'."
  (let ((cache (tip--compile-cache)))
    (puthash (tip--cache-key content)
             (plist-put (copy-sequence plist) :ts (tip--cache-next-ts))
             cache)
    (when (and (bound-and-true-p tip-cache-max-entries)
               (> (hash-table-count cache) tip-cache-max-entries))
      (tip--cache-evict-lru))))

(defun tip--cache-get (content &optional _fg)
  "Return cached plist for CONTENT, or nil.
On hit, bumps the entry's timestamp so it survives eviction longer."
  (when tip--compile-cache
    (when-let* ((entry (gethash (tip--cache-key content)
                                tip--compile-cache)))
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
                                           is-display font-size-pt
                                           frag-beg frag-end))
           (image-face (tip--resolve-image-face frag-beg frag-end))
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
      (overlay-put ov 'display img-spec)
      ;; When `tip-image-face' computed a face, also pin it on the
      ;; overlay itself.  Emacs merges buffer-text-face under the image
      ;; for currentColor resolution; setting overlay 'face takes
      ;; priority and gives a clean single source.
      (when image-face (overlay-put ov 'face image-face))
      (overlay-put ov 'modification-hooks
                   (list #'tip--invalidate-on-modification))
      (when (and is-single-line-display tip-display-indicator)
        (overlay-put ov 'before-string tip-display-indicator))
      t)))

;; (Forward declarations at top of file.)

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
Respects `face-remapping-alist' (e.g. `variable-pitch-mode').
`face-attribute' can return the symbol `unspecified' (truthy but
not a font) when no graphical frame is selected — e.g. inside a
daemon's callback dispatched from a non-GUI context; guard with
`fontp'."
  (let ((font (face-attribute 'default :font)))
    (if (fontp font)
        (let ((sz (font-get font :size)))
          (if (and (numberp sz) (> sz 0)) sz 15))
      15)))

(defun tip--font-metrics ()
  "Return (ASCENT . DESCENT) in pixels for the default face font.
Respects `face-remapping-alist'.  Falls back to 80/20 split of
pixel-size when the face has no real font (daemon without GUI
frame, batch mode, etc.)."
  (let* ((font (face-attribute 'default :font))
         (info (and (fontp font) (font-info (font-xlfd-name font)))))
    (if (and info (> (length info) 9))
        (cons (aref info 8) (aref info 9))
      (let ((px (tip--font-pixel-size)))
        (cons (round (* px 0.8)) (round (* px 0.2)))))))

;;; * image spec

(defun tip--resolve-image-face (frag-beg frag-end)
  "Return the face to attach to the overlay's image spec, or nil.
Honors `tip-image-face':
  nil    → return nil (Emacs picks the face at point — default).
  symbol → that symbol (e.g. `default', `shadow').
  `auto' → `(get-text-property (1- frag-beg) \\='face)' (or just
           after frag-end if before is unhelpful), filtered through
           `tip-image-face-blocklist', wrapped to fall back to
           `default'.  Mirrors org-latex-preview's --face-around."
  (cond
   ((null tip-image-face) nil)
   ((not (eq tip-image-face 'auto)) tip-image-face)
   (t
    (let* ((raw
            (or (and (> frag-beg (point-min))
                     (not (eq (char-before frag-beg) ?\n))
                     (get-text-property (1- frag-beg) 'face))
                (and (< frag-end (point-max))
                     (not (eq (char-after frag-end) ?\n))
                     (get-text-property frag-end 'face))))
           (filtered
            (cond
             ((null raw) nil)
             ((and (symbolp raw)
                   (memq raw tip-image-face-blocklist))
              nil)
             ((symbolp raw) raw)
             ((listp raw)
              (let ((cleaned
                     (seq-remove
                      (lambda (f) (and (symbolp f)
                                       (memq f tip-image-face-blocklist)))
                      raw)))
                (cond
                 ((null cleaned) nil)
                 ((= (length cleaned) 1) (car cleaned))
                 (t cleaned)))))))
      ;; Always include `default' as a fallback so attribute lookups
      ;; resolve sanely.  When filtered is nil, just use default.
      (cond
       ((null filtered) 'default)
       ((symbolp filtered) (list filtered 'default))
       ((listp filtered) (append filtered '(default))))))))

(defun tip--make-image-spec (svg-data height-pt depth-pt
                                      &optional display-p rendered-pt
                                      frag-beg frag-end)
  "Create an image display spec from SVG-DATA with HEIGHT-PT and DEPTH-PT.
When DISPLAY-P is non-nil, use vertical centering (for display math).
RENDERED-PT is the backend's native render size (see
`tip--effective-scale').  Defaults to 11.0.
FRAG-BEG/FRAG-END are used by `tip-image-face' = `auto' to compute
the surrounding face."
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
    (let ((face (and frag-beg frag-end
                     (tip--resolve-image-face frag-beg frag-end))))
      (list (cons 'image
                  (append (list :type 'svg
                                :data svg-data
                                :height `(,height-em . em)
                                :ascent ascent
                                :pointer 'hand)
                          (when face (list :face face))))))))

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
Handles narrowed buffers: `byte-to-position' needs full buffer access.

Cascade-suspect errors are demoted to `tip-cascade-face' — see
`tip--detect-cascade'.  When a cascade is detected, a one-line
diagnostic is echoed and later errors get minimal visual weight."
  (let* ((cascade-root (and (fboundp 'tip--detect-cascade)
                            (tip--detect-cascade fragment-results)))
         (frag-idx -1))
    (when cascade-root
      (let ((errs (seq-filter (lambda (f) (alist-get 'error_detail f))
                              (append fragment-results nil))))
        (message "tip: %d/%d errors look like a cascade — fix the first one"
                 (length errs) (length (append fragment-results nil)))))
  (save-restriction
    (widen)
    (seq-doseq (frag fragment-results)
      (cl-incf frag-idx)
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
             ;; Typst backend currently emits only a plain `error'
             ;; string (no structured `error_detail'); LaTeX populates
             ;; both.  Synthesize minimal severity/message from `err'
             ;; so navigation/eldoc/flymake don't silently drop Typst
             ;; errors.  Normalize severity to a symbol: json-parse
             ;; hands us "warning" / "error" strings, and earlier
             ;; client code assumed a symbol.
             (err-severity (let ((s (or (alist-get 'severity err-detail)
                                        (and err 'error))))
                             (if (stringp s) (intern s) s)))
             (err-message (or (alist-get 'message err-detail) err))
             (err-hint (alist-get 'hint err-detail))
             (err-line (alist-get 'line_in_fragment err-detail))
             (err-full (alist-get 'detail err-detail)))
        ;; Failed fragment path: err OR err-detail present.  Show the
        ;; source text with an inline marker + error-face underline on
        ;; the hint region (if we can locate it).  preview.sty often
        ;; produces a partial SVG even on error — we intentionally do
        ;; NOT display that garbled image; user needs to see the source
        ;; to fix it.
        ;;
        ;; Warnings (severity = warning) are a separate case: the SVG
        ;; DID render correctly, the warning is informational.  Those
        ;; fall through to the success path and attach a `⚑' hint
        ;; via a secondary overlay below.
        (when (and frag-beg frag-end (or err err-detail)
                   (not (eq err-severity 'warning)))
          (tip-log 'warning 'compile "[%s] %s"
                   (or err-severity "error")
                   (or err-message err "compile failed"))
          (dolist (ov (overlays-in frag-beg frag-end))
            (when (eq (overlay-get ov 'tip) 'tip)
              (delete-overlay ov)))
          (let* ((hint-range (tip--locate-error-hint frag-beg frag-end
                                                     err-hint err-line))
                 (is-cascade-victim
                  (and cascade-root (/= frag-idx cascade-root)))
                 (face (cond (is-cascade-victim 'tip-cascade-face)
                             ((eq err-severity 'warning) 'tip-warning-face)
                             (t 'tip-error-face)))
                 (marker (cond (is-cascade-victim "")
                               ((eq err-severity 'warning) "⚑ ")
                               (t "⚠ ")))
                 ;; Underline overlay: whole fragment if hint can't be
                 ;; located, else just the hint region.
                 (under-beg (or (car hint-range) frag-beg))
                 (under-end (or (cdr hint-range) frag-end))
                 (ov (make-overlay under-beg under-end)))
            (overlay-put ov 'tip 'tip)
            (overlay-put ov 'face face)
            (when is-cascade-victim
              (overlay-put ov 'tip-cascade t))
            (overlay-put ov 'before-string
                         (if (string-empty-p marker)
                             nil
                           (propertize marker 'face face)))
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
        ;; Success path — valid SVG AND no render-blocking error.
        ;; Warnings are tolerated: the SVG is good, we'll attach the
        ;; warning as metadata on the overlay so flymake / eldoc still
        ;; surface it.
        (when (and frag-beg frag-end (> (length svg-data) 0)
                   (> (or height-pt 0) 0.01)
                   (> (or width-pt 0) 0.01)
                   (or (null err-detail) (eq err-severity 'warning))
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
                                                 is-display font-size-pt
                                                 frag-beg frag-end))
                 (display img-spec)
                 (image-face (tip--resolve-image-face frag-beg frag-end))
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
            (when image-face (overlay-put ov 'face image-face))
            ;; Populate the compile cache (so cursor transitions don't
            ;; re-compile), but only for backends where the (content+fg)
            ;; key actually captures the full compile input.  See
            ;; `tip--caching-enabled-p'.
            (when (tip--caching-enabled-p)
              (tip--cache-put
               frag-text
               (tip--color-to-hex (face-attribute 'default :foreground))
               (list :svg svg-data :height-pt height-pt :depth-pt depth-pt
                     :width-pt (or width-pt 0) :font-size-pt font-size-pt)))
            (overlay-put ov 'display display)
            (overlay-put ov 'modification-hooks
                         (list #'tip--invalidate-on-modification))
            ;; If the fragment rendered but emitted a warning (e.g.
            ;; `\ref{foo}' resolving to ??), stamp the warning onto
            ;; the image overlay so flymake / eldoc / tip-next-error
            ;; still see it.  The image itself stays displayed.
            (when (eq err-severity 'warning)
              (overlay-put ov 'tip-error-severity 'warning)
              (overlay-put ov 'tip-error-message err-message)
              (overlay-put ov 'tip-error-hint err-hint)
              (overlay-put ov 'tip-error-line err-line)
              (overlay-put ov 'tip-error-detail err-full)
              (overlay-put ov 'tip-frag-beg frag-beg)
              (overlay-put ov 'tip-frag-end frag-end)
              (overlay-put ov 'help-echo (or err-message err)))
            (when (and is-single-line-display tip-display-indicator)
              (overlay-put ov 'before-string tip-display-indicator)))))))))

;;; * font change: rescale image specs without recompile
;;
;; Theme-change tracking used to live here — a string-replace pass over
;; every overlay's SVG on `enable-theme-functions' that swapped the
;; baked-in fg color.  The server now emits SVGs with
;; `fill="currentColor"' (see tip-protocol::svg_color), so Emacs picks
;; the face's :foreground at display time and theme changes cost
;; nothing.  Font-size changes still require rescaling the image spec
;; because `(N . em)' in Emacs image heights is evaluated once at
;; overlay creation — see `tip--on-font-change' below.

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

(defun tip--refresh-overlay-face (ov)
  "Re-resolve `tip-image-face' for OV and rebuild its image spec.
Use when surrounding text changed so the face under the fragment
shifted (e.g. user removed a `\\fbox{...}' wrapper).  No recompile —
just walks `tip-image-face' against the current buffer state and
rebuilds the SVG image spec."
  (when (and (eq (overlay-get ov 'tip) 'tip)
             (overlay-get ov 'tip-svg)
             (overlay-get ov 'display))
    (let* ((frag-beg (overlay-start ov))
           (frag-end (overlay-end ov))
           (new-face (tip--resolve-image-face frag-beg frag-end))
           (old-face (overlay-get ov 'face)))
      (unless (equal new-face old-face)
        (let* ((svg (overlay-get ov 'tip-svg))
               (h   (overlay-get ov 'tip-height-pt))
               (d   (overlay-get ov 'tip-depth-pt))
               (fs  (overlay-get ov 'tip-font-size-pt))
               (disp (overlay-get ov 'display))
               (is-display (eq (plist-get (cdr disp) :ascent) 'center))
               (spec (tip--make-image-spec svg h d is-display fs
                                           frag-beg frag-end)))
          (overlay-put ov 'face new-face)
          (overlay-put ov 'display (car spec)))))))

;;;###autoload
(defun tip-refresh-overlay-faces ()
  "Re-resolve `tip-image-face' on every tip overlay in this buffer.
Use after structural edits (e.g. removing a `\\fbox{...}' wrapper)
that change the surrounding face but leave the math fragment
itself intact.  No recompile.  Also runs as `:after' advice on
`font-lock-update' (`C-x x f') for `tip-mode' buffers."
  (interactive)
  (when tip-image-face
    (dolist (ov (overlays-in (point-min) (point-max)))
      (tip--refresh-overlay-face ov))))

(defun tip--refresh-on-font-lock-update (&rest _)
  (when (bound-and-true-p tip-mode)
    (tip-refresh-overlay-faces)))

(advice-add 'font-lock-update :after #'tip--refresh-on-font-lock-update)

(defun tip--on-font-change (&rest _)
  "Update all tip buffers after a font change.
Rescales overlays using current font metrics — no recompilation."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when tip-mode
        (tip--rescale-overlays)
        (setq tip-live--content-cache "")
        (setq tip-echo--content-cache "")))))

;; tip-follow-theme-mode used to live here as a separate minor mode that
;; (a) hooked enable-theme-functions to recolor SVGs and (b) hooked
;; buffer-face-mode-hook to rescale on font change.  (a) is no longer
;; needed (currentColor handles theme), and (b) is now wired directly
;; from `tip-mode' — no separate toggle adds value.

(provide 'tip-render)

;;; tip-render.el ends here
