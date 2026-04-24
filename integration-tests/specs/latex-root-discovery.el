;;; latex-root-discovery.el --- Project root resolution for LaTeX  -*- lexical-binding: t; -*-

;; Three channels by which `tip-latex-maybe-setup-project' decides
;; on a project root for a buffer that uses `\input' / `\include':
;;
;;   1. Existing `tip-project-root-path' (from .dir-locals.el etc.) wins.
;;   2. `% !TEX root = ...' magic comment.
;;   3. Session-file lookup.
;;
;; A fourth channel — an interactive prompt — is exercised in manual
;; testing; it's not automated here.  A file-less buffer containing
;; `\input' must error loudly rather than silently mis-render.

(defmacro tip-test--with-latex-file (path content &rest body)
  "Visit a fresh .tex file at PATH, insert CONTENT, run BODY, clean up."
  (declare (indent 2))
  `(let ((tip-project-root-path nil)
         (tip-latex-session-file nil) ; don't touch disk
         (tip-latex--session-cache nil)
         (tip-latex--session-loaded nil))
     (let ((buf (find-file-noselect ,path)))
       (unwind-protect
           (with-current-buffer buf
             (erase-buffer)
             (insert ,content)
             (latex-mode)
             ,@body)
         (with-current-buffer buf (set-buffer-modified-p nil))
         (let ((kill-buffer-query-functions nil))
           (kill-buffer buf))))))

(tip-test-deftest latex-root-explicit-override-wins
  :doc "An already-set `tip-project-root-path' is not overridden."
  :tags (latex project-root)
  (let ((tmpdir (make-temp-file "tip-root-" t))
        (explicit "/some/explicit/root.tex"))
    (unwind-protect
        (tip-test--with-latex-file (expand-file-name "child.tex" tmpdir)
          "\\input{other}\n"
          (setq-local tip-project-root-path explicit)
          (tip-latex-maybe-setup-project)
          (should (equal tip-project-root-path explicit)))
      (delete-directory tmpdir t))))

(tip-test-deftest latex-root-single-file-skips-setup
  :doc "A buffer with no \\input/\\include keeps root unset."
  :tags (latex project-root)
  (let ((tmpdir (make-temp-file "tip-root-" t)))
    (unwind-protect
        (tip-test--with-latex-file (expand-file-name "solo.tex" tmpdir)
          "\\documentclass{article}\\begin{document}$a+b$\\end{document}\n"
          (tip-latex-maybe-setup-project)
          (should-not tip-project-root-path))
      (delete-directory tmpdir t))))

(tip-test-deftest latex-root-magic-comment-resolved
  :doc "`% !TEX root = main.tex' picks up main.tex in the same dir."
  :tags (latex project-root)
  (let ((tmpdir (make-temp-file "tip-root-" t)))
    (unwind-protect
        (progn
          ;; Create the main file so `expand-file-name' is meaningful.
          (with-temp-file (expand-file-name "main.tex" tmpdir)
            (insert "\\documentclass{article}\\begin{document}\\end{document}\n"))
          (tip-test--with-latex-file (expand-file-name "intro.tex" tmpdir)
            "% !TEX root = main.tex\n\\input{other}\n"
            (tip-latex-maybe-setup-project)
            (should (equal tip-project-root-path
                           (expand-file-name "main.tex" tmpdir)))))
      (delete-directory tmpdir t))))

(tip-test-deftest latex-root-file-less-buffer-errors
  :doc "A buffer with \\input but no backing file signals user-error."
  :tags (latex project-root)
  (let ((tip-project-root-path nil)
        (tip-latex-session-file nil)
        (tip-latex--session-cache nil))
    (with-temp-buffer
      (latex-mode)
      (insert "\\input{other}\n")
      (setq tip-latex--has-includes 'unknown)
      (should-error (tip-latex-maybe-setup-project) :type 'user-error))))
