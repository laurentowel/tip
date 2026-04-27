;;; short-fragments.el --- Boundary precision with adjacent short fragments  -*- lexical-binding: t; -*-

;; Back-to-back short fragments like `$a$ $b$ $c$ $d$' exercise the
;; half-open-interval boundary detection.  Historically the bug was
;; that position at fragment end was misreported as "inside", preventing
;; the overlay from closing.  Ported from legacy 11-short-fragment-open-close.

(tip-test-deftest adjacent-shorts-each-close-on-leave
  :doc "Four back-to-back $X$ fragments all close correctly on forward exit."
  (tip-test-with-fresh-typst-buffer
   "Text $a$ then $b$ then $g$ then $d$ end.\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let ((ranges (tip-test-fragment-ranges)))
      (should (= (length ranges) 4))
      (dotimes (i 4)
        (let* ((inside (tip-test-inside-fragment i))
               (after (tip-test-after-fragment i)))
          ;; Park outside first so "enter" is a transition.
          (tip-test-simulate-command 'forward-char (point-min))
          (tip-test-simulate-command 'forward-char inside)
          (tip-test-simulate-command 'forward-char after)
          (tip-test-wait-for-pending 3)
          (should (tip-test-overlay-showing-image-p inside)))))))

(tip-test-deftest adjacent-shorts-close-on-jump-between
  :doc "Cursor jump between adjacent short fragments closes the previous one."
  (tip-test-with-fresh-typst-buffer
   "Text $a$ then $b$ then $g$ then $d$ end.\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let* ((ranges (tip-test-fragment-ranges))
           (first-inside (tip-test-inside-fragment 0)))
      (tip-test-simulate-command 'forward-char first-inside)
      (should-not (tip-test-overlay-showing-image-p first-inside))
      (dotimes (i (1- (length ranges)))
        (let ((prev (tip-test-inside-fragment i))
              (next (tip-test-inside-fragment (1+ i))))
          (tip-test-simulate-command 'forward-char next)
          (tip-test-wait-for-pending 3)
          (should (tip-test-overlay-showing-image-p prev))
          (should-not (tip-test-overlay-showing-image-p next)))))))
