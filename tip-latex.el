;;; tip-latex.el --- LaTeX backend for tip -*- lexical-binding: t; -*-

;;; Commentary:

;; LaTeX backend.  Detects math fragments by regex (see
;; `tip-latex--math-begin-re' and friends), skips comments via
;; `syntax-ppss', and skips verbatim-like environments via a pre-pass.
;; Preamble is the raw text before `\\begin{document}'.
;;
;; Scope: single-file for v1.  If the preamble contains `\\input',
;; `\\include', or `\\subimport' a one-time warning is emitted; we
;; still preview but the compile may fail (soft-refuse).  See
;; doc/latex-preview-survey.md and doc/digestif-extraction.md for
;; rationale.
;;
;; No AUCTeX dependency.  When AUCTeX is loaded, `texmathp' could be
;; used for a more robust bounds-at-point check; not adopted yet.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tip-backend)

;; Customs live in tip.el when possible; this backend's own knobs go here.
(declare-function tip--color-to-hex "tip" (color))
(defvar tip-transparent-bg)
(defvar tip-server-executable)
(defvar tip-project-root-path)
(declare-function tip-latex-treesit-collect-fragments  "tip-latex-parse-treesit")
(declare-function tip-latex-treesit-bounds-at-point    "tip-latex-parse-treesit")

;;; * customization

(defgroup tip-latex nil
  "LaTeX backend for tip."
  :group 'tip
  :prefix "tip-latex-")

(defcustom tip-latex-default-preamble
  "\\documentclass{article}
\\usepackage{amsmath,amssymb,amsthm}
\\usepackage[utf8]{inputenc}
"
  "Preamble used when the buffer has no `\\begin{document}'."
  :type 'string
  :group 'tip-latex)

;;; * fragment detection — delegates to tree-sitter
;;
;; Tree-sitter (alex-pinkus/tree-sitter-latex) is the only fragment
;; parser tip ships now.  The previous regex parser had a 200-line
;; verbatim/comment/escape state machine plus an idle-debounced cache
;; whose stale window caused "C-e out of fragment doesn't trigger
;; recompile" misbehaviors — see commits leading up to this one.
;;
;; The treesit module is loaded lazily so the tip core boots even
;; without the grammar; collect/bounds return nil when the grammar
;; isn't installed, prompting the user to run
;; `M-x tip-latex-install-treesit-grammar' (clones latex-lsp/
;; tree-sitter-latex, runs `tree-sitter generate', compiles into
;; ~/.emacs.d/tree-sitter/).

(defun tip-latex-collect-fragments (beg end &optional avoid-pos)
  "Collect math fragments intersecting BEG..END.
Returns alists with \"start\"/\"end\" byte offsets per the
`tip-collect-fragments' contract.  Delegates to the treesit parser
in `tip-latex-parse-treesit'; returns nil when the latex grammar
isn't installed."
  (require 'tip-latex-parse-treesit)
  (tip-latex-treesit-collect-fragments beg end avoid-pos))

(defun tip-latex-bounds-at-point (pos)
  "Return (BEG . END) of the math fragment at POS, or nil.
Half-open: BEG <= POS < END."
  (require 'tip-latex-parse-treesit)
  (tip-latex-treesit-bounds-at-point pos))

;;; * multi-file detection

(defvar-local tip-latex--has-includes 'unknown
  "Buffer-local cache: `t', `nil', or the sentinel `unknown'.
Set by `tip-latex--buffer-has-includes-p' on first check; invalidated
when the buffer is modified (see `tip-latex--on-change').")

(defun tip-latex--include-re ()
  "Regex matching `\\input', `\\include', or `\\subimport' commands."
  "\\\\\\(input\\|include\\|subimport\\)\\b")

(defun tip-latex--buffer-has-includes-p ()
  "Return non-nil if the buffer contains a live \\input/\\include/\\subimport.
Scans the WHOLE buffer (ignoring narrowing) so a narrow-to-section
doesn't hide an include lurking in the preamble.  Skips matches inside
comments.  Cached in `tip-latex--has-includes'."
  (if (not (eq tip-latex--has-includes 'unknown))
      tip-latex--has-includes
    (setq tip-latex--has-includes
          (save-restriction
            (widen)
            (save-excursion
              (goto-char (point-min))
              (catch 'found
                (while (re-search-forward (tip-latex--include-re) nil t)
                  (save-excursion
                    (unless (nth 4 (syntax-ppss (match-beginning 0)))
                      (throw 'found t))))
                nil))))))

(defun tip-latex--on-change (&rest _)
  "Invalidate the include-scan cache when the buffer changes.
The fragment list itself is owned by the treesit parser (which is
incremental); no separate rescan needed here."
  (setq tip-latex--has-includes 'unknown))

(add-hook 'after-change-functions #'tip-latex--on-change)

(declare-function tip--sync-buffer "tip-server-proc")

(defvar tip-latex--syncing-root nil
  "Re-entry guard for `tip-latex--sync-project-root-buffer'.")

(defun tip-latex--sync-project-root-buffer ()
  "Push the project ROOT buffer's CURRENT state to the server.
No-op when:
- the active backend isn't latex,
- there's no `tip-project-root-path' (single-file edit),
- this buffer IS the root,
- the root file isn't currently visited in any Emacs buffer.

Otherwise we run `tip--sync-buffer' inside the root buffer, which
itself bails when the root's `buffer-chars-modified-tick' hasn't
advanced — so the cost is one buffer lookup per compile when the
root is unchanged.

Hooked from `tip-pre-sync-functions' so it fires before every
compile request from a child file: a `\\newcommand' edit in the
parent reaches the server before the child's `compile_fragments'
fires.  Same handling covers `\\input', `\\include', `\\subimport'
(all share the parent preamble per LaTeX semantics)."
  (when-let* (((not tip-latex--syncing-root))
              (b (and (fboundp 'tip-active-backend) (tip-active-backend)))
              ((eq (tip-backend-name b) 'latex))
              (root (and (boundp 'tip-project-root-path) tip-project-root-path))
              (root-canon (expand-file-name root))
              ;; Skip if this IS the root buffer.
              ((not (and buffer-file-name
                         (string= (expand-file-name buffer-file-name) root-canon))))
              (root-buf (find-buffer-visiting root-canon)))
    (let ((tip-latex--syncing-root t))
      (with-current-buffer root-buf
        (when (fboundp 'tip--sync-buffer)
          (tip--sync-buffer))))))

(add-hook 'tip-pre-sync-functions #'tip-latex--sync-project-root-buffer)

;;; * preamble extraction

(defun tip-latex--preamble-end ()
  "Return position of `\\begin{document}' (buffer-wide) or nil.
Ignores narrowing — a narrow-to-section should still see the real
preamble.  Skips matches inside `%'-comments so prose or example
text in a comment doesn't prematurely terminate the preamble."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (let (found)
        (while (and (not found)
                    (re-search-forward "\\\\begin{document}" nil t))
          (let ((ls (line-beginning-position))
                (mb (match-beginning 0)))
            ;; Comment if a `%' sits on the same line before the match
            ;; and isn't itself escaped (`\\%' is a literal percent).
            (unless (save-excursion
                      (goto-char ls)
                      (catch 'comment
                        (while (re-search-forward "%" mb t)
                          (unless (and (> (match-beginning 0) ls)
                                       (eq (char-before (match-beginning 0)) ?\\))
                            (throw 'comment t)))
                        nil))
              (setq found mb))))
        found))))

(defun tip-latex-build-preamble ()
  "Return the document preamble as a string.
Reads from buffer start (widened) to `\\begin{document}' — a
narrow-to-section leaves preamble extraction intact.  If there's no
`\\begin{document}' anywhere, returns `tip-latex-default-preamble'."
  (save-restriction
    (widen)
    (let ((pend (tip-latex--preamble-end)))
      (if pend
          (buffer-substring-no-properties (point-min) pend)
        tip-latex-default-preamble))))

;;; * classification

(defun tip-latex-classify-fragment (text)
  "Classify fragment TEXT for display purposes.
Returns one of `inline', `display-single', `display-multi'.
LaTeX has no `block' analogue in v1."
  (cond
   ((zerop (length text)) 'inline)
   ;; Display openers
   ((or (string-prefix-p "\\[" text)
        (string-prefix-p "$$" text)
        (string-prefix-p "\\begin{" text))
    (if (string-match-p "\n" text) 'display-multi 'display-single))
   ;; Everything else: \(...\) or $...$ → inline.
   (t 'inline)))

;;; * project root discovery

(defcustom tip-latex-session-file
  (locate-user-emacs-file "tip-latex-sessions.el")
  "File persisting per-buffer project-root choices across sessions.
Written whenever `tip-latex-set-root' or the first-time prompt
records an answer.  Disable by setting to nil — choices then live
only for the current Emacs session."
  :type '(choice (const :tag "Disable persistence" nil) file)
  :group 'tip)

(defvar tip-latex--session-cache nil
  "In-memory mirror of `tip-latex-session-file' — an alist
mapping absolute buffer path → absolute root path.
Loaded lazily by `tip-latex--session-load'.")

(defvar tip-latex--session-loaded nil)

(defun tip-latex--session-load ()
  "Read `tip-latex-session-file' into `tip-latex--session-cache'."
  (unless tip-latex--session-loaded
    (setq tip-latex--session-loaded t)
    (when (and tip-latex-session-file
               (file-readable-p tip-latex-session-file))
      (with-demoted-errors "tip-latex-session-load: %S"
        (with-temp-buffer
          (insert-file-contents tip-latex-session-file)
          (setq tip-latex--session-cache (read (current-buffer))))))))

(defun tip-latex--session-save ()
  "Write `tip-latex--session-cache' to disk."
  (when tip-latex-session-file
    (with-demoted-errors "tip-latex-session-save: %S"
      (make-directory (file-name-directory tip-latex-session-file) t)
      (with-temp-file tip-latex-session-file
        (let ((print-length nil) (print-level nil))
          (prin1 tip-latex--session-cache (current-buffer)))))))

(defun tip-latex--session-lookup (file)
  "Return the saved root for FILE, or nil."
  (tip-latex--session-load)
  (cdr (assoc (expand-file-name file) tip-latex--session-cache)))

(defun tip-latex--session-store (file root)
  "Persist (FILE → ROOT) in the session file."
  (tip-latex--session-load)
  (setf (alist-get (expand-file-name file)
                   tip-latex--session-cache nil nil #'equal)
        (expand-file-name root))
  (tip-latex--session-save))

(defun tip-latex--magic-comment-root ()
  "Parse the `% !TEX root = PATH' magic comment anywhere in the
buffer.  Returns PATH resolved against the buffer's directory, or
nil.  Scanning the whole buffer is microseconds — no 1000-byte
cap like digestif."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (re-search-forward
             "^[[:blank:]]*%[[:blank:]]*!TEX[[:blank:]]+root[[:blank:]]*=[[:blank:]]*\\(.+?\\)[[:blank:]]*$"
             nil t)
        (let ((raw (match-string-no-properties 1)))
          (expand-file-name raw (file-name-directory
                                 (or buffer-file-name default-directory))))))))

(defun tip-latex--candidate-roots ()
  "Return a list of plausible root `.tex' paths in ancestor dirs.
A plausible root is a `.tex' file whose first 4k contains
`\\documentclass'.  Walks up from the buffer's directory to home
or filesystem root, whichever comes first."
  (let* ((start (file-name-directory (or buffer-file-name default-directory)))
         (home (expand-file-name "~/"))
         (candidates nil)
         (dir (expand-file-name start)))
    (while (and dir
                (not (string= dir (expand-file-name "/")))
                (not (string= dir home)))
      (dolist (f (ignore-errors (directory-files dir t "\\.tex\\'")))
        (when (and (file-readable-p f)
                   (not (file-directory-p f))
                   (with-temp-buffer
                     (insert-file-contents f nil 0 4096)
                     (save-excursion
                       (goto-char (point-min))
                       (re-search-forward "\\\\documentclass" nil t))))
          (push f candidates)))
      (let ((parent (file-name-directory (directory-file-name dir))))
        (setq dir (unless (equal parent dir) parent))))
    (nreverse candidates)))

(defun tip-latex--prompt-for-root ()
  "Ask the user which file is this project's root.
Default is the current buffer file; completions are
`tip-latex--candidate-roots' — any `\\documentclass'-bearing
`.tex' in an ancestor directory."
  (let* ((here (or buffer-file-name default-directory))
         (candidates (tip-latex--candidate-roots))
         (default (or (car candidates) here))
         (prompt (format "tip-latex project root (default %s): "
                         (file-name-nondirectory default)))
         (choice (completing-read prompt candidates nil nil nil nil default)))
    (expand-file-name choice)))

(defun tip-latex-set-root (root)
  "Re-prompt for this buffer's project root and persist the answer.
ROOT is resolved against the buffer's directory if relative."
  (interactive (list (tip-latex--prompt-for-root)))
  (setq-local tip-project-root-path (expand-file-name root))
  (when buffer-file-name
    (tip-latex--session-store buffer-file-name tip-project-root-path))
  (message "tip-latex root → %s" tip-project-root-path)
  tip-project-root-path)

(defun tip-latex-maybe-setup-project ()
  "Resolve this buffer's project root on `tip-mode' enable.
Precedence:
  1. `tip-project-root-path' already set (by user or .dir-locals.el) — keep.
  2. `% !TEX root' magic comment (child files usually have this and
     no \\input of their own).
  3. Saved session answer for this file.
  4. If the buffer has \\input/\\include/\\subimport and is file-backed
     — prompt the user; remember the answer.
  5. If the buffer has \\input but is NOT file-backed — error loudly.
  6. Otherwise skip (single-file, no multi-file signals).

Called from `tip-mode' activation via the LaTeX backend."
  (when (and (derived-mode-p 'latex-mode 'LaTeX-mode)
             (not tip-project-root-path))
    (let ((magic (tip-latex--magic-comment-root))
          (saved (and buffer-file-name
                      (tip-latex--session-lookup buffer-file-name)))
          (has-inc (tip-latex--buffer-has-includes-p)))
      (cond
       (magic (setq-local tip-project-root-path magic))
       (saved (setq-local tip-project-root-path saved))
       ((and has-inc (null buffer-file-name))
        (user-error
         "tip-latex: buffer contains \\input/\\include but is not visiting a file"))
       (has-inc
        (tip-latex-set-root (tip-latex--prompt-for-root)))))))

;;; * skeleton view

(declare-function tip--show-debug-skeleton "tip")

(defun tip-latex-show-skeleton ()
  "Show the assembled LaTeX preamble for this buffer.
LaTeX preambles are document-wide; no fragment-at-point required.
The server walks the multi-file project (when active) and returns
the preamble it would prepend to a fragment compile."
  (tip--show-debug-skeleton
   0 0 "*tip-preamble*"
   (and (fboundp 'latex-mode) #'latex-mode)))

;;; * backend registration

(tip-register-backend
 (make-tip-backend
  :name 'latex
  :major-modes '(latex-mode LaTeX-mode)
  :collect-fragments-fn #'tip-latex-collect-fragments
  :bounds-at-point-fn #'tip-latex-bounds-at-point
  :build-preamble-fn #'tip-latex-build-preamble
  :classify-fragment-fn #'tip-latex-classify-fragment
  :server-executable "tip-server"
  :show-skeleton-fn #'tip-latex-show-skeleton))

(provide 'tip-latex)

;;; tip-latex.el ends here
