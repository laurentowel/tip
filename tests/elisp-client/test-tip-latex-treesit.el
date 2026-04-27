;;; test-tip-latex-treesit.el --- ERT tests for treesit LaTeX parser -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run with the latex grammar on `treesit-extra-load-path':
;;   emacs --batch -L . \
;;         --eval '(add-to-list (quote treesit-extra-load-path) "/tmp/")' \
;;         -l test-tip-latex-treesit.el
;;
;; All tests skip silently when the grammar isn't available.

;;; Code:

(require 'ert)
(add-to-list 'load-path
             (expand-file-name "../.."
                               (file-name-directory
                                (or load-file-name buffer-file-name))))
(require 'tip-latex)
(require 'tip-latex-parse-treesit)

(defmacro tlt-with (text &rest body)
  "Insert TEXT into a temp latex buffer and run BODY with treesit parser ready."
  (declare (indent 1))
  `(progn
     (skip-unless (and (fboundp 'treesit-ready-p)
                       (treesit-ready-p 'latex t)))
     (with-temp-buffer
       (insert ,text)
       (latex-mode)
       (let ((tip-latex--treesit-parser nil))   ; force re-create
         ,@body))))

(defun tlt-frags ()
  "Return collector output as `(START END TEXT)' triples (1-based positions)."
  (mapcar (lambda (f)
            (let ((s (1+ (alist-get "start" f nil nil #'equal)))
                  (e (1+ (alist-get "end" f nil nil #'equal))))
              (list (byte-to-position s)
                    (byte-to-position e)
                    (buffer-substring-no-properties
                     (byte-to-position s) (byte-to-position e)))))
          (tip-latex-collect-fragments (point-min) (point-max))))

(defun tlt-texts ()
  (mapcar #'caddr (tlt-frags)))

;;; --- delimiters ---------------------------------------------------------

(ert-deftest tlt/dollar-inline ()
  (tlt-with "before $a + b$ after"
    (should (equal (tlt-texts) '("$a + b$")))))

(ert-deftest tlt/paren-inline ()
  (tlt-with "before \\( a + b \\) after"
    (should (equal (tlt-texts) '("\\( a + b \\)")))))

(ert-deftest tlt/bracket-display ()
  (tlt-with "before\n\\[ x^2 \\]\nafter"
    (should (equal (tlt-texts) '("\\[ x^2 \\]")))))

(ert-deftest tlt/equation-env ()
  (tlt-with "\\begin{equation} y = mx + b \\end{equation}\n"
    (should (equal (tlt-texts) '("\\begin{equation} y = mx + b \\end{equation}")))))

(ert-deftest tlt/align-env ()
  (tlt-with "\\begin{align*}\n  a &= b \\\\\n  c &= d\n\\end{align*}\n"
    (should (= 1 (length (tlt-frags))))
    (should (string-match-p "begin{align\\*}" (car (tlt-texts))))))

;;; --- multiple fragments -------------------------------------------------

(ert-deftest tlt/two-inline ()
  (tlt-with "$a$ and $b$"
    (should (equal (tlt-texts) '("$a$" "$b$")))))

(ert-deftest tlt/inline-then-display ()
  (tlt-with "Try $a$ then\n\\[ b^2 \\]\ndone"
    (should (equal (tlt-texts) '("$a$" "\\[ b^2 \\]")))))

(ert-deftest tlt/all-three-kinds ()
  (tlt-with "$x$ \\( y \\) \\[ z \\] \\begin{equation} w \\end{equation}"
    (should (= 4 (length (tlt-frags))))))

;;; --- adjacency ----------------------------------------------------------

(ert-deftest tlt/adjacent-no-separator-grammar-limitation ()
  ;; Documented limitation: tree-sitter-latex tokenizes the middle `$$'
  ;; in `$a$$b$' as a single token (intended for display math) and
  ;; produces ERROR, leaving zero `inline_formula' nodes.  Real users
  ;; write `$a$ $b$' with whitespace; the regex parser handles the
  ;; degenerate case but we accept this gap as the cost of stable
  ;; tree-sitter results elsewhere.
  (tlt-with "$a$$b$"
    (should (null (tlt-texts)))))

(ert-deftest tlt/adjacent-with-space ()
  (tlt-with "$a$ $b$"
    (should (equal (tlt-texts) '("$a$" "$b$")))))

;;; --- verbatim / verb ----------------------------------------------------

(ert-deftest tlt/skip-verbatim-env ()
  (tlt-with "Real $a$\n\\begin{verbatim}\n$ignored$\n\\end{verbatim}\nreal $b$"
    ;; Verbatim env content is treesit `comment'; no formula leaks.
    (should (equal (tlt-texts) '("$a$" "$b$")))))

(ert-deftest tlt/skip-verb-inline ()
  (tlt-with "real $a$ and \\verb|$ignored$| and real $b$"
    ;; tip-latex--treesit-inside-verb-p drops the false-positive inside.
    (let ((texts (tlt-texts)))
      (should (member "$a$" texts))
      (should (member "$b$" texts))
      (should-not (member "$ignored$" texts)))))

;;; --- bounds-at-point ----------------------------------------------------

(ert-deftest tlt/bounds-inside-inline ()
  (tlt-with "pre $a + b$ post"
    ;; pre = chars 1-4, $ at 5, a at 6, + at 8, b at 10, $ at 11, then space.
    (should (equal (tip-latex-bounds-at-point 8) '(5 . 12)))
    (should (equal (tip-latex-bounds-at-point 5) '(5 . 12)))
    (should (equal (tip-latex-bounds-at-point 11) '(5 . 12)))))

(ert-deftest tlt/bounds-half-open-at-end ()
  (tlt-with "$a$"
    (should (equal (tip-latex-bounds-at-point 1) '(1 . 4)))
    (should (equal (tip-latex-bounds-at-point 3) '(1 . 4)))
    ;; Position 4 = right after closing $ → outside.
    (should-not (tip-latex-bounds-at-point 4))))

(ert-deftest tlt/bounds-outside-returns-nil ()
  (tlt-with "  $a$  "
    (should-not (tip-latex-bounds-at-point 1))
    (should-not (tip-latex-bounds-at-point 6))
    (should-not (tip-latex-bounds-at-point 7))))

(ert-deftest tlt/bounds-multiline-display ()
  (tlt-with "before\n\\[\n  x^2\n\\]\nafter"
    (let ((mid (with-temp-buffer
                 (insert "before\n\\[\n  x^2\n\\]\nafter")
                 (goto-char (point-min))
                 (search-forward "x^2")
                 (- (point) 1))))
      (let ((b (tip-latex-bounds-at-point mid)))
        (should b)
        (should (string-match-p "x\\^2"
                                (buffer-substring-no-properties
                                 (car b) (cdr b))))))))

(ert-deftest tlt/bounds-equation-env ()
  (tlt-with "\\begin{equation} a = b \\end{equation}"
    (let ((b (tip-latex-bounds-at-point 18)))   ; inside `a = b'
      (should b)
      (should (string-prefix-p "\\begin{equation}"
                               (buffer-substring-no-properties
                                (car b) (cdr b))))
      (should (string-suffix-p "\\end{equation}"
                               (buffer-substring-no-properties
                                (car b) (cdr b)))))))

(ert-deftest tlt/bounds-at-each-byte ()
  ;; Sweep every byte in a small buffer and confirm bounds-at-point is
  ;; consistent with collect-fragments.
  (tlt-with "x $ab$ y \\(c\\) z"
    (let ((frags (tlt-frags)))
      (cl-loop for p from 1 to (point-max) do
               (let ((b (tip-latex-bounds-at-point p))
                     (in (cl-some (lambda (f)
                                    (and (<= (nth 0 f) p) (< p (nth 1 f))
                                         (cons (nth 0 f) (nth 1 f))))
                                  frags)))
                 (should (equal b in)))))))

;;; --- avoid-pos ----------------------------------------------------------

(ert-deftest tlt/avoid-pos-drops-containing-fragment ()
  (tlt-with "$a$ $b$ $c$"
    ;; Without avoid-pos: 3 fragments.
    (should (= 3 (length (tip-latex-collect-fragments (point-min) (point-max)))))
    ;; With avoid-pos inside $b$ (positions 5-8): 2 fragments left.
    (let ((without-b (tip-latex-collect-fragments (point-min) (point-max) 6)))
      (should (= 2 (length without-b))))))

;;; --- pathological -------------------------------------------------------

(ert-deftest tlt/lots-of-dollars-terminates ()
  ;; 100 single dollars — must not hang, must produce SOME fragmentation
  ;; (treesit pairs them; our test only asserts termination).
  (let ((s (apply #'concat (make-list 100 "$ "))))
    (tlt-with s
      (should (listp (tlt-frags))))))

(ert-deftest tlt/empty-paren-fragment ()
  ;; `\(\)' is empty math; treesit still parses it as inline_formula.
  (tlt-with "before \\(\\) after"
    (let ((frags (tlt-frags)))
      (should (= 1 (length frags)))
      (should (equal "\\(\\)" (caddr (car frags)))))))

(ert-deftest tlt/no-math-no-frags ()
  (tlt-with "no math here, just words and \\textbf{commands}"
    (should (null (tlt-frags)))))

;;; --- preamble + scope ---------------------------------------------------

(ert-deftest tlt/skip-fragment-in-newcommand-body ()
  ;; `\newcommand{\foo}{\begin{equation}}' shouldn't pick up a phantom
  ;; equation start.  treesit parses this differently than the regex —
  ;; it sees a `generic_command' containing a `curly_group' with the
  ;; tokens, NOT a `math_environment'.  Verify no fragment leaks.
  (tlt-with "\\newcommand{\\beq}{\\begin{equation}}\nReal: $a$\n"
    (should (equal (tlt-texts) '("$a$")))))

(ert-deftest tlt/skip-fragment-in-comment ()
  (tlt-with "\\documentclass{article}\n% $not-math$\n\\begin{document}\nReal: $a$\n\\end{document}"
    (should (equal (tlt-texts) '("$a$")))))

(let ((n-failed 0) (n-ran 0))
  (ert-run-tests-batch-and-exit))
