;;; 09-theme-change-typst.el --- Theme switch preserves overlays  -*- lexical-binding: t; -*-

;; SVGs emit `fill="currentColor"' — Emacs picks the face foreground
;; at display time, so a theme change is literally free: no server
;; round-trip, no SVG string-replace, no overlay rebuild.  These tests
;; assert the observable invariant: loading a new theme doesn't drop
;; or corrupt any overlays.

(tip-test-deftest font-change-rescales-overlays
  :doc "tip-mode wires buffer-face-mode-hook for font-size changes."
  :tags (theme typst)
  (tip-test-with-fresh-typst-buffer "$a$\n"
    (should (memq #'tip--on-font-change buffer-face-mode-hook))))

(tip-test-deftest theme-switch-preserves-overlays
  :doc "Loading a theme keeps overlays alive (currentColor in SVG)."
  :tags (theme render typst)
  (tip-test-with-fresh-typst-buffer
   "Inline $a + b$ and $x^2$\nDisplay: $ sum_k k $\n"
    (tip-render-all)
    (tip-test-wait-for-pending 20)
    (let ((before (length (overlays-in (point-min) (point-max)))))
      (should (> before 0))
      (mapc #'disable-theme custom-enabled-themes)
      (load-theme 'wombat t)
      (redisplay t)
      (sit-for 0.3)
      (should (= before (length (overlays-in (point-min) (point-max))))))
    ;; Reset so later tests have a predictable face.
    (mapc #'disable-theme custom-enabled-themes)))
