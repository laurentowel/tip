;;; test-diagrams.el --- Visual test for CeTZ and Fletcher diagram preview -*- lexical-binding: t; -*-

;;; Commentary:
;; Opens diagrams.typ, flashes detected fragments (math + diagrams),
;; compiles all, reports success/failure.
;;
;; Run:
;;   emacs -Q --init-directory tests/emacs-sandbox -l tests/test-diagrams.el

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

(setq tip-enable-debug nil)

;; --- Flash helpers ---

(defface test-flash-math '((t :background "#3a5f3a")) "Math flash.")
(defface test-flash-diagram '((t :background "#5f5f3a")) "Diagram flash.")
(defface test-flash-ok '((t :background "#2a4a2a")) "Success flash.")
(defface test-flash-fail '((t :background "#5f2a2a")) "Failure flash.")

(defvar test--results nil)

(defun test--log (fmt &rest args)
  (push (apply #'format fmt args) test--results))

;; --- Open file ---

(let ((base (file-name-directory load-file-name)))
  (find-file (expand-file-name
              "../tip-server/crates/tip-core/tests/fixtures/diagrams.typ"
              base)))
(switch-to-buffer (current-buffer))
(typst-ts-mode)

;; Wait for mode to settle
(sleep-for 0.5)

;; --- Detect fragments ---

(let* ((math-ranges (treesit-query-range 'typst "((math) @math)"))
       (diagram-ranges
        (when tip-diagram-functions
          (let ((root (treesit-buffer-root-node 'typst)))
            (when root
              (tip--collect-diagram-ranges root (point-min) (point-max) nil)))))
       (all-ranges (append math-ranges diagram-ranges))
       ;; Filter nested
       (outer (seq-filter
               (lambda (r)
                 (not (seq-find
                       (lambda (o)
                         (and (not (equal o r))
                              (<= (car o) (car r))
                              (>= (cdr o) (cdr r))))
                       all-ranges)))
               all-ranges)))

  (test--log "=== Diagram Preview Test ===")
  (test--log "Math fragments: %d" (length math-ranges))
  (test--log "Diagram fragments: %d" (length diagram-ranges))
  (test--log "Total (after nesting filter): %d" (length outer))

  ;; Phase 1: Flash all detected fragments
  (dolist (r outer)
    (let* ((text (buffer-substring-no-properties (car r) (min (+ (car r) 5) (cdr r))))
           (is-diagram (string-prefix-p "#" text))
           (face (if is-diagram 'test-flash-diagram 'test-flash-math))
           (ov (make-overlay (car r) (cdr r))))
      (overlay-put ov 'face face)
      (overlay-put ov 'test-flash t)))
  (redisplay t)
  (sleep-for 2)

  ;; Clear flashes
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'test-flash)
      (delete-overlay ov)))

  ;; Phase 2: Enable tip-mode and render
  (tip-mode 1)
  (sleep-for 1)

  ;; Manually compile all fragments
  (tip--sync-buffer)
  (accept-process-output tip--server-process 2)

  (let* ((frag-locs (tip-collect-fragment-locations (point-min) (point-max)))
         (fg (tip--color-to-hex (face-attribute 'default :foreground)))
         (preamble (tip--build-preamble))
         (done nil)
         (compile-result nil))
    (tip--send-request
     "compile_fragments"
     `(("uri" . ,(buffer-file-name))
       ("fragments" . ,(vconcat frag-locs))
       ("color" . ,fg)
       ("preamble" . ,preamble))
     (lambda (result)
       (setq compile-result result)
       (setq done t)))

    ;; Wait
    (let ((deadline (+ (float-time) 30)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output tip--server-process 0.1)))

    (when done
      (let* ((frags (alist-get 'fragments compile-result))
             (ok 0) (fail 0))
        (seq-doseq (f frags)
          (let ((svg (alist-get 'svg f))
                (h (alist-get 'height_pt f)))
            (if (and svg (> (length svg) 0) h (> h 0))
                (cl-incf ok)
              (cl-incf fail))))
        (test--log "Compiled: %d OK, %d failed" ok fail)

        ;; Apply overlays
        (tip--apply-fragment-results frags)
        (redisplay t)

        (test--log "Overlays created: %d"
                   (length (seq-filter
                            (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
                            (overlays-in (point-min) (point-max)))))))))

;; Write results
(let ((results-file (expand-file-name
                     "test-diagrams-results.txt"
                     (file-name-directory (or load-file-name ".")))))
  (with-temp-file results-file
    (dolist (line (nreverse test--results))
      (insert line "\n")))
  (message "Results: %s" results-file))

(goto-char (point-min))
(message "Diagram test done. Math=green, Diagrams=yellow. Check overlays.")
