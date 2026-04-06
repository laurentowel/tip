;;; test-harness.el --- Error capture harness for GUI tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Wrap test body in `test-harness-run' to capture errors to a file
;; visible from the terminal, even when Emacs runs with a GUI.
;;
;; Usage:
;;   (require 'test-harness)
;;   (test-harness-run "my-test"
;;     (lambda ()
;;       ... test body ...))
;;
;; On error, writes backtrace to tests/<name>-error.txt and exits 1.
;; On success, exits 0.
;; All `message' output is also mirrored to stderr via external-debugging-output.

;;; Code:

(defvar test-harness--base-dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun test-harness--mirror-messages (&rest _)
  "Advice for `message' that copies output to stderr."
  (let ((msg (current-message)))
    (when msg
      (print msg #'external-debugging-output))))

(defun test-harness-run (name body-fn)
  "Run BODY-FN with error capture.  NAME is used for the error file.
On error, writes backtrace to tests/NAME-error.txt and exits 1."
  (let ((error-file (expand-file-name (format "%s-error.txt" name)
                                       test-harness--base-dir)))
    ;; Mirror messages to stderr
    (advice-add 'message :after #'test-harness--mirror-messages)
    ;; Run with error capture
    (condition-case err
        (progn
          (funcall body-fn)
          ;; Clean up error file from previous runs
          (when (file-exists-p error-file)
            (delete-file error-file))
          (kill-emacs 0))
      (error
       (let ((backtrace (with-temp-buffer
                          (insert (format "Error: %S\n\n" err))
                          (insert "Backtrace:\n")
                          (let ((standard-output (current-buffer)))
                            (backtrace))
                          (buffer-string))))
         (with-temp-file error-file
           (insert backtrace))
         (print (format "TEST ERROR: %S (see %s)" err error-file)
                #'external-debugging-output)
         (kill-emacs 1))))))

(provide 'test-harness)

;;; test-harness.el ends here
