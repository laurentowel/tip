;;; 03-theme-swap.el --- Theme cycling refreshes math colors live  -*- lexical-binding: t; -*-

;; Cycles through several built-in themes.  tip's SVG recolor runs on
;; each theme change — math stays in sync with face colors without
;; a server round-trip.

(tip-test-deftest showcase-theme-cycle
  :doc "Cycle through three themes; watch math recolor each time."
  :tags (showcase theme)
  (tip-test-with-fresh-typst-buffer
   (concat "Theme-aware rendering:\n\n"
           "$ phi.alt = (1 + sqrt(5))/2 $\n"
           "$ e^(i pi) + 1 = 0 $\n"
           "$ sum_(n=1)^oo 1/n^2 = pi^2 / 6 $\n")
    (tip-render-all)
    (tip-test-wait-for-pending 20)
    (redisplay t)
    (sit-for 1.0)
    (dolist (theme '(wombat tango modus-operandi))
      (mapc #'disable-theme custom-enabled-themes)
      (condition-case _ (load-theme theme t) (error nil))
      (redisplay t)
      (sit-for 2.2))
    ;; Return to the user's original (no theme).
    (mapc #'disable-theme custom-enabled-themes)
    (redisplay t)))
