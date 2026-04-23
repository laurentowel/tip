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
  4  single $  (inline) — only when not escaped and not doubled
  5  \\begin{ENV}  (display, named environment)
  6  →    the ENV name (inside group 5)"
  (concat
   "\\(\\\\\\[\\)"                                     ; 1 \[
   "\\|\\(\\\\(\\)"                                    ; 2 \(
   "\\|\\(\\$\\$\\)"                                   ; 3 $$
   "\\|\\(?:\\(?:^\\|[^\\\\$]\\)\\(\\$\\)\\)"          ; 4 single $
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

(defun tip-latex--find-close (opener-kind start)
  "Find the end of a fragment starting at START with given OPENER-KIND.
OPENER-KIND is one of the symbols `bracket' (\\[), `paren' (\\(),
`dollar2' ($$), `dollar1' (single $), or `env:NAME' (cons cell).
Returns end position (after the closer) or nil if unterminated."
  (save-excursion
    (cond
     ((eq opener-kind 'bracket)
      (goto-char start)
      (when (search-forward "\\]" nil t)
        (point)))
     ((eq opener-kind 'paren)
      (goto-char start)
      (when (search-forward "\\)" nil t)
        (point)))
     ((eq opener-kind 'dollar2)
      (goto-char (+ start 2))
      (when (search-forward "$$" nil t)
        (point)))
     ((eq opener-kind 'dollar1)
      (goto-char (1+ start))
      (let (found)
        (while (and (not found)
                    (re-search-forward "\\$" nil t))
          ;; Accept only non-escaped, not doubled.
          (let ((p (match-beginning 0)))
            (when (and (not (eq (char-before p) ?\\))
                       (not (eq (char-after (1+ p)) ?$))
                       (not (eq (char-before p) ?$)))
              (setq found (match-end 0)))))
        found))
     ((and (consp opener-kind) (eq (car opener-kind) 'env))
      (goto-char start)
      (when (re-search-forward
             (concat "\\\\end{" (regexp-quote (cdr opener-kind)) "}")
             nil t)
        (match-end 0))))))

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
  "Collect math fragments in BEG..END.
Returns a list of alists with \"start\"/\"end\" byte offsets, matching
`tip-collect-fragments's contract."
  (let ((verbatim (tip-latex--verbatim-ranges beg end))
        (re (tip-latex--math-begin-re))
        ranges)
    (save-excursion
      (goto-char beg)
      (while (re-search-forward re end t)
        (let* ((kind (tip-latex--opener-kind-at-match))
               (start (tip-latex--opener-start)))
          ;; Emacs regex uses leftmost match across alternatives; the single-$
          ;; branch includes the preceding char so it matches one position
          ;; earlier than the $$ branch, beating $$ on a tie.  Reclassify.
          (when (and (eq kind 'dollar1) start
                     (< (1+ start) (point-max))
                     (eq (char-after (1+ start)) ?$))
            (setq kind 'dollar2))
          (when (and kind start
                     ;; syntax-ppss with POS moves point — save around it.
                     (save-excursion (not (nth 4 (syntax-ppss start))))
                     (not (tip-latex--in-ranges-p start verbatim)))
            (let ((fend (tip-latex--find-close kind start)))
              (when (and fend
                         (or (null avoid-pos)
                             (not (and (>= avoid-pos start)
                                       (<= avoid-pos fend)))))
                (push (cons start fend) ranges)
                ;; Resume past the close so we don't match inside.
                (goto-char fend)))))))
    (let ((outer (tip-latex--outermost (nreverse ranges))))
      (mapcar (lambda (pair)
                `(("start" . ,(1- (position-bytes (car pair))))
                  ("end"   . ,(1- (position-bytes (cdr pair))))))
              outer))))

;;; * bounds at point

(defun tip-latex-bounds-at-point (pos)
  "Return (BEG . END) of the math fragment at POS, or nil.
Half-open: valid only when BEG <= POS < END."
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

;;; * preamble extraction

(defvar-local tip-latex--include-warned nil
  "t once we've warned about \\input/\\include in this buffer's preamble.")

(defun tip-latex--preamble-end ()
  "Return position of `\\begin{document}' or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "\\\\begin{document}" nil t)
      (match-beginning 0))))

(defun tip-latex--preamble-contains-includes (str)
  "Return non-nil if STR looks like it contains \\input/\\include/\\subimport."
  (string-match-p "\\\\\\(input\\|include\\|subimport\\)\\b" str))

(defun tip-latex-build-preamble ()
  "Return the document preamble as a string.
If the buffer has no `\\begin{document}', return
`tip-latex-default-preamble'.  If the preamble contains `\\input',
`\\include', or `\\subimport', emit a one-time warning — multi-file
support is v2+."
  (let* ((pend (tip-latex--preamble-end))
         (preamble (if pend
                       (buffer-substring-no-properties (point-min) pend)
                     tip-latex-default-preamble)))
    (when (and pend
               (not tip-latex--include-warned)
               (tip-latex--preamble-contains-includes preamble))
      (setq tip-latex--include-warned t)
      (message "tip-latex: preamble contains \\input/\\include; multi-file \
support is v2 — previews may fail until then."))
    preamble))

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
  :server-executable "tip-server-latex"))

(provide 'tip-latex)

;;; tip-latex.el ends here
