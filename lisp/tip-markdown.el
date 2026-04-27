;;; tip-markdown.el --- KaTeX backend for markdown buffers -*- lexical-binding: t; -*-

;;; Commentary:

;; Registers a `katex' backend for `markdown-ts-mode' / `markdown-mode'.
;; Detects math fragments written with the usual markdown delimiters
;; — `$...$', `$$...$$', `\(...\)', `\[...\]' — while skipping fenced
;; code blocks, inline code spans, and HTML blocks.  No preamble, no
;; project tracking: KaTeX fragments are standalone (users put any
;; `\newcommand' calls inside the fragment itself, matching Kodama's
;; convention — see CLAUDE.md's math-backend notes).
;;
;; Fragment detection prefers tree-sitter when a markdown parser is
;; installed (cheap, accurate over code blocks); falls back to a
;; lightweight regex scan that queries `markdown-code-at-point-p' when
;; available.

;;; Code:

(require 'tip-backend)
(require 'treesit nil t)

(declare-function treesit-available-p        "treesit")
(declare-function treesit-ready-p            "treesit")
(declare-function treesit-parser-list        "treesit")
(declare-function treesit-parser-create      "treesit")
(declare-function treesit-parser-root-node   "treesit")
(declare-function treesit-query-capture      "treesit")
(declare-function treesit-node-start         "treesit")
(declare-function treesit-node-end           "treesit")

(defgroup tip-markdown nil
  "KaTeX-backed math rendering for markdown."
  :group 'tip)

(defcustom tip-markdown-delimiters
  '(("$$" . "$$")
    ("$"  . "$")
    ("\\(" . "\\)")
    ("\\[" . "\\]"))
  "Ordered list of `(OPEN . CLOSE)' math-delimiter pairs.
Order matters: longer openers come first so `$$' is matched before `$'."
  :type '(repeat (cons string string))
  :group 'tip-markdown)

(defvar-local tip-markdown--skip-cache nil
  "Cons of (TICK . RANGES).  RANGES is a sorted list of skip ranges
matched at buffer modification tick TICK.  Recomputed on miss.")

(defvar-local tip-markdown--parser nil
  "Cached treesit parser for the current buffer, nil if unavailable.
Kept buffer-local so parser creation happens at most once per buffer —
`treesit-parser-create' is expensive.  Set to the symbol `unavailable'
when the grammar is not installed, so we don't probe again.")

(defun tip-markdown--get-parser ()
  "Return a live markdown treesit parser for this buffer, or nil.
Result is cached in `tip-markdown--parser'.  Never triggers grammar
installation — `treesit-ready-p' with the NOERROR arg."
  (cond
   ((eq tip-markdown--parser 'unavailable) nil)
   (tip-markdown--parser tip-markdown--parser)
   ((not (and (fboundp 'treesit-available-p) (treesit-available-p)))
    (setq tip-markdown--parser 'unavailable) nil)
   ;; treesit-ready-p (defined in treesit.el) may not be loaded in
   ;; minimal environments — guard with fboundp.  The QUIET arg keeps
   ;; us from triggering the grammar-install prompt during batch runs.
   ((not (and (fboundp 'treesit-ready-p)
              (treesit-ready-p 'markdown t)))
    (setq tip-markdown--parser 'unavailable) nil)
   (t
    (setq tip-markdown--parser
          (or (car (treesit-parser-list (current-buffer) 'markdown))
              (treesit-parser-create 'markdown))))))

(defun tip-markdown--skip-ranges ()
  "Return a list of `(BEG . END)' ranges that must NOT contain math.
Cached per buffer, keyed on `buffer-chars-modified-tick' — recomputed
only when the buffer changes.  Populated from tree-sitter nodes when a
markdown parser is available (and the grammar installed); falls back
to a regex scan otherwise."
  (let ((tick (buffer-chars-modified-tick)))
    (if (and tip-markdown--skip-cache
             (eq (car tip-markdown--skip-cache) tick))
        (cdr tip-markdown--skip-cache)
      (let* ((block-ranges (if (tip-markdown--get-parser)
                               (tip-markdown--skip-ranges-treesit)
                             (tip-markdown--skip-ranges-regex)))
             (inline-ranges (tip-markdown--skip-ranges-regex-inline))
             (ranges (sort (nconc block-ranges inline-ranges)
                           (lambda (a b) (< (car a) (car b))))))
        (setq tip-markdown--skip-cache (cons tick ranges))
        ranges))))

(defvar tip-markdown--skip-node-types
  '("fenced_code_block"
    "indented_code_block"
    "html_block")
  "Block-level tree-sitter node types whose byte ranges must NOT contain math.
The block grammar doesn't expose inline nodes (`code_span', `inline_html')
— those live in the `markdown-inline' grammar.  To catch inline code
spans and HTML spans we layer `tip-markdown--skip-ranges-regex-inline'
on top of the tree-sitter block ranges; see `tip-markdown--skip-ranges'.")

(defun tip-markdown--skip-ranges-treesit ()
  "Collect block-level skip-ranges via the markdown tree-sitter parser.
Assumes `tip-markdown--get-parser' already returned non-nil.  Unknown
node types (older grammar versions) are tolerated silently."
  (let* ((parser tip-markdown--parser)
         (root (treesit-parser-root-node parser))
         ranges)
    (dolist (type tip-markdown--skip-node-types)
      (condition-case _
          (dolist (cell (treesit-query-capture root `((,(intern type)) @n)))
            (let ((n (cdr cell)))
              (push (cons (treesit-node-start n)
                          (treesit-node-end n))
                    ranges)))
        (treesit-query-error nil)))
    ranges))

(defun tip-markdown--skip-ranges-regex-inline ()
  "Collect inline skip-ranges (single-backtick `code spans`) via regex.
Used regardless of the block-level parser: the block grammar doesn't
see inline nodes."
  (save-excursion
    (goto-char (point-min))
    (let (ranges)
      (while (re-search-forward "`[^`\n]+`" nil t)
        (push (cons (match-beginning 0) (match-end 0)) ranges))
      ranges)))

(defun tip-markdown--skip-ranges-regex ()
  "Collect skip-ranges via a regex scan (fallback).
Covers triple-backtick fences and single-backtick code spans."
  (save-excursion
    (goto-char (point-min))
    (let (ranges)
      (while (re-search-forward "```" nil t)
        (let ((beg (match-beginning 0)))
          (when (re-search-forward "```" nil t)
            (push (cons beg (match-end 0)) ranges))))
      (goto-char (point-min))
      (while (re-search-forward "`[^`\n]+`" nil t)
        (push (cons (match-beginning 0) (match-end 0)) ranges))
      (sort ranges (lambda (a b) (< (car a) (car b)))))))

(defun tip-markdown--in-skip-p (pos ranges)
  "Return non-nil if POS falls inside any range in RANGES."
  (seq-some (lambda (r) (and (<= (car r) pos) (< pos (cdr r)))) ranges))

(defun tip-markdown--next-open (pos skip)
  "Scan forward from POS for the next opener in `tip-markdown-delimiters'.
Skips matches inside SKIP ranges.  Returns `(BEG OPEN CLOSE)' or nil.
Ties resolved by `tip-markdown-delimiters' order — `$$' matches before
`$' at the same position."
  (let ((best nil))
    (save-excursion
      (dolist (pair tip-markdown-delimiters)
        (let* ((open (car pair))
               (close (cdr pair))
               (limit (if best (car best) nil))
               (found (tip-markdown--find-outside-skip pos open skip limit)))
          (when (and found (or (null best) (< found (car best))))
            (setq best (list found open close))))))
    best))

(defun tip-markdown--find-outside-skip (from needle skip limit)
  "Return the first position >= FROM where NEEDLE starts, outside SKIP.
Returns nil if not found, or >= LIMIT (when LIMIT is non-nil)."
  (save-excursion
    (goto-char from)
    (let ((result nil) (keep t))
      (while (and keep
                  (let ((case-fold-search nil))
                    (search-forward needle nil t))
                  (or (null limit) (< (match-beginning 0) limit)))
        (let ((mb (match-beginning 0)))
          (if (tip-markdown--in-skip-p mb skip)
              ;; inside a skip range — keep searching
              nil
            (setq result mb
                  keep nil))))
      result)))

(defun tip-markdown--fragment-at (open-beg open close skip limit)
  "Given a fragment opener at OPEN-BEG with OPEN/CLOSE strings, find the end.
CLOSE is searched starting immediately after the opener.  Returns
`(BEG . END)' covering the fragment including delimiters, or nil if no
matching closer exists within the buffer range [0, LIMIT]."
  (let* ((scan-from (+ open-beg (length open)))
         (close-beg (tip-markdown--find-outside-skip scan-from close skip limit)))
    (when close-beg
      (cons open-beg (+ close-beg (length close))))))

(defun tip-markdown-collect-fragments (beg end &optional _avoid-pos)
  "Return math fragments between BEG and END as a list of alists.
Keys `start' and `end' are byte offsets, matching the contract in
`tip-backend-collect-fragments-fn'.  Guaranteed to make progress each
iteration: on an unterminated opener we advance past its first byte,
never looping on the same position."
  (let ((skip (tip-markdown--skip-ranges))
        (pos beg)
        fragments)
    (while (and pos (< pos end))
      (let ((hit (tip-markdown--next-open pos skip)))
        (cond
         ((null hit)
          (setq pos nil))
         (t
          (let* ((open-beg (nth 0 hit))
                 (open (nth 1 hit))
                 (close (nth 2 hit))
                 (range (tip-markdown--fragment-at open-beg open close skip end)))
            (cond
             ((and range (<= (cdr range) end))
              (push `(("start" . ,(1- (position-bytes (car range))))
                      ("end"   . ,(1- (position-bytes (cdr range)))))
                    fragments)
              (setq pos (cdr range)))
             (t
              ;; No closer — skip past the opener's first byte so we
              ;; always make progress; unterminated math is dropped.
              (setq pos (1+ open-beg)))))))))
    (nreverse fragments)))

(defun tip-markdown-bounds-at-point (pos)
  "Return `(BEG . END)' of the math fragment at POS, or nil.
Half-open convention: POS must satisfy BEG <= POS < END."
  (let* ((scan-beg (max (point-min) (- pos 2000)))
         (scan-end (min (point-max) (+ pos 2000)))
         (frags (save-restriction
                  (widen)
                  (tip-markdown-collect-fragments scan-beg scan-end))))
    (seq-some (lambda (f)
                (let ((b (byte-to-position
                          (1+ (alist-get "start" f nil nil #'equal))))
                      (e (byte-to-position
                          (1+ (alist-get "end" f nil nil #'equal)))))
                  (and b e (<= b pos) (< pos e) (cons b e))))
              frags)))

(defun tip-markdown-build-preamble ()
  "KaTeX has no preamble.  Return empty string."
  "")

(defun tip-markdown-classify-fragment (text)
  "Block for `$$…$$' / `\\[…\\]', inline otherwise."
  (cond
   ((string-match-p "\\`\\$\\$" text) 'display-multi)
   ((string-match-p "\\`\\\\\\[" text) 'display-multi)
   (t 'inline)))

(tip-register-backend
 (make-tip-backend
  :name 'katex
  :major-modes '(markdown-ts-mode markdown-mode gfm-mode)
  :collect-fragments-fn #'tip-markdown-collect-fragments
  :bounds-at-point-fn #'tip-markdown-bounds-at-point
  :build-preamble-fn #'tip-markdown-build-preamble
  :classify-fragment-fn #'tip-markdown-classify-fragment
  :server-executable "tip-server"))

(provide 'tip-markdown)

;;; tip-markdown.el ends here
