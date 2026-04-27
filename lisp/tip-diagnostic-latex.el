;;; tip-diagnostic-latex.el --- LaTeX file collection for tip-bug-report -*- lexical-binding: t; -*-

;;; Commentary:

;; Thin backend-specific layer over `list_project_files'.  The server
;; owns the graph walk (via TexProject); this file exists so future
;; LaTeX-only tweaks (e.g. bundling the `kpsewhich'-resolved paths of
;; every `\usepackage' target, or the `.bib' files of a \\bibliography
;; call) have a clear home.

;;; Code:

(declare-function tip--send-request "tip-server-proc")

(defun tip-diagnostic-latex-collect (uri callback)
  "Collect the LaTeX project files connected to URI.
Calls CALLBACK with `(root . files)' once the server replies.  FILES
is the connected component via `\\input'/`\\include' discovered by the
server's `TexProject'; ROOT is the directory all paths are relative to."
  (tip--send-request
   "list_project_files"
   `(("uri" . ,uri))
   (lambda (result)
     (let ((root (alist-get 'root result))
           (files (append (alist-get 'files result) nil)))
       (funcall callback (cons root files))))))

(provide 'tip-diagnostic-latex)

;;; tip-diagnostic-latex.el ends here
