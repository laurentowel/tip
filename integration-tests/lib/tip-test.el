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

(defvar tip-test--inter-test-sleep 0
  "Seconds to sleep between consecutive tests.  Useful when
eye-balling results — with 0 the whole suite can blur past too
fast to watch.  Set via env TIP_IT_SLEEP read at daemon startup.")

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

(defun tip-test--cleanup-extra-windows ()
  "Keep the test frame to a single window.  Any previous test's
buffer is killed in its `unwind-protect'; that leaves an empty
window which we delete here, so each test starts in a single-
window frame."
  (dolist (frame (frame-list))
    (with-selected-frame frame
      (when (and (not (frame-parameter frame 'tip-test--control))
                 (> (length (window-list frame 0)) 1))
        (delete-other-windows (frame-root-window frame))))))

(defun tip-test-reset ()
  "Kill server process, temp buffers, and pending state."
  (tip-test--cleanup-extra-windows)
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
  "Block until no pending server callbacks, or DEADLINE-S seconds pass.
Also drain any just-fired async timers so the rendered-overlay
state is settled before the test asserts on it."
  (let ((deadline (+ (float-time) (or deadline-s 10))))
    (while (and (< (float-time) deadline)
                (boundp 'tip--server-process)
                tip--server-process
                (process-live-p tip--server-process)
                (boundp 'tip--pending-callbacks)
                (> (hash-table-count tip--pending-callbacks) 0))
      (accept-process-output tip--server-process 0.1)
      (redisplay t)))
  ;; Give the response filter's callback (which creates overlays)
  ;; one more chance to run after the process-output loop exits.
  (sit-for 0.05)
  (redisplay t))

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
`display' property renders an SVG image.

The display spec produced by `tip--make-image-spec' is a list like
`((image :type svg :data ...))' — i.e. a LIST of specs where the
first element is itself a list starting with `image'.  Accept both
that shape and the bare `(image ...)' form, since emacs accepts
both as a display property."
  (let ((p (or pos (point))))
    (seq-some (lambda (ov)
                (and (eq (overlay-get ov 'tip) 'tip)
                     (let ((disp (overlay-get ov 'display)))
                       (cond
                        ((null disp) nil)
                        ;; ((image ...) [...]) — current tip shape.
                        ((and (consp disp) (consp (car disp))
                              (eq (car (car disp)) 'image))
                         t)
                        ;; (image ...) — bare spec.
                        ((eq (car-safe disp) 'image) t)))))
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
           ;; Rotate the test buffer INTO the selected window rather
           ;; than splitting off a new one each time.  pop-to-buffer-
           ;; same-window is aggressive enough to take over any
           ;; dedicated/minibuffer concern.
           (pop-to-buffer-same-window buf)
           ;; Buffer-local header-line showing what this test does.
           (setq-local header-line-format
                       '(:eval (tip-test--header-line)))
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
           ;; Rotate the test buffer INTO the selected window rather
           ;; than splitting off a new one each time.  pop-to-buffer-
           ;; same-window is aggressive enough to take over any
           ;; dedicated/minibuffer concern.
           (pop-to-buffer-same-window buf)
           ;; Buffer-local header-line showing what this test does.
           (setq-local header-line-format
                       '(:eval (tip-test--header-line)))
           ,@body)
       (when (buffer-live-p buf)
         (with-current-buffer buf (set-buffer-modified-p nil))
         (let ((kill-buffer-query-functions nil))
           (kill-buffer buf)))
       (ignore-errors (delete-file file)))))

;;; ---- runner ----

(defvar tip-test--current-name nil
  "Name of the test currently running, for header-line display.")

(defvar tip-test--current-doc nil
  "Docstring of the running test, for header-line display.")

(defface tip-test-header-name
  '((t :weight bold :inherit warning :height 1.15))
  "Face for the running test's name in the header-line.")

(defface tip-test-header-doc
  '((t :weight normal :inherit shadow))
  "Face for the running test's docstring in the header-line.")

(defun tip-test--header-line ()
  "Header-line format showing the active test and its docstring.
Uses a newline so the test name stays prominent and the doc gets
its own row underneath."
  (when tip-test--current-name
    (concat
     (propertize (format " ◉ %s " (symbol-name tip-test--current-name))
                 'face 'tip-test-header-name)
     (when (and tip-test--current-doc
                (not (string-empty-p tip-test--current-doc)))
       (concat "\n "
               (propertize tip-test--current-doc
                           'face 'tip-test-header-doc))))))

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
    (setq tip-test--current-name name
          tip-test--current-doc (plist-get entry :doc))
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
a plist (:results LIST :passed N :failed N).  Pauses
`tip-test--inter-test-sleep' seconds between tests so a human
watching the frame can see each result settle before the next
takes over."
  (let ((results nil) (passed 0) (failed 0)
        (tests (reverse tip-test--tests))
        (last (car (last (reverse tip-test--tests)))))
    (dolist (cell tests)
      (let* ((name (car cell))
             (r (tip-test-run-one name)))
        (push r results)
        (if (eq (plist-get r :status) 'pass)
            (cl-incf passed)
          (cl-incf failed))
        ;; Pause between tests (but not after the last one).
        (when (and (> tip-test--inter-test-sleep 0)
                   (not (eq cell last)))
          (redisplay t)
          (sleep-for tip-test--inter-test-sleep))))
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
