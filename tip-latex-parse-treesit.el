;;; tip-latex-parse-treesit.el --- Tree-sitter LaTeX fragment collector -*- lexical-binding: t; -*-

;;; Commentary:

;; Tree-sitter (alex-pinkus/tree-sitter-latex; same grammar texlab uses)
;; alternative to the regex parser in tip-latex.el.  Loaded only when
;; `tip-latex-parser' resolves to `treesit'.
;;
;; Cache story: there is none.  treesit's incremental parser always
;; reflects the current buffer state, so callers can ask for
;; `collect-fragments' / `bounds-at-point' synchronously without
;; idle-debounce.  This fixes the "I C-e out of a fragment and the
;; close-at-marker doesn't fire" class of bug — the regex path served a
;; stale-on-purpose cache during active typing, which left
;; `bounds-at-point' returning wrong ranges in the window between an
;; edit and the next idle pause.
;;
;; Math node types in the tree-sitter-latex grammar:
;;   - `inline_formula'      — `$...$', `\(...\)'
;;   - `displayed_equation'  — `\[...\]'
;;   - `math_environment'    — `\begin{equation}...', `\begin{align*}...', etc.
;;
;; Skip handling:
;;   - `verbatim_environment' (parser puts inner text in `comment'; no
;;     formula node leaks).  No-op needed.
;;   - `\verb|...|' — known false positive: parser reports `inline_formula'
;;     inside.  Filtered post-hoc by checking whether a `\verb' command
;;     immediately precedes the candidate.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'treesit nil t)

(declare-function treesit-available-p      "treesit")
(declare-function treesit-ready-p          "treesit")
(declare-function treesit-parser-list      "treesit")
(declare-function treesit-parser-create    "treesit")
(declare-function treesit-parser-root-node "treesit")
(declare-function treesit-query-capture    "treesit")
(declare-function treesit-node-start       "treesit")
(declare-function treesit-node-end         "treesit")

(defvar-local tip-latex--treesit-parser nil
  "Buffer-local cached treesit parser (or `unavailable' sentinel).")

(defun tip-latex--treesit-parser ()
  "Return a live latex treesit parser for the current buffer, or nil.
Caches in `tip-latex--treesit-parser'.  Probes via
`treesit-ready-p ... t' so it never triggers the grammar-install
prompt during batch / headless runs."
  (cond
   ((eq tip-latex--treesit-parser 'unavailable) nil)
   (tip-latex--treesit-parser tip-latex--treesit-parser)
   ((not (and (fboundp 'treesit-available-p) (treesit-available-p)))
    (setq tip-latex--treesit-parser 'unavailable) nil)
   ((not (and (fboundp 'treesit-ready-p) (treesit-ready-p 'latex t)))
    (setq tip-latex--treesit-parser 'unavailable) nil)
   (t
    (setq tip-latex--treesit-parser
          (or (car (treesit-parser-list (current-buffer) 'latex))
              (treesit-parser-create 'latex))))))

(defconst tip-latex--treesit-math-node-types
  '("inline_formula" "displayed_equation" "math_environment")
  "Tree-sitter latex node types that carry a math fragment.")

(defvar-local tip-latex--treesit-fragment-cache nil
  "Cons (TICK . RANGES) — one entry per `buffer-chars-modified-tick'.
RANGES is a sorted list of `(START . END)' integer ranges (1-based
buffer positions) covering every math node in the buffer, with
verb-span false-positives filtered out.

Because the tick only changes on text edits, repeated cursor-motion
queries reuse the same cache.  Treesit's parser is incremental on
edits, so the next computation after an edit is still fast — but
calling `treesit-query-capture' over the whole buffer N times per
C-n compounds at high key-repeat rates.")

(defun tip-latex--treesit-all-fragments ()
  "Return cached `(START . END)' ranges for all math nodes; recompute on edit."
  (let ((tick (buffer-chars-modified-tick)))
    (if (and tip-latex--treesit-fragment-cache
             (eq (car tip-latex--treesit-fragment-cache) tick))
        (cdr tip-latex--treesit-fragment-cache)
      (let* ((parser (tip-latex--treesit-parser))
             (ranges nil))
        (when parser
          (let ((root (treesit-parser-root-node parser)))
            (dolist (type tip-latex--treesit-math-node-types)
              (condition-case _
                  (dolist (cell (treesit-query-capture
                                 root `((,(intern type)) @n)))
                    (let ((node (cdr cell)))
                      (push (cons (treesit-node-start node)
                                  (treesit-node-end node))
                            ranges)))
                (treesit-query-error nil)))))
        (setq ranges (sort ranges (lambda (a b) (< (car a) (car b)))))
        ;; Drop verb false-positives once, not per-call.
        (setq ranges (seq-remove
                      (lambda (r) (tip-latex--treesit-inside-verb-p (car r)))
                      ranges))
        (setq tip-latex--treesit-fragment-cache (cons tick ranges))
        ranges))))

(defun tip-latex--treesit-inside-verb-p (start)
  "Return non-nil if START sits inside a `\\verb|...|' span.
The latex grammar parses the inner `$...$' as `inline_formula' even
when the outer `\\verb' makes it literal.  Heuristic: the immediately
preceding `\\verb' (or `\\verb*') command up to a whitespace or EOL
isn't closed by a matching delimiter before START."
  (save-excursion
    (goto-char start)
    (when (re-search-backward "\\\\verb\\*?\\([^a-zA-Z*]\\)"
                              (max (point-min) (- start 200)) t)
      (let* ((open (match-end 0))
             (delim (match-string 1)))
        (and (> open (point-min))
             (let ((close (save-excursion
                            (goto-char open)
                            (search-forward delim start t))))
               (or (null close) (>= close start))))))))

(defun tip-latex-treesit-collect-fragments (beg end &optional avoid-pos)
  "Return math fragments overlapping [BEG, END) via the treesit parser.
Format matches the regex collector: alists with string keys
`start' / `end' carrying 0-based byte offsets.  AVOID-POS, when
non-nil, drops the fragment that contains it (cursor-leave path
uses this to not re-render the fragment the user just exited).
Reads from `tip-latex--treesit-all-fragments' which caches by
buffer-modified-tick — cursor-motion calls hit cache."
  (let (out)
    (dolist (r (tip-latex--treesit-all-fragments))
      (let ((s (car r)) (e (cdr r)))
        (when (and (< s end) (> e beg)
                   (not (and avoid-pos (<= s avoid-pos) (< avoid-pos e))))
          (push `(("start" . ,(1- (position-bytes s)))
                  ("end"   . ,(1- (position-bytes e))))
                out))))
    (nreverse out)))

(defun tip-latex-treesit-bounds-at-point (pos)
  "Return `(BEG . END)' of the math fragment at POS via treesit.
Half-open: BEG ≤ POS < END.  Synchronous; no stale cache (the
underlying fragment list is recomputed on every buffer edit and
reused across cursor motion)."
  (let ((best nil))
    (dolist (r (tip-latex--treesit-all-fragments))
      (let ((s (car r)) (e (cdr r)))
        (when (and (<= s pos) (< pos e))
          (when (or (null best) (< (- e s) (- (cdr best) (car best))))
            (setq best (cons s e))))))
    best))

;;;###autoload
(defun tip-latex-install-treesit-grammar ()
  "Build and install the latex-lsp/tree-sitter-latex grammar.
Upstream does not commit `parser.c', so the standard
`treesit-install-language-grammar' path can't pull a pre-generated
artifact.  Workflow:
  1. clone https://github.com/latex-lsp/tree-sitter-latex
  2. run `tree-sitter generate' inside it
  3. compile the produced parser.c (and scanner.c / scanner.cc, if any)
     into `~/.emacs.d/tree-sitter/libtree-sitter-latex.<so|dylib|dll>'

Requires the `tree-sitter' CLI on `PATH' — install via
`cargo install tree-sitter-cli', `npm i -g tree-sitter-cli', or your
distro package.  And a C compiler (cc/gcc).  Pattern adapted from
cdmath's grammar bootstrap."
  (interactive)
  (unless (executable-find "tree-sitter")
    (user-error
     "tree-sitter CLI not found.  Install it via `cargo install tree-sitter-cli', \
`npm i -g tree-sitter-cli', or your package manager and retry"))
  (let* ((url "https://github.com/latex-lsp/tree-sitter-latex")
         (tmp (make-temp-file "tip-latex-grammar-" t))
         (repo (expand-file-name "tree-sitter-latex" tmp))
         (out-dir (expand-file-name "tree-sitter" user-emacs-directory))
         (log "*tip-latex-install*"))
    (unless (yes-or-no-p
             (format "tip-latex: download from %s and build in %s, \
installing into %s.  Proceed? "
                     url tmp out-dir))
      (delete-directory tmp t)
      (user-error "Aborted"))
    (unwind-protect
        (progn
          (with-current-buffer (get-buffer-create log) (erase-buffer))
          (message "tip-latex: cloning %s..." url)
          (unless (zerop (call-process "git" nil log nil
                                       "clone" "--depth" "1" url repo))
            (pop-to-buffer log)
            (error "git clone failed"))
          (let ((default-directory repo))
            (message "tip-latex: running `tree-sitter generate'...")
            (unless (zerop (call-process "tree-sitter" nil log nil "generate"))
              (pop-to-buffer log)
              (error "tree-sitter generate failed")))
          (let* ((src-dir (expand-file-name "src" repo))
                 (parser-c (expand-file-name "parser.c" src-dir))
                 (scanner-c (expand-file-name "scanner.c" src-dir))
                 (scanner-cc (expand-file-name "scanner.cc" src-dir))
                 (ext (pcase system-type
                        ('darwin "dylib")
                        ('windows-nt "dll")
                        (_ "so")))
                 (so-path (expand-file-name
                           (format "libtree-sitter-latex.%s" ext) out-dir))
                 (cc (or (executable-find "cc") (executable-find "gcc")
                         (user-error "No C compiler found (cc/gcc)")))
                 (c++ (or (executable-find "c++") (executable-find "g++") cc))
                 (compiler (if (file-exists-p scanner-cc) c++ cc))
                 (srcs (delq nil
                             (list parser-c
                                   (and (file-exists-p scanner-c) scanner-c)
                                   (and (file-exists-p scanner-cc) scanner-cc))))
                 (args (append (list "-fPIC" "-shared" "-O2" "-I" src-dir
                                     "-o" so-path)
                               srcs)))
            (unless (file-exists-p parser-c)
              (error "parser.c not produced; tree-sitter generate may have failed silently"))
            (make-directory out-dir t)
            (message "tip-latex: compiling %s..." (file-name-nondirectory so-path))
            (unless (zerop (apply #'call-process compiler nil log nil args))
              (pop-to-buffer log)
              (error "C compilation failed"))
            (message "tip-latex: installed %s" so-path)))
      ;; Always clean up the build dir.
      (when (file-exists-p tmp)
        (delete-directory tmp t)))))

(provide 'tip-latex-parse-treesit)

;;; tip-latex-parse-treesit.el ends here
