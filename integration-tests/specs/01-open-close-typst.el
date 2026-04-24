;;; open-close.el --- Fragment overlay open/close cycle -*- lexical-binding: t; -*-

;; Tests the core preview-toggle cycle: after render-all, moving the
;; cursor INTO a fragment opens the overlay (reveals source), moving
;; OUT closes it (re-renders the image).  Ported from the legacy
;; 00-overlay-open-close.el, trimmed to the essential assertions.

(tip-test-deftest render-all-produces-image-overlays
  :doc "tip-render-all creates a rendered image overlay per fragment."
  (tip-test-with-fresh-typst-buffer "before $a + b$ middle $x^2$ after\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let ((ranges (tip-test-fragment-ranges)))
      (should (= (length ranges) 2))
      (dotimes (i 2)
        (let ((pos (tip-test-inside-fragment i)))
          (should (tip-test-overlay-showing-image-p pos)))))))

(tip-test-deftest forward-into-fragment-opens-overlay
  :doc "Moving the cursor INTO a rendered fragment reveals the source."
  (tip-test-with-fresh-typst-buffer "start $a + b$ end\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let ((inside (tip-test-inside-fragment 0)))
      (tip-test-simulate-command 'forward-char inside)
      ;; Overlay is now "open" — display property gone, source visible.
      (should-not (tip-test-overlay-showing-image-p inside)))))

(tip-test-deftest leaving-fragment-closes-overlay
  :doc "Moving OUT of a fragment re-renders and restores the image."
  (tip-test-with-fresh-typst-buffer "start $a + b$ end\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let* ((ranges (tip-test-fragment-ranges))
           (inside (tip-test-inside-fragment 0))
           (after (tip-test-after-fragment 0)))
      (tip-test-simulate-command 'forward-char inside)
      (tip-test-simulate-command 'forward-char after)
      (tip-test-wait-for-pending 5)
      (should (tip-test-overlay-showing-image-p inside)))))
