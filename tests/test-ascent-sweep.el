;;; test-ascent-sweep.el --- Sweep ascent values for each expression -*- lexical-binding: t; -*-

(require 'package)
(package-initialize)
(setq create-lockfiles nil make-backup-files nil auto-save-default nil)

(let ((base (file-name-directory load-file-name)))
  (setq tip-server-executable
        (expand-file-name "../../tip-server/target/release/tip-server" base))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base)))

(tip-ensure)
(sleep-for 1)
(accept-process-output tip--server-process 1)

(defun test--compile-sync (math-str)
  (let* ((doc (concat "#set text(size: 11pt)\n" math-str "\n"))
         (result nil) (done nil)
         (frag-start (string-match "\\$" doc))
         (frag-end (and frag-start (1+ (or (string-match "\\$" doc (1+ frag-start)) 0)))))
    (unless (and frag-start frag-end (> frag-end frag-start))
      (cl-return-from test--compile-sync nil))
    (tip--send-request "sync" `(("uri" . "/tmp/sweep.typ") ("content" . ,doc)))
    (accept-process-output tip--server-process 1)
    (tip--send-request
     "compile_fragments"
     `(("uri" . "/tmp/sweep.typ")
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
    (let ((deadline (+ (float-time) 10)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output tip--server-process 0.1)))
    result))

(switch-to-buffer (get-buffer-create "*ascent-sweep*"))
(erase-buffer)

;; For each expression, show it at ascent 40,50,60,70,80,90
;; so the user can pick which looks best
(let ((exprs '("$a + b$" "$a_b$" "$a^a$" "$a^(a^a)$" "$frac(a,b)$" "$x_i$"))
      (ascents '(40 50 60 70 80 90)))
  (dolist (expr exprs)
    (let ((res (test--compile-sync expr)))
      (when (and res (nth 0 res) (> (length (nth 0 res)) 0))
        (let* ((svg (nth 0 res))
               (h (nth 1 res))
               (height-em (/ h 11.0)))
          (insert (format "%s (h=%.1f):\n" expr h))
          (dolist (asc ascents)
            (insert (format "  %2d%%: xbq" asc))
            (insert-image `(image :type svg :data ,svg
                                  :height (,height-em . em) :ascent ,asc))
            (insert "xbq  "))
          (insert "\n\n"))))))

(goto-char (point-min))
(message "For each expression, find which ascent % aligns 'xbq' baselines")
