;;; edit-recompile.el --- Editing a fragment and leaving triggers recompile  -*- lexical-binding: t; -*-

;; Core preview-toggle contract: when the cursor EXITS a math fragment,
;; tip-server is asked to recompile that fragment so the overlay
;; reflects the new source.  Ported from legacy 02-edit-leave-recompile,
;; trimmed to the observable signal (compile request count).

(tip-test-deftest leaving-edited-fragment-triggers-compile
  :doc "Editing inside a fragment then moving out fires a compile request."
  :tags (render edit)
  (tip-test-with-fresh-typst-buffer "Start $a$ end\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let ((compiles 0))
      (cl-letf* ((orig (symbol-function 'tip--send-request))
                 ((symbol-function 'tip--send-request)
                  (lambda (method &rest args)
                    (when (member method '("compile_fragments" "compile_live"))
                      (cl-incf compiles))
                    (apply orig method args))))
        ;; Enter the fragment.
        (tip-test-simulate-command 'forward-char
                                   (tip-test-inside-fragment 0))
        ;; Edit it.
        (goto-char (tip-test-inside-fragment 0))
        (insert "b")
        ;; Leave — this should trigger recompile of the edited fragment.
        (tip-test-simulate-command 'forward-char
                                   (tip-test-after-fragment 0))
        (tip-test-wait-for-pending 5))
      (should (> compiles 0)))))
