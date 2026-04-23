;;; test-tip.el --- Automated tests for tip.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: emacs --batch -l test-tip.el

;;; Code:

(require 'ert)

;; Add directory to load-path so (require 'preview-toggle) works
(add-to-list 'load-path (file-name-directory load-file-name))
(load (expand-file-name "tip.el" (file-name-directory load-file-name)))

;;; * Byte compilation

(ert-deftest tip-test-byte-compile ()
  "tip.el should byte-compile without errors or warnings."
  (let ((byte-compile-error-on-warn t)
        (tip-el (expand-file-name "tip.el" (file-name-directory load-file-name))))
    (should (byte-compile-file tip-el))))

;;; * Loading and basic definitions

(ert-deftest tip-test-feature-provided ()
  (should (featurep 'tip)))

(ert-deftest tip-test-customization-vars-exist ()
  (should (boundp 'tip-enable-debug))
  (should (boundp 'tip-server-executable))
  (should (boundp 'tip-scale)))

(ert-deftest tip-test-customization-defaults ()
  (should (eq tip-enable-debug nil))
  (should (or (null tip-server-executable) (stringp tip-server-executable)))
  (should (numberp tip-scale))
  (should (> tip-scale 0)))

(ert-deftest tip-test-interactive-commands-exist ()
  (should (fboundp 'tip-ensure))
  (should (fboundp 'tip-render-all))
  (should (fboundp 'tip-send-nbd))
  (should (fboundp 'tip-send-all))
  (should (fboundp 'tip-open))
  (should (fboundp 'tip-clear-region))
  (should (fboundp 'tip-clear-buffer))
  (should (fboundp 'tip-clear-all))
  (should (fboundp 'tip-shutdown))
  (should (fboundp 'tip-live-setup))
  (should (fboundp 'tip-live-teardown))
  (should (fboundp 'tip-mode)))

;;; * Image spec building

(ert-deftest tip-test-make-image-spec ()
  "Image spec should have correct structure and reasonable ascent."
  (let ((spec (tip--make-image-spec "<svg></svg>" 12.0 2.0)))
    (should (consp spec))
    (let ((img (car spec)))
      (should (eq (car img) 'image))
      (should (eq (plist-get (cdr img) :type) 'svg))
      (should (stringp (plist-get (cdr img) :data)))
      (let ((ascent (plist-get (cdr img) :ascent)))
        (should (or (eq ascent 'center)
                    (and (numberp ascent) (>= ascent 0) (<= ascent 100)))))
      (should (consp (plist-get (cdr img) :height)))
      (should (> (car (plist-get (cdr img) :height)) 0)))))

;;; * Request ID generation

(ert-deftest tip-test-request-ids-increment ()
  (let ((tip--request-id 0))
    (should (= (tip--next-id) 1))
    (should (= (tip--next-id) 2))
    (should (= (tip--next-id) 3))))

;;; * Server process integration

(ert-deftest tip-test-server-spawn-and-shutdown ()
  "Should spawn tip-server, communicate, and shut down cleanly."
  (let* ((tip-server-executable
          (expand-file-name
           "tip-server/target/debug/tip-server-typst"
           (file-name-directory load-file-name)))
         (tip-use-docker nil)
         (tip--server-process nil)
         (tip--request-id 0)
         (tip--response-buffer "")
         (tip--pending-callbacks (make-hash-table :test 'eql))
         (response nil)
         (got-response nil))
    (unless (file-executable-p tip-server-executable)
      (ert-skip "tip-server binary not built"))
    (tip-ensure)
    (should (process-live-p tip--server-process))
    ;; Sync
    (tip--send-request
     "sync"
     '(("uri" . "/tmp/test.typ") ("content" . "$a + b$"))
     (lambda (result)
       (setq response result)
       (setq got-response t)))
    (with-timeout (5 (error "timeout"))
      (while (not got-response)
        (accept-process-output tip--server-process 0.1)))
    (should got-response)
    (should (eq (alist-get 'ok response) t))
    ;; Compile
    (setq got-response nil response nil)
    (tip--send-request
     "compile_fragments"
     '(("uri" . "/tmp/test.typ")
       ("fragments" . [((start . 0) (end . 7))])
       ("color" . "#000000"))
     (lambda (result)
       (setq response result)
       (setq got-response t)))
    (with-timeout (10 (error "timeout"))
      (while (not got-response)
        (accept-process-output tip--server-process 0.1)))
    (should got-response)
    (let ((frags (alist-get 'fragments response)))
      (should (> (length frags) 0))
      (should (stringp (alist-get 'svg (aref frags 0))))
      (should (string-match-p "<svg" (alist-get 'svg (aref frags 0))))
      (should (> (alist-get 'height_pt (aref frags 0)) 0)))
    ;; Shutdown
    (tip--send-request "shutdown" nil)
    (sit-for 1)
    (should (not (process-live-p tip--server-process)))))

;;; * Overlay management

(ert-deftest tip-test-clear-region-removes-tip-overlays ()
  (with-temp-buffer
    (insert "hello $a+b$ world")
    (let ((ov (make-overlay 7 12)))
      (overlay-put ov 'tip 'tip))
    (let ((ov (make-overlay 1 5)))
      (overlay-put ov 'face 'bold))
    (should (= (length (overlays-in (point-min) (point-max))) 2))
    (tip-clear-region (point-min) (point-max))
    (should (= (length (overlays-in (point-min) (point-max))) 1))))

(ert-deftest tip-test-clear-buffer-removes-all-tip-overlays ()
  (with-temp-buffer
    (insert "hello $a+b$ world $c+d$ end")
    (let ((ov1 (make-overlay 7 12))
          (ov2 (make-overlay 19 24)))
      (overlay-put ov1 'tip 'tip)
      (overlay-put ov2 'tip 'tip))
    (should (= (length (overlays-in (point-min) (point-max))) 2))
    (tip-clear-buffer)
    (should (= (length (overlays-in (point-min) (point-max))) 0))))

;;; * Figure rendering (tip-render-figure)

(defun tip-test--setup-typst-buffer (content)
  "Insert CONTENT into the current buffer and attach a typst treesit parser.
Caller is responsible for being inside a `with-temp-buffer'."
  (unless (treesit-language-available-p 'typst)
    (ert-skip "typst tree-sitter grammar not installed"))
  (insert content)
  (treesit-parser-create 'typst))

(defun tip-test--fragment-texts ()
  "Return list of fragment substrings from `tip-collect-fragment-locations'.
Converts byte offsets back to character positions."
  (mapcar (lambda (frag)
            (let* ((sbyte (1+ (alist-get "start" frag nil nil #'equal)))
                   (ebyte (1+ (alist-get "end" frag nil nil #'equal)))
                   (s (byte-to-position sbyte))
                   (e (byte-to-position ebyte)))
              (buffer-substring-no-properties s e)))
          (tip-collect-fragment-locations (point-min) (point-max))))

(ert-deftest tip-test-figure-with-diagram-flag-off ()
  "With `tip-render-figure' nil, a bare #figure(...) — even containing a
diagram call — produces no fragments.  Non-math content is only rendered
when wrapped in a figure AND the flag is on."
  (with-temp-buffer
    (tip-test--setup-typst-buffer
     "#figure(\n  diagram(node((0,0), [A])),\n  caption: [c],\n)\n")
    (let ((tip-render-figure nil))
      (should (null (tip-collect-fragment-locations (point-min) (point-max)))))))

(ert-deftest tip-test-figure-with-diagram-flag-on ()
  "With `tip-render-figure' t, the whole #figure is the fragment; inner
diagram and math are swallowed."
  (with-temp-buffer
    (tip-test--setup-typst-buffer
     "#figure(\n  diagram(node((0,0), [A])),\n  caption: [c],\n)\n")
    (let ((tip-render-figure t))
      (let ((texts (tip-test--fragment-texts)))
        (should (= 1 (length texts)))
        (should (string-prefix-p "#figure(" (car texts)))
        (should (string-match-p "caption" (car texts)))))))

(ert-deftest tip-test-figure-with-image-flag-off ()
  "With `tip-render-figure' nil, a figure wrapping an image is not rendered."
  (with-temp-buffer
    (tip-test--setup-typst-buffer
     "#figure(\n  image(\"foo.png\"),\n  caption: [c],\n)\n")
    (let ((tip-render-figure nil))
      (should (null (tip-collect-fragment-locations (point-min) (point-max)))))))

(ert-deftest tip-test-figure-with-image-flag-on ()
  "With `tip-render-figure' t, a figure wrapping an image IS rendered as a
single fragment — body type doesn't matter."
  (with-temp-buffer
    (tip-test--setup-typst-buffer
     "#figure(\n  image(\"foo.png\"),\n  caption: [c],\n)\n")
    (let ((tip-render-figure t))
      (let ((texts (tip-test--fragment-texts)))
        (should (= 1 (length texts)))
        (should (string-prefix-p "#figure(" (car texts)))
        (should (string-match-p "image(" (car texts)))))))

(ert-deftest tip-test-figure-swallows-inner-math ()
  "With `tip-render-figure' t, math inside a figure is filtered as nested."
  (with-temp-buffer
    (tip-test--setup-typst-buffer
     "#figure($ integral_0^1 f $, caption: [c])\n\n$ a + b $\n")
    (let ((tip-render-figure t))
      (let ((texts (tip-test--fragment-texts)))
        (should (= 2 (length texts)))
        (should (cl-some (lambda (s) (string-prefix-p "#figure(" s)) texts))
        (should (cl-some (lambda (s) (string-match-p "a \\+ b" s)) texts))
        ;; The inner `$ integral $` must NOT appear as its own fragment.
        (should-not (cl-some (lambda (s)
                               (and (string-prefix-p "$" s)
                                    (string-match-p "integral" s)))
                             texts))))))

(ert-deftest tip-test-figure-bounds-at-point-flag-on ()
  "With `tip-render-figure' t, a position inside a nested call resolves
to the enclosing figure's bounds."
  (with-temp-buffer
    (tip-test--setup-typst-buffer
     "#figure(\n  diagram(node((0,0), [A])),\n  caption: [c],\n)\n")
    (let ((tip-render-figure t))
      (goto-char (point-min))
      (search-forward "node")
      (let* ((pos (point))
             (bounds (tip--get-bounds-of-math-at-point pos))
             (text (and bounds
                        (buffer-substring-no-properties (car bounds) (cdr bounds)))))
        (should bounds)
        (should (string-prefix-p "#figure(" text))
        (should (string-match-p "caption" text))))))

(ert-deftest tip-test-figure-bounds-at-point-flag-off ()
  "With `tip-render-figure' nil, a position inside a non-math call inside
a figure returns nil (nothing renderable there)."
  (with-temp-buffer
    (tip-test--setup-typst-buffer
     "#figure(\n  diagram(node((0,0), [A])),\n  caption: [c],\n)\n")
    (let ((tip-render-figure nil))
      (goto-char (point-min))
      (search-forward "node")
      (should (null (tip--get-bounds-of-math-at-point (point)))))))

;;; Run tests

(when noninteractive
  (ert-run-tests-batch-and-exit))

;;; test-tip.el ends here
