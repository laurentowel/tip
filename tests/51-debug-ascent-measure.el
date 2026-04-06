;;; test-ascent-debug2.el --- Test :ascent with position measurement -*- lexical-binding: t; -*-

(setq create-lockfiles nil make-backup-files nil auto-save-default nil)

(defvar test--svg
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50\" height=\"30\">
     <rect width=\"50\" height=\"30\" fill=\"#ddf\" stroke=\"black\"/>
     <text x=\"5\" y=\"20\" font-size=\"14\">xy</text>
   </svg>")

(defvar test--results nil)

(switch-to-buffer (get-buffer-create "*ascent-test*"))
(erase-buffer)
(insert "\n") ;; give some space

(dolist (asc '(0 25 50 75 100 center))
  (let ((start (point)))
    (insert (format "asc=%S: before " asc))
    (let ((img-start (point)))
      (insert-image
       (list 'image :type 'svg :data test--svg :ascent asc)
       "IMG")
      (insert " after\n")
      ;; Force display
      (redisplay t)
      (sleep-for 0.1)
      ;; Measure: get pixel position of the image
      (goto-char img-start)
      (let* ((pos (posn-at-point))
             (xy (posn-x-y pos))
             (x (car xy))
             (y (cdr xy)))
        (push (format "ascent=%-7S  pixel-y=%d  x=%d" asc y x) test--results)))))

(goto-char (point-max))
(insert "\n--- Results ---\n")
(dolist (r (nreverse test--results))
  (insert r "\n"))

;; Also write to file
(let ((results-file (expand-file-name
                     "test-ascent-results.txt"
                     (file-name-directory (or load-file-name ".")))))
  (with-temp-file results-file
    (dolist (r (reverse test--results))
      (insert r "\n")))
  (insert (format "\nWritten to %s\n" results-file)))

(goto-char (point-min))
(redisplay t)
(sleep-for 2)
(kill-emacs 0)
