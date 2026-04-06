;;; tip.el --- Typst Inline Preview -*- lexical-binding: t; -*-

;; Author: Elio Azuray
;; URL: https://github.com/elioazuray/typst-inline-preview
;; Version: 2.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, typst, preview

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Inline math preview for typst-ts-mode.  Renders Typst math fragments
;; as SVG images displayed as overlays in the buffer.
;;
;; Communicates with tip-server (Rust binary) via stdio JSON-RPC.
;; Requires: tip-server binary on `exec-path' or configured via
;; `tip-server-executable'.

;;; Code:

(require 'json)
(require 'treesit)
(require 'preview-toggle)

;;; * custom settings

(defcustom tip-enable-debug nil
  "Enable debug messages."
  :type 'boolean
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

(defcustom tip-docker-image "tip-server:latest"
  "Docker image name for tip-server."
  :type 'string
  :group 'tip)

(defcustom tip-display-indicator
  (propertize "𝐃" 'face '(:foreground "orange" :weight bold))
  "String shown before single-line display math overlays.
Set to nil to disable the indicator."
  :type '(choice string (const nil))
  :group 'tip)

(defcustom tip-diagram-functions
  '("cetz.canvas" "canvas" "diagram" "comm-diag" "fletcher.diagram")
  "List of function names recognized as diagram calls for preview.
These are previewed as block elements (centered, no baseline alignment)."
  :type '(repeat string)
  :group 'tip)

(defcustom tip-scale 1.0
  "Scaling factor for inline preview images.
At 1.0, math is sized to match the buffer's text size.
Increase for larger previews."
  :type 'float
  :group 'tip)

(defcustom tip-baseline-offset -2
  "Baseline correction in ascent percentage points.
Adjusts the vertical position of all math fragments uniformly.
Positive shifts math down, negative shifts up.
To calibrate: evaluate in a typst-ts-mode buffer with tip-mode:
  (progn (setq tip-baseline-offset -2) (tip-render-all))
Adjust the number and re-evaluate until baselines align."
  :type 'number
  :group 'tip)

(defcustom tip-live-docstring-scale 2.1
  "Scale factor for live preview in eldoc."
  :type 'float
  :group 'tip)

;;; * utils

(defmacro tip-debug-msg (&rest args)
  `(when tip-enable-debug
     (message ,@args)))

;;; * server process management

(defvar tip--server-process nil
  "The tip-server child process.")

(defvar tip--request-id 0
  "Monotonically increasing request ID.")

(defvar tip--response-buffer ""
  "Accumulates partial output from the server.")

(defvar tip--pending-callbacks (make-hash-table :test 'eql)
  "Maps request ID to callback function.")

(defun tip--next-id ()
  "Return next request ID."
  (cl-incf tip--request-id))

(defun tip--package-dir ()
  "Return the directory containing tip.el."
  (file-name-directory (or load-file-name (locate-library "tip") "")))

(defun tip--find-server ()
  "Find the tip-server executable, or prompt user to install.
Returns the path, or nil if Docker mode (handled separately)."
  (when tip-use-docker
    (cl-return-from tip--find-server nil))
  (or tip-server-executable
      (executable-find "tip-server")
      ;; Check local build beside tip.el
      (let ((local (expand-file-name
                    "tip-server/target/release/tip-server"
                    (tip--package-dir))))
        (when (file-executable-p local) local))
      ;; Check in elpaca build dir (source repo)
      (let ((elpaca-src (expand-file-name
                         "tip-server/target/release/tip-server"
                         (file-name-directory
                          (or (locate-library "tip") "")))))
        (when (file-executable-p elpaca-src) elpaca-src))
      ;; Prompt
      (tip--prompt-install)))

(defun tip--prompt-install ()
  "Prompt user to install tip-server."
  (let ((choice (read-char-choice
                 (concat
                  "tip-server not found. Choose:\n"
                  "  [c] Compile from source (needs Rust toolchain)\n"
                  "  [d] Use Docker (needs Docker installed)\n"
                  "  [p] Set path manually\n"
                  "  [q] Cancel\n"
                  "Choice: ")
                 '(?c ?d ?p ?q))))
    (pcase choice
      (?c (tip--compile-from-source))
      (?d (setq tip-use-docker t)
          (tip--build-docker-image)
          "docker")
      (?p (let ((path (read-file-name "Path to tip-server: ")))
            (setq tip-server-executable path)
            path))
      (?q (user-error "tip-server is required for tip-mode")))))

;;;###autoload
(defun tip--compile-from-source ()
  "Compile tip-server from Rust source using `compilation-mode'."
  (interactive)
  (unless (executable-find "cargo")
    (user-error "Rust toolchain not found. Install from https://rustup.rs"))
  (let* ((pkg-dir (tip--package-dir))
         (server-dir (expand-file-name "tip-server" pkg-dir))
         (target (expand-file-name "target/release/tip-server" server-dir)))
    (unless (file-directory-p server-dir)
      (user-error "tip-server source not found at %s" server-dir))
    (let ((default-directory server-dir)
          (compilation-finish-functions
           (list (lambda (_buf status)
                   (when (string-match-p "finished" status)
                     (setq tip-server-executable target)
                     (message "tip-server compiled: %s" target))))))
      (compile "cargo build --release"))))

(defun tip--build-docker-image ()
  "Build the tip-server Docker image if not already available."
  (interactive)
  (unless (executable-find "docker")
    (user-error "Docker not found. Install from https://docs.docker.com/get-docker/"))
  (let* ((pkg-dir (tip--package-dir))
         (dockerfile (expand-file-name "tip-server/Dockerfile" pkg-dir)))
    (unless (file-exists-p dockerfile)
      (user-error "Dockerfile not found at %s" dockerfile))
    ;; Check if image already exists
    (if (= 0 (call-process "docker" nil nil nil "image" "inspect" tip-docker-image))
        (message "Docker image %s already exists" tip-docker-image)
      (let ((buf (get-buffer-create "*tip-server-docker-build*")))
        (pop-to-buffer buf)
        (let ((inhibit-read-only t)) (erase-buffer))
        (insert (format "Building Docker image %s...\n\n" tip-docker-image))
        (let* ((default-directory (expand-file-name "tip-server" pkg-dir))
               (proc (start-process "tip-docker-build" buf
                                    "docker" "build" "-t" tip-docker-image ".")))
          (set-process-sentinel
           proc
           (lambda (_proc event)
             (if (string-match-p "finished" event)
                 (message "Docker image %s built successfully" tip-docker-image)
               (error "Docker build failed. See *tip-server-docker-build*"))))
          (message "Building Docker image... (see *tip-server-docker-build*)"))))))

(defun tip--start-server-process ()
  "Start tip-server as a local process."
  (let ((exe (tip--find-server)))
    (unless exe
      (user-error "No tip-server binary found. Run M-x tip--compile-from-source"))
    (make-process
     :name "tip-server"
     :command (list exe)
     :connection-type 'pipe
     :filter #'tip--process-filter
     :sentinel #'tip--process-sentinel
     :noquery t)))

(defun tip--start-docker-process ()
  "Start tip-server via Docker with stdio."
  (let* ((project-dir (or (and buffer-file-name
                               (file-name-directory buffer-file-name))
                          default-directory))
         (local-pkgs (expand-file-name "~/.local/share/typst/packages"))
         (cache-pkgs (expand-file-name "~/.cache/typst/packages"))
         (cmd (append (list "docker" "run" "--rm" "-i")
                      (list "-v" (concat project-dir ":/project"))
                      (when (file-directory-p local-pkgs)
                        (list "-v" (concat local-pkgs
                                           ":/root/.local/share/typst/packages:ro")))
                      (when (file-directory-p cache-pkgs)
                        (list "-v" (concat cache-pkgs
                                           ":/root/.cache/typst/packages:ro")))
                      (list tip-docker-image))))
    (make-process
     :name "tip-server"
     :command (seq-remove #'null cmd)
     :connection-type 'pipe
     :filter #'tip--process-filter
     :sentinel #'tip--process-sentinel
     :noquery t)))

;;;###autoload
(defun tip-ensure (&optional force)
  "Ensure tip-server is running.  With FORCE, restart it."
  (interactive "P")
  (when (and tip--server-process force)
    (tip-debug-msg "Killing existing tip-server")
    (delete-process tip--server-process)
    (setq tip--server-process nil))
  (unless (and tip--server-process
               (process-live-p tip--server-process))
    (setq tip--response-buffer "")
    (setq tip--server-process
          (condition-case err
              (if tip-use-docker
                  (tip--start-docker-process)
                (tip--start-server-process))
            (error
             (message "tip-server: %s" (error-message-string err))
             nil)))
    (if tip--server-process
        (message "tip-server started (pid %d)" (process-id tip--server-process))
      (message "tip-server failed to start"))))

(defun tip--process-sentinel (proc event)
  "Handle tip-server process state changes."
  (tip-debug-msg "tip-server: %s" (string-trim event))
  (when (not (process-live-p proc))
    (setq tip--server-process nil)
    (message "tip-server exited: %s" (string-trim event))))

(defun tip--process-filter (_proc output)
  "Handle output from tip-server.  Parse newline-delimited JSON responses."
  (setq tip--response-buffer (concat tip--response-buffer output))
  ;; Process complete lines
  (while (string-match "\n" tip--response-buffer)
    (let* ((newline-pos (match-beginning 0))
           (line (substring tip--response-buffer 0 newline-pos)))
      (setq tip--response-buffer (substring tip--response-buffer (1+ newline-pos)))
      (when (> (length line) 0)
        (condition-case err
            (let* ((response (json-parse-string line :object-type 'alist))
                   (id (alist-get 'id response))
                   (result (alist-get 'result response))
                   (callback (gethash id tip--pending-callbacks)))
              (remhash id tip--pending-callbacks)
              (tip-debug-msg "tip-server response id=%s" id)
              (when callback
                (funcall callback result)))
          (error
           (tip-debug-msg "tip-server parse error: %S for line: %s" err line)))))))

;;; * request/response

(defun tip--send-request (method params &optional callback)
  "Send a JSON-RPC request to tip-server.
METHOD is the method name string.
PARAMS is an alist of parameters.
CALLBACK is called with the result alist when response arrives."
  (tip-ensure)
  (let* ((id (tip--next-id))
         (request `(("id" . ,id)
                    ("method" . ,method)
                    ("params" . ,params))))
    (when callback
      (puthash id callback tip--pending-callbacks))
    (let ((json (concat (json-encode request) "\n")))
      (tip-debug-msg "tip-server send: %s" (string-trim json))
      (process-send-string tip--server-process json))))

(defun tip--sync-buffer ()
  "Sync current buffer content to tip-server."
  (tip--send-request
   "sync"
   `(("uri" . ,(buffer-file-name))
     ("content" . ,(buffer-substring-no-properties (point-min) (point-max))))))

;;; * fragment collection

(defun tip--diagram-node-p (node)
  "Return non-nil if NODE is a function call matching `tip-diagram-functions'."
  (when (and node (string-match-p "call" (symbol-name (treesit-node-type node))))
    (let* ((callee (treesit-node-child-by-field-name node "callee"))
           (name (and callee (treesit-node-text callee t))))
      (and name (member name tip-diagram-functions)))))

(defun tip-collect-fragment-locations (beg end &optional avoid-pos)
  "Collect math and diagram fragment byte positions in region BEG..END.
Returns a list of alists with start/end keys.
Skips fragment containing AVOID-POS if given.
Filters out nested math — only keeps outermost fragments.
Diagrams (matching `tip-diagram-functions') are included as fragments."
  (let (ranges fragments)
    ;; Collect math ranges
    (dolist (pair (treesit-query-range 'typst "((math) @math)"))
      (when (and
             (>= (car pair) beg)
             (<= (cdr pair) end)
             (or (null avoid-pos)
                 (not (and (>= avoid-pos (car pair))
                           (<= avoid-pos (cdr pair))))))
        (push pair ranges)))
    ;; Collect diagram ranges by walking the tree
    (when tip-diagram-functions
      (let ((root (treesit-buffer-root-node 'typst)))
        (when root
          (setq ranges (nconc ranges
                              (tip--collect-diagram-ranges root beg end avoid-pos))))))
    ;; Filter out nested: skip any range contained within another
    (setq ranges (nreverse ranges))
    (let (outer)
      (dolist (r ranges)
        (unless (cl-some (lambda (o)
                           (and (not (equal o r))
                                (<= (car o) (car r))
                                (>= (cdr o) (cdr r))))
                         ranges)
          (push r outer)))
      ;; Convert to byte offsets
      (dolist (pair (nreverse outer))
        (push `(("start" . ,(1- (position-bytes (car pair))))
                ("end" . ,(1- (position-bytes (cdr pair)))))
              fragments)))
    (nreverse fragments)))

(defun tip--collect-diagram-ranges (node beg end avoid-pos)
  "Recursively find diagram function calls under NODE.
Returns a list of (BEG . END) ranges."
  (let ((node-start (treesit-node-start node))
        (node-end (treesit-node-end node))
        (result nil))
    (when (and (<= node-start end) (>= node-end beg))
      (if (tip--diagram-node-p node)
          (let ((start (max beg (1- node-start)))
                (dend (min end node-end)))
            (when (or (null avoid-pos)
                      (not (and (>= avoid-pos start) (<= avoid-pos dend))))
              (push (cons start dend) result)))
        (dotimes (i (treesit-node-child-count node))
          (setq result (nconc result
                              (tip--collect-diagram-ranges
                               (treesit-node-child node i) beg end avoid-pos))))))
    result))

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

(defun tip--build-preamble ()
  "Build a Typst preamble string that syncs Emacs theme colors and text size.
The server always includes bounded() for anti-clipping.
This preamble adds color sync and font size matching."
  (let ((fg (tip--color-to-hex (face-attribute 'default :foreground)))
        (bg (tip--color-to-hex (face-attribute 'default :background)))
        (font-pt (tip--font-size-pt)))
    (concat
     (format "#set text(size: %spt)\n" font-pt)
     (format "#show math.equation: set text(rgb(\"%s\"))\n" fg)
     (format "#set page(fill: rgb(\"%s\"))\n" bg))))

;;; * compilation and rendering

(defun tip-send-region (beg end &optional avoid-pos)
  "Compile and render all math fragments in region BEG..END."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (error "No region selected")))
  (let ((buf (current-buffer))
        (fg (tip--color-to-hex (face-attribute 'default :foreground)))
        (preamble (tip--build-preamble)))
    ;; Sync buffer content first
    (tip--sync-buffer)
    ;; Then request compilation of fragments
    (tip--send-request
     "compile_fragments"
     `(("uri" . ,(buffer-file-name))
       ("fragments" . ,(vconcat (tip-collect-fragment-locations beg end avoid-pos)))
       ("color" . ,fg)
       ("preamble" . ,preamble))
     (lambda (result)
       (with-current-buffer buf
         (tip--apply-fragment-results
          (alist-get 'fragments result)))))))

(defun tip--apply-fragment-results (fragment-results)
  "Apply compiled SVG results as overlays.
FRAGMENT-RESULTS is a vector of alists with start, end, svg,
height_pt, and depth_pt keys."
  (seq-doseq (frag fragment-results)
    (let* ((byte-start (alist-get 'start frag))
           (byte-end (alist-get 'end frag))
           ;; Convert byte offsets back to Emacs positions
           (frag-beg (byte-to-position (1+ byte-start)))
           (frag-end (byte-to-position (1+ byte-end)))
           (svg-data (alist-get 'svg frag))
           (height-pt (alist-get 'height_pt frag))
           (depth-pt (alist-get 'depth_pt frag)))
      (when (and frag-beg frag-end (> (length svg-data) 0))
        ;; Clear existing overlays at this location
        (dolist (ov (overlays-in frag-beg frag-end))
          (when (eq (overlay-get ov 'tip) 'tip)
            (delete-overlay ov)))
        ;; Detect single-line display math for indicator
        (let* ((frag-text (buffer-substring-no-properties frag-beg frag-end))
               (is-diagram (eq (aref frag-text 0) ?#))
               (is-single-line-display
                (and (not is-diagram)
                     (>= (length frag-text) 3)
                     (eq (aref frag-text 0) ?$)
                     (memq (aref frag-text 1) '(?\s ?\t))
                     (not (string-match-p "\n" (substring frag-text 1 -1)))))
               (is-display (or is-diagram
                              is-single-line-display
                              (and (not is-diagram)
                                   (string-match-p "\n" (substring frag-text 1 -1)))))
               (img-spec (tip--make-image-spec svg-data height-pt depth-pt is-display))
               (display img-spec)
               (ov (make-overlay frag-beg frag-end)))
          (overlay-put ov 'tip 'tip)
          (overlay-put ov 'view-text nil)
          (overlay-put ov 'tip-height-pt height-pt)
          (overlay-put ov 'tip-depth-pt depth-pt)
          (overlay-put ov 'display display)
          (when (and is-single-line-display tip-display-indicator)
            (overlay-put ov 'before-string tip-display-indicator)))))))

(defun tip--font-size-pt ()
  "Return the default font size in points."
  (let ((h (face-attribute 'default :height)))
    (if (numberp h)
        (/ h 10.0)
      11.0)))  ;; fallback

(defun tip--make-image-spec (svg-data height-pt depth-pt &optional display-p)
  "Create an image display spec from SVG-DATA with HEIGHT-PT and DEPTH-PT.
When DISPLAY-P is non-nil, use vertical centering (for display math).
Otherwise use baseline alignment for inline math."
  (let* ((font-pt (tip--font-size-pt))
         (height-em (* tip-scale (/ height-pt font-pt)))
         (ascent (if display-p
                     'center
                   ;; Inline: align to math baseline with user offset
                   (let ((raw (if (> height-pt 0)
                                  (* 100.0 (/ (- height-pt depth-pt) height-pt))
                                50.0)))
                     (max 0 (min 100 (round (- raw tip-baseline-offset))))))))
    (list (cons 'image
                (list :type 'svg
                      :data svg-data
                      :height `(,height-em . em)
                      :ascent ascent
                      :pointer 'hand)))))

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

;;; * cursor and overlay management (delegates to preview-toggle)

;;;###autoload
(defun tip-open ()
  "Open overlay at point."
  (interactive)
  (preview-toggle-open-at-point))

(defun tip--compile-region (beg end)
  "Compile math fragments in region BEG..END for preview-toggle."
  (tip-send-region beg end))

;;; * fragment detection

(defun tip--get-bounds-of-math-at-point (x)
  "Return (BEG . END) of math or diagram fragment at position X, or nil."
  (or
   ;; Check math ranges
   (let* ((ranges (treesit-query-range 'typst "((math) @math)"))
          (valid (cl-remove-if-not
                  (lambda (r) (and (<= (car r) x) (< x (cdr r))))
                  ranges)))
     (when valid (car (sort valid :lessp #'< :key #'car))))
   ;; Check diagram ranges (walk tree upward from point)
   (let ((node (treesit-node-at x 'typst)))
     (while (and node (not (tip--diagram-node-p node)))
       (setq node (treesit-node-parent node)))
     (when node
       (cons (1- (treesit-node-start node)) ;; include #
             (treesit-node-end node))))))

;;; * live preview with eldoc

(defvar-local tip-live--content-cache ""
  "Cache of the last live-previewed fragment content.")

(defvar-local tip-live--docstring "tip"
  "String holding the live preview image as a text property.")

(defvar-local tip-live--timer nil
  "Idle timer for live preview.")

(defun tip-live--compile-partial ()
  "Compile the math fragment at point for live preview."
  (when-let* (((eq major-mode 'typst-ts-mode))
              (buf (current-buffer))
              (bound (tip--get-bounds-of-math-at-point (point)))
              (content (buffer-substring-no-properties (car bound) (cdr bound)))
              ((not (string-equal tip-live--content-cache content)))
              (fg (tip--color-to-hex (face-attribute 'default :foreground)))
              (byte-start (1- (position-bytes (car bound))))
              (byte-end (1- (position-bytes (cdr bound)))))
    (setq tip-live--content-cache content)
    (tip--sync-buffer)
    (tip--send-request
     "compile_live"
     `(("uri" . ,(buffer-file-name))
       ("start" . ,byte-start)
       ("end" . ,byte-end)
       ("color" . ,fg)
       ("preamble" . ,(tip--build-preamble)))
     (lambda (result)
       (with-current-buffer buf
         (let* ((err (alist-get 'error result))
                (frag (alist-get 'fragment result))
                (svg-data (and frag (alist-get 'svg frag)))
                (height-pt (and frag (alist-get 'height_pt frag))))
           (cond
            ;; Compile error: show error text
            (err
             (tip--feed-error-to-docstring err)
             (eldoc--invoke-strategy nil))
            ;; Success: show SVG
            ((and svg-data (> (length svg-data) 0) height-pt)
             (tip--feed-image-to-docstring svg-data height-pt)
             (eldoc--invoke-strategy nil)))))))))

(defun tip--feed-image-to-docstring (svg-data height-pt)
  "Set the live preview docstring to display SVG-DATA."
  (setq tip-live--docstring
        (propertize "tip"
                    'display
                    (list (cons 'image
                                (list :type 'svg
                                      :data svg-data
                                      :height `(,(* tip-live-docstring-scale
                                                    (/ height-pt (tip--font-size-pt)))
                                                . em)
                                      :pointer 'hand))))))

(defun tip--feed-error-to-docstring (err)
  "Set the live preview docstring to show error ERR."
  (setq tip-live--docstring
        (propertize (format "TIP error: %s" err)
                    'face 'error)))

(defun tip-live--display-in-eldoc (callback)
  "Eldoc documentation function for live typst previews."
  (if (tip--get-bounds-of-math-at-point (point))
      (when tip-live--docstring
        (funcall callback tip-live--docstring))
    ;; Outside math: clear live preview state
    (setq tip-live--docstring nil)
    (setq tip-live--content-cache "")))

;;;###autoload
(defun tip-live-setup ()
  "Enable live preview for math fragments via eldoc."
  (interactive)
  (setq eldoc-idle-delay 0.1)
  (setq tip-live--timer
        (run-with-idle-timer 0.1 t #'tip-live--compile-partial))
  (add-hook 'eldoc-documentation-functions #'tip-live--display-in-eldoc nil t))

;;;###autoload
(defun tip-live-teardown ()
  "Disable live preview."
  (interactive)
  (when tip-live--timer
    (cancel-timer tip-live--timer))
  (remove-hook 'eldoc-documentation-functions #'tip-live--display-in-eldoc t))

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
        ;; Configure preview-toggle for Typst math
        (setq-local preview-toggle-type 'tip)
        (setq-local preview-toggle-region-at-point-fn
                    #'tip--get-bounds-of-math-at-point)
        (setq-local preview-toggle-compile-region-fn
                    #'tip--compile-region)
        (preview-toggle-mode 1)
        ;; Live preview via eldoc
        (tip-live-setup)
        ;; Render visible fragments after a short delay (server needs to start)
        (run-with-timer 0.5 nil
                        (lambda ()
                          (when (buffer-live-p (current-buffer))
                            (with-current-buffer (current-buffer)
                              (when tip-mode
                                (tip-send-nbd)))))))
    ;; Teardown
    (tip-live-teardown)
    (preview-toggle-mode -1)))

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

(provide 'tip)

;;; tip.el ends here
