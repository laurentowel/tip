;;; tip-edit-indirect.el --- Indirect edit for math/figure fragments -*- lexical-binding: t; -*-

;;; Commentary:

;; C-c '-style indirect edit for the math or figure fragment at point.
;; Like `org-edit-special': the fragment text is opened in a temporary
;; buffer for distraction-free editing.  C-c C-c commits, C-c C-k aborts.
;;
;; UI: when entered, the current window is split vertically into two
;; temporary windows.  The top window shows a live SVG preview (or the
;; current compile error); the bottom window is the edit buffer.  The
;; original window configuration is restored on commit/abort.
;;
;; This replaces the previous childframe-based live preview for the
;; edit workflow — the split is more readable for multi-line fragments
;; and stays out of the way of the cursor.

;;; Code:

(require 'tip-server-proc)
(require 'tip-backend)

;; Forward decls — defined in tip.el.
(declare-function tip--color-to-hex "tip" (color))
(declare-function tip--resolve-project-root "tip" ())
(declare-function tip--font-size-pt "tip" ())
(declare-function tip--sync-buffer "tip" ())
(declare-function tip-build-preamble "tip" ())
(declare-function tip-ensure "tip" (&optional restart))
(defvar tip-mode)

;;; * state

(defvar-local tip-edit-indirect--source-buffer nil
  "The source buffer this edit buffer is linked to.")

(defvar-local tip-edit-indirect--source-overlay nil
  "Overlay in the source buffer marking the edited region.")

(defvar-local tip-edit-indirect--preview-timer nil
  "Idle timer for live preview in edit buffer.")

(defvar-local tip-edit-indirect--content-cache ""
  "Last edit-buffer text we sent to the server, to debounce no-op compiles.")

(defvar-local tip-edit-indirect--strip-amount 0
  "Number of leading whitespace columns stripped from the fragment on entry.
Re-prepended to every non-first non-blank line on commit so the source
buffer's original indentation is restored exactly.  See
`tip-edit-indirect--compute-strip' for the dedent rule.")

(defvar-local tip-edit-indirect--source-hash nil
  "SHA-256 of the source-region text at entry.
Compared against the current source-region content on commit; a
mismatch aborts the commit.  Belt-and-suspenders against the source
fragment being modified out from under us — the overlay's
modification-hooks already block direct edits to the region, but
indirect changes (revert-buffer, font-lock injection bugs, batch
replace-string in the source) can still slip through.")

(defvar tip-edit-indirect--saved-window-config nil
  "Window configuration captured on entry, restored on commit/abort.
Single global slot — entering a second `tip-edit-indirect' while the
first is active would clobber it, but the source-overlay's
modification-hook already blocks nested edits of the same region.")

(defconst tip-edit-indirect--preview-buffer "*tip-edit-preview*"
  "Name of the buffer that displays the live SVG / error in the top split.")

;;; * keymap and minor mode

(defvar tip-edit-indirect-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'tip-edit-indirect-commit)
    (define-key map (kbd "C-c C-k") #'tip-edit-indirect-abort)
    (define-key map (kbd "C-c '") #'tip-edit-indirect-commit)
    map)
  "Keymap for `tip-edit-indirect-mode'.")

(define-minor-mode tip-edit-indirect-mode
  "Minor mode active in tip indirect edit buffers.
\\[tip-edit-indirect-commit] to save changes back, \\[tip-edit-indirect-abort] to cancel."
  :lighter " TIP-Edit"
  :keymap tip-edit-indirect-mode-map)

;;; * preview window

(defun tip-edit-indirect--ensure-preview-buffer ()
  "Return the preview buffer, creating it (read-only) if needed."
  (let ((buf (get-buffer-create tip-edit-indirect--preview-buffer)))
    (with-current-buffer buf
      (setq buffer-read-only t)
      (setq mode-line-format nil))
    buf))

(defun tip-edit-indirect--show-preview (payload kind)
  "Render PAYLOAD into the preview buffer.  KIND is `image' or `error'.
For images, sizes the SVG to fit the preview window with a small margin."
  (let* ((buf (tip-edit-indirect--ensure-preview-buffer))
         (win (get-buffer-window buf t)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (pcase kind
          ('image
           ;; Cap the SVG to the visible preview window so a tall
           ;; equation doesn't push the image past the split.  Leave
           ;; ~16 px slack for fringes/margins; fall back to 600x300
           ;; if the buffer isn't currently displayed (test path).
           (let* ((max-w (if win (max 80 (- (window-pixel-width win) 32)) 600))
                  (max-h (if win (max 60 (- (window-pixel-height win) 32)) 300))
                  (img (list 'image
                             :type 'svg
                             :data payload
                             :max-width max-w
                             :max-height max-h
                             :ascent 'center)))
             (insert "\n  ")
             (insert-image img)
             (insert "\n")))
          ('error
           (insert (propertize payload 'face 'error)))))
      (goto-char (point-min)))))

;;; * compile + display

(defvar tip-live--content-cache) ; defined in tip-live.el — coordinated debounce

(defun tip-edit-indirect--live-preview ()
  "Compile the edit-buffer text and update the preview window.
Splices the edit text into the source buffer's content so context
(scope, surrounding paragraph) is preserved during compilation.
Skipped when the source buffer isn't visiting a file — the protocol
requires a string `uri', and tying it to `buffer-name' would confuse
project-root discovery."
  (let* ((src-buf tip-edit-indirect--source-buffer)
         (ov tip-edit-indirect--source-overlay)
         (uri (and (buffer-live-p src-buf)
                   (buffer-local-value 'buffer-file-name src-buf)))
         (new-text (buffer-substring-no-properties (point-min) (point-max))))
    (cond
     ((null uri)
      (tip-edit-indirect--show-preview
       "Source buffer is not visiting a file — save it to enable live preview."
       'error))
     ((and src-buf (buffer-live-p src-buf) ov (overlay-buffer ov)
           (not (equal new-text tip-edit-indirect--content-cache)))
      (setq tip-edit-indirect--content-cache new-text)
      ;; Keep tip-live's cache aligned so a tip-live-mode session that
      ;; coexists with an edit doesn't fight us for the same fragment.
      (when (boundp 'tip-live--content-cache)
        (setq tip-live--content-cache new-text))
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
            (let ((sync-params `(("uri" . ,(buffer-file-name))
                                 ("content" . ,spliced))))
              (when-let ((root (tip--resolve-project-root)))
                (push (cons "project_root" root) sync-params))
              (tip--send-request "sync" sync-params))
            (tip--send-request
             "compile_fragments"
             `(("uri" . ,(buffer-file-name))
               ("fragments" . ,(vector `(("start" . ,byte-start)
                                          ("end" . ,byte-end))))
               ("color" . ,fg)
               ("preamble" . ,(tip-build-preamble)))
             #'tip-edit-indirect--handle-result))))))))

(defun tip-edit-indirect--handle-result (result)
  "Display RESULT — image or error — in the preview window."
  (let* ((err (alist-get 'error result))
         (frags (alist-get 'fragments result))
         (frag (and frags (> (length frags) 0) (aref frags 0)))
         (frag-err (and frag (alist-get 'error frag)))
         (svg (and frag (alist-get 'svg frag)))
         (h (and frag (alist-get 'height_pt frag))))
    (cond
     (err (tip-edit-indirect--show-preview err 'error))
     (frag-err (tip-edit-indirect--show-preview frag-err 'error))
     ((and svg (> (length svg) 0) h (> h 0))
      (tip-edit-indirect--show-preview svg 'image))
     (t (tip-edit-indirect--show-preview "(empty result)" 'error)))))

;;; * indentation handling

;; The fragment text returned by `tip-bounds-at-point' starts at the
;; opening delimiter (e.g. the leading `$').  In the source buffer
;; that delimiter sits at column N, but the substring captured by
;; `buffer-substring' starts the line at column 0 — so the first line
;; of the fragment text always has zero leading whitespace, while
;; interior body lines and the closing delimiter line keep their full
;; source indent.  Editing in that raw form is awkward when the body
;; is heavily indented (the user has to mentally subtract a constant
;; from every column).
;;
;; The dedent rule below strips a uniform prefix of length
;;   N = min(leading-WS) over all non-first non-blank lines
;; from the same set on entry, and re-prepends it on commit.  Because
;; the prefix is uniform and applied to the same lines both ways:
;;
;;  - body alignment is preserved relative to itself (e.g. `&='
;;    columns in alignat-style equations stay aligned);
;;  - asymmetric original indents are preserved exactly — if the
;;    closing `$' was at a different column than the body, that
;;    asymmetry round-trips because we never normalize it, only
;;    subtract and re-add the same amount;
;;  - blank lines are left verbatim and never re-prefixed (avoids
;;    introducing trailing whitespace);
;;  - single-line fragments (no `\n' in TEXT) bypass the rule.

(defun tip-edit-indirect--compute-strip (text)
  "Return the column count to strip from TEXT under the dedent rule.
Computes the minimum leading whitespace count across all non-first,
non-blank lines.  The first line is excluded because it begins at
column 0 (the fragment starts at the opening delimiter).  Returns 0
for single-line input or when no non-blank interior line exists."
  (if (not (string-match-p "\n" text))
      0
    (let ((lines (cdr (split-string text "\n")))  ; drop first
          (min-indent nil))
      (dolist (line lines)
        (unless (string-match-p "\\`[ \t]*\\'" line)
          (when (string-match "[^ \t]" line)
            (let ((n (match-beginning 0)))
              (setq min-indent (if min-indent (min min-indent n) n))))))
      (or min-indent 0))))

(defun tip-edit-indirect--dedent (text n)
  "Strip N leading whitespace chars from each non-first non-blank line of TEXT.
A no-op when N is 0 or TEXT has no newline.  Lines shorter than N
chars are reduced to empty (defensive — should not happen given the
strip amount comes from `tip-edit-indirect--compute-strip')."
  (if (or (zerop n) (not (string-match-p "\n" text)))
      text
    (let* ((lines (split-string text "\n"))
           (head (car lines))
           (rest (mapcar (lambda (line)
                           (if (string-match-p "\\`[ \t]*\\'" line)
                               line
                             (substring line (min n (length line)))))
                         (cdr lines))))
      (mapconcat #'identity (cons head rest) "\n"))))

(defun tip-edit-indirect--reindent (text n)
  "Prepend N spaces to each non-first non-blank line of TEXT.
A no-op when N is 0 or TEXT has no newline.  Blank lines are left
unchanged so commit doesn't introduce trailing-whitespace lines."
  (if (or (zerop n) (not (string-match-p "\n" text)))
      text
    (let* ((prefix (make-string n ?\s))
           (lines (split-string text "\n"))
           (head (car lines))
           (rest (mapcar (lambda (line)
                           (if (string-match-p "\\`[ \t]*\\'" line)
                               line
                             (concat prefix line)))
                         (cdr lines))))
      (mapconcat #'identity (cons head rest) "\n"))))

;;; * entry point

;;;###autoload
(defun tip-edit-indirect ()
  "Open an indirect edit buffer for the math/figure at point.
Like `org-edit-special' (C-c ').  Splits the current window into a
preview pane (top) and an edit pane (bottom); typing in the edit pane
updates the preview on idle.  \\[tip-edit-indirect-commit] saves back,
\\[tip-edit-indirect-abort] cancels.

The fragment text is dedented before insertion: the minimum leading
whitespace across all non-first non-blank lines is stripped, producing
a clean editing surface even for heavily indented body lines.  The
exact prefix is restored on commit, so asymmetric original
indentation (e.g. closing `$' at a different column from the body) is
preserved verbatim — see `tip-edit-indirect--compute-strip'."
  (interactive)
  (let ((bounds (tip-bounds-at-point (point))))
    (unless bounds
      (user-error "No math or figure at point"))
    (let* ((beg (car bounds))
           (end (cdr bounds))
           (raw-text (buffer-substring-no-properties beg end))
           (strip (tip-edit-indirect--compute-strip raw-text))
           (text (tip-edit-indirect--dedent raw-text strip))
           (src-buf (current-buffer))
           (ov (make-overlay beg end))
           ;; `generate-new-buffer' uniquifies with `<2>', `<3>' etc.
           ;; if a previous edit buffer is still around.
           (edit-buf (generate-new-buffer "*tip-edit*"))
           (preview-buf (tip-edit-indirect--ensure-preview-buffer)))
      ;; Mark source region so the user can't edit it from elsewhere.
      (overlay-put ov 'face 'highlight)
      (overlay-put ov 'tip-edit-indirect t)
      (overlay-put ov 'modification-hooks
                   (list (lambda (&rest _)
                           (user-error "Region being edited in %s" edit-buf))))
      ;; Set up edit buffer.
      (with-current-buffer edit-buf
        (insert text)
        (goto-char (point-min))
        (when (fboundp 'typst-ts-mode)
          (condition-case nil (typst-ts-mode) (error nil)))
        (tip-edit-indirect-mode 1)
        ;; Header-line shows commit/abort bindings.  Use literal key
        ;; descriptions because `substitute-command-keys' can produce
        ;; surprising output when called during mode init before the
        ;; new keymap is fully active.  Force a redraw so the header
        ;; appears even if a containing setup overrides display.
        (setq-local header-line-format
                    (concat
                     (propertize " tip-edit-indirect" 'face 'mode-line-emphasis)
                     " — "
                     (propertize "C-c C-c" 'face 'help-key-binding)
                     " commit, "
                     (propertize "C-c C-k" 'face 'help-key-binding)
                     " abort"))
        (force-mode-line-update)
        (setq-local tip-edit-indirect--source-buffer src-buf)
        (setq-local tip-edit-indirect--source-overlay ov)
        (setq-local tip-edit-indirect--content-cache "")
        (setq-local tip-edit-indirect--strip-amount strip)
        (setq-local tip-edit-indirect--source-hash
                    (secure-hash 'sha256 raw-text))
        (setq-local tip-edit-indirect--preview-timer
                    (run-with-idle-timer
                     0.3 t
                     (lambda ()
                       (when (and (buffer-live-p edit-buf)
                                  (eq (current-buffer) edit-buf))
                         (tip-edit-indirect--live-preview))))))
      ;; Take over the current window: save config, lay out preview/edit,
      ;; focus the edit window.
      (setq tip-edit-indirect--saved-window-config (current-window-configuration))
      (delete-other-windows)
      (let* ((preview-win (selected-window))
             (edit-win (split-window preview-win nil 'below)))
        (set-window-buffer preview-win preview-buf)
        (set-window-buffer edit-win edit-buf)
        (set-window-dedicated-p preview-win t)
        (select-window edit-win))
      ;; Kick off an immediate first compile so the preview isn't blank.
      (tip-edit-indirect--live-preview)
      (message "Edit fragment.  C-c C-c to commit, C-c C-k to abort."))))

;;; * commit / abort

(defun tip-edit-indirect-commit ()
  "Write edit buffer contents back to source and close the edit UI.
Reapplies the leading-whitespace prefix recorded at entry to every
non-first non-blank line, so the source buffer's original indentation
is restored — see `tip-edit-indirect--reindent'.

Aborts the commit if the source-region content has changed since
entry (SHA-256 mismatch).  This guards against changes that bypass
the overlay's `modification-hooks' — e.g., `revert-buffer',
out-of-band buffer updates, or a global replace-string that altered
our fragment along with everything else.  When a mismatch is
detected, the edit buffer is left intact so the user can copy their
changes out manually before deciding what to do."
  (interactive)
  (unless (and tip-edit-indirect--source-buffer tip-edit-indirect--source-overlay)
    (user-error "Not in a tip edit buffer"))
  (let* ((edit-text (buffer-substring-no-properties (point-min) (point-max)))
         (n tip-edit-indirect--strip-amount)
         (new-text (tip-edit-indirect--reindent edit-text n))
         (src-buf tip-edit-indirect--source-buffer)
         (ov tip-edit-indirect--source-overlay)
         (expected-hash tip-edit-indirect--source-hash)
         (beg (overlay-start ov))
         (end (overlay-end ov)))
    (unless (and beg end (buffer-live-p src-buf))
      (user-error "Source region or buffer no longer exists"))
    (with-current-buffer src-buf
      (let ((current-hash (secure-hash 'sha256
                                       (buffer-substring-no-properties beg end))))
        (unless (equal current-hash expected-hash)
          (user-error
           "Source region changed since edit started; commit aborted")))
      ;; `save-excursion' is enough: `delete-region' + `insert' at
      ;; BEG leaves point at BEG + (length new-text), but the marker
      ;; semantics restore the original source-buffer point on exit.
      (save-excursion
        (delete-overlay ov)
        (goto-char beg)
        (delete-region beg end)
        (insert new-text)))
    (tip-edit-indirect--cleanup)
    (message "Fragment updated.")))

(defun tip-edit-indirect-abort ()
  "Cancel editing and discard changes."
  (interactive)
  (when tip-edit-indirect--source-overlay
    (delete-overlay tip-edit-indirect--source-overlay))
  (tip-edit-indirect--cleanup)
  (message "Edit cancelled."))

(defun tip-edit-indirect--cleanup ()
  "Tear down edit buffer + preview, restore window configuration."
  (when tip-edit-indirect--preview-timer
    (cancel-timer tip-edit-indirect--preview-timer))
  (let ((edit-buf (current-buffer))
        (preview-buf (get-buffer tip-edit-indirect--preview-buffer))
        (saved tip-edit-indirect--saved-window-config))
    (when (and preview-buf (buffer-live-p preview-buf))
      (with-current-buffer preview-buf
        (let ((inhibit-read-only t)) (erase-buffer)))
      ;; Drop dedication so set-window-configuration can reuse the window.
      (dolist (win (get-buffer-window-list preview-buf nil t))
        (set-window-dedicated-p win nil))
      (kill-buffer preview-buf))
    (when (buffer-live-p edit-buf)
      (kill-buffer edit-buf))
    (when saved
      (set-window-configuration saved)
      (setq tip-edit-indirect--saved-window-config nil))))

;;; * keymap installer (called from tip-mode setup)

(defun tip-edit-indirect-setup-keys ()
  "Bind C-c ' (and C-c j for `tip-jump') in the current buffer."
  (local-set-key (kbd "C-c '") #'tip-edit-indirect)
  (when (fboundp 'tip-jump)
    (local-set-key (kbd "C-c j") #'tip-jump)))

(provide 'tip-edit-indirect)

;;; tip-edit-indirect.el ends here
