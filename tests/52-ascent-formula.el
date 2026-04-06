;;; test-ascent-formula.el --- Find correct ascent formula -*- lexical-binding: t; -*-

(require 'package)
(package-initialize)
(setq create-lockfiles nil make-backup-files nil auto-save-default nil)

(let ((base (file-name-directory load-file-name)))
  (setq tip-server-executable
        (expand-file-name "../tip-server/target/release/tip-server" base))
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
      (cl-return-from test--compile-sync nil))
    (tip--send-request "sync"
                       `(("uri" . "/tmp/asc-test.typ") ("content" . ,doc)))
    (accept-process-output tip--server-process 1)
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
    (let ((deadline (+ (float-time) 10)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output tip--server-process 0.1)))
    result))

;; Also compile a reference "x" to know what ascent should look like
(defvar test--ref-result (test--compile-sync "$x$"))
(defvar test--ref-height (and test--ref-result (nth 1 test--ref-result)))
(defvar test--ref-depth (and test--ref-result (nth 2 test--ref-result)))

(switch-to-buffer (get-buffer-create "*ascent-formula*"))
(erase-buffer)
(setq-local line-spacing 4)

(let ((exprs '("$x$" "$a + b$" "$a^a$" "$a_b$" "$a^(a^a)$"
               "$a^(a^(a^a))$" "$frac(a,b)$" "$x_i$")))

  ;; Try different formulas
  (dolist (formula-info
           `(("center" . ,(lambda (_h _d) 'center))
             ;; org-latex-preview style: ascent = 100*(1 - depth/height)
             ("100*(1-d/h)" . ,(lambda (h d)
                                  (if (and (> h 0) (> d 0))
                                      (max 0 (min 100 (round (* 100 (- 1.0 (/ d h))))))
                                    'center)))
             ;; Based on reference x: the baseline is where x's center would be
             ;; ref_ascent = ref_h - ref_d = height above baseline for x
             ;; For any eq: ascent_px = ref_ascent (constant absolute)
             ;; ascent_pct = ref_ascent / h * 100
             ("ref-x based" . ,(lambda (h _d)
                                  (if (and test--ref-height test--ref-depth (> h 0))
                                      (let* ((ref-ascent (- test--ref-height test--ref-depth)))
                                        (max 0 (min 100 (round (* 100 (/ ref-ascent h))))))
                                    'center)))
             ;; Assume math baseline = x-height above bottom
             ;; x-height ≈ 0.45 * font-size for Computer Modern
             ;; ascent = (h - 0.45*11) / h * 100... no
             ;; Actually: ascent-from-bottom = x-height ≈ 5pt for 11pt
             ;; ascent-pct = (h - 5) / h * 100
             ("fixed 5pt depth" . ,(lambda (h _d)
                                     (if (> h 0)
                                         (max 0 (min 100 (round (* 100 (/ (- h 5.0) h)))))
                                       'center)))))
    (let ((name (car formula-info))
          (fn (cdr formula-info)))
      (insert (format "=== Formula: %s ===\n" name))
      (dolist (expr exprs)
        (let ((res (test--compile-sync expr)))
          (when (and res (nth 0 res) (> (length (nth 0 res)) 0))
            (let* ((svg (nth 0 res))
                   (h (nth 1 res))
                   (d (nth 2 res))
                   (ascent (funcall fn h d))
                   (height-em (/ h 11.0)))
              (insert (format "  %-16s asc=%3S: xbq " expr ascent))
              (insert-image `(image :type svg :data ,svg
                                    :height (,height-em . em) :ascent ,ascent))
              (insert " xbq\n")))))
      (insert "\n"))))

(goto-char (point-min))
(redisplay t)
(message "Compare formulas in *ascent-formula*. Look at xbq alignment.")
