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
non-nil, is excluded — the fragment containing AVOID-POS is dropped
(the cursor-leave path uses this to not re-render the fragment the
user just exited)."
  (let* ((parser (tip-latex--treesit-parser))
         (frags nil))
    (when parser
      (let ((root (treesit-parser-root-node parser)))
        (dolist (type tip-latex--treesit-math-node-types)
          (condition-case _
              (dolist (cell (treesit-query-capture
                             root `((,(intern type)) @n)))
                (let* ((node (cdr cell))
                       (s (treesit-node-start node))
                       (e (treesit-node-end node)))
                  (when (and (< s end) (> e beg)
                             (not (and avoid-pos
                                       (<= s avoid-pos)
                                       (< avoid-pos e)))
                             (not (tip-latex--treesit-inside-verb-p s)))
                    (push (cons s e) frags))))
            (treesit-query-error nil)))))
    (mapcar (lambda (r)
              `(("start" . ,(1- (position-bytes (car r))))
                ("end"   . ,(1- (position-bytes (cdr r))))))
            (sort frags (lambda (a b) (< (car a) (car b)))))))

(defun tip-latex-treesit-bounds-at-point (pos)
  "Return `(BEG . END)' of the math fragment at POS via treesit.
Half-open: BEG ≤ POS < END.  Synchronous — no debounce, no stale
cache."
  (let* ((parser (tip-latex--treesit-parser))
         (best nil))
    (when parser
      (let ((root (treesit-parser-root-node parser)))
        (dolist (type tip-latex--treesit-math-node-types)
          (condition-case _
              (dolist (cell (treesit-query-capture
                             root `((,(intern type)) @n)))
                (let* ((node (cdr cell))
                       (s (treesit-node-start node))
                       (e (treesit-node-end node)))
                  (when (and (<= s pos) (< pos e)
                             (not (tip-latex--treesit-inside-verb-p s)))
                    ;; Smallest enclosing wins.
                    (when (or (null best)
                              (< (- e s) (- (cdr best) (car best))))
                      (setq best (cons s e))))))
            (treesit-query-error nil)))))
    best))

;;;###autoload
(defun tip-latex-install-treesit-grammar ()
  "Install the alex-pinkus/tree-sitter-latex grammar via `treesit'.
Same grammar texlab uses; widely tested.  Adds the URL to
`treesit-language-source-alist' if not present."
  (interactive)
  (unless (boundp 'treesit-language-source-alist)
    (user-error "treesit not available in this Emacs"))
  (unless (alist-get 'latex treesit-language-source-alist)
    (add-to-list 'treesit-language-source-alist
                 '(latex "https://github.com/latex-lsp/tree-sitter-latex")))
  (treesit-install-language-grammar 'latex))

(provide 'tip-latex-parse-treesit)

;;; tip-latex-parse-treesit.el ends here
