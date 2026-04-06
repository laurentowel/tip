;;; test-highlight-fragments.el --- Visual flash of detected fragments -*- lexical-binding: t; -*-

;;; Commentary:
;; Highlights each math fragment tip will render with a brief flash,
;; like the beacon package. Shows what tip "sees" before compiling.
;;
;; Run:
;;   emacs -Q --init-directory tests/emacs-sandbox -l tests/test-highlight-fragments.el

;;; Code:

(require 'package)
(package-initialize)
(setq create-lockfiles nil make-backup-files nil auto-save-default nil)

(unless (package-installed-p 'typst-ts-mode)
  (package-vc-install
   '(typst-ts-mode :url "https://codeberg.org/meow_king/typst-ts-mode")))
(require 'typst-ts-mode)
(unless (treesit-language-available-p 'typst)
  (setq treesit-language-source-alist
        '((typst "https://github.com/uben0/tree-sitter-typst")))
  (treesit-install-language-grammar 'typst))

(let ((base (file-name-directory load-file-name)))
  (setq tip-server-executable
        (expand-file-name "../tip-server/target/release/tip-server" base))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base)))

;; --- Flash effect ---

(defface tip-flash-inline
  '((t :background "#3a5f3a" :extend t))
  "Face for flashing inline math fragments.")

(defface tip-flash-display
  '((t :background "#3a3a5f" :extend t))
  "Face for flashing display math fragments.")

(defface tip-flash-error
  '((t :background "#5f3a3a" :extend t))
  "Face for fragments that fail to compile.")

(defvar tip-flash--overlays nil
  "Active flash overlays.")

(defun tip-flash--clear ()
  "Remove all flash overlays."
  (mapc #'delete-overlay tip-flash--overlays)
  (setq tip-flash--overlays nil))

(defun tip-flash--fragment (beg end face &optional duration)
  "Flash region BEG..END with FACE for DURATION seconds."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'face face)
    (overlay-put ov 'tip-flash t)
    (push ov tip-flash--overlays)
    (redisplay t)
    (when duration
      (run-with-timer duration nil
                      (lambda ()
                        (when (overlay-buffer ov)
                          (delete-overlay ov)))))))

(defun tip-flash-all-fragments ()
  "Flash all math fragments detected by tree-sitter.
Green = inline, Blue = display.
Then compile each and flash red if it fails."
  (interactive)
  (tip-flash--clear)
  (let* ((ranges (treesit-query-range 'typst "((math) @math)"))
         ;; Filter nested (same as tip-collect-fragment-locations)
         (outer (seq-filter
                 (lambda (r)
                   (not (seq-find
                         (lambda (o)
                           (and (not (equal o r))
                                (<= (car o) (car r))
                                (>= (cdr o) (cdr r))))
                         ranges)))
                 ranges))
         (total (length outer))
         (idx 0))

    (message "Flashing %d fragments..." total)

    ;; Phase 1: flash all green/blue
    (dolist (range outer)
      (let* ((beg (car range))
             (end (cdr range))
             (content (buffer-substring-no-properties beg end))
             (is-display (and (>= (length content) 2)
                              (eq (aref content 0) ?$)
                              (memq (aref content 1) '(?\s ?\t ?\n))))
             (face (if is-display 'tip-flash-display 'tip-flash-inline)))
        (tip-flash--fragment beg end face)))
    (redisplay t)
    (sleep-for 1.5)

    ;; Phase 2: compile each, flash red on failure
    (tip-flash--clear)
    (tip-ensure)
    (sleep-for 0.5)
    (accept-process-output tip--server-process 1)
    (tip--sync-buffer)
    (accept-process-output tip--server-process 1)

    (let ((ok 0) (fail 0))
      (dolist (range outer)
        (let* ((beg (car range))
               (end (cdr range))
               (content (buffer-substring-no-properties beg end))
               (byte-start (1- (position-bytes beg)))
               (byte-end (1- (position-bytes end)))
               (done nil)
               (success nil))

          ;; Compile this fragment
          (tip--send-request
           "compile_fragments"
           `(("uri" . ,(buffer-file-name))
             ("fragments" . ,(vector `(("start" . ,byte-start) ("end" . ,byte-end))))
             ("color" . ,(tip--color-to-hex (face-attribute 'default :foreground)))
             ("preamble" . ,(tip--build-preamble)))
           (lambda (result)
             (let ((frags (alist-get 'fragments result)))
               (setq success (and frags (> (length frags) 0)
                                  (> (length (alist-get 'svg (aref frags 0))) 0))))
             (setq done t)))

          ;; Wait
          (let ((deadline (+ (float-time) 5)))
            (while (and (not done) (< (float-time) deadline))
              (accept-process-output tip--server-process 0.05)))

          (cl-incf idx)
          (if success
              (progn
                (cl-incf ok)
                (tip-flash--fragment beg end 'tip-flash-inline 0.3))
            (cl-incf fail)
            (tip-flash--fragment beg end 'tip-flash-error 2.0)
            (message "FAIL [%d/%d]: %s" idx total
                     (if (> (length content) 50)
                         (concat (substring content 0 47) "...")
                       content)))
          (redisplay t)
          (sleep-for 0.15)))

      (message "Done: %d/%d compiled, %d failed" ok total fail))))

;; --- Open file and run ---

(let ((base (file-name-directory load-file-name)))
  (find-file (expand-file-name
              "../tip-server/crates/tip-core/tests/fixtures/list_math.typ"
              base)))
(switch-to-buffer (current-buffer))
(typst-ts-mode)

;; Flash on load, then enable tip-mode
(run-with-timer 1.0 nil
  (lambda ()
    (tip-flash-all-fragments)
    (run-with-timer 2.0 nil
      (lambda ()
        (tip-mode 1)
        (message "Fragments flashed. tip-mode enabled. M-x tip-flash-all-fragments to re-flash.")))))

(message "Loading... fragments will flash in 1s")
