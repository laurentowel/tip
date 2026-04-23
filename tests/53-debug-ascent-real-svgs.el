;;; test-ascent-real.el --- Test :ascent with actual tip SVGs -*- lexical-binding: t; -*-

(require 'package)
(package-initialize)
(setq create-lockfiles nil make-backup-files nil auto-save-default nil)

(let ((base (file-name-directory load-file-name)))
  (setq tip-server-executable
        (expand-file-name "../tip-server/target/release/tip-server-typst" base))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base)))

(tip-ensure)
(sleep-for 1)
(accept-process-output tip--server-process 1)

(defun test--compile-sync (math-str)
  "Compile MATH-STR synchronously, return (svg height depth) or nil."
  (let* ((doc (concat "#set text(size: 11pt)\n" math-str "\n"))
         (result nil)
         (done nil)
         (frag-start (string-match "\\$" doc))
         (frag-end (and frag-start
                        (1+ (or (string-match "\\$" doc (1+ frag-start)) 0)))))
    (unless (and frag-start frag-end (> frag-end frag-start))
      (message "Could not find $ delimiters in: %s" math-str)
      (cl-return-from test--compile-sync nil))
    ;; Sync
    (tip--send-request "sync"
                       `(("uri" . "/tmp/asc-test.typ") ("content" . ,doc)))
    (accept-process-output tip--server-process 1)
    ;; Compile
    (tip--send-request
     "compile_fragments"
     `(("uri" . "/tmp/asc-test.typ")
       ("fragments" . ,(vector `(("start" . ,frag-start) ("end" . ,frag-end))))
       ("color" . "#000000"))
     (lambda (res)
       (let ((frags (alist-get 'fragments res)))
         (when (and frags (> (length frags) 0))
           (let ((f (aref frags 0)))
             (setq result (list (alist-get 'svg f)
                                (alist-get 'height_pt f)
                                (alist-get 'depth_pt f))))))
       (setq done t)))
    ;; Wait
    (let ((deadline (+ (float-time) 10)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output tip--server-process 0.1)))
    result))

(switch-to-buffer (get-buffer-create "*ascent-test*"))
(erase-buffer)

(let ((exprs '("$a + b$" "$a^a$" "$a_b$" "$a^(a^a)$" "$frac(a,b)$"
               "$x$" "$integral_0^1$" "$sum_(i=0)^n$")))

  ;; Section 1: computed ascent
  (insert "=== Computed :ascent ===\n\n")
  (dolist (expr exprs)
    (let ((res (test--compile-sync expr)))
      (if (and res (nth 0 res) (> (length (nth 0 res)) 0))
          (let* ((svg (nth 0 res))
                 (h (nth 1 res))
                 (d (nth 2 res))
                 (ascent (if (and (> h 0) (> d 0))
                             (max 0 (min 100 (round (* 100 (- 1.0 (/ d h))))))
                           'center))
                 (height-em (/ h 11.0)))
            (insert (format "%-16s (h=%.1f d=%.1f asc=%3S): abc " expr h d ascent))
            (insert-image `(image :type svg :data ,svg
                                  :height (,height-em . em) :ascent ,ascent))
            (insert " abc\n"))
        (insert (format "%-16s COMPILE FAILED\n" expr)))))

  (insert "\n=== All with :ascent center ===\n\n")
  (dolist (expr exprs)
    (let ((res (test--compile-sync expr)))
      (when (and res (nth 0 res) (> (length (nth 0 res)) 0))
        (let* ((svg (nth 0 res))
               (h (nth 1 res))
               (height-em (/ h 11.0)))
          (insert (format "%-16s center: abc " expr))
          (insert-image `(image :type svg :data ,svg
                                :height (,height-em . em) :ascent center))
          (insert " abc\n")))))

  (insert "\n=== All with :ascent 89 (like a+b) ===\n\n")
  (dolist (expr exprs)
    (let ((res (test--compile-sync expr)))
      (when (and res (nth 0 res) (> (length (nth 0 res)) 0))
        (let* ((svg (nth 0 res))
               (h (nth 1 res))
               (height-em (/ h 11.0)))
          (insert (format "%-16s asc=89: abc " expr))
          (insert-image `(image :type svg :data ,svg
                                :height (,height-em . em) :ascent 89))
          (insert " abc\n"))))))

(goto-char (point-min))
(redisplay t)
(message "Check *ascent-test* — compare 3 sections")
