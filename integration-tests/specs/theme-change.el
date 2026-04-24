;;; theme-change.el --- Theme switch re-colors overlays without recompile  -*- lexical-binding: t; -*-

;; `tip-follow-theme-mode' hooks into `enable-theme-functions' so a
;; theme change triggers `tip--on-theme-change', which does fast SVG
;; color substitution (no server round-trip).  Ported from
;; legacy 08-theme-change, trimmed to the observable signals.

(tip-test-deftest follow-theme-mode-hooks-installed
  :doc "tip-mode activates follow-theme-mode and registers the hook."
  :tags (theme)
  (tip-test-with-fresh-typst-buffer "$a$\n"
    (should tip-follow-theme-mode)
    (should (memq #'tip--on-theme-change enable-theme-functions))))

(tip-test-deftest theme-switch-preserves-overlays
  :doc "Loading a theme keeps overlays alive (no rebuild needed)."
  :tags (theme render)
  (tip-test-with-fresh-typst-buffer
   "Inline $a + b$ and $x^2$\nDisplay: $ sum_k k $\n"
    (tip-render-all)
    (tip-test-wait-for-pending 20)
    (let ((before (length (overlays-in (point-min) (point-max))))
          (fired 0))
      (should (> before 0))
      (cl-letf* ((orig (symbol-function 'tip--on-theme-change))
                 ((symbol-function 'tip--on-theme-change)
                  (lambda (&rest args) (cl-incf fired) (apply orig args))))
        (mapc #'disable-theme custom-enabled-themes)
        (load-theme 'wombat t)
        (redisplay t)
        (sit-for 0.3))
      (should (> fired 0))
      (should (= before (length (overlays-in (point-min) (point-max))))))
    ;; Reset to default so later tests have a predictable face.
    (mapc #'disable-theme custom-enabled-themes)))
