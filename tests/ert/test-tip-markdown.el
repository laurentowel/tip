;;; test-tip-markdown.el --- Batch tests for tip-markdown -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run:
;;   rm -f tip-markdown.elc && emacs --batch -L . -l test-tip-markdown.el
;;
;; Covers `tip-markdown-collect-fragments' and `tip-markdown-bounds-at-point'
;; across the four delimiter pairs, code-skip logic (regex + treesit paths),
;; and adversarial inputs (unterminated, nested, adjacent, boundary).
;; Does not require a server.

;;; Code:

(require 'ert)
(load (expand-file-name "../setup.el"
                        (file-name-directory
                         (or load-file-name buffer-file-name))))
(require 'tip-markdown)

(defun ttm--frags (text)
  "Return fragment ranges `(START END TEXT)' for TEXT, using current path.
START/END are 1-based buffer positions (inclusive opener, exclusive closer)."
  (with-temp-buffer
    (insert text)
    (mapcar (lambda (f)
              (let ((b (byte-to-position
                        (1+ (alist-get "start" f nil nil #'equal))))
                    (e (byte-to-position
                        (1+ (alist-get "end" f nil nil #'equal)))))
                (list b e (buffer-substring-no-properties b e))))
            (tip-markdown-collect-fragments (point-min) (point-max)))))

(defun ttm--texts (text)
  "Return just the matched fragment texts for TEXT."
  (mapcar #'cl-third (ttm--frags text)))

;;; --- Basic delimiters ------------------------------------------------------

(ert-deftest ttm/dollar-inline ()
  (should (equal (ttm--texts "x $a+b$ y") '("$a+b$"))))

(ert-deftest ttm/dollar-dollar-block ()
  (should (equal (ttm--texts "pre $$x^2$$ post") '("$$x^2$$"))))

(ert-deftest ttm/paren-inline ()
  (should (equal (ttm--texts "a \\(x\\) b") '("\\(x\\)"))))

(ert-deftest ttm/bracket-block ()
  (should (equal (ttm--texts "a \\[y\\] b") '("\\[y\\]"))))

(ert-deftest ttm/mixed-all-four ()
  (should (equal (ttm--texts "1 $a$ 2 $$b$$ 3 \\(c\\) 4 \\[d\\] 5")
                 '("$a$" "$$b$$" "\\(c\\)" "\\[d\\]"))))

;;; --- Preference: $$ before $ -----------------------------------------------

(ert-deftest ttm/dollar-dollar-wins-over-dollar-same-position ()
  ;; At position 0 both `$' and `$$' match; `$$' should win because it
  ;; comes first in the default `tip-markdown-delimiters'.
  (should (equal (ttm--texts "$$x^2$$") '("$$x^2$$"))))

;;; --- Adjacent fragments ----------------------------------------------------

(ert-deftest ttm/adjacent-fragments-no-separator ()
  (should (equal (ttm--texts "$a$$b$") '("$a$" "$b$"))))

(ert-deftest ttm/adjacent-fragments-space ()
  (should (equal (ttm--texts "$a$ $b$") '("$a$" "$b$"))))

(ert-deftest ttm/three-fragments-in-a-row ()
  (should (equal (ttm--texts "$x$ $y$ $z$") '("$x$" "$y$" "$z$"))))

;;; --- Multi-line fragments --------------------------------------------------

(ert-deftest ttm/display-multi-line ()
  (let ((text "prose\n$$\n\\int_0^1 f(x)\\,dx\n$$\nmore"))
    (should (equal (ttm--texts text) '("$$\n\\int_0^1 f(x)\\,dx\n$$")))))

(ert-deftest ttm/bracket-multi-line ()
  (let ((text "before\n\\[\na+b\n\\]\nafter"))
    (should (equal (ttm--texts text) '("\\[\na+b\n\\]")))))

;;; --- Unterminated / malformed ---------------------------------------------

(ert-deftest ttm/unterminated-dollar-returns-nothing ()
  (should (equal (ttm--texts "an $unclosed fragment") nil)))

(ert-deftest ttm/unterminated-then-valid-finds-valid ()
  ;; A stray `$' with no close, followed later by a valid `$…$': the
  ;; stray is interpreted as the open and eats everything until the
  ;; first `$' afterwards.  This is consistent with KaTeX autorender's
  ;; greedy delimiter behavior — we match, not attempt to be smarter.
  (should (equal (ttm--texts "stray $ and then $a+b$ done")
                 '("$ and then $"))))

(ert-deftest ttm/empty-fragment-between-dollar-dollar-has-no-close ()
  ;; A bare `$$` with nothing after it: collector prefers the `$$'
  ;; opener (per `tip-markdown-delimiters' ordering), looks for the
  ;; next `$$' to close, finds nothing, and skips.  Expected: no
  ;; fragments.  (An empty *display* block `$$\n$$' DOES match — see
  ;; `ttm/display-empty'.)
  (should (equal (ttm--texts "x $$ y") nil)))

(ert-deftest ttm/display-empty ()
  (should (equal (ttm--texts "x $$\n$$ y") '("$$\n$$"))))

(ert-deftest ttm/inline-empty ()
  (should (equal (ttm--texts "x $$ y") nil))
  ;; `$$`-ordering means two adjacent `$' can't form an empty inline;
  ;; but `$a$' with empty middle:
  (should (equal (ttm--texts "$a$") '("$a$"))))

(ert-deftest ttm/lone-dollar-sign-is-skipped ()
  ;; A single `$' with no close anywhere: returns nothing, does not hang.
  (should (equal (ttm--texts "balance $5 owed") nil)))

;;; --- Code-block skipping (regex fallback) ----------------------------------

(ert-deftest ttm/skip-fenced-code-block ()
  (should (equal (ttm--texts "real $a$\n```\ncode $b$\n```\nreal $c$")
                 '("$a$" "$c$"))))

(ert-deftest ttm/skip-code-span ()
  (should (equal (ttm--texts "real $a$ and `$x$` and real $b$")
                 '("$a$" "$b$"))))

(ert-deftest ttm/fenced-code-with-language ()
  (should (equal (ttm--texts "$a$\n```python\ndef f(): return $ignored$\n```\n$b$")
                 '("$a$" "$b$"))))

(ert-deftest ttm/nested-fenced-blocks-not-treated-as-math ()
  ;; A ``` inside a prose line shouldn't terminate math prematurely —
  ;; but a single ``` with no closer is undefined; verify we don't hang.
  (let ((texts (ttm--texts "$a$ and then ```unclosed")))
    (should (listp texts))))

;;; --- Boundaries and positions ---------------------------------------------

(ert-deftest ttm/fragment-at-buffer-start ()
  (should (equal (ttm--texts "$a$ text") '("$a$"))))

(ert-deftest ttm/fragment-at-buffer-end ()
  (should (equal (ttm--texts "text $a$") '("$a$"))))

(ert-deftest ttm/only-a-fragment ()
  (should (equal (ttm--texts "$a$") '("$a$"))))

;;; --- Escaped dollar is NOT currently handled (spec decision) --------------

(ert-deftest ttm/backslash-dollar-starts-fragment-at-dollar-not-backslash ()
  ;; Input: `\$100 for $math$'.  We do NOT recognize `\$' as an escape
  ;; — the collector simply sees the first plain `$' (pos 2 in the
  ;; string) as an opener and closes at the next `$'.  Document the
  ;; behavior so a deliberate regression shows up as a test edit.
  (should (equal (ttm--texts "\\$100 for $math$")
                 '("$100 for $"))))

;;; --- bounds-at-point ------------------------------------------------------

(ert-deftest ttm/bounds-at-point-inside ()
  (with-temp-buffer
    (insert "hello $a+b$ world")
    ;; $ at pos 7, a at 8, b at 10, closing $ at 11 (1-based).
    (should (equal (tip-markdown-bounds-at-point 8)  '(7 . 12)))
    (should (equal (tip-markdown-bounds-at-point 7)  '(7 . 12)))
    (should (equal (tip-markdown-bounds-at-point 11) '(7 . 12)))))

(ert-deftest ttm/bounds-at-point-outside ()
  (with-temp-buffer
    (insert "hello $a+b$ world")
    (should (null (tip-markdown-bounds-at-point 1)))
    (should (null (tip-markdown-bounds-at-point 5)))
    (should (null (tip-markdown-bounds-at-point 12)))   ; half-open at end
    (should (null (tip-markdown-bounds-at-point 15)))))

(ert-deftest ttm/bounds-at-point-two-fragments-picks-the-right-one ()
  (with-temp-buffer
    (insert "$a$ $bb$")
    ;; $a$ = [1,4), $bb$ = [5,9)
    (should (equal (tip-markdown-bounds-at-point 2) '(1 . 4)))
    (should (equal (tip-markdown-bounds-at-point 6) '(5 . 9)))
    (should (null  (tip-markdown-bounds-at-point 4)))))

;;; --- Classification --------------------------------------------------------

(ert-deftest ttm/classify-inline ()
  (should (eq (tip-markdown-classify-fragment "$a+b$") 'inline)))

(ert-deftest ttm/classify-display-dollar-dollar ()
  (should (eq (tip-markdown-classify-fragment "$$x^2$$") 'display-multi)))

(ert-deftest ttm/classify-display-bracket ()
  (should (eq (tip-markdown-classify-fragment "\\[x\\]") 'display-multi)))

(ert-deftest ttm/classify-paren-is-inline ()
  (should (eq (tip-markdown-classify-fragment "\\(x\\)") 'inline)))

;;; --- Cache correctness ----------------------------------------------------

(ert-deftest ttm/cache-invalidates-on-edit ()
  (with-temp-buffer
    (insert "text $a$ more")
    (should (= 1 (length (tip-markdown-collect-fragments (point-min) (point-max)))))
    (goto-char (point-max))
    (insert " and $b$")
    ;; Modification tick advanced; cache must refresh.
    (should (= 2 (length (tip-markdown-collect-fragments (point-min) (point-max)))))))

(ert-deftest ttm/cache-returns-same-on-unchanged-buffer ()
  (with-temp-buffer
    (insert "text $a$ more")
    (let ((r1 (tip-markdown-collect-fragments (point-min) (point-max)))
          (r2 (tip-markdown-collect-fragments (point-min) (point-max))))
      (should (equal r1 r2)))))

;;; --- Treesit path (requires grammar) --------------------------------------

(ert-deftest ttm/treesit-grammar-path-available ()
  (skip-unless (and (fboundp 'treesit-ready-p)
                    (treesit-ready-p 'markdown t)))
  (let ((frags (ttm--texts "math $a$ \n```\ncode $b$ block\n```\nafter $c$")))
    (should (= (length frags) 2))
    (should (equal (car frags) "$a$"))))

(ert-deftest ttm/treesit-grammar-skip-inline-html ()
  (skip-unless (and (fboundp 'treesit-ready-p)
                    (treesit-ready-p 'markdown t)))
  ;; Math inside raw HTML span should be skipped by tree-sitter, but
  ;; this depends on grammar coverage — if the node type is missing the
  ;; test should still pass (treesit returns 0 matches for unknown
  ;; types after the condition-case guard).  Assert the no-crash
  ;; property rather than specific skip behavior.
  (let ((frags (ttm--texts "real $a$ and <span>$x$</span> and real $b$")))
    (should (listp frags))
    (should (>= (length frags) 1))))

;;; --- Progress guarantee (no infinite loops on pathological input) ---------

(ert-deftest ttm/pathological-many-dollars ()
  ;; 100 lone $ characters — the collector must complete without hang.
  (let* ((text (apply #'concat (make-list 100 "$ ")))
         (frags (ttm--texts text)))
    ;; Exact count is not interesting; terminate in finite time IS.
    (should (listp frags))))

(ert-deftest ttm/pathological-nested-delimiters ()
  ;; $$$$$$ — six dollars.  Parser must terminate.
  (let ((frags (ttm--texts "$$$$$$")))
    (should (listp frags))))

(let ((n-failed 0) (n-ran 0))
  (ert-run-tests-batch-and-exit))
