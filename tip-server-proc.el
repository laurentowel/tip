;;; tip-server-proc.el --- tip-server process + JSON-RPC stdio transport -*- lexical-binding: t; -*-

;;; Commentary:

;; Backend-agnostic process management for a tip-* server binary.  One
;; process per Emacs session (for now), newline-delimited JSON-RPC over
;; stdio.  The concrete binary is discovered via `tip-server-executable'
;; or falls back to searching for `tip-server-typst' on PATH and in the
;; local build tree.  A future tip-backend struct will parameterise this
;; lookup per active backend.
;;
;; Public entry points:
;;   `tip-ensure'        spawn if not running
;;   `tip--send-request' fire a method call, invoke callback on response
;;   `tip--sync-buffer'  send the current buffer content as `sync'

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'tip-backend)

;; Customs that live in tip.el — forward-declared so the byte-compiler
;; knows they'll exist at runtime.
(defvar tip-enable-debug)
(defvar tip-font-dirs)
(defvar tip-server-executable)
(defvar tip-use-docker)
(defvar tip-docker-image)

;;; * debug

(defmacro tip-debug-msg (&rest args)
  `(when tip-enable-debug
     (message ,@args)))

;;; * font directory resolution

(defun tip--package-dir ()
  "Return the directory containing tip.el."
  (file-name-directory (or load-file-name (locate-library "tip") "")))

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

;;; * process state

(defvar tip--server-process nil
  "The tip-server child process.")

(defvar tip--request-id 0
  "Monotonically increasing request ID.")

(defvar tip--response-buffer ""
  "Accumulates partial output from the server.")

(defvar tip--pending-callbacks (make-hash-table :test 'eql)
  "Maps request ID to callback function.")

(defvar tip-server-response-functions nil
  "Hook run after each tip-server response is processed.
Called with one argument: the result alist.")

(defun tip--next-id ()
  "Return next request ID."
  (cl-incf tip--request-id))

;;; * discovery / installation

(defun tip--find-server ()
  "Find the backend's server executable, or prompt user to install.
Returns the path, or nil if Docker mode (handled separately).
Uses `tip-server-executable-name' from the active backend; falls back
to the Typst default when no backend is active (e.g. bare test buffers)."
  (when tip-use-docker
    (cl-return-from tip--find-server nil))
  (let* ((name (or (tip-server-executable-name) "tip-server"))
         ;; When the backend resolved to an absolute path already, use it.
         (absolute (and name (file-name-absolute-p name) (file-executable-p name))))
    (or (and absolute name)
        tip-server-executable
        (executable-find name)
        ;; Check local build beside tip.el
        (let ((local (expand-file-name
                      (concat "tip-server/target/release/" name)
                      (tip--package-dir))))
          (when (file-executable-p local) local))
        ;; Check in elpaca build dir (source repo)
        (let ((elpaca-src (expand-file-name
                           (concat "tip-server/target/release/" name)
                           (file-name-directory
                            (or (locate-library "tip") "")))))
          (when (file-executable-p elpaca-src) elpaca-src))
        (tip--prompt-install))))

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
  "Compile tip-server from Rust source using `compilation-mode'.
Builds the binary matching the active backend's `server-executable'
field (defaulting to tip-server-typst)."
  (interactive)
  (unless (executable-find "cargo")
    (user-error "Rust toolchain not found. Install from https://rustup.rs"))
  (let* ((pkg-dir (tip--package-dir))
         (server-dir (expand-file-name "tip-server" pkg-dir))
         (bin (or (tip-server-executable-name) "tip-server"))
         (target (expand-file-name (concat "target/release/" bin) server-dir)))
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

;;; * process spawn

(defconst tip--server-stderr-buffer-name "*tip-server-stderr*"
  "Buffer name capturing tip-server's stderr.
Panic backtraces (RUST_BACKTRACE=1 is set by `tip--start-server-process')
land here.  View via `tip-show-server-stderr'.")

(defun tip--server-stderr-buffer ()
  "Return (creating if needed) the tip-server stderr capture buffer."
  (let ((buf (get-buffer-create tip--server-stderr-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    buf))

(defun tip--start-server-process ()
  "Start tip-server as a local process.
Stderr is captured into `tip--server-stderr-buffer-name' so panic
backtraces (RUST_BACKTRACE=1) survive an exit.  No perf cost:
RUST_BACKTRACE is only consulted when the process actually panics."
  (let ((exe (tip--find-server)))
    (unless exe
      (user-error "No tip-server binary found. Run M-x tip--compile-from-source"))
    (let ((process-environment
           (cons "RUST_BACKTRACE=1" process-environment)))
      (make-process
       :name "tip-server"
       :command (list exe)
       :connection-type 'pipe
       :filter #'tip--process-filter
       :sentinel #'tip--process-sentinel
       :stderr (tip--server-stderr-buffer)
       :noquery t))))

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
     :stderr (tip--server-stderr-buffer)
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
          (tip-debug-msg "tip-server started (pid %d)"
                         (process-id tip--server-process))
          ;; Cross-backend / cross-binary cache collisions are real
          ;; (see tip-cache-clear-on-server-restart doc).  Drop every
          ;; buffer's cache when a new server process starts.
          (when (and (boundp 'tip-cache-clear-on-server-restart)
                     tip-cache-clear-on-server-restart
                     (fboundp 'tip-cache-clear))
            (tip-cache-clear t))
          ;; New server has no synced buffers — invalidate every
          ;; buffer's last-sync tick so the next compile re-syncs.
          (dolist (buf (buffer-list))
            (with-current-buffer buf
              (when (local-variable-p 'tip--last-sync-tick)
                (setq tip--last-sync-tick nil))))
          (let ((dirs (tip--resolve-font-dirs)))
            (when dirs
              (tip--send-request "init" `(("font_dirs" . ,(vconcat dirs)))))))
      (message "tip-server failed to start"))))

(defun tip--server-stderr-tail (&optional n-lines)
  "Return the last N-LINES of the tip-server stderr buffer, or nil.
Defaults to 10 lines."
  (let ((buf (get-buffer tip--server-stderr-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((end (point-max))
              (n (or n-lines 10)))
          (save-excursion
            (goto-char end)
            (forward-line (- n))
            (let ((s (buffer-substring-no-properties (point) end)))
              (unless (string-empty-p (string-trim s)) s))))))))

(defun tip--process-sentinel (proc event)
  "Handle tip-server process state changes.
On unexpected exits, surface the stderr tail so the user sees panic
backtraces (RUST_BACKTRACE=1) instead of a bare `exited abnormally'."
  (tip-debug-msg "tip-server: %s" (string-trim event))
  (when (not (process-live-p proc))
    (setq tip--server-process nil)
    (let ((ev (string-trim event))
          (tail (tip--server-stderr-tail 20)))
      (cond
       ((or (string-match-p "finished" ev) (string-match-p "killed" ev))
        (message "tip-server exited: %s" ev))
       (t
        (message "tip-server exited: %s (M-x tip-show-server-stderr for details)%s"
                 ev
                 (if tail
                     (format "\n--- last stderr lines ---\n%s"
                             (string-trim tail))
                   "")))))))

;;;###autoload
(defun tip-show-server-stderr ()
  "Pop the tip-server stderr capture buffer.
Useful for panic backtraces after an unexpected `exit 1'.
RUST_BACKTRACE=1 is set at process spawn so panics include frames."
  (interactive)
  (let ((buf (get-buffer tip--server-stderr-buffer-name)))
    (if (and buf (> (buffer-size buf) 0))
        (pop-to-buffer buf)
      (message "tip-server stderr is empty (no panics / warnings captured)"))))

(defun tip--process-filter (_proc output)
  "Handle output from tip-server.  Parse newline-delimited JSON responses."
  (setq tip--response-buffer (concat tip--response-buffer output))
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
              ;; Any error inside a user callback (dead buffer,
              ;; type mismatch, etc.) must not propagate — emacs
              ;; would print it as "error in process sentinel"
              ;; and mask the real cause.  Catch + log and move on.
              (when callback
                (condition-case cb-err
                    (funcall callback result)
                  (error
                   (tip-debug-msg "tip-server callback error: %S id=%s"
                                  cb-err id))))
              (condition-case hook-err
                  (run-hook-with-args 'tip-server-response-functions result)
                (error
                 (tip-debug-msg "tip-server response-hook error: %S" hook-err))))
          (error
           (tip-debug-msg "tip-server parse error: %S for line: %s" err line)))))))

;;; * request/response

(defvar tip--backend-carrying-methods
  '("sync" "compile_fragments" "compile_live" "debug_skeleton" "list_project_files")
  "Request methods that carry a `backend' field.
`init', `health_check', and `shutdown' do not — they are backend-agnostic.")

(defun tip--current-backend-id ()
  "Return the current buffer's backend as a protocol id string.
Derived from `tip-active-backend' (which is based on `major-mode').
Returns \"typst\" if no backend is active (safe default — the server
treats it as Typst per `BackendId::default')."
  (let ((b (and (fboundp 'tip-active-backend) (tip-active-backend))))
    (if b (symbol-name (tip-backend-name b)) "typst")))

(defun tip--send-request (method params &optional callback)
  "Send a JSON-RPC request to tip-server.
METHOD is the method name string.
PARAMS is an alist of parameters.  For methods in
`tip--backend-carrying-methods' a `backend' field is auto-injected
from the current buffer's active backend so a single server process
can serve multiple backends per Emacs session.
CALLBACK is called with the result alist when response arrives."
  (tip-ensure)
  (let* ((id (tip--next-id))
         (params (if (and (member method tip--backend-carrying-methods)
                          (not (assoc "backend" params)))
                     (cons `("backend" . ,(tip--current-backend-id)) params)
                   params))
         (request `(("id" . ,id)
                    ("method" . ,method)
                    ("params" . ,params))))
    (when callback
      (puthash id callback tip--pending-callbacks))
    (let ((json (concat (json-encode request) "\n")))
      (tip-debug-msg "tip-server send: %s" (string-trim json))
      (process-send-string tip--server-process json))))

(defvar-local tip--last-sync-tick nil
  "`buffer-chars-modified-tick' value at the last successful sync.
Compared in `tip--sync-buffer' to skip redundant whole-buffer sends
when nothing has changed.  Reset to nil when the server restarts or
the cache is cleared (see `tip-cache-clear-on-server-restart').")

(defvar tip-pre-sync-functions nil
  "Hook run before `tip--sync-buffer' sends.
Backends register here to ship companion buffers (e.g. tip-latex
syncs the project root buffer when the user is editing a child
file, so a `\\newcommand' edit in the parent reaches the server
before the child's compile fires).  Functions take no args; each
runs with the EDITED buffer current.")

(defun tip--sync-buffer ()
  "Sync current buffer content to tip-server.
Skips when `buffer-chars-modified-tick' hasn't advanced since the
last sync.  Cursor toggles in/out of fragments don't change the tick,
so tight C-n/C-p loops don't reship the buffer.  Forces a fresh send
when the server process changed (e.g. after restart) — see
`tip-ensure'."
  (run-hooks 'tip-pre-sync-functions)
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eq tip--last-sync-tick tick)
      (setq tip--last-sync-tick tick)
      (let ((params
             `(("uri" . ,(buffer-file-name))
               ("content" . ,(save-restriction
                               (widen)
                               (buffer-substring-no-properties (point-min)
                                                               (point-max)))))))
        (when-let ((root (and (fboundp 'tip--resolve-project-root)
                              (tip--resolve-project-root))))
          (push (cons "project_root" root) params))
        (tip--send-request "sync" params)))))

(provide 'tip-server-proc)

;;; tip-server-proc.el ends here
