;;; 60-latex-arxiv-corpus.el --- Stress tip-latex against arXiv sources -*- lexical-binding: t; -*-

;;; Commentary:
;; Runs `tip-latex-collect-fragments' across a corpus of arXiv .tex
;; files at .ref/arxiv-samples/ and reports fragment counts and timings.
;; Skips silently if the corpus isn't present.
;;
;; Usage:
;;   emacs --batch -l tests/60-latex-arxiv-corpus.el

;;; Code:

(add-to-list 'load-path (expand-file-name ".." (file-name-directory (or load-file-name "."))))
(load (expand-file-name "tip.el" (expand-file-name ".." (file-name-directory (or load-file-name "."))))
      nil t)

(defun corpus--dir ()
  (expand-file-name ".ref/arxiv-samples"
                    (expand-file-name "../../" (file-name-directory (or load-file-name ".")))))

(defun corpus--tex-files ()
  (let ((d (corpus--dir)))
    (when (file-directory-p d)
      (cl-loop for id in (directory-files d nil "\\`[0-9]")
               for subdir = (expand-file-name id d)
               when (file-directory-p subdir)
               nconc (directory-files subdir t "\\.tex\\'")))))

(defun corpus--kind-of (text)
  "Return a coarse classification: block, display-multi, display-single, inline."
  (cond
   ((string-prefix-p "\\begin{" text)
    (if (string-match-p "\n" text) 'display-multi 'display-single))
   ((or (string-prefix-p "\\[" text) (string-prefix-p "$$" text))
    (if (string-match-p "\n" text) 'display-multi 'display-single))
   (t 'inline)))

(defun corpus--process-file (path)
  (with-temp-buffer
    (insert-file-contents path)
    ;; Run latex-mode for comment-syntax — if available in this Emacs.
    (when (fboundp 'latex-mode)
      (delay-mode-hooks (latex-mode)))
    (let* ((t0 (float-time))
           (frags (tip-latex-collect-fragments (point-min) (point-max)))
           (elapsed (- (float-time) t0))
           (preamble-len (length (tip-latex-build-preamble)))
           (counts (make-hash-table :test 'eq)))
      (dolist (frag frags)
        (let* ((sb (1+ (alist-get "start" frag nil nil #'equal)))
               (eb (1+ (alist-get "end"   frag nil nil #'equal)))
               (txt (buffer-substring-no-properties
                     (byte-to-position sb) (byte-to-position eb))))
          (cl-incf (gethash (corpus--kind-of txt) counts 0))))
      (list :path path
            :size (buffer-size)
            :frags (length frags)
            :elapsed elapsed
            :preamble-len preamble-len
            :counts counts))))

(defun corpus--fmt-row (r)
  (let* ((c (plist-get r :counts))
         (g (lambda (k) (gethash k c 0))))
    (format "  %-60s  %6d bytes  %4d frags  (inline=%-3d  dispS=%-3d  dispM=%-3d)  %5.1f ms"
            (file-relative-name (plist-get r :path) (corpus--dir))
            (plist-get r :size)
            (plist-get r :frags)
            (funcall g 'inline)
            (funcall g 'display-single)
            (funcall g 'display-multi)
            (* 1000.0 (plist-get r :elapsed)))))

(defun corpus--run ()
  (let* ((files (corpus--tex-files))
         (n (length files)))
    (if (zerop n)
        (message "arxiv-samples corpus not present at %s — skipping" (corpus--dir))
      (message "=== tip-latex corpus: %d files ===" n)
      (let* ((results (mapcar #'corpus--process-file files))
             (total-frags (apply #'+ (mapcar (lambda (r) (plist-get r :frags)) results)))
             (total-time  (apply #'+ (mapcar (lambda (r) (plist-get r :elapsed)) results)))
             (total-bytes (apply #'+ (mapcar (lambda (r) (plist-get r :size)) results))))
        (dolist (r results) (message "%s" (corpus--fmt-row r)))
        (message "---")
        (message "  total: %d files, %d bytes, %d fragments, %.1f ms  (%.2f µs/byte)"
                 n total-bytes total-frags (* 1000.0 total-time)
                 (if (zerop total-bytes) 0.0
                   (/ (* 1e6 total-time) total-bytes)))))))

(when noninteractive
  (corpus--run))

;;; 60-latex-arxiv-corpus.el ends here
