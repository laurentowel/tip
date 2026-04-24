;;; batch.el --- Run tip-mode against one paper, print one JSON line  -*- lexical-binding: t; -*-

;; Usage:
;;   emacs --batch -Q -l batch.el --eval '(tip-sampler-run ROOT-TEX-PATH ID)'
;;
;; ROOT is the absolute path to the paper's main .tex file.
;; ID is a short identifier (e.g. the arxiv number) for the report row.
;; Prints one JSON object to stdout on the line `ARXIV-SAMPLE: {...}'.
;; Exit code is 0 always — the report captures failures as data.

(require 'json)
(require 'seq)

(defvar tip-sampler-repo (or (getenv "TIP_REPO")
                             (expand-file-name "..")
                             (expand-file-name ".")))

(defun tip-sampler--load-tip ()
  (add-to-list 'load-path tip-sampler-repo)
  (unless (getenv "TIP_SERVER_EXECUTABLE_OK")
    (setq tip-server-executable
          (or (getenv "TIP_SERVER_EXECUTABLE")
              (expand-file-name "tip-server/target/release/tip-server"
                                tip-sampler-repo))))
  (setq tip-verbose nil tip-enable-debug nil)
  (load (expand-file-name "tip.el" tip-sampler-repo) nil t))

(defun tip-sampler--wait-pending (deadline-s)
  (let ((deadline (+ (float-time) deadline-s)))
    (while (and (< (float-time) deadline)
                (boundp 'tip--pending-callbacks)
                tip--server-process
                (process-live-p tip--server-process)
                (> (hash-table-count tip--pending-callbacks) 0))
      (accept-process-output tip--server-process 0.2))))

(defun tip-sampler-run (root-path id)
  "Render ROOT-PATH with tip-mode; print an `ARXIV-SAMPLE:' JSON line."
  (tip-sampler--load-tip)
  (setq root-path (expand-file-name root-path))
  (let* ((t0 (float-time))
         (summary
          (condition-case err
              (with-current-buffer (find-file-noselect root-path)
                (latex-mode)
                (setq-local tip-project-root-path root-path)
                (tip-mode 1)
                (let ((nfrags (length (tip-latex-collect-fragments
                                       (point-min) (point-max)))))
                  (tip-render-all)
                  (tip-sampler--wait-pending 180)
                  (let* ((ovs (seq-filter
                               (lambda (o) (eq (overlay-get o 'tip) 'tip))
                               (overlays-in (point-min) (point-max))))
                         (with-img (seq-filter
                                    (lambda (o) (overlay-get o 'display)) ovs))
                         ;; A fragment that rendered with a warning
                         ;; attached is still a success; `errored' is
                         ;; reserved for real failures (no image).
                         (errored (seq-filter
                                   (lambda (o)
                                     (and (overlay-get o 'tip-error-message)
                                          (not (overlay-get o 'display))))
                                   ovs))
                         (warned (seq-filter
                                  (lambda (o)
                                    (and (overlay-get o 'tip-error-message)
                                         (overlay-get o 'display)))
                                  ovs))
                         (sample-err (and errored
                                          (overlay-get (car errored)
                                                       'tip-error-message))))
                    `((id . ,id)
                      (root . ,root-path)
                      (detected . ,nfrags)
                      (rendered . ,(length with-img))
                      (warned . ,(length warned))
                      (errored . ,(length errored))
                      (first-error . ,(or sample-err :null))
                      (elapsed . ,(- (float-time) t0))))))
            (error
             `((id . ,id)
               (root . ,root-path)
               (detected . 0)
               (rendered . 0)
               (errored . 0)
               (first-error . ,(format "HARNESS: %S" err))
               (elapsed . ,(- (float-time) t0)))))))
    (princ (format "ARXIV-SAMPLE: %s\n" (json-encode summary)))))
