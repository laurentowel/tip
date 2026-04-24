;;; cursor-into-overlay.el --- C-b into a rendered overlay  -*- lexical-binding: t; -*-

;; Pathological entry path: the cursor is AFTER a rendered overlay
;; and moves BACKWARD (C-b) into it.  Must correctly detect "entered"
;; and open the overlay.  Ported from legacy 01-cursor-into-overlay.el.

(tip-test-deftest c-b-into-rendered-overlay
  :doc "Cursor moving backward into an overlay opens it (reveals source)."
  (tip-test-with-fresh-typst-buffer "pre $a + b$ post\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let* ((inside (tip-test-inside-fragment 0))
           (after (tip-test-after-fragment 0)))
      ;; Park cursor after the fragment.
      (tip-test-simulate-command 'forward-char after)
      (should (tip-test-overlay-showing-image-p inside))
      ;; C-b into the overlay.
      (tip-test-simulate-command 'backward-char inside)
      (should-not (tip-test-overlay-showing-image-p inside)))))

(tip-test-deftest c-b-from-buffer-end-into-last-overlay
  :doc "C-b from the very end of the buffer into the last fragment opens it."
  (tip-test-with-fresh-typst-buffer "prefix $x^2$"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (tip-test-simulate-command 'forward-char (point-max))
    (let ((inside (tip-test-inside-fragment 0)))
      (tip-test-simulate-command 'backward-char inside)
      (should-not (tip-test-overlay-showing-image-p inside)))))
