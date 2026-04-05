;;; test-ascent-debug.el --- Test if :ascent actually works -*- lexical-binding: t; -*-

;;; Code:

(setq create-lockfiles nil make-backup-files nil auto-save-default nil)

;; Create a simple SVG
(defvar test--svg
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50\" height=\"30\">
     <rect width=\"50\" height=\"30\" fill=\"#eee\" stroke=\"black\"/>
     <line x1=\"0\" y1=\"15\" x2=\"50\" y2=\"15\" stroke=\"red\" stroke-width=\"1\"/>
     <text x=\"5\" y=\"20\" font-size=\"14\">ab</text>
   </svg>")

(switch-to-buffer (get-buffer-create "*ascent-test*"))
(erase-buffer)

;; Show same image at different :ascent values
(insert "Ascent test — red line is the SVG midpoint.\n")
(insert "If :ascent works, the red line should move vertically.\n\n")

(dolist (asc '(0 25 50 75 100 center))
  (insert (format "ascent=%S: text-before " asc))
  (insert-image
   (list 'image
         :type 'svg
         :data test--svg
         :ascent asc))
  (insert " text-after\n"))

(insert "\n\nIf all red lines are at the same vertical position,\n")
(insert ":ascent is NOT working.\n")
(insert "If they shift up/down with different values, it IS working.\n")

(goto-char (point-min))
(message "Check the *ascent-test* buffer")
