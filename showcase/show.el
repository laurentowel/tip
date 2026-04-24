;;; show.el --- demo-it steps for the tip showcase  -*- lexical-binding: t; -*-

;; Two-file showcase: init.el loads + tweaks + runs; this file is the
;; script.  Single `demo-it-create' call.  Kbd-strings drive M-x so
;; the viewer sees the minibuffer; expressions do real work.

;;; Code:

(require 'demo-it)

(defvar tip-showcase--typ-buf nil)
(defvar tip-showcase--tex-buf nil)
(defvar tip-showcase--typ-file nil)
(defvar tip-showcase--tex-file nil)

(defun tip-showcase--fresh-typst ()
  (setq tip-showcase--typ-file (make-temp-file "tip-show-" nil ".typ")
        tip-showcase--typ-buf (generate-new-buffer "*tip-showcase-typst*"))
  (switch-to-buffer tip-showcase--typ-buf)
  (setq buffer-file-name tip-showcase--typ-file)
  (typst-ts-mode))

(defun tip-showcase--fresh-latex ()
  (setq tip-showcase--tex-file (make-temp-file "tip-show-" nil ".tex")
        tip-showcase--tex-buf (generate-new-buffer "*tip-showcase-latex*"))
  (switch-to-buffer tip-showcase--tex-buf)
  (setq buffer-file-name tip-showcase--tex-file)
  (insert "\\documentclass{article}\n\\usepackage{amsmath}\n"
          "\\newcommand{\\lapl}{\\nabla^2}\n"
          "\\begin{document}\n\\end{document}\n")
  (goto-char (point-min)) (forward-line 4)
  (latex-mode)
  (when (buffer-live-p tip-showcase--typ-buf)
    (with-current-buffer tip-showcase--typ-buf (set-buffer-modified-p nil))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer tip-showcase--typ-buf))
    (ignore-errors (delete-file tip-showcase--typ-file))))

(defun tip-showcase--fix-notafunc ()
  (save-excursion
    (goto-char (point-min))
    (while (search-forward "notafunc(x)" nil t)
      (replace-match "sin(x) + cos(x)" nil t))))

(defun tip-showcase--teardown ()
  (dolist (b (list tip-showcase--typ-buf tip-showcase--tex-buf))
    (when (buffer-live-p b)
      (with-current-buffer b (set-buffer-modified-p nil))
      (let ((kill-buffer-query-functions nil)) (kill-buffer b))))
  (dolist (f (list tip-showcase--typ-file tip-showcase--tex-file))
    (ignore-errors (and f (delete-file f)))))

(setq typst-ts-indent-offset 2)

(demo-it-create
 :insert-fast
 tip-showcase--fresh-typst
 "RET"

 (call-interactively #'execute-extended-command)
 (demo-it-insert "tip-mode")
 "RET"

 (call-interactively #'execute-extended-command)
 (demo-it-insert "electric-pair-mode")
 "RET"

 (demo-it-insert "Let's type some math: ")
 "$"
 (demo-it-insert "f(x) = sum_(k=1)^n k^3")
 "C-e"
 (demo-it-insert ".\n\nScope is tracked -- let's define a variable `foo` with let binding:
#let foo = $a^(b^(c^d))$\nThen we can use foo: ")
 "$"
 (demo-it-insert "foo = foo = foo")
 "C-e"

 (demo-it-insert ".\n`tip` is smart enough so that the right hand side of the let binding isn't rendered.")

 (demo-it-insert "\n\n`tip` traverses the AST of the document so that this works in any nested scope:
#list[
  #let foo = math.cal(\"A\") // we just redefined foo!
  #list[
    #let bar = math.cal(\"B\")
  ]
]")

 "C-p C-o"
 "$"
 (demo-it-insert "foo plus.o bar")
 "C-e C-n C-n"
 
 (demo-it-insert "\n\nWhat if there's a typo:\n")
 "$"
 (demo-it-insert "sine(x)+1")
 "C-e RET"

 (demo-it-insert "hmm there's an error....  Let's fix it")
 
 "C-p M-3 M-b C-f"

 "M-d"
 (demo-it-insert "sin")
 "C-e"
 "RET"

 (demo-it-insert "\nModular design —- latex-mode works too.\n")
 tip-showcase--fresh-latex

 (call-interactively #'execute-extended-command)
 (demo-it-insert "tip-mode")
 "RET"

 "C-o"
 (demo-it-insert "The file contains a custom command.")

 "C-p C-p"

 "C-n C-n C-e RET RET"
 "$"
 (demo-it-insert "\\partial_t u = \\alpha \\lapl u")
 "C-e"

 tip-showcase--teardown)

(defvar tip-showcase-steps demo-it--steps
  "Frozen snapshot of the demo-it steps.  Iterated by the driver
defined in init.el.")

(provide 'tip-showcase-show)
;;; show.el ends here
