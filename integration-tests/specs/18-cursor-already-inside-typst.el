;;; 18-cursor-already-inside-typst.el --- open when cursor is parked on a fragment  -*- lexical-binding: t; -*-

;; Edge case: the cursor is ALREADY inside a fragment when rendering
;; finishes (e.g. user opens a file, tip-mode turns on, the render
;; completes while their cursor happens to sit in a math span).  The
;; overlay must still open on the very next command rather than
;; requiring the user to leave-and-reenter.  Regression for the
;; level-triggered open logic in `preview-toggle--post-command'.

(tip-test-deftest cursor-already-inside-opens-on-next-command
  :doc "Overlay opens when the first command fires with cursor already inside."
  :tags (render open-close typst)
  (tip-test-with-fresh-typst-buffer "pre $a + b$ post\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let ((inside (tip-test-inside-fragment 0)))
      ;; Park the cursor inside the fragment BEFORE any command fires.
      ;; `preview-toggle--was-inside' defaults to nil at mode activation.
      (goto-char inside)
      (should (tip-test-overlay-showing-image-p inside))
      ;; A trivial no-op command — the cursor doesn't move, but the
      ;; post-command hook must still see "inside + image displayed"
      ;; and open the overlay.
      (tip-test-simulate-command 'ignore inside)
      (should-not (tip-test-overlay-showing-image-p inside)))))
