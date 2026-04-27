;;; 19-error-clears-on-edit-latex.el --- Error overlay cleared on edit  -*- lexical-binding: t; -*-

;; Regression: when a fragment compiles with an error, the error
;; overlay must NOT linger after the user edits inside the fragment.
;; The eager-clear path (`tip--cleanup-stale-overlays' on
;; after-change) keys on `tip-frag-beg'/`tip-frag-end' so a typo
;; correction anywhere in the fragment range removes the warn/err
;; face, even when the underline was on a sub-range.

(tip-test-deftest error-overlay-clears-on-edit-inside-fragment
  :doc "Editing inside an errored fragment removes the error overlay."
  :tags (latex error)
  (tip-test-with-fresh-latex-buffer
   "\\documentclass{article}\n\\usepackage{amsmath,amssymb}\n\\begin{document}\n\\( \\bet \\)\n\\end{document}\n"
    (tip-render-all)
    (tip-test-wait-for-pending 25)
    ;; The fragment `\( \bet \)' triggers a LaTeX error (\\bet is not
    ;; defined).  Confirm the error overlay landed before testing the
    ;; clear.
    (let ((errs (seq-filter (lambda (o)
                              (and (eq (overlay-get o 'tip) 'tip)
                                   (overlay-get o 'tip-error-severity)))
                            (overlays-in (point-min) (point-max)))))
      (should (> (length errs) 0)))
    ;; Edit INSIDE the fragment — fix the typo.
    (let* ((errs (seq-filter (lambda (o)
                               (and (eq (overlay-get o 'tip) 'tip)
                                    (overlay-get o 'tip-error-severity)))
                             (overlays-in (point-min) (point-max))))
           (frag-beg (overlay-get (car errs) 'tip-frag-beg))
           (frag-end (overlay-get (car errs) 'tip-frag-end)))
      (goto-char (/ (+ frag-beg frag-end) 2))
      (insert "a"))
    ;; The error overlay must be gone immediately.
    (let ((errs (seq-filter (lambda (o)
                              (and (eq (overlay-get o 'tip) 'tip)
                                   (overlay-get o 'tip-error-severity)))
                            (overlays-in (point-min) (point-max)))))
      (should (zerop (length errs))))))
