;;; nested-math.el --- Pathological nested LaTeX math detection  -*- lexical-binding: t; -*-

;; Regression tests for the closer-scanner that handles `$...\text{$a$}...$',
;; `\(...\text{\(x\)}...\)', `%'-comments containing fake closers, and
;; `\begin{aligned}' nested inside `\[...\]'.  Pure-logic assertions only
;; — these don't need the server.

(tip-test-deftest nested-dollar-in-text
  :doc "$outer \\text{$inner$}$ stays one fragment."
  (tip-test-with-fresh-latex-buffer
   "prefix $oeuo \\text{$a$}$ between $b$ end.\n"
    (let* ((frags (tip-latex-collect-fragments (point-min) (point-max)))
           (texts (mapcar (lambda (f)
                            (let ((sb (1+ (alist-get "start" f nil nil #'equal)))
                                  (eb (1+ (alist-get "end"   f nil nil #'equal))))
                              (buffer-substring-no-properties
                               (byte-to-position sb) (byte-to-position eb))))
                          frags)))
      (should (equal texts '("$oeuo \\text{$a$}$" "$b$"))))))

(tip-test-deftest nested-paren-in-text
  :doc "\\(...\\text{\\(x\\)}...\\) stays one fragment."
  (tip-test-with-fresh-latex-buffer
   "pre \\(a + \\text{\\(x + 1\\)} + b\\) post\n"
    (let* ((frags (tip-latex-collect-fragments (point-min) (point-max)))
           (count (length frags)))
      (should (= count 1)))))

(tip-test-deftest paren-comment-skip
  :doc "A `%' comment inside \\(...\\) with a fake \\) must not close early."
  (tip-test-with-fresh-latex-buffer
   "pre \\(a + b % fake \\) close\n + c\\) post\n"
    (let* ((frags (tip-latex-collect-fragments (point-min) (point-max)))
           (count (length frags)))
      (should (= count 1)))))

(tip-test-deftest aligned-env-inside-display
  :doc "\\begin{aligned}...\\end{aligned} nested inside \\[...\\] stays one top-level fragment."
  (tip-test-with-fresh-latex-buffer
   "\\[\n\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}\n\\]\n"
    (let ((frags (tip-latex-collect-fragments (point-min) (point-max))))
      (should (= (length frags) 1)))))
