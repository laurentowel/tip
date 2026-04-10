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
(require 'tip-childframe)

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


;;; * utils

(defmacro tip-debug-msg (&rest args)
  `(when tip-enable-debug
     (message ,@args)))

;;; * font directory resolution

(defun tip--resolve-font-dirs ()
  "Resolve `tip-font-dirs' to a list of absolute directory paths.
Strings are used as-is (must be absolute).
Cons pairs (ANCHOR . RELATIVE) are resolved: \".\" means the
directory containing the nearest .dir-locals.el."
  (let (result)
    (dolist (entry tip-font-dirs)
      (cond
       ((stringp entry)
        (push (expand-file-name entry) result))
       ((consp entry)
        (let* ((anchor (car entry))
               (relative (cdr entry))
               (anchor-dir (if (string= anchor ".")
                               (let ((dl (dir-locals-find-file
                                          (or buffer-file-name default-directory))))
                                 (cond
                                  ((stringp dl) dl)
                                  ((listp dl) (car dl))
                                  (t default-directory)))
                             (expand-file-name anchor))))
          (push (expand-file-name relative anchor-dir) result)))))
    (nreverse result)))

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
        (progn
          (message "tip-server started (pid %d)" (process-id tip--server-process))
          ;; Send init with font dirs if configured
          (let ((dirs (tip--resolve-font-dirs)))
            (when dirs
              (tip--send-request "init" `(("font_dirs" . ,(vconcat dirs)))))))
      (message "tip-server failed to start"))))

(defun tip--process-sentinel (proc event)
  "Handle tip-server process state changes."
  (tip-debug-msg "tip-server: %s" (string-trim event))
  (when (not (process-live-p proc))
    (setq tip--server-process nil)
    (message "tip-server exited: %s" (string-trim event))))

(defvar tip-server-response-functions nil
  "Hook run after each tip-server response is processed.
Called with one argument: the result alist.")

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
                (funcall callback result))
              (run-hook-with-args 'tip-server-response-functions result))
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
  "Sync current buffer content to tip-server.
Always sends the full buffer, ignoring narrowing."
  (tip--send-request
   "sync"
   `(("uri" . ,(buffer-file-name))
     ("content" . ,(save-restriction
                     (widen)
                     (buffer-substring-no-properties (point-min) (point-max)))))))

;;; * fragment collection

(defun tip--diagram-node-p (node)
  "Return non-nil if NODE is a function call matching `tip-diagram-functions'."
  (when-let* ((node)
              (ntype (treesit-node-type node))
              ((equal "call" (if (symbolp ntype) (symbol-name ntype) ntype)))
              (first-child (treesit-node-child node 0))
              (name (treesit-node-text first-child t)))
    (member name tip-diagram-functions)))

(defun tip-collect-fragment-locations (beg end &optional avoid-pos)
  "Collect math and diagram fragment byte positions in region BEG..END.
Returns a list of alists with start/end keys.
Skips fragment containing AVOID-POS if given.
Filters out nested math — only keeps outermost fragments.
Diagrams (matching `tip-diagram-functions') are included as fragments."
  (let (ranges fragments)
    ;; Collect math ranges (skip empty, skip inside #let bindings)
    (dolist (pair (treesit-query-range 'typst "((math) @math)"))
      (when (and
             (>= (car pair) beg)
             (<= (cdr pair) end)
             (> (- (cdr pair) (car pair)) 2) ;; skip $$ (length 2)
             (not (string-blank-p
                   (buffer-substring-no-properties
                    (1+ (car pair)) (1- (cdr pair))))) ;; skip $ $
             ;; Skip math inside #let definitions (not rendered content)
             (not (tip--inside-let-binding-p
                   (treesit-node-at (car pair) 'typst)))
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

(defun tip--inside-let-binding-p (node)
  "Return non-nil if NODE is inside a let binding (definition, not invocation)."
  (let ((parent (treesit-node-parent node)))
    (while (and parent
                (not (equal "let" (treesit-node-type parent))))
      (setq parent (treesit-node-parent parent)))
    (not (null parent))))

(defun tip--collect-diagram-ranges (node beg end avoid-pos)
  "Recursively find diagram function calls under NODE.
Skips calls inside #let bindings (function definitions, not invocations).
Returns a list of (BEG . END) ranges."
  (let ((node-start (treesit-node-start node))
        (node-end (treesit-node-end node))
        (result nil))
    (when (and (<= node-start end) (>= node-end beg))
      (if (and (tip--diagram-node-p node)
               (not (tip--inside-let-binding-p node)))
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
  "Build a Typst preamble that syncs Emacs theme colors.
Text size override is sent separately via page_setup (after skeleton)
so it takes precedence over document-level #set text rules."
  (let ((fg (tip--color-to-hex (face-attribute 'default :foreground)))
        (bg (tip--color-to-hex (face-attribute 'default :background))))
    (concat
     (format "#show math.equation: set text(rgb(\"%s\"))\n" fg)
     (format "#set page(fill: rgb(\"%s\"))\n" bg))))

;;; * compilation and rendering

(defun tip-send-region (beg end &optional avoid-pos)
  "Compile and render all math fragments in region BEG..END."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (error "No region selected")))
  (let* ((buf (current-buffer))
         (fg (tip--color-to-hex (face-attribute 'default :foreground)))
         (preamble (tip--build-preamble))
         (frag-locs (tip-collect-fragment-locations beg end avoid-pos))
         (n (length frag-locs)))
    (when (> n 0)
      (tip--sync-buffer)
      (tip--send-request
       "compile_fragments"
       `(("uri" . ,(buffer-file-name))
         ("fragments" . ,(vconcat frag-locs))
         ("color" . ,fg)
         ("preamble" . ,preamble))
       (lambda (result)
         (with-current-buffer buf
           (tip--apply-fragment-results
            (alist-get 'fragments result))))))))

(defun tip--apply-fragment-results (fragment-results)
  "Apply compiled SVG results as overlays.
FRAGMENT-RESULTS is a vector of alists with start, end, svg,
height_pt, and depth_pt keys.
Handles narrowed buffers: byte-to-position needs full buffer access."
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
           (err (alist-get 'error frag)))
      ;; Error fragment: highlight with error face, optionally log to echo area
      (when (and err frag-beg frag-end (= (length svg-data) 0))
        (when tip-echo-errors
          (message "TIP: %s" err))
        ;; Clear any existing overlay here first
        (dolist (ov (overlays-in frag-beg frag-end))
          (when (eq (overlay-get ov 'tip) 'tip)
            (delete-overlay ov)))
        (let ((ov (make-overlay frag-beg frag-end)))
          (overlay-put ov 'tip 'tip)
          (overlay-put ov 'face 'tip-error-face)))
      (when (and frag-beg frag-end (> (length svg-data) 0)
                 (> (or height-pt 0) 0.01)
                 (> (or width-pt 0) 0.01)
                 ;; Belt-and-suspenders: also check SVG width attr directly
                 (not (string-match-p "width=\"0pt\"" svg-data)))
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
               ;; For display math, eat the preceding newline so no blank line appears
               (ov-beg (if (and is-display
                                (> frag-beg (point-min))
                                (eq (char-before frag-beg) ?\n)
                                ;; Only eat the newline if it's a blank line
                                ;; (preceded by another newline or buffer start),
                                ;; otherwise text on the previous line gets merged.
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
          (overlay-put ov 'tip-svg svg-data)
          (overlay-put ov 'tip-fg (tip--color-to-hex
                                    (face-attribute 'default :foreground)))
          (overlay-put ov 'tip-bg (tip--color-to-hex
                                    (face-attribute 'default :background)))
          (overlay-put ov 'display display)
          (when (and is-single-line-display tip-display-indicator)
            (overlay-put ov 'before-string tip-display-indicator))))))))

(defun tip--font-size-pt ()
  "Return the default font size in points."
  (let ((h (face-attribute 'default :height)))
    (if (numberp h)
        (/ h 10.0)
      11.0)))  ;; fallback

(defun tip--effective-scale ()
  "Return the effective scale factor.
When `tip-scale' is `auto', compute from the buffer font size."
  (if (eq tip-scale 'auto)
      (/ (tip--font-size-pt) 11.0)
    tip-scale))

(defun tip--font-pixel-size ()
  "Return the default font's pixel size.
Respects `face-remapping-alist' (e.g. `variable-pitch-mode')."
  (let ((font (face-attribute 'default :font)))
    (if font
        (let ((sz (font-get font :size)))
          (if (and (numberp sz) (> sz 0)) sz 15))
      15))) ;; fallback

(defun tip--font-metrics ()
  "Return (ASCENT . DESCENT) in pixels for the default face font.
Respects `face-remapping-alist'."
  (let* ((font (face-attribute 'default :font))
         (info (and font (font-info (font-xlfd-name font)))))
    (if (and info (> (length info) 9))
        (cons (aref info 8) (aref info 9))
      ;; Fallback: estimate from pixel size
      (let ((px (tip--font-pixel-size)))
        (cons (round (* px 0.8)) (round (* px 0.2)))))))

(defun tip--make-image-spec (svg-data height-pt depth-pt &optional display-p)
  "Create an image display spec from SVG-DATA with HEIGHT-PT and DEPTH-PT.
When DISPLAY-P is non-nil, use vertical centering (for display math).
Otherwise use baseline alignment for inline math."
  (let* ((font-pt (tip--font-size-pt))
         (height-em (* (tip--effective-scale) (/ height-pt font-pt)))
         (ascent (if display-p
                     'center
                   ;; Inline: compute ascent from pixel-level prediction.
                   ;;
                   ;; Emacs computes: height_px = ceil(height_em * pixel_size)
                   ;; then positions: ascent_px = height_px * (pct / 100.0)
                   ;;
                   ;; We predict height_px, compute the desired ascent in
                   ;; pixels, and find the percentage that best matches.
                   ;; This accounts for ceil() rounding and integer %.
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
  (let ((bounds (tip--get-bounds-of-math-at-point (point))))
    (unless bounds
      (user-error "No math or diagram fragment at point"))
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

;;; * fragment detection

(defun tip--get-bounds-of-math-at-point (x)
  "Return (BEG . END) of math or diagram fragment at position X, or nil.
Uses local tree-sitter node walk — O(depth) not O(buffer).
Half-open interval: returns bounds only if BEG <= X < END."
  (let ((node (treesit-node-at x 'typst)))
    (or
     ;; Check if we're inside a math node (walk up)
     ;; Skip math inside #let bindings (definitions, not rendered)
     (let ((n node))
       (while (and n (not (equal "math" (treesit-node-type n))))
         (setq n (treesit-node-parent n)))
       (when (and n
                  (<= (treesit-node-start n) x)
                  (< x (treesit-node-end n))
                  (not (tip--inside-let-binding-p n)))
         (cons (treesit-node-start n) (treesit-node-end n))))
     ;; Check diagram ranges (walk up for call node)
     (let ((n node) (found nil))
       (while (and n (not found))
         (if (tip--diagram-node-p n)
             (setq found n)
           (setq n (treesit-node-parent n))))
       ;; If at # prefix, the call node is a sibling — check x+1
       (when (and (not found) (< x (point-max)) (eq (char-after x) ?#))
         (setq n (treesit-node-at (1+ x) 'typst))
         (while (and n (not found))
           (if (tip--diagram-node-p n)
               (setq found n)
             (setq n (treesit-node-parent n)))))
       (when found
         (let ((beg (1- (treesit-node-start found)))
               (end (treesit-node-end found)))
           (when (and (<= beg x) (< x end))
             (cons beg end))))))))

;;; * echo-area error feedback (while editing inside a fragment)

(defvar-local tip-echo--content-cache ""
  "Cache of the last echo-error-checked fragment content.")

(defvar-local tip-echo--timer nil
  "Idle timer for echo-area error checking.")

(defun tip-echo--handle-result (result)
  "Show compilation errors in the echo area, ignore success."
  (let* ((err (alist-get 'error result))
         (frags (alist-get 'fragments result))
         (frag (and frags (> (length frags) 0) (aref frags 0)))
         (frag-err (and frag (alist-get 'error frag))))
    (cond
     (err (message "TIP: %s" err))
     (frag-err (message "TIP: %s" frag-err)))))

(defun tip-echo--compile-partial ()
  "Compile fragment at point and echo errors."
  (when (and tip-echo-errors
             tip-mode
             (eq major-mode 'typst-ts-mode)
             (eq (current-buffer) (window-buffer))
             (not (bound-and-true-p tip-live-mode)))
    (if-let* ((bound (tip--get-bounds-of-math-at-point (point)))
              (content (buffer-substring-no-properties (car bound) (cdr bound))))
        (unless (string-equal tip-echo--content-cache content)
          (setq tip-echo--content-cache content)
          (let ((fg (tip--color-to-hex (face-attribute 'default :foreground)))
                (byte-start (1- (position-bytes (car bound))))
                (byte-end (1- (position-bytes (cdr bound)))))
            (tip--sync-buffer)
            (tip--send-request
             "compile_fragments"
             `(("uri" . ,(buffer-file-name))
               ("fragments" . ,(vector `(("start" . ,byte-start)
                                          ("end" . ,byte-end))))
               ("color" . ,fg)
               ("preamble" . ,(tip--build-preamble)))
             #'tip-echo--handle-result)))
      (setq tip-echo--content-cache ""))))

;;; * live preview (childframe-based, via tip-childframe.el)

(defvar-local tip-live--content-cache ""
  "Cache of the last live-previewed fragment content.")

(defvar-local tip-live--timer nil
  "Idle timer for live preview.")

(defun tip-live--handle-result (result)
  "Handle compilation result — show SVG or error in childframe.
Errors are shown both in the childframe and echoed to the message area."
  (let* ((err (alist-get 'error result))
         (frags (alist-get 'fragments result))
         (frag (and frags (> (length frags) 0) (aref frags 0)))
         (frag-err (and frag (alist-get 'error frag)))
         (svg (and frag (alist-get 'svg frag)))
         (h (and frag (alist-get 'height_pt frag))))
    (cond
     ;; Explicit error on the response
     (err
      (tip-childframe-show-text err 'error)
      (message "TIP: %s" err))
     ;; Per-fragment error from the server
     (frag-err
      (tip-childframe-show-text frag-err 'error)
      (message "TIP: %s" frag-err))
     ;; Fragment with valid SVG
     ((and svg (> (length svg) 0) h (> h 0))
      (tip-childframe-show svg))
     (t (tip-childframe-hide)))))

(defun tip-live--compile-partial ()
  "Compile the math fragment at point for live preview.
Works in both normal typst-ts-mode and tip-edit buffers."
  (cond
   ;; In tip-edit buffer: delegate to edit preview
   ((bound-and-true-p tip-edit-mode)
    (tip-edit--live-preview))
   ;; In typst-ts-mode: compile fragment at point
   ((eq major-mode 'typst-ts-mode)
    (if-let* ((bound (tip--get-bounds-of-math-at-point (point)))
              (content (buffer-substring-no-properties (car bound) (cdr bound))))
        (unless (string-equal tip-live--content-cache content)
          (setq tip-live--content-cache content)
          (let ((fg (tip--color-to-hex (face-attribute 'default :foreground)))
                (byte-start (1- (position-bytes (car bound))))
                (byte-end (1- (position-bytes (cdr bound)))))
            (tip--sync-buffer)
            (tip--send-request
             "compile_fragments"
             `(("uri" . ,(buffer-file-name))
               ("fragments" . ,(vector `(("start" . ,byte-start)
                                          ("end" . ,byte-end))))
               ("color" . ,fg)
               ("preamble" . ,(tip--build-preamble)))
             (lambda (result)
               (tip-live--handle-result result)))))
      ;; Outside math: hide childframe, clear cache
      (tip-childframe-hide)
      (setq tip-live--content-cache "")))))

(defun tip-live--on-buffer-change (&rest _)
  "Hide childframe when switching away from a tip-mode buffer."
  (unless (and (eq major-mode 'typst-ts-mode)
               (bound-and-true-p tip-mode)
               (bound-and-true-p tip-live-mode))
    (tip-childframe-hide)))

(defun tip-live--on-buffer-kill ()
  "Hide childframe when a tip-mode buffer is killed."
  (when (bound-and-true-p tip-live-mode)
    (tip-childframe-hide)))

;;;###autoload
(define-minor-mode tip-live-mode
  "Live preview of the math fragment at point in a childframe.
Compiles the fragment under cursor on idle and shows the result
in a floating childframe.  Disabled by default — enable with
M-x tip-live-mode or (tip-live-mode 1)."
  :init-value nil
  :lighter " TIP-live"
  (if tip-live-mode
      (progn
        (setq tip-live--timer
              (run-with-idle-timer 0.3 t #'tip-live--compile-partial))
        (add-hook 'window-buffer-change-functions #'tip-live--on-buffer-change)
        (add-hook 'kill-buffer-hook #'tip-live--on-buffer-kill nil t))
    ;; Teardown: cancel timer, remove hooks, hide frame, clear cache
    (when tip-live--timer
      (cancel-timer tip-live--timer)
      (setq tip-live--timer nil))
    (remove-hook 'window-buffer-change-functions #'tip-live--on-buffer-change)
    (remove-hook 'kill-buffer-hook #'tip-live--on-buffer-kill t)
    (tip-childframe-hide)
    (setq tip-live--content-cache "")))

;;; * theme change tracking

(defun tip--recolor-overlays ()
  "Update SVG colors in all tip overlays to match current theme.
Does string replacement on cached SVG data — no server round-trip."
  (let ((new-fg (tip--color-to-hex (face-attribute 'default :foreground)))
        (new-bg (tip--color-to-hex (face-attribute 'default :background))))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (eq (overlay-get ov 'tip) 'tip)
        (let ((old-fg (overlay-get ov 'tip-fg))
              (old-bg (overlay-get ov 'tip-bg))
              (disp (overlay-get ov 'display)))
          (when (and old-fg old-bg disp (not (string= old-fg new-fg)))
            (let ((svg (plist-get (cdr (car-safe disp)) :data)))
              (when svg
                (let ((new-svg (string-replace old-bg new-bg
                                               (string-replace old-fg new-fg svg))))
                  (setcar (cdr (plist-member (cdar disp) :data)) new-svg)
                  (overlay-put ov 'tip-fg new-fg)
                  (overlay-put ov 'tip-bg new-bg))))))))))

(defun tip--on-theme-change (&rest _)
  "Update all tip buffers after a theme change.
Uses fast SVG color substitution (no recompilation).
Invalidates live preview cache so childframe updates."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when tip-mode
        (tip--recolor-overlays)
        (setq tip-live--content-cache "")))))

(defun tip--rescale-overlays ()
  "Update image specs on all tip overlays for the current font.
Recomputes scale and ascent from the current font metrics without
recompiling SVGs — no server round-trip."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (and (eq (overlay-get ov 'tip) 'tip)
               (overlay-get ov 'display))
      (let ((svg (overlay-get ov 'tip-svg))
            (h (overlay-get ov 'tip-height-pt))
            (d (overlay-get ov 'tip-depth-pt)))
        (when (and svg h (> h 0))
          (let* ((is-display (eq (overlay-get ov 'view-text) nil)
                  ;; Check if it was display math by looking at ascent
                  )
                 (disp (overlay-get ov 'display))
                 (old-ascent (plist-get (cdr (car-safe disp)) :ascent))
                 (is-display (eq old-ascent 'center))
                 (new-spec (tip--make-image-spec svg h d is-display)))
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
        ;; Font changes via variable-pitch-mode / buffer-face-mode
        (add-hook 'buffer-face-mode-hook #'tip--on-font-change nil t))
    (remove-hook 'enable-theme-functions #'tip--on-theme-change)
    (remove-hook 'disable-theme-functions #'tip--on-theme-change)
    (remove-hook 'buffer-face-mode-hook #'tip--on-font-change t)))

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
  "Jump to a math/diagram fragment using avy-style tree selection.
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
  "Open an indirect edit buffer for the math/diagram at point.
Like `org-edit-special' (C-c ').  Shows live preview while editing.
\\[tip-edit-commit] saves back, \\[tip-edit-abort] cancels."
  (interactive)
  (let ((bounds (tip--get-bounds-of-math-at-point (point))))
    (unless bounds
      (user-error "No math or diagram at point"))
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
               ("preamble" . ,(tip--build-preamble)))
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
