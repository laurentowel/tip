;;; 02-live-editing.el --- Live edit → re-render → error → fix cycle  -*- lexical-binding: t; -*-

;; Shows the preview-toggle cycle working in real time.  Types math,
;; watches it render, moves into the fragment (overlay opens, source
;; back), edits, moves out (re-renders).  Each scene lingers long
;; enough for a human to follow.

(defun tip-test--pause (secs) (redisplay t) (sit-for secs))

(tip-test-deftest showcase-type-and-render
  :doc "Type a fragment from scratch; watch it render."
  :tags (showcase edit)
  (tip-test-with-fresh-typst-buffer "Let's type some math:\n\n"
    (goto-char (point-max))
    (tip-test--pause 1.0)
    ;; Type a non-trivial fragment, character by character, with
    ;; a pre/post-command hook cycle on each insert so live tooling
    ;; sees real keystrokes.
    (dolist (ch (string-to-list "$ integral_0^1 x^2 dif x = 1/3 $"))
      (let ((this-command 'self-insert-command))
        (run-hooks 'pre-command-hook))
      (insert ch)
      (let ((this-command 'self-insert-command))
        (run-hooks 'post-command-hook))
      (redisplay t)
      (sit-for 0.05))
    (insert "\n")
    (tip-render-all)
    (tip-test-wait-for-pending 15)))

(tip-test-deftest showcase-edit-inside-fragment
  :doc "Enter a rendered fragment, edit it, leave, watch it re-render."
  :tags (showcase edit)
  (tip-test-with-fresh-typst-buffer
   "Before edit: $a + b$ end\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (tip-test--pause 1.5)
    ;; Step into the fragment (overlay opens — source revealed).
    (tip-test-simulate-command 'forward-char (tip-test-inside-fragment 0))
    (tip-test--pause 1.2)
    ;; Edit the content to something longer.
    (goto-char (tip-test-inside-fragment 0))
    (insert "+ c^2 ")
    (tip-test--pause 0.8)
    ;; Leave — triggers recompile.
    (tip-test-simulate-command 'forward-char (tip-test-after-fragment 0))
    (tip-test-wait-for-pending 10)))

(tip-test-deftest showcase-error-then-fix
  :doc "A typo gets a red underline; fixing it restores the render."
  :tags (showcase error)
  (tip-test-with-fresh-typst-buffer
   "Intentionally broken: $ notafunc(x) $ — watch it light up.\n"
    (tip-render-all)
    (tip-test-wait-for-pending 20)
    (tip-test--pause 2.0)
    ;; "Fix" by replacing with valid content.
    (goto-char (point-min))
    (when (search-forward "notafunc(x)" nil t)
      (replace-match "sin(x) + cos(x)" nil t))
    (tip-render-all)
    (tip-test-wait-for-pending 15)))
