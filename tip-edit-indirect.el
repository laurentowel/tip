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
  "Render PAYLOAD into the preview buffer.  KIND is `image' or `error'."
  (let ((buf (tip-edit-indirect--ensure-preview-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (pcase kind
          ('image
           (let* ((font-pt (if (fboundp 'tip--font-size-pt) (tip--font-size-pt) 11.0))
                  (scale (/ font-pt 11.0))
                  (img (list 'image
                             :type 'svg
                             :data payload
                             :scale (* scale 2.0)
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
(scope, surrounding paragraph) is preserved during compilation."
  (let ((src-buf tip-edit-indirect--source-buffer)
        (ov tip-edit-indirect--source-overlay)
        (new-text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and src-buf (buffer-live-p src-buf) ov (overlay-buffer ov)
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
             #'tip-edit-indirect--handle-result)))))))

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

;;; * entry point

;;;###autoload
(defun tip-edit-indirect ()
  "Open an indirect edit buffer for the math/figure at point.
Like `org-edit-special' (C-c ').  Splits the current window into a
preview pane (top) and an edit pane (bottom); typing in the edit pane
updates the preview on idle.  \\[tip-edit-indirect-commit] saves back,
\\[tip-edit-indirect-abort] cancels."
  (interactive)
  (let ((bounds (tip-bounds-at-point (point))))
    (unless bounds
      (user-error "No math or figure at point"))
    (let* ((beg (car bounds))
           (end (cdr bounds))
           (text (buffer-substring-no-properties beg end))
           (src-buf (current-buffer))
           (ov (make-overlay beg end))
           (edit-buf (generate-new-buffer
                      (format "*tip-edit:%s*"
                              (truncate-string-to-width
                               (string-trim text) 30))))
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
        (setq-local tip-edit-indirect--source-buffer src-buf)
        (setq-local tip-edit-indirect--source-overlay ov)
        (setq-local tip-edit-indirect--content-cache "")
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
  "Write edit buffer contents back to source and close the edit UI."
  (interactive)
  (unless (and tip-edit-indirect--source-buffer tip-edit-indirect--source-overlay)
    (user-error "Not in a tip edit buffer"))
  (let* ((new-text (buffer-substring-no-properties (point-min) (point-max)))
         (src-buf tip-edit-indirect--source-buffer)
         (ov tip-edit-indirect--source-overlay)
         (beg (overlay-start ov))
         (end (overlay-end ov)))
    (with-current-buffer src-buf
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
