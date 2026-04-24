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

(defcustom tip-latex-verbatim-environments
  '("verbatim" "Verbatim" "verbatim*"
    "lstlisting" "minted" "alltt"
    "comment" "BVerbatim" "LVerbatim")
  "Environments whose contents are not scanned for math fragments."
  :type '(repeat string)
  :group 'tip-latex)

(defcustom tip-latex-math-environments
  '("equation" "equation*" "align" "align*"
    "gather" "gather*" "multline" "multline*"
    "eqnarray" "eqnarray*" "displaymath" "math"
    "flalign" "flalign*" "alignat" "alignat*")
  "LaTeX environments treated as display math fragments."
  :type '(repeat string)
  :group 'tip-latex)

;;; * regex construction

(defun tip-latex--math-env-group-re ()
  "Regex group matching any environment name in `tip-latex-math-environments'."
  (regexp-opt tip-latex-math-environments t))

(defun tip-latex--verb-env-group-re ()
  "Regex group matching any environment name in `tip-latex-verbatim-environments'."
  (regexp-opt tip-latex-verbatim-environments t))

(defun tip-latex--math-begin-re ()
  "Regex matching the *opening* of any math fragment.
Groups:
  1  \\[  (display)
  2  \\(  (inline)
  3  $$   (display)
  4  single $  (inline)  — caller must post-filter escapes
  5  \\begin{ENV}  (display, named environment)
  6  →    the ENV name (inside group 5)

Note: group 4 matches ANY `$' (no preceding-char constraint), because
a lookbehind would require scanning before point and breaks
`re-search-forward' when the caller does `goto-char' directly at an
opening `$'.  The collector filters escapes (`\\$') and `$$' pairs in
post-processing."
  (concat
   "\\(\\\\\\[\\)"                                     ; 1 \[
   "\\|\\(\\\\(\\)"                                    ; 2 \(
   "\\|\\(\\$\\$\\)"                                   ; 3 $$ (before single-$ so prefers)
   "\\|\\(\\$\\)"                                      ; 4 single $
   "\\|\\(\\\\begin{" (tip-latex--math-env-group-re) "}\\)"))
                                                      ; 5 whole \begin{…}, 6 name

;;; * verbatim pre-pass

(defun tip-latex--verbatim-ranges (beg end)
  "Return list of (VBEG . VEND) ranges covering verbatim-like environments
between BEG and END."
  (save-excursion
    (goto-char beg)
    (let ((opener (concat "\\\\begin{" (tip-latex--verb-env-group-re) "}"))
          result)
      (while (re-search-forward opener end t)
        (let ((vbeg (match-beginning 0))
              (name (match-string-no-properties 1))
              (after (match-end 0)))
          (if (re-search-forward
               (concat "\\\\end{" (regexp-quote name) "}") end t)
              (push (cons vbeg (match-end 0)) result)
            ;; Unmatched \begin — skip its opener so we don't loop.
            (goto-char after))))
      (nreverse result))))

(defun tip-latex--in-ranges-p (pos ranges)
  "Return non-nil if POS is inside any (BEG . END) in RANGES."
  (cl-some (lambda (r) (and (>= pos (car r)) (< pos (cdr r)))) ranges))

;;; * finding fragment ends

(defun tip-latex--scan-for-closer (from check-fn)
  "Walk forward from FROM, honoring `\\'-escapes, `%'-comments, and
`{...}' brace nesting.  At each position where brace depth is zero and
we're not inside an escape/comment, call CHECK-FN with point at the
candidate.  If CHECK-FN returns a position, that is the result; else
scanning continues.  Returns nil if end-of-buffer is reached."
  (save-excursion
    (goto-char from)
    (let ((depth 0) found)
      (while (and (not found) (< (point) (point-max)))
        ;; At brace depth 0, give CHECK-FN first crack — so closers like
        ;; `\)' or `\]' aren't swallowed by the escape branch below.
        (let ((r (and (zerop depth) (funcall check-fn))))
          (if r
              (setq found r)
            (let ((c (char-after)))
              (cond
               ((eq c ?\\)
                (forward-char (if (< (1+ (point)) (point-max)) 2 1)))
               ((eq c ?%)
                (end-of-line)
                (unless (eobp) (forward-char)))
               ((eq c ?{)
                (cl-incf depth) (forward-char))
               ((eq c ?})
                (cl-decf depth) (forward-char))
               (t (forward-char)))))))
      found)))

(defun tip-latex--find-close-dollar (start double-p)
  "Find the closing `$' (or `$$' when DOUBLE-P) for a fragment at START.
Returns the position AFTER the closing delimiter, or nil."
  (tip-latex--scan-for-closer
   (+ start (if double-p 2 1))
   (lambda ()
     (when (eq (char-after) ?$)
       (let ((p (point)))
         (cond
          ((and double-p (eq (char-after (1+ p)) ?$)) (+ p 2))
          ((and (not double-p) (not (eq (char-after (1+ p)) ?$))) (1+ p))))))))

(defun tip-latex--find-close (opener-kind start)
  "Find the end of a fragment starting at START with given OPENER-KIND.
OPENER-KIND is one of the symbols `bracket' (\\[), `paren' (\\(),
`dollar2' ($$), `dollar1' (single $), or `env:NAME' (cons cell).
Returns end position (after the closer) or nil if unterminated.
Honors `\\'-escapes, `%'-comments, and skips inside `{...}' groups."
  (cond
   ((eq opener-kind 'bracket)
    (tip-latex--scan-for-closer
     (+ start 2)
     (lambda ()
       (when (and (eq (char-after) ?\\) (eq (char-after (1+ (point))) ?\]))
         (+ (point) 2)))))
   ((eq opener-kind 'paren)
    (tip-latex--scan-for-closer
     (+ start 2)
     (lambda ()
       (when (and (eq (char-after) ?\\) (eq (char-after (1+ (point))) ?\)))
         (+ (point) 2)))))
   ((eq opener-kind 'dollar2)
    (tip-latex--find-close-dollar start t))
   ((eq opener-kind 'dollar1)
    (tip-latex--find-close-dollar start nil))
   ((and (consp opener-kind) (eq (car opener-kind) 'env))
    (let ((end-re (concat "\\\\end{" (regexp-quote (cdr opener-kind)) "}")))
      (tip-latex--scan-for-closer
       (save-excursion (goto-char start)
                       (if (re-search-forward "\\\\begin{[^}]+}" nil t)
                           (match-end 0)
                         (point-max)))
       (lambda ()
         (when (looking-at end-re)
           (match-end 0))))))))

(defun tip-latex--opener-kind-at-match ()
  "Classify the current match (produced by `tip-latex--math-begin-re')
into an opener-kind symbol.  Returns nil if the single-$ match is not
really a math opener (e.g. \\$ escape)."
  (cond
   ((match-beginning 1) 'bracket)
   ((match-beginning 2) 'paren)
   ((match-beginning 3) 'dollar2)
   ((match-beginning 4) 'dollar1)
   ((match-beginning 5) (cons 'env (match-string-no-properties 6)))))

(defun tip-latex--opener-start ()
  "Return the start position of the fragment opener in the current match."
  (or (match-beginning 1)
      (match-beginning 2)
      (match-beginning 3)
      (match-beginning 4)
      (match-beginning 5)))

;;; * blank-content guard

(defun tip-latex--fragment-blank-p (kind start fend)
  "Return non-nil if the fragment at START..FEND of the given KIND has
only whitespace between its delimiters.  Used to skip empty math like
`$ $', `\\[ \\]', `\\(  \\)', `\\begin{equation}  \\end{equation}'."
  (let ((inner-beg
         (cond
          ((eq kind 'dollar1) (1+ start))
          ((eq kind 'dollar2) (+ start 2))
          ((memq kind '(bracket paren)) (+ start 2))
          ((and (consp kind) (eq (car kind) 'env))
           (+ start 1 (length "\\begin{") (length (cdr kind)) 1))
          (t start)))
        (inner-end
         (cond
          ((eq kind 'dollar1) (1- fend))
          ((eq kind 'dollar2) (- fend 2))
          ((memq kind '(bracket paren)) (- fend 2))
          ((and (consp kind) (eq (car kind) 'env))
           (- fend 1 (length "\\end{") (length (cdr kind)) 1))
          (t fend))))
    (and (<= inner-beg inner-end)
         (string-blank-p (buffer-substring-no-properties inner-beg inner-end)))))

;;; * outermost filter

(defun tip-latex--outermost (ranges)
  "Drop any range in RANGES contained in another.  RANGES is a list of (BEG . END)."
  (let (outer)
    (dolist (r ranges)
      (unless (cl-some (lambda (o)
                         (and (not (equal o r))
                              (<= (car o) (car r))
                              (>= (cdr o) (cdr r))))
                       ranges)
        (push r outer)))
    (nreverse outer)))

;;; * fragment collection

(defun tip-latex-collect-fragments (beg end &optional avoid-pos)
  "Collect math fragments intersecting BEG..END.
Returns a list of alists with \"start\"/\"end\" byte offsets, matching
`tip-collect-fragments's contract.

Always scans from `point-min' (widened) so the detector starts in a
known text-mode state, then filters to fragments that overlap
BEG..END.  This avoids a subtle bug where scanning from BEG lands
in the middle of an existing `$...$' fragment: the first `$' seen
is the closing one, which the detector then treats as an opener
and fuses with a subsequent fragment.  Correct-always > cheap-wrong.

Multi-file projects are supported: fragments in a child file are
detected locally; the server walks the project graph to assemble
the compile-time preamble from `tip-project-root-path'."
  (let ((scan-beg (point-min))
        (scan-end (point-max))
        (verbatim (tip-latex--verbatim-ranges (point-min) (point-max)))
        (re (tip-latex--math-begin-re))
        ranges)
    (save-excursion
      (goto-char scan-beg)
      (while (re-search-forward re scan-end t)
        (let* ((kind (tip-latex--opener-kind-at-match))
               (start (tip-latex--opener-start)))
          ;; Skip `\$' (escaped dollar): a single-$ match whose preceding
          ;; char is a backslash isn't a math opener.
          (when (and (eq kind 'dollar1) start
                     (> start (point-min))
                     (eq (char-before start) ?\\))
            (setq kind nil))
          ;; `$' immediately followed by another `$' is `$$' — the regex's
          ;; $$ alternative comes first so we only hit this when there's
          ;; no match at the first `$' position (e.g. scanning started
          ;; inside `$$…$$' past the first `$').
          (when (and (eq kind 'dollar1) start
                     (< (1+ start) (point-max))
                     (eq (char-after (1+ start)) ?$))
            (setq kind 'dollar2))
          (when (and kind start
                     ;; syntax-ppss with POS moves point — save around it.
                     (save-excursion (not (nth 4 (syntax-ppss start))))
                     (not (tip-latex--in-ranges-p start verbatim)))
            (let ((fend (tip-latex--find-close kind start)))
              (when fend
                (let ((blank (tip-latex--fragment-blank-p kind start fend))
                      (within-avoid (and avoid-pos
                                         (>= avoid-pos start)
                                         (<= avoid-pos fend))))
                  (unless (or blank within-avoid)
                    (push (cons start fend) ranges))
                  ;; Advance past the close (and clamp to scan-end so the
                  ;; next re-search-forward doesn't get an out-of-range
                  ;; bound).
                  (if (>= fend scan-end)
                      (goto-char scan-end)
                    (goto-char fend)))))))))
    (let* ((outer (tip-latex--outermost (nreverse ranges)))
           ;; Filter to fragments that intersect the caller's [beg, end].
           (in-range (seq-filter
                      (lambda (r)
                        (and (< (car r) end) (> (cdr r) beg)))
                      outer)))
      (mapcar (lambda (pair)
                `(("start" . ,(1- (position-bytes (car pair))))
                  ("end"   . ,(1- (position-bytes (cdr pair))))))
              in-range))))

;;; * bounds at point

(defun tip-latex-bounds-at-point (pos)
  "Return (BEG . END) of the math fragment at POS, or nil.
Half-open: valid only when BEG <= POS < END.

Multi-file projects are supported by the server-side graph walk."
  (let* ((scan-beg (max (point-min) (- pos 4096)))
         (scan-end (min (point-max) (+ pos 4096)))
         (frags (tip-latex-collect-fragments scan-beg scan-end)))
    (cl-some
     (lambda (frag)
       (let ((b (byte-to-position (1+ (alist-get "start" frag nil nil #'equal))))
             (e (byte-to-position (1+ (alist-get "end"   frag nil nil #'equal)))))
         (when (and (<= b pos) (< pos e))
           (cons b e))))
     frags)))

;;; * multi-file detection

(defvar-local tip-latex--include-warned nil
  "t once we've warned about \\input/\\include/\\subimport in this buffer.")

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
  "Invalidate the include-scan cache when the buffer changes."
  (setq tip-latex--has-includes 'unknown))

(add-hook 'after-change-functions #'tip-latex--on-change)

(defun tip-latex--refuse-if-includes ()
  "If the buffer has \\input/\\include, warn once and return t.
Callers that refuse to produce previews use the return value to short-circuit."
  (when (tip-latex--buffer-has-includes-p)
    (unless tip-latex--include-warned
      (setq tip-latex--include-warned t)
      (message "tip-latex: buffer contains \\input/\\include/\\subimport — \
multi-file support is v2; previews disabled in this buffer."))
    t))

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

;;; * backend registration

(tip-register-backend
 (make-tip-backend
  :name 'latex
  :major-modes '(latex-mode LaTeX-mode)
  :collect-fragments-fn #'tip-latex-collect-fragments
  :bounds-at-point-fn #'tip-latex-bounds-at-point
  :build-preamble-fn #'tip-latex-build-preamble
  :classify-fragment-fn #'tip-latex-classify-fragment
  :server-executable "tip-server"))

(provide 'tip-latex)

;;; tip-latex.el ends here
