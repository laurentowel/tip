;;; tip-test.el --- Integration-test runner for TIP  -*- lexical-binding: t; -*-

;;; Commentary:
;; Tiny harness loaded inside the long-lived emacs daemon that the
;; integration-tests/ suite targets.  One daemon, many specs, each
;; isolated via a reset between tests.
;;
;; Spec files define tests with `tip-test-deftest':
;;
;;     (tip-test-deftest overlay-opens-on-enter
;;       :doc "Entering a fragment shows the source under the cursor."
;;       (tip-test-with-fresh-typst-buffer "$ a + b $\n"
;;         (tip-render-all)
;;         (tip-test-wait-for-pending 10)
;;         (goto-char (tip-test-inside-fragment 0))
;;         (should (tip-test-overlay-showing-source-p))))
;;
;; Run all registered tests with `tip-test-run-all', which returns a
;; result plist.  `run.sh' calls this via emacsclient and prints the
;; summary.

;;; Code:

(require 'cl-lib)
(require 'ert)              ; only for `should' semantics
(require 'treesit)
(require 'typst-ts-mode nil t)
(require 'tip)
(require 'tip-typst nil t)
(require 'tip-latex nil t)

(defvar tip-test--tests nil
  "Alist of (NAME . PLIST) registered via `tip-test-deftest'.
PLIST carries :fn, :doc, :file — NAME and :fn are always present.")

(defvar tip-test--per-test-timeout 90
  "Hard timeout per test, in seconds.  A hung test fails instead of
stalling the whole suite.")

;;; ---- spec registration ----

(defmacro tip-test-deftest (name &rest body)
  "Register NAME as a test with BODY.  BODY can start with a keyword
plist; supported keys:
  :doc STRING       — short description printed in the report
  :tags (SYMBOLS…)  — tags (unused for now, reserved)

The rest is the test body."
  (declare (indent 1) (doc-string 2))
  (let* ((plist nil))
    (while (keywordp (car body))
      (push (pop body) plist)
      (push (pop body) plist))
    (setq plist (nreverse plist))
    `(let ((entry (list :fn (lambda () ,@body)
                        :doc ,(or (plist-get plist :doc) "")
                        :tags ',(plist-get plist :tags)
                        :file load-file-name)))
       (setf (alist-get ',name tip-test--tests) entry)
       ',name)))

;;; ---- reset between tests ----

(defun tip-test-reset ()
  "Kill server process, temp buffers, and pending state."
  (when (and (boundp 'tip--server-process)
             tip--server-process
             (process-live-p tip--server-process))
    (ignore-errors (tip-shutdown)))
  (dolist (buf (buffer-list))
    (when (string-prefix-p "*tip-test-" (buffer-name buf))
      (with-current-buffer buf (set-buffer-modified-p nil))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf))))
  (when (boundp 'tip--pending-callbacks)
    (clrhash tip--pending-callbacks))
  (when (fboundp 'tip--cache-clear) (tip--cache-clear))
  ;; Clear any overlay in the current buffer too.
  (remove-overlays))

;;; ---- helpers for spec writers ----

(defun tip-test-wait-for-pending (&optional deadline-s)
  "Block until no pending server callbacks, or DEADLINE-S seconds pass."
  (let ((deadline (+ (float-time) (or deadline-s 10))))
    (while (and (< (float-time) deadline)
                (boundp 'tip--server-process)
                tip--server-process
                (process-live-p tip--server-process)
                (boundp 'tip--pending-callbacks)
                (> (hash-table-count tip--pending-callbacks) 0))
      (accept-process-output tip--server-process 0.1)
      (redisplay t))))

(defun tip-test-fragment-ranges ()
  "Return the tree-sitter math fragment ranges in the current buffer.
For typst-ts-mode buffers only."
  (treesit-query-range 'typst "((math) @math)"))

(defun tip-test-inside-fragment (index)
  "Return a buffer position one past the opener of the INDEX-th
math fragment (0-based).  For Typst `$...$', that's the position
immediately after the opening `$'."
  (1+ (car (nth index (tip-test-fragment-ranges)))))

(defun tip-test-after-fragment (index)
  "Return the buffer position just after the INDEX-th fragment's closer."
  (min (1+ (cdr (nth index (tip-test-fragment-ranges))))
       (point-max)))

(defun tip-test-overlay-showing-image-p (&optional pos)
  "Return non-nil if there's a TIP overlay at POS (or point) whose
`display' property is a rendered SVG image."
  (let ((p (or pos (point))))
    (seq-some (lambda (ov)
                (and (eq (overlay-get ov 'tip) 'tip)
                     (let ((disp (overlay-get ov 'display)))
                       (and (consp disp) (eq (car disp) 'image)))))
              (overlays-at p))))

(defun tip-test-simulate-command (cmd pos)
  "Simulate running COMMAND (a symbol) that moves point to POS.
Fires pre-command and post-command hooks so preview-toggle sees
the transition as a genuine interactive movement."
  (let ((this-command cmd))
    (run-hooks 'pre-command-hook)
    (goto-char pos)
    (let ((this-command cmd))
      (run-hooks 'post-command-hook))
    (redisplay t)))

(defmacro tip-test-with-fresh-typst-buffer (content &rest body)
  "Create a fresh .typ buffer filled with CONTENT, activate
typst-ts-mode + tip-mode, then run BODY.  The buffer is killed
after BODY (or on error).  The buffer is named `*tip-test-<N>*'
so `tip-test-reset' can find and kill it."
  (declare (indent 1))
  `(let* ((file (make-temp-file "tip-test-" nil ".typ"))
          (buf (generate-new-buffer "*tip-test-typst*")))
     (unwind-protect
         (with-current-buffer buf
           (setq buffer-file-name file)
           (insert ,content)
           (typst-ts-mode)
           (tip-mode 1)
           (when (fboundp 'tip-live-mode) (tip-live-mode -1))
           ;; Make the buffer visible in whatever frame the user is
           ;; watching, so test actions are observable.
           (when-let ((win (get-buffer-window buf t)))
             (select-window win))
           (display-buffer buf '((display-buffer-reuse-window
                                  display-buffer-pop-up-window))
                           '((inhibit-same-window . nil)))
           ,@body)
       (when (buffer-live-p buf)
         (with-current-buffer buf (set-buffer-modified-p nil))
         (let ((kill-buffer-query-functions nil))
           (kill-buffer buf)))
       (ignore-errors (delete-file file)))))

(defmacro tip-test-with-fresh-latex-buffer (content &rest body)
  "LaTeX counterpart of `tip-test-with-fresh-typst-buffer'."
  (declare (indent 1))
  `(let* ((file (make-temp-file "tip-test-" nil ".tex"))
          (buf (generate-new-buffer "*tip-test-latex*")))
     (unwind-protect
         (with-current-buffer buf
           (setq buffer-file-name file)
           (insert ,content)
           (latex-mode)
           (tip-mode 1)
           (when (fboundp 'tip-live-mode) (tip-live-mode -1))
           (display-buffer buf '((display-buffer-reuse-window
                                  display-buffer-pop-up-window))
                           '((inhibit-same-window . nil)))
           ,@body)
       (when (buffer-live-p buf)
         (with-current-buffer buf (set-buffer-modified-p nil))
         (let ((kill-buffer-query-functions nil))
           (kill-buffer buf)))
       (ignore-errors (delete-file file)))))

;;; ---- runner ----

(defun tip-test-run-one (name)
  "Run the test registered under NAME.  Returns a plist
\\='(:name NAME :status STATUS :error ERR :elapsed SECONDS)
where STATUS is one of `pass', `fail', `error', `timeout'."
  (let* ((entry (alist-get name tip-test--tests))
         (fn (plist-get entry :fn))
         (start (float-time))
         (status 'pass)
         (errmsg nil))
    (unless fn
      (error "No such test: %s" name))
    (tip-test-reset)
    (condition-case err
        (with-timeout (tip-test--per-test-timeout
                       (setq status 'timeout
                             errmsg (format "exceeded %ds" tip-test--per-test-timeout)))
          (funcall fn))
      (ert-test-failed
       (setq status 'fail errmsg (format "%S" (cdr err))))
      (error
       (setq status 'error errmsg (format "%S" err))))
    (list :name name :status status :error errmsg
          :elapsed (- (float-time) start))))

(defun tip-test-run-all ()
  "Run every registered test in order of registration.  Returns
a plist (:results LIST :passed N :failed N)."
  (let ((results nil) (passed 0) (failed 0))
    (dolist (cell (reverse tip-test--tests))
      (let* ((name (car cell))
             (r (tip-test-run-one name)))
        (push r results)
        (if (eq (plist-get r :status) 'pass)
            (cl-incf passed)
          (cl-incf failed))))
    (list :results (nreverse results) :passed passed :failed failed)))

(defun tip-test-format-summary (summary)
  "Pretty-print a SUMMARY plist as a multi-line string."
  (let ((lines nil))
    (push (format "  passed: %d  failed: %d"
                  (plist-get summary :passed)
                  (plist-get summary :failed))
          lines)
    (dolist (r (plist-get summary :results))
      (push (format "  [%-5s] %-45s %.2fs%s"
                    (upcase (symbol-name (plist-get r :status)))
                    (symbol-name (plist-get r :name))
                    (plist-get r :elapsed)
                    (if (plist-get r :error)
                        (format "  — %s" (plist-get r :error))
                      ""))
            lines))
    (push "" lines)
    (push "tip integration-tests" lines)
    (mapconcat #'identity (reverse lines) "\n")))

(defun tip-test-load-specs (dir)
  "Load every .el file in DIR so their tests register."
  (dolist (f (directory-files dir t "\\.el\\'"))
    (load f nil t)))

(provide 'tip-test)
;;; tip-test.el ends here
