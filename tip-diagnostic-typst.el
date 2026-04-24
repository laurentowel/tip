;;; tip-diagnostic-typst.el --- Typst file collection for tip-bug-report -*- lexical-binding: t; -*-

;;; Commentary:

;; Thin backend-specific layer over `list_project_files'.  Typst has no
;; dependency graph on the server yet, so this currently forwards to the
;; server which returns just the URI itself (plus a root discovered via
;; marker walk).  A future enhancement would walk `#import'/`#include'
;; strings from the root file — either server-side (preferred, so other
;; clients benefit) or here with a client-local AST walk.

;;; Code:

(declare-function tip--send-request "tip-server-proc")

(defun tip-diagnostic-typst-collect (uri callback)
  "Collect Typst files reachable from URI.
Calls CALLBACK with `(root . files)'.  Today FILES is just (URI);
ROOT comes from the server's project-marker walk (`typst.toml',
`Kodama.toml', `.git') or URI's parent as a fallback."
  (tip--send-request
   "list_project_files"
   `(("uri" . ,uri))
   (lambda (result)
     (let ((root (alist-get 'root result))
           (files (append (alist-get 'files result) nil)))
       (funcall callback (cons root files))))))

(provide 'tip-diagnostic-typst)

;;; tip-diagnostic-typst.el ends here
