;;; tip-live.el --- Live preview (childframe) + echo-area error feedback -*- lexical-binding: t; -*-

;;; Commentary:

;; Two small subsystems that sit on top of the compile pipeline:
;;
;; - tip-echo--compile-partial: while `tip-echo-errors' is on and the
;;   cursor is inside a fragment, recompile on idle and mirror any
;;   compilation error to the echo area.  Does not show successful
;;   renders (the overlay pipeline handles those).
;;
;; - tip-live-mode: compile the fragment at point on idle and show the
;;   live SVG.  `tip-live-style' picks the surface:
;;     - `after-string' (default): inline overlay, olp-live style.
;;       Inline math gets the image just after the closing delimiter;
;;       display math gets it on the line below.
;;     - `childframe': floating childframe (see tip-childframe.el).
;;
;; Both subsystems call into the backend via `tip--send-request' and
;; use `tip--get-bounds-of-math-at-point' / `tip--build-preamble' from
;; the Typst backend today.  When the tip-backend struct lands (task
;; #7) those calls will route through the active backend.

;;; Code:

(require 'tip-childframe)
(require 'tip-server-proc)
(require 'tip-backend)

;; Forward-declares from tip / tip-typst.
(defvar tip-echo-errors)
(defvar tip-mode)
(declare-function tip--color-to-hex "tip" (color))
(declare-function tip-edit-indirect--live-preview "tip-edit-indirect" ())
(defvar tip-edit-indirect-mode)

;;; * echo-area error feedback

(defvar-local tip-echo--content-cache ""
  "Cache of the last echo-error-checked fragment content.")

(defvar-local tip-echo--timer nil
  "Idle timer for echo-area error checking.")

(defun tip-echo--handle-result (result)
  "Log compilation errors via `tip-log'; ignore success."
  (let* ((err (alist-get 'error result))
         (frags (alist-get 'fragments result))
         (frag (and frags (> (length frags) 0) (aref frags 0)))
         (frag-err (and frag (alist-get 'error frag))))
    (cond
     (err (tip-log 'warning 'compile "%s" err))
     (frag-err (tip-log 'warning 'compile "%s" frag-err)))))

(defun tip-echo--compile-partial ()
  "Compile fragment at point and echo errors."
  (when (and tip-echo-errors
             tip-mode
             (eq major-mode 'typst-ts-mode)
             (eq (current-buffer) (window-buffer))
             (not (bound-and-true-p tip-live-mode)))
    (if-let* ((bound (tip-bounds-at-point (point)))
              (content (buffer-substring-no-properties (car bound) (cdr bound))))
        (unless (string-equal tip-echo--content-cache content)
          (setq tip-echo--content-cache content)
          (let ((byte-start (1- (position-bytes (car bound))))
                (byte-end (1- (position-bytes (cdr bound)))))
            (tip--sync-buffer)
            (tip--send-compile-fragments
             (list (cons byte-start byte-end))
             #'tip-echo--handle-result)))
      (setq tip-echo--content-cache ""))))

;;; * live preview

(defface tip-live-image
  '((((background light))
     :box (:line-width (1 . 1) :color "#9aa0a6")
     :background "#f1f3f4")
    (t
     :box (:line-width (1 . 1) :color "#5f6368")
     :background "#2d2f31"))
  "Face for the live preview image in `'after-string' style.
Provides a 1px border and a tinted background so the live preview
is visually distinct from the regular tip overlays."
  :group 'tip)

(defcustom tip-live-style 'after-string
  "How `tip-live-mode' displays the live preview.

- `after-string': inline overlay using the math fragment's `after-string'
  property, mirroring `org-latex-preview-live'.  Inline math gets the
  rendered image right after the closing delimiter; display math gets
  it on the line below the fragment.  No childframe.
- `childframe': floating childframe positioned per
  `tip-childframe-position'."
  :type '(choice (const :tag "Inline after-string (olp-style)" after-string)
                 (const :tag "Floating childframe" childframe))
  :group 'tip)

(defvar-local tip-live--content-cache ""
  "Cache of the last live-previewed fragment content.")

(defvar-local tip-live--timer nil
  "Idle timer for live preview.")

(defvar-local tip-live--anchor-pos nil
  "Buffer position to anchor the live preview to (end of current fragment).
Set by `tip-live--compile-partial' before each request and read by
`tip-live--handle-result' so the response lands at the fragment that
was current when the request was issued — surviving cursor moves
during the round-trip.")

(defvar-local tip-live--bound nil
  "(BEG . END) of the fragment being live-previewed.
Used by `'after-string' style to find/move the live overlay.")

(defvar-local tip-live--ov nil
  "Buffer-local overlay carrying the `after-string' live preview.
A single overlay is reused while the cursor stays in one fragment;
moved to a new range when the cursor enters a different fragment.")

(declare-function tip--make-image-spec "tip-render"
                  (svg-data height-pt depth-pt
                            &optional display-p rendered-pt frag-beg frag-end))

(defun tip-live--fragment-blank-p (text)
  "Non-nil when math fragment TEXT has whitespace-only inner content.
Strips one outer delimiter from each side (`$', `$$', `\\=\\(', `\\=\\[',
`\\=\\begin{X}', `\\=\\end{X}') and asks whether the rest is purely
blank.  Used by the live preview to skip empty fragments — they
produce zero-content overlays that show up as a stray box in the
buffer."
  (let ((s text))
    (when (string-match "\\`\\(\\\\begin{[^}]+}\\|\\\\\\[\\|\\\\(\\|\\$+\\)" s)
      (setq s (substring s (match-end 0))))
    (when (string-match "\\(\\\\end{[^}]+}\\|\\\\\\]\\|\\\\)\\|\\$+\\)\\'" s)
      (setq s (substring s 0 (match-beginning 0))))
    (string-match-p "\\`[ \t\n\r]*\\'" s)))

(defun tip-live--cleanup-overlay ()
  "Delete the live `after-string' overlay if any."
  (when (overlayp tip-live--ov)
    (when (overlay-buffer tip-live--ov)
      (delete-overlay tip-live--ov))
    (setq tip-live--ov nil)))

(defun tip-live--ensure-overlay (beg end)
  "Return a live overlay covering BEG..END, creating or moving as needed.
The overlay is tagged `tip-live' so it doesn't collide with the
regular `tip' overlays managed by `tip-render' / preview-toggle.  We
deliberately do NOT set its `display' — the user must see source
text while editing; the rendered image goes in `after-string'."
  (unless (and (overlayp tip-live--ov) (overlay-buffer tip-live--ov))
    (setq tip-live--ov (make-overlay beg end nil nil t))
    (overlay-put tip-live--ov 'tip-live t)
    ;; Sit above the static tip overlay so our after-string isn't
    ;; hidden by it (display property of underlying overlay would
    ;; otherwise eat the after-string visually).
    (overlay-put tip-live--ov 'priority 100))
  (move-overlay tip-live--ov beg end)
  tip-live--ov)

(defun tip-live--build-after-string (img-spec is-display)
  "Construct the after-string carrying IMG-SPEC.
For inline math (IS-DISPLAY nil): single space with image on it,
appearing just after the closing delimiter.  For display math: a
leading newline + zero-width space pushes the image onto the next
line — same trick `org-latex-preview-live' uses to avoid breaking
the surrounding paragraph layout."
  (let ((s (if is-display "\n​ " " ")))
    (setq s (copy-sequence s))
    (put-text-property (1- (length s)) (length s) 'display img-spec s)
    ;; Border + bg tinge on the image-bearing char so the live preview
    ;; reads as distinct from the static tip overlays.  (olp uses
    ;; `'(:box t)' here; we add a background and a softer color via
    ;; `tip-live-image' so the live state is more visually obvious.)
    (put-text-property (1- (length s)) (length s) 'face 'tip-live-image s)
    s))

(defun tip-live--show-after-string (svg h d _w fs class beg end)
  "Render SVG/H/D as an after-string on the live overlay at BEG..END.
CLASS is from `tip-classify-fragment' — `display-*' / `block' get
the next-line layout, others get inline-after layout."
  (let* ((is-display (memq class '(display-single display-multi block)))
         (img (tip--make-image-spec svg h d is-display fs beg end))
         (ov (tip-live--ensure-overlay beg end))
         (str (tip-live--build-after-string img is-display)))
    (overlay-put ov 'after-string str)))

(defun tip-live--show-error-after-string (msg beg end)
  "Stick an error MSG on the live overlay at BEG..END."
  (let ((ov (tip-live--ensure-overlay beg end)))
    (overlay-put ov 'after-string
                 (concat " " (propertize msg 'face 'error)))))

(defun tip-live--handle-result (result)
  "Handle compilation RESULT — show SVG or error per `tip-live-style'."
  (let* ((err (alist-get 'error result))
         (frags (alist-get 'fragments result))
         (frag (and frags (> (length frags) 0) (aref frags 0)))
         (frag-err (and frag (alist-get 'error frag)))
         (svg (and frag (alist-get 'svg frag)))
         (h  (and frag (alist-get 'height_pt frag)))
         (d  (and frag (alist-get 'depth_pt frag)))
         (w  (and frag (alist-get 'width_pt frag)))
         (fs (and frag (alist-get 'font_size_pt frag)))
         (anchor tip-live--anchor-pos)
         (bound tip-live--bound)
         (style tip-live-style))
    (pcase style
      ('after-string
       (cond
        ((or err frag-err)
         (when bound
           (tip-live--show-error-after-string (or err frag-err)
                                              (car bound) (cdr bound)))
         (tip-log 'warning 'compile "%s" (or err frag-err)))
        ((and svg (> (length svg) 0) h (> h 0) bound)
         (let* ((text (buffer-substring-no-properties (car bound) (cdr bound)))
                (class (tip-classify-fragment text)))
           (tip-live--show-after-string svg h d w fs class
                                        (car bound) (cdr bound))))
        (t (tip-live--cleanup-overlay))))
      (_  ; childframe
       (cond
        (err
         (tip-childframe-show-text err 'error anchor)
         (tip-log 'warning 'compile "%s" err))
        (frag-err
         (tip-childframe-show-text frag-err 'error anchor)
         (tip-log 'warning 'compile "%s" frag-err))
        ((and svg (> (length svg) 0) h (> h 0))
         (tip-childframe-show svg anchor))
        (t (tip-childframe-hide)))))))

(defun tip-live--hide ()
  "Tear down whichever live preview surface is active."
  (pcase tip-live-style
    ('after-string (tip-live--cleanup-overlay))
    (_             (tip-childframe-hide))))

(defun tip-live--compile-partial ()
  "Compile the math fragment at point for live preview.
Works in both normal typst-ts-mode and tip-edit-indirect buffers."
  (cond
   ;; In tip-edit-indirect buffer: delegate to the edit preview.
   ((bound-and-true-p tip-edit-indirect-mode)
    (tip-edit-indirect--live-preview))
   ;; In typst-ts-mode: compile fragment at point.
   ((eq major-mode 'typst-ts-mode)
    (let ((bound (tip-bounds-at-point (point))))
      (cond
       ((null bound)
        (tip-live--hide)
        (setq tip-live--content-cache "")
        (setq tip-live--anchor-pos nil)
        (setq tip-live--bound nil))
       (t
        ;; If the cursor jumped to a different fragment, drop the
        ;; old after-string overlay so the previous fragment's
        ;; live image disappears immediately.
        (unless (equal bound tip-live--bound)
          (when (eq tip-live-style 'after-string)
            (tip-live--cleanup-overlay)))
        (let ((content (buffer-substring-no-properties (car bound) (cdr bound))))
          (cond
           ;; Whitespace-only fragment — skip and clear any leftover
           ;; preview from a previous non-empty state of this same
           ;; fragment range.
           ((tip-live--fragment-blank-p content)
            (tip-live--hide)
            (setq tip-live--content-cache content
                  tip-live--anchor-pos (cdr bound)
                  tip-live--bound bound))
           ((string-equal tip-live--content-cache content) nil)
           (t
            (setq tip-live--content-cache content)
            (setq tip-live--anchor-pos (cdr bound))
            (setq tip-live--bound bound)
            (let ((byte-start (1- (position-bytes (car bound))))
                  (byte-end   (1- (position-bytes (cdr bound)))))
              (tip--sync-buffer)
              (tip--send-compile-fragments
               (list (cons byte-start byte-end))
               #'tip-live--handle-result)))))))))))

(defun tip-live--post-command ()
  "Drop the live preview the moment point leaves its fragment.
Without this, the live overlay only disappears on the next idle
tick (>=0.3s), which feels sticky.  Cheap: one position-compare per
command, no recompute."
  (when (and tip-live--bound
             (or (< (point) (car tip-live--bound))
                 (>= (point) (cdr tip-live--bound))))
    (tip-live--cleanup-overlay)
    (when (eq tip-live-style 'childframe) (tip-childframe-hide))
    (setq tip-live--content-cache ""
          tip-live--anchor-pos nil
          tip-live--bound nil)))

(defun tip-live--on-buffer-change (&rest _)
  "Tear down the live preview when switching away from a tip-mode buffer."
  (unless (and (eq major-mode 'typst-ts-mode)
               (bound-and-true-p tip-mode)
               (bound-and-true-p tip-live-mode))
    (tip-childframe-hide)))

(defun tip-live--on-buffer-kill ()
  "Tear down the live preview when a tip-mode buffer is killed."
  (when (bound-and-true-p tip-live-mode)
    (tip-live--cleanup-overlay)
    (tip-childframe-hide)))

;;;###autoload
(define-minor-mode tip-live-mode
  "Live preview of the math fragment at point.
Compiles the fragment under cursor on idle and shows the result via
`tip-live-style' — either an inline `after-string' overlay (default,
org-latex-preview-live style) or a floating childframe.  Opt-in:
enable with M-x tip-live-mode."
  :init-value nil
  :lighter " TIP-live"
  (if tip-live-mode
      (progn
        (setq tip-live--timer
              (run-with-idle-timer 0.3 t #'tip-live--compile-partial))
        (add-hook 'post-command-hook #'tip-live--post-command nil t)
        (add-hook 'window-buffer-change-functions #'tip-live--on-buffer-change)
        (add-hook 'kill-buffer-hook #'tip-live--on-buffer-kill nil t))
    (when tip-live--timer
      (cancel-timer tip-live--timer)
      (setq tip-live--timer nil))
    (remove-hook 'post-command-hook #'tip-live--post-command t)
    (remove-hook 'window-buffer-change-functions #'tip-live--on-buffer-change)
    (remove-hook 'kill-buffer-hook #'tip-live--on-buffer-kill t)
    (tip-live--cleanup-overlay)
    (tip-childframe-hide)
    (setq tip-live--content-cache ""
          tip-live--anchor-pos nil
          tip-live--bound nil)))

(provide 'tip-live)

;;; tip-live.el ends here
