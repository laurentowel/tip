;;; childframe.el --- childframe show/hide/error-text lifecycle  -*- lexical-binding: t; -*-

;; Core childframe API: `tip-childframe-show', `...-hide',
;; `...-show-text ... 'error'.  Ported from legacy
;; 04-childframe-lifecycle.el — only the state-oriented checks; the
;; position-mode variations are visual and stay in legacy.

(require 'tip-childframe nil t)

(tip-test-deftest childframe-show-then-hide
  :doc "show makes the frame visible; hide makes it invisible."
  :tags (childframe)
  (tip-test-with-fresh-typst-buffer "Hello $alpha + beta$ end\n"
    ;; Childframes only work on graphical displays.  Skip cleanly
    ;; when running headless (CI).  `skip-unless' isn't autoloaded.
    (require 'ert)
    (unless (display-graphic-p)
      (ert-skip "no graphical display"))
    (tip-childframe-show
     "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\">\
<rect width=\"40\" height=\"20\" fill=\"#ccc\"/></svg>")
    (redisplay t)
    (sleep-for 0.2)
    (should (frame-live-p tip-childframe--frame))
    (should (frame-visible-p tip-childframe--frame))
    (tip-childframe-hide)
    (redisplay t)
    (sleep-for 0.2)
    (should-not (frame-visible-p tip-childframe--frame))))

(tip-test-deftest childframe-show-text-error
  :doc "show-text with 'error shows an error string in the childframe."
  :tags (childframe error)
  (tip-test-with-fresh-typst-buffer "$x$\n"
    ;; Childframes only work on graphical displays.  Skip cleanly
    ;; when running headless (CI).  `skip-unless' isn't autoloaded.
    (require 'ert)
    (unless (display-graphic-p)
      (ert-skip "no graphical display"))
    (tip-childframe-show-text "unknown variable: foo" 'error)
    (redisplay t)
    (sleep-for 0.2)
    (should (frame-visible-p tip-childframe--frame))
    (should (with-current-buffer (tip-childframe--ensure-buffer)
              (string-match-p "unknown variable"
                              (buffer-substring-no-properties
                               (point-min) (point-max)))))
    (tip-childframe-hide)))
