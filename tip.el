;;; tip.el --- Typeset Inline Preview -*- lexical-binding: t; -*-

;; Author: Elio Azuray
;; URL: https://github.com/elioazuray/typst-inline-preview
;; Version: 2.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, typst, tex, preview

;; This file is not part of GNU Emacs.

;;; Commentary:

;; TIP — Typeset Inline Preview.  A backend-pluggable framework for
;; rendering typeset fragments (math, figures) as inline SVG overlays.
;; The active backend today is Typst (via typst-ts-mode); a LaTeX
;; backend is planned.
;;
;; Communicates with a per-backend server binary (e.g. tip-server-typst)
;; via stdio JSON-RPC.  Requires the binary on `exec-path' or
;; configured via `tip-server-executable'.

;;; Code:

(require 'json)
(require 'treesit)
(require 'cl-lib)
(require 'preview-toggle)
(require 'tip-childframe)
(require 'tip-backend)
(require 'tip-server-proc)
(require 'tip-render)
(require 'tip-typst)
(require 'tip-latex)
(require 'tip-live)

;;; * custom settings

(defcustom tip-enable-debug nil
  "Enable debug messages."
  :type 'boolean
  :group 'tip)

(defcustom tip-echo-errors nil
  "When non-nil, show compilation errors in the echo area."
  :type 'boolean
  :group 'tip)

(defcustom tip-font-dirs nil
  "Additional font directories for tip-server.
Each entry is either:
- An absolute path string (used as-is)
- A cons pair (ANCHOR . RELATIVE) where ANCHOR is a directory
  and RELATIVE is resolved against it.  Use \".\" as ANCHOR in
  .dir-locals.el to mean the project root (the directory
  containing .dir-locals.el).

Example in .dir-locals.el:
  ((typst-ts-mode . ((tip-font-dirs . ((\".\" . \"fonts\"))))))

Example in init.el (global):
  (setq-default tip-font-dirs \\='(\"/home/user/.local/share/fonts/math\"))"
  :type '(repeat (choice string (cons string string)))
  :group 'tip)

(defcustom tip-server-executable nil
  "Path to the tip-server binary.
If nil, auto-detected from PATH, local build, or user prompted."
  :type '(choice (const :tag "Auto-detect" nil) string)
  :group 'tip)

(defcustom tip-use-docker nil
  "If non-nil, run tip-server via Docker instead of a local binary."
  :type 'boolean
  :group 'tip)

(defcustom tip-docker-image "tip-server-typst:latest"
  "Docker image name for tip-server."
  :type 'string
  :group 'tip)

(defcustom tip-display-indicator
  (propertize "𝐃" 'face '(:foreground "orange" :weight bold))
  "String shown before single-line display math overlays.
Set to nil to disable the indicator."
  :type '(choice string (const nil))
  :group 'tip)

(defcustom tip-scale 'auto
  "Scaling factor for inline preview images.
When `auto' (default), computed as emacs-font-size / 11.0 so that
math rendered at Typst's fixed 11pt matches the buffer text size.
Set to a number to override (1.0 = render at Typst's native 11pt)."
  :type '(choice (const :tag "Auto (match buffer font size)" auto)
                 (float :tag "Manual scale factor"))
  :group 'tip)

(defcustom tip-baseline-offset 0
  "Baseline correction in ascent percentage points.
Adjusts the vertical position of all math fragments uniformly.
Positive shifts math down, negative shifts up.
Default is 0 — the pixel-aware ascent calculation should handle
rounding automatically.  Adjust only if baselines are visibly off:
  (progn (setq tip-baseline-offset -1) (tip-render-all))"
  :type 'number
  :group 'tip)

(defcustom tip-display-math-padding 3.0
  "Extra vertical padding (in pt) added above and below display math.
Prevents the rendered image from feeling cramped.  Applied by
expanding the SVG viewBox; does not require recompilation.
  (progn (setq tip-display-math-padding 5) (tip-render-all))"
  :type 'number
  :group 'tip)

(defcustom tip-transparent-bg t
  "If non-nil, render SVGs with transparent background.
When nil, the SVG background is filled with the Emacs default
background color (and swapped on theme change)."
  :type 'boolean
  :group 'tip)

(defcustom tip-cache-max-entries 500
  "Maximum fragments kept in the buffer-local compile cache.
When the cache grows past this, the least-recently-accessed entry is
evicted.  ~5 KB per SVG × 500 ≈ 2.5 MB per buffer — negligible for
typical papers (50-200 fragments) but caps memory on pathologically
large buffers.  Set to nil to disable eviction.

The cache is in-memory only; it does not survive Emacs restart.
Persistent cache is future work (see doc/latex-preview-survey.md)."
  :type '(choice (const :tag "Unbounded (not recommended)" nil)
                 (integer :tag "Max entries"))
  :group 'tip)

(defcustom tip-display-math-width nil
  "Target width for displayed math overlays, in em.
Applies to block math, numbered equations, multi-line aligns,
pmatrix, cases — anything classified as display-single, display-multi,
or block.  Inline math is never affected.

  nil         — tight (ink-cropped) SVG at cursor position.  Default.
  NUMBER      — total SVG width in em units (e.g. 20 → 20em wide,
                math centered within).
  PLIST       — per-backend override.  Keys are backend names (symbols
                matching `(tip-backend-name (tip-active-backend))'),
                plus optional `:default'.  Each value obeys the NUMBER
                rule.  Example: \\='(:latex 22 :typst 20 :default 20).

Future: a window-fraction mode (e.g. 0.9 → 90% of line width) may be
added; for now keep it explicit in em to sidestep window-size volatility.
Buffer-local."
  :type '(choice (const :tag "Tight (ink-cropped)" nil)
                 (number :tag "Absolute width in em")
                 (plist  :key-type symbol :value-type number))
  :group 'tip
  :local t)


;;; * preamble (theme sync)

(defun tip--color-to-hex (color)
  "Convert an Emacs COLOR name or hex to a #RRGGBB hex string."
  (if (string-prefix-p "#" color)
      ;; Already hex — ensure 7-char format
      (if (= (length color) 7)
          color
        ;; Handle #RGB short form or other lengths
        (apply #'format "#%02x%02x%02x"
               (mapcar (lambda (c) (/ c 256))
                       (color-values color))))
    ;; Named color — convert via color-values
    (let ((vals (color-values color)))
      (if vals
          (apply #'format "#%02x%02x%02x"
                 (mapcar (lambda (c) (/ c 256)) vals))
        "#000000"))))

;;; * compilation and rendering

(defun tip-send-region (beg end &optional avoid-pos)
  "Compile and render all math fragments in region BEG..END."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (error "No region selected")))
  (let* ((buf (current-buffer))
         (fg (tip--color-to-hex (face-attribute 'default :foreground)))
         (preamble (tip-build-preamble))
         (frag-locs (tip-collect-fragments beg end avoid-pos))
         (n (length frag-locs))
         (display-width-em (tip--resolve-display-width-em))
         ;; Partition into cache hits (create overlays immediately) and
         ;; cache misses (send to the server).
         (misses nil)
         (cache-hits 0))
    (dolist (frag frag-locs)
      (let* ((sb (1+ (alist-get "start" frag nil nil #'equal)))
             (eb (1+ (alist-get "end"   frag nil nil #'equal)))
             (p1 (byte-to-position sb))
             (p2 (byte-to-position eb))
             (content (buffer-substring-no-properties p1 p2))
             (cached (tip--cache-get content fg)))
        (if cached
            (progn
              (tip--apply-cached-fragment p1 p2 cached)
              (cl-incf cache-hits))
          (push frag misses))))
    (setq misses (nreverse misses))
    (when (and tip-enable-debug (> cache-hits 0))
      (message "tip: cache hits=%d misses=%d" cache-hits (length misses)))
    (when misses
      (let ((params `(("uri" . ,(buffer-file-name))
                      ("fragments" . ,(vconcat misses))
                      ("color" . ,fg)
                      ("preamble" . ,preamble))))
        (when display-width-em
          (setq params
                (append params
                        `(("display_math_width"
                           . ,(format "%sem" display-width-em))))))
        (tip--sync-buffer)
        (tip--send-request
         "compile_fragments" params
         (lambda (result)
           (with-current-buffer buf
             (tip--apply-fragment-results
              (alist-get 'fragments result)))))))
    ;; Return value unused; keep n for the interactive case.
    n))

;;; * public commands

;;;###autoload
(defun tip-render-all ()
  "Render all math fragments in the buffer."
  (interactive)
  (tip-send-region (point-min) (point-max)))

;;;###autoload
(defun tip-send-nbd ()
  "Render visible fragments, avoiding the one at point."
  (interactive)
  (tip-send-region (window-start) (window-end) (point)))

;;;###autoload
(defun tip-send-all ()
  "Render the whole buffer."
  (interactive)
  (tip-send-region (point-min) (point-max)))

;;;###autoload
(defun tip-copy-svg-at-point ()
  "Copy the SVG data of the tip overlay at point to the kill ring.
Works even when the overlay is open (display cleared)."
  (interactive)
  (let ((ov (seq-find (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
                      (append (overlays-at (point))
                              (overlays-in (point) (min (1+ (point)) (point-max)))))))
    (if ov
        (let* ((disp (overlay-get ov 'display))
               (svg (or (and disp (plist-get (cdr (car-safe disp)) :data))
                        (overlay-get ov 'tip-svg))))
          (if svg
              (progn
                (kill-new svg)
                (message "SVG copied (%d bytes)" (length svg)))
            (message "Overlay has no SVG data (not yet compiled?)")))
      (message "No tip overlay at point"))))

;;;###autoload
(defun tip-show-skeleton-at-point ()
  "Display the scoped skeleton for the fragment at point.
Shows the synthetic Typst source that the server would compile,
including all scope-defining statements visible at this position."
  (interactive)
  (let ((bounds (tip-bounds-at-point (point))))
    (unless bounds
      (user-error "No math or figure fragment at point"))
    (let ((byte-start (1- (position-bytes (car bounds))))
          (byte-end (1- (position-bytes (cdr bounds))))
          (buf (current-buffer)))
      (tip--sync-buffer)
      (tip--send-request
       "debug_skeleton"
       `(("uri" . ,(buffer-file-name))
         ("start" . ,byte-start)
         ("end" . ,byte-end))
       (lambda (result)
         (let ((source (alist-get 'source result))
               (err (alist-get 'error result)))
           (if err
               (message "TIP skeleton error: %s" err)
             (with-current-buffer (get-buffer-create "*tip-skeleton*")
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert source)
                 (when (fboundp 'typst-ts-mode) (typst-ts-mode))
                 (goto-char (point-min)))
               (display-buffer (current-buffer))))))))))

;;; * cursor and overlay management (delegates to preview-toggle)

;;;###autoload
(defun tip-open ()
  "Open overlay at point."
  (interactive)
  (preview-toggle-open-at-point))

(defun tip--compile-region (beg end)
  "Compile math fragments in region BEG..END for preview-toggle."
  (tip-send-region beg end))

;;; * the minor mode

;;;###autoload
(define-minor-mode tip-mode
  "A minor mode for inline preview of Typst math.
Automatically renders visible fragments and enables live preview."
  :init-value nil
  :lighter " TIP"
  :global nil
  (if tip-mode
      (progn
        (tip-ensure)
        ;; Configure preview-toggle to route fragment lookup through the
        ;; active backend.
        (setq-local preview-toggle-type 'tip)
        (setq-local preview-toggle-region-at-point-fn
                    #'tip-bounds-at-point)
        (setq-local preview-toggle-compile-region-fn
                    #'tip--compile-region)
        (preview-toggle-mode 1)
        ;; Belt-and-suspenders: preview-toggle-mode may be a no-op if it was
        ;; already enabled, and something (other major-mode setup, third-party
        ;; hooks) occasionally clears our local post-command-hook between
        ;; mode activation and the user's first cursor move.  Force both
        ;; hooks in directly — add-hook is idempotent.
        (unless preview-toggle--marker
          (setq preview-toggle--marker (make-marker)))
        (add-hook 'pre-command-hook #'preview-toggle--pre-command nil 'local)
        (add-hook 'post-command-hook #'preview-toggle--post-command nil 'local)
        ;; Live preview via childframe (off by default, user enables with M-x tip-live-mode)
        ;; C-c ' to edit fragment in indirect buffer
        (tip-edit-setup-keys)
        ;; Clean up stale overlays on buffer changes
        (add-hook 'after-change-functions #'tip--cleanup-stale-overlays nil t)
        ;; Track theme changes
        (tip-follow-theme-mode 1)
        ;; Kodama integration (auto-detect)
        (when (fboundp 'tip-kodama-maybe-enable)
          (tip-kodama-maybe-enable))
        ;; Echo-area error timer (always start, checked inside the function)
        (setq tip-echo--timer
              (run-with-idle-timer 0.5 t #'tip-echo--compile-partial))
        ;; Render visible fragments after a short delay (server needs to start)
        (run-with-timer 0.5 nil
                        (lambda ()
                          (when (buffer-live-p (current-buffer))
                            (with-current-buffer (current-buffer)
                              (when tip-mode
                                (tip-send-nbd)))))))
    ;; Teardown
    (when tip-echo--timer
      (cancel-timer tip-echo--timer)
      (setq tip-echo--timer nil))
    (when tip-live-mode (tip-live-mode -1))
    (tip-follow-theme-mode -1)
    (when (bound-and-true-p tip-kodama-mode) (tip-kodama-mode -1))
    (remove-hook 'after-change-functions #'tip--cleanup-stale-overlays t)
    (preview-toggle-mode -1)))

;;; * auto-compile minor mode

(defvar-local tip-auto--timer nil
  "Idle timer for auto-compiling visible fragments.")

;;;###autoload
(define-minor-mode tip-auto-mode
  "Automatically compile visible unrendered fragments on idle.
Useful after theme changes clear off-screen overlays, or for
keeping previews up to date as you scroll through a large file."
  :init-value nil
  :lighter " TIP-auto"
  (if tip-auto-mode
      (setq tip-auto--timer
            (run-with-idle-timer 0.5 t
                                 (lambda ()
                                   (when (and tip-mode (eq (current-buffer) (window-buffer)))
                                     (tip-send-nbd)))))
    (when tip-auto--timer
      (cancel-timer tip-auto--timer)
      (setq tip-auto--timer nil))))

;;; * avy-style jump to fragment

(defcustom tip-jump-keys "asdfjkl;ghqweruioptyzxcvbnm"
  "Characters used for avy-style jump labels, in priority order.
Home row first for qwerty ergonomics."
  :type 'string
  :group 'tip)

;;;###autoload
(defun tip-jump ()
  "Jump to a math/figure fragment using avy-style tree selection.
Shows labels on visible fragments. Press a key to narrow candidates;
if one remains, jump. Otherwise show next level and read again."
  (interactive)
  (let* ((ovs (seq-filter
               (lambda (ov)
                 (and (eq (overlay-get ov 'tip) 'tip)
                      (overlay-get ov 'display)
                      (let ((start (overlay-start ov)))
                        (and (>= start (window-start))
                             (<= start (window-end))))))
               (overlays-in (point-min) (point-max))))
         (n (length ovs)))
    (when (= n 0)
      (user-error "No visible fragments to jump to"))
    (when (= n 1)
      (goto-char (overlay-start (car ovs)))
      (preview-toggle-open-at-point)
      (cl-return-from tip-jump))
    ;; Build tree paths: assign each candidate a sequence of keys
    (let* ((keys tip-jump-keys)
           (nkeys (length keys))
           (paths (tip-jump--build-paths n nkeys))
           (candidates (cl-mapcar #'cons paths ovs)))
      (tip-jump--select candidates keys))))

(defun tip-jump--build-paths (n nkeys)
  "Build N tree paths using NKEYS branching factor.
Returns a list of strings, each a sequence of key indices."
  (let ((depth (max 1 (ceiling (log n nkeys))))
        (paths nil))
    ;; Generate paths breadth-first
    (dotimes (i n)
      (let ((path "")
            (idx i))
        (dotimes (_ depth)
          (setq path (concat (string (% idx nkeys)) path))
          (setq idx (/ idx nkeys)))
        (push path paths)))
    (nreverse paths)))

(defun tip-jump--select (candidates keys)
  "Interactively narrow CANDIDATES by reading keys.
Each candidate is (PATH . OVERLAY) where PATH is a string of key indices."
  (let ((label-ovs nil))
    (unwind-protect
        (catch 'done
          (while (> (length candidates) 1)
            ;; Show current labels
            (dolist (lov label-ovs) (delete-overlay lov))
            (setq label-ovs nil)
            (dolist (cand candidates)
              (let* ((path (car cand))
                     (ov (cdr cand))
                     ;; Show the first unconsumed key as the label
                     (key-idx (aref path 0))
                     (label (string (aref keys key-idx)))
                     (label-ov (make-overlay (overlay-start ov)
                                             (1+ (overlay-start ov)))))
                (overlay-put label-ov 'display
                             (propertize (format " %s " label)
                                         'face '(:background "#ff6600"
                                                 :foreground "white"
                                                 :weight bold)))
                (overlay-put label-ov 'priority 100)
                (push label-ov label-ovs)))
            (redisplay t)
            ;; Read one key
            (let* ((char (read-char "tip-jump:"))
                   (key-pos (cl-position char keys)))
              (unless key-pos
                (throw 'done nil)) ;; invalid key, cancel
              ;; Filter candidates matching this key at position 0
              (setq candidates
                    (cl-loop for cand in candidates
                             when (= (aref (car cand) 0) key-pos)
                             collect (cons (substring (car cand) 1)
                                          (cdr cand))))))
          ;; One candidate left
          (when (= (length candidates) 1)
            (let ((target-ov (cdar candidates)))
              (goto-char (overlay-start target-ov))
              (preview-toggle-open-at-point))))
      ;; Cleanup
      (dolist (lov label-ovs)
        (delete-overlay lov)))))

;;; * inline error display

(defface tip-error-face
  '((((background light)) :background "#fff3cd")
    (((background dark))  :background "#1a2744"))
  "Face for fragments that failed to compile.
Light yellow on light backgrounds, deep blue on dark."
  :group 'tip)

;;; * stale overlay cleanup

(defun tip--cleanup-stale-overlays (_beg _end _len)
  "Remove zero-width tip overlays left behind after text deletion.
Called from `after-change-functions'."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (eq (overlay-get ov 'tip) 'tip)
      (when (>= (overlay-start ov) (overlay-end ov))
        (delete-overlay ov)))))

;;; * cleanup

;;;###autoload
(defun tip-clear-region (beg end)
  "Clear tip overlays in region."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (error "No region selected")))
  (dolist (ov (overlays-in beg end))
    (when (eq (overlay-get ov 'tip) 'tip)
      (delete-overlay ov))))

;;;###autoload
(defun tip-clear-buffer ()
  "Clear all tip overlays in current buffer."
  (interactive)
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (eq 'tip (overlay-get ov 'tip))
      (delete-overlay ov))))

;;;###autoload
(defun tip-clear-all ()
  "Clear all overlays and image cache."
  (interactive)
  (clear-image-cache t)
  (tip-clear-buffer))

;;;###autoload
(defun tip-shutdown ()
  "Shut down the tip-server process."
  (interactive)
  (when (and tip--server-process (process-live-p tip--server-process))
    (tip--send-request "shutdown" nil)
    (sit-for 0.5)
    (when (process-live-p tip--server-process)
      (delete-process tip--server-process))
    (setq tip--server-process nil)
    (message "tip-server shut down")))

;;;###autoload
(defun tip-restart-server ()
  "Restart tip-server (shutdown then start fresh)."
  (interactive)
  (tip-shutdown)
  (tip-ensure t)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when tip-mode
        (tip-render-all)))))

;;;###autoload
(defun tip-restart ()
  "Full reset: restart server, clear all overlays, re-enable tip-mode."
  (interactive)
  (tip-shutdown)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when tip-mode
        (tip-mode -1))))
  (tip-ensure t)
  (tip-mode 1))

;;;###autoload
(defun tip-server-info ()
  "Show tip-server status: binary path, modification time, PID."
  (interactive)
  (let ((exe (unless tip-use-docker (tip--find-server)))
        (alive (and tip--server-process (process-live-p tip--server-process))))
    (message "tip-server: %s | binary: %s | %s"
             (if alive
                 (format "running (pid %d)" (process-id tip--server-process))
               "not running")
             (if tip-use-docker
                 (format "docker:%s" tip-docker-image)
               (if exe
                   (let* ((mtime (file-attribute-modification-time
                                  (file-attributes exe)))
                          (ago (- (float-time) (float-time mtime)))
                          (ago-str (cond
                                    ((< ago 60) (format "%ds ago" (round ago)))
                                    ((< ago 3600) (format "%dm ago" (round (/ ago 60))))
                                    ((< ago 86400) (format "%dh ago" (round (/ ago 3600))))
                                    (t (format "%dd ago" (round (/ ago 86400)))))))
                     (format "%s (built %s, %s)"
                             (abbreviate-file-name exe)
                             (format-time-string "%Y-%m-%d %H:%M" mtime)
                             ago-str))
                 "not found"))
             (if (and alive tip--request-id)
                 (format "%d requests sent" tip--request-id)
               ""))))

;;; * indirect edit (C-c ')

(defvar-local tip-edit--source-buffer nil
  "The source buffer this edit buffer is linked to.")
(defvar-local tip-edit--source-overlay nil
  "Overlay in the source buffer marking the edited region.")
(defvar-local tip-edit--preview-timer nil
  "Idle timer for live preview in edit buffer.")

(defvar tip-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'tip-edit-commit)
    (define-key map (kbd "C-c C-k") #'tip-edit-abort)
    (define-key map (kbd "C-c '") #'tip-edit-commit)
    map)
  "Keymap for `tip-edit-mode'.")

(define-minor-mode tip-edit-mode
  "Minor mode active in tip indirect edit buffers.
\\[tip-edit-commit] to save changes back, \\[tip-edit-abort] to cancel."
  :lighter " TIP-Edit"
  :keymap tip-edit-mode-map)

;;;###autoload
(defun tip-edit ()
  "Open an indirect edit buffer for the math/figure at point.
Like `org-edit-special' (C-c ').  Shows live preview while editing.
\\[tip-edit-commit] saves back, \\[tip-edit-abort] cancels."
  (interactive)
  (let ((bounds (tip-bounds-at-point (point))))
    (unless bounds
      (user-error "No math or figure at point"))
    (let* ((beg (car bounds))
           (end (cdr bounds))
           (text (buffer-substring-no-properties beg end))
           (src-buf (current-buffer))
           ;; Create overlay on source to mark region
           (ov (make-overlay beg end))
           ;; Create edit buffer
           (edit-buf (generate-new-buffer
                      (format "*tip-edit:%s*"
                              (truncate-string-to-width
                               (string-trim text) 30)))))
      ;; Mark source region
      (overlay-put ov 'face 'highlight)
      (overlay-put ov 'tip-edit t)
      (overlay-put ov 'modification-hooks
                   (list (lambda (&rest _)
                           (user-error "Region being edited in %s" edit-buf))))
      ;; Set up edit buffer
      (with-current-buffer edit-buf
        (insert text)
        (goto-char (point-min))
        ;; Use typst-ts-mode if available for syntax highlighting
        (when (fboundp 'typst-ts-mode)
          (condition-case nil (typst-ts-mode) (error nil)))
        (tip-edit-mode 1)
        (setq-local tip-edit--source-buffer src-buf)
        (setq-local tip-edit--source-overlay ov)
        ;; Live preview on idle
        (setq-local tip-edit--preview-timer
                    (run-with-idle-timer
                     0.3 t
                     (lambda ()
                       (when (and (buffer-live-p edit-buf)
                                  (eq (current-buffer) edit-buf))
                         (tip-edit--live-preview))))))
      ;; Display edit buffer
      (pop-to-buffer edit-buf)
      (message "Edit fragment. C-c C-c to commit, C-c C-k to abort."))))

(defun tip-edit--live-preview ()
  "Compile edit buffer content and show preview in side window.
Splices current edit text into source buffer before compiling.
Reuses the shared `tip-live--show-preview' / `tip-live--handle-result'."
  (let ((src-buf tip-edit--source-buffer)
        (ov tip-edit--source-overlay)
        (new-text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and src-buf (buffer-live-p src-buf) ov (overlay-buffer ov)
               (not (equal new-text tip-live--content-cache)))
      (setq tip-live--content-cache new-text)
      (let ((beg (overlay-start ov))
            (end (overlay-end ov)))
        (with-current-buffer src-buf
          (tip-ensure)
          (let* ((full-text (buffer-substring-no-properties (point-min) (point-max)))
                 (before (substring full-text 0 (1- beg)))
                 (after (substring full-text (1- end)))
                 (spliced (concat before new-text after))
                 (fg (tip--color-to-hex (face-attribute 'default :foreground)))
                 (byte-start (string-bytes before))
                 (byte-end (+ byte-start (string-bytes new-text))))
            (tip--send-request "sync"
                               `(("uri" . ,(buffer-file-name))
                                 ("content" . ,spliced)))
            (tip--send-request
             "compile_fragments"
             `(("uri" . ,(buffer-file-name))
               ("fragments" . ,(vector `(("start" . ,byte-start)
                                          ("end" . ,byte-end))))
               ("color" . ,fg)
               ("preamble" . ,(tip-build-preamble)))
             (lambda (result)
               (tip-live--handle-result result)))))))))

(defun tip-edit-commit ()
  "Write edit buffer contents back to source and close."
  (interactive)
  (unless (and tip-edit--source-buffer tip-edit--source-overlay)
    (user-error "Not in a tip edit buffer"))
  (let* ((new-text (buffer-substring-no-properties (point-min) (point-max)))
         (src-buf tip-edit--source-buffer)
         (ov tip-edit--source-overlay)
         (beg (overlay-start ov))
         (end (overlay-end ov)))
    ;; Replace in source buffer
    (with-current-buffer src-buf
      (save-excursion
        (delete-overlay ov)
        (goto-char beg)
        (delete-region beg end)
        (insert new-text)))
    ;; Cleanup
    (tip-edit--cleanup)
    (pop-to-buffer src-buf)
    (message "Fragment updated.")))

(defun tip-edit-abort ()
  "Cancel editing and discard changes."
  (interactive)
  (let ((src-buf tip-edit--source-buffer))
    (when tip-edit--source-overlay
      (delete-overlay tip-edit--source-overlay))
    (tip-edit--cleanup)
    (when (buffer-live-p src-buf)
      (pop-to-buffer src-buf))
    (message "Edit cancelled.")))

(defun tip-edit--cleanup ()
  "Clean up edit buffer state."
  (when tip-edit--preview-timer
    (cancel-timer tip-edit--preview-timer))
  (tip-childframe-hide)
  ;; Kill edit buffer
  (let ((buf (current-buffer)))
    (quit-window t)
    (when (buffer-live-p buf)
      (kill-buffer buf))))

;; Bind C-c ' in tip-mode
(defun tip-edit-setup-keys ()
  "Set up keybindings for tip-edit and tip-jump."
  (local-set-key (kbd "C-c '") #'tip-edit)
  (local-set-key (kbd "C-c j") #'tip-jump))

(provide 'tip)

;;; tip.el ends here
