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
  (should (boundp 'tip-log-min-level))
  (should (boundp 'tip-server-executable))
  (should (boundp 'tip-scale)))

(ert-deftest tip-test-customization-defaults ()
  (should (eq tip-log-min-level 'info))
  (should (or (null tip-server-executable) (stringp tip-server-executable)))
  ;; tip-scale is 'auto by default (computes scale from font size); allow
  ;; either the sentinel symbol or a positive number.
  (should (or (eq tip-scale 'auto)
              (and (numberp tip-scale) (> tip-scale 0)))))

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
  ;; Live preview became a minor mode rather than paired setup/teardown
  ;; fns — the mode function itself covers both directions.
  (should (fboundp 'tip-live-mode))
  (should (fboundp 'tip-mode))
  ;; New since error-handling arc.
  (should (fboundp 'tip-next-error))
  (should (fboundp 'tip-prev-error))
  (should (fboundp 'tip-flymake-mode)))

;;; * Image spec building

(ert-deftest tip-test-make-image-spec ()
  "Image spec should have correct structure and reasonable ascent."
  ;; In --batch, `face-attribute 'default :font' returns the symbol
  ;; `unspecified', which breaks `font-get' inside tip--make-image-spec.
  ;; The function is exercised by the full e2e live-render test; this
  ;; unit test is kept for GUI runs.
  (unless (display-graphic-p)
    (ert-skip "image spec needs a graphical display"))
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
           "tip-server/target/debug/tip-server"
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

(ert-deftest tip-test-protocol-version-handshake-match ()
  "Init with the actual `tip-protocol-version' should report no mismatch."
  (let* ((tip-server-executable
          (expand-file-name
           "tip-server/target/debug/tip-server"
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
    (tip--send-request
     "init"
     `(("font_dirs" . [])
       ("client_version" . ,tip-protocol-version))
     (lambda (result)
       (setq response result)
       (setq got-response t)))
    (with-timeout (5 (error "timeout"))
      (while (not got-response)
        (accept-process-output tip--server-process 0.1)))
    (should got-response)
    (should (eq (alist-get 'ok response) t))
    (should (string= (alist-get 'server_version response)
                     tip-protocol-version))
    ;; version_mismatch field is omitted when empty (skip_serializing_if).
    (should (or (null (alist-get 'version_mismatch response))
                (string-empty-p (alist-get 'version_mismatch response))))
    (tip--send-request "shutdown" nil)
    (sit-for 1)))

(ert-deftest tip-test-protocol-version-handshake-mismatch ()
  "Init with a fake client_version should come back with a non-empty
`version_mismatch' field naming both sides."
  (let* ((tip-server-executable
          (expand-file-name
           "tip-server/target/debug/tip-server"
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
    (tip--send-request
     "init"
     '(("font_dirs" . [])
       ("client_version" . "9.99-bogus"))
     (lambda (result)
       (setq response result)
       (setq got-response t)))
    (with-timeout (5 (error "timeout"))
      (while (not got-response)
        (accept-process-output tip--server-process 0.1)))
    (should got-response)
    ;; Mismatch is non-fatal — the server still says ok.
    (should (eq (alist-get 'ok response) t))
    (let ((mismatch (alist-get 'version_mismatch response)))
      (should (stringp mismatch))
      (should (not (string-empty-p mismatch)))
      (should (string-match-p "9.99-bogus" mismatch))
      (should (string-match-p tip-protocol-version mismatch)))
    ;; The elisp-side handler should produce a `display-warning' here.
    ;; Capture by binding `display-warning' to a stub.
    (let ((warned nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type _msg &rest _) (setq warned t))))
        (tip--handle-init-response response))
      (should warned))
    (tip--send-request "shutdown" nil)
    (sit-for 1)))

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

;;; * LaTeX backend (tip-latex.el)

(defun tip-latex-test--frag-texts (beg end)
  (mapcar (lambda (frag)
            (let* ((sb (1+ (alist-get "start" frag nil nil #'equal)))
                   (eb (1+ (alist-get "end"   frag nil nil #'equal))))
              (buffer-substring-no-properties
               (byte-to-position sb) (byte-to-position eb))))
          (tip-latex-collect-fragments beg end)))

(ert-deftest tip-latex-test-inline-and-display ()
  (with-temp-buffer
    (insert "Text $a+b$ more \\[ x^2 \\] and \\( y \\) done.\n")
    (let ((texts (tip-latex-test--frag-texts (point-min) (point-max))))
      (should (equal texts '("$a+b$" "\\[ x^2 \\]" "\\( y \\)"))))))

(ert-deftest tip-latex-test-escaped-dollar ()
  "\\$ must not open a math fragment."
  (with-temp-buffer
    (insert "Price \\$5 and $x$ here.\n")
    (let ((texts (tip-latex-test--frag-texts (point-min) (point-max))))
      (should (equal texts '("$x$"))))))

(ert-deftest tip-latex-test-double-dollar ()
  (with-temp-buffer
    (insert "Before $$ a+b $$ after $c$.\n")
    (let ((texts (tip-latex-test--frag-texts (point-min) (point-max))))
      (should (equal (length texts) 2))
      (should (string-match-p "\\$\\$ a\\+b \\$\\$" (car texts)))
      (should (equal (cadr texts) "$c$")))))

(ert-deftest tip-latex-test-skip-comments ()
  (with-temp-buffer
    (latex-mode)
    (insert "Real $x$\n% fake $y$\nmore $z$.\n")
    (let ((texts (tip-latex-test--frag-texts (point-min) (point-max))))
      (should (equal texts '("$x$" "$z$"))))))

(ert-deftest tip-latex-test-skip-verbatim ()
  (with-temp-buffer
    (insert "Before $x$\n")
    (insert "\\begin{verbatim}\ninside $y$ nope\n\\end{verbatim}\n")
    (insert "After $z$.\n")
    (let ((texts (tip-latex-test--frag-texts (point-min) (point-max))))
      (should (equal texts '("$x$" "$z$"))))))

(ert-deftest tip-latex-test-named-environments ()
  (with-temp-buffer
    (insert "\\begin{equation}\n  a + b = c\n\\end{equation}\n")
    (let ((texts (tip-latex-test--frag-texts (point-min) (point-max))))
      (should (= 1 (length texts)))
      (should (string-prefix-p "\\begin{equation}" (car texts)))
      (should (string-match-p "\\\\end{equation}$" (car texts))))))

(ert-deftest tip-latex-test-nested-math-filtered ()
  "Inner $x$ inside \\[...\\] should not appear as a separate fragment."
  (with-temp-buffer
    (insert "\\[ \\text{foo $x$ bar} \\]\n")
    (let ((texts (tip-latex-test--frag-texts (point-min) (point-max))))
      (should (= 1 (length texts)))
      (should (string-prefix-p "\\[" (car texts))))))

(ert-deftest tip-latex-test-bounds-at-point ()
  (with-temp-buffer
    (insert "Text $a+b$ more.")
    (goto-char (point-min))
    (search-forward "a+b")
    (let ((bounds (tip-latex-bounds-at-point (point))))
      (should bounds)
      (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
                     "$a+b$")))))

(ert-deftest tip-latex-test-bounds-at-point-outside ()
  (with-temp-buffer
    (insert "Text $a+b$ more.")
    (goto-char (point-min))
    (should (null (tip-latex-bounds-at-point (point))))))

(ert-deftest tip-latex-test-preamble-extraction ()
  (with-temp-buffer
    (insert "\\documentclass{article}\n")
    (insert "\\usepackage{amsmath}\n")
    (insert "\\newcommand{\\R}{\\mathbb{R}}\n")
    (insert "\\begin{document}\n")
    (insert "$x \\in \\R$\n")
    (insert "\\end{document}\n")
    (let ((preamble (tip-latex-build-preamble)))
      (should (string-match-p "amsmath" preamble))
      (should (string-match-p "\\\\R" preamble))
      (should-not (string-match-p "\\\\begin{document}" preamble)))))

(ert-deftest tip-latex-test-preamble-default-when-no-document ()
  (with-temp-buffer
    (insert "$x$\n")
    (should (equal (tip-latex-build-preamble) tip-latex-default-preamble))))

(ert-deftest tip-latex-test-classify ()
  (should (eq (tip-latex-classify-fragment "$a+b$") 'inline))
  (should (eq (tip-latex-classify-fragment "\\(a\\)") 'inline))
  (should (eq (tip-latex-classify-fragment "\\[x\\]") 'display-single))
  (should (eq (tip-latex-classify-fragment "$$x$$") 'display-single))
  (should (eq (tip-latex-classify-fragment "\\begin{equation}\nx\n\\end{equation}")
              'display-multi)))

(ert-deftest tip-latex-test-collects-fragments-with-includes-present ()
  "TexProject support: \\input/\\include/\\subimport in the buffer no
longer disables the backend.  Collect returns the math fragments;
bounds-at-point resolves on math regardless of nearby includes.
Project-root multi-file machinery handles the include resolution
out-of-band."
  (dolist (cmd '("\\input{macros}" "\\include{chap1}" "\\subimport{sub}{file}"))
    (with-temp-buffer
      (delay-mode-hooks (latex-mode))
      (insert "\\documentclass{article}\n")
      (insert "\\begin{document}\n")
      (insert "$x$ before " cmd " $y$ after.\n")
      (insert "\\end{document}\n")
      (let ((frags (tip-latex-collect-fragments (point-min) (point-max))))
        (should (= 2 (length frags))))
      (goto-char (point-min))
      (search-forward "$x$")
      (should (tip-latex-bounds-at-point (1- (point)))))))

(ert-deftest tip-latex-test-preamble-under-narrowing ()
  "Narrowing to a section shouldn't hide the preamble from extraction."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "\\documentclass{article}\n"
            "\\usepackage{amsmath}\n"
            "\\newcommand{\\R}{\\mathbb{R}}\n"
            "\\begin{document}\n"
            "Section body with $x \\in \\R$ math.\n"
            "\\end{document}\n")
    (let ((body-start (save-excursion
                        (goto-char (point-min))
                        (search-forward "Section body")
                        (line-beginning-position)))
          (body-end (save-excursion
                      (goto-char (point-min))
                      (search-forward "\\end{document}")
                      (line-beginning-position))))
      (narrow-to-region body-start body-end)
      ;; Preamble extraction must ignore narrowing.
      (let ((preamble (tip-latex-build-preamble)))
        (should (string-match-p "\\\\R" preamble))
        (should (string-match-p "amsmath" preamble)))
      ;; Fragment collection respects narrowing — only finds math in the
      ;; narrowed range.
      (should (= 1 (length (tip-latex-collect-fragments
                            (point-min) (point-max))))))))

(ert-deftest tip-latex-test-includes-detected-outside-narrowing ()
  "Detection of \\input in the preamble works regardless of buffer
narrowing — `tip-latex--buffer-has-includes-p' walks the full buffer.
TexProject reads this signal to know the document spans multiple
files; collection no longer refuses on it."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "\\documentclass{article}\n"
            "\\input{macros}\n"
            "\\begin{document}\n"
            "Just math: $a+b$.\n"
            "\\end{document}\n")
    (let ((body-start (save-excursion (goto-char (point-min))
                                       (search-forward "Just math")
                                       (line-beginning-position)))
          (body-end (point-max)))
      (narrow-to-region body-start body-end)
      ;; Detection-still-fires invariant.
      (should (tip-latex--buffer-has-includes-p))
      ;; Collection still produces the fragment; refuse policy gone.
      (should (= 1 (length (tip-latex-collect-fragments
                            (point-min) (point-max))))))))

;;; * Error navigation, eldoc, and Flymake backend

(defun tip-test--mk-error-overlay (beg end severity message &optional hint)
  "Create a tip error overlay in the current buffer for tests."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'tip 'tip)
    (overlay-put ov 'tip-error-severity severity)
    (overlay-put ov 'tip-error-message message)
    (overlay-put ov 'tip-error-hint hint)
    (overlay-put ov 'tip-frag-beg beg)
    (overlay-put ov 'tip-frag-end end)
    (overlay-put ov 'face 'tip-error-face)
    ov))

(ert-deftest tip-test-error-overlays-sorted ()
  "`tip--error-overlays' returns error overlays sorted by start."
  (with-temp-buffer
    (insert "aaaaa bbbbb ccccc ddddd")
    ;; Create overlays out of order.
    (tip-test--mk-error-overlay 13 18 'error "C-error")
    (tip-test--mk-error-overlay 1 6 'error "A-error")
    (tip-test--mk-error-overlay 7 12 'warning "B-warning")
    ;; Non-error tip overlay shouldn't appear.
    (let ((ov (make-overlay 19 23))) (overlay-put ov 'tip 'tip))
    (let ((ovs (tip--error-overlays)))
      (should (= 3 (length ovs)))
      (should (equal (mapcar (lambda (o) (overlay-get o 'tip-error-message)) ovs)
                     '("A-error" "B-warning" "C-error"))))))

(ert-deftest tip-test-next-error-moves-forward-and-wraps ()
  (with-temp-buffer
    (insert "aaaaa bbbbb ccccc ddddd")
    (tip-test--mk-error-overlay 1 6 'error "A")
    (tip-test--mk-error-overlay 13 18 'error "C")
    (goto-char 1)
    (tip-next-error)
    (should (= 13 (point)))
    ;; Past the last → wrap back to first.
    (tip-next-error)
    (should (= 1 (point)))))

(ert-deftest tip-test-next-error-no-wrap-errors ()
  (with-temp-buffer
    (insert "aaaaa bbbbb")
    (tip-test--mk-error-overlay 1 6 'error "A")
    (goto-char 1)
    ;; With NO-WRAP, walking past the last fragment should user-error.
    (should-error (tip-next-error t) :type 'user-error)))

(ert-deftest tip-test-prev-error-moves-backward ()
  (with-temp-buffer
    (insert "aaaaa bbbbb ccccc")
    (tip-test--mk-error-overlay 1 6 'error "A")
    (tip-test--mk-error-overlay 13 18 'error "C")
    (goto-char 13)
    (tip-prev-error)
    (should (= 1 (point)))
    ;; Before the first → wrap to last.
    (goto-char 1)
    (tip-prev-error)
    (should (= 13 (point)))))

(ert-deftest tip-test-next-error-empty-buffer ()
  (with-temp-buffer
    (insert "no errors here")
    (should-error (tip-next-error) :type 'user-error)
    (should-error (tip-prev-error) :type 'user-error)))

(ert-deftest tip-test-eldoc-returns-error-at-point ()
  (with-temp-buffer
    (insert "aaaaa bbbbb ccccc")
    (tip-test--mk-error-overlay 7 12 'error "Undefined control sequence" "$\\foo")
    ;; Inside overlay → callback receives the message, no `(near)' tag.
    (goto-char 9)
    (let (captured)
      (tip--eldoc-error (lambda (msg &rest _) (setq captured msg)))
      (should captured)
      (should (string-match-p "Undefined control sequence" captured))
      (should (string-match-p "\\[error\\]" captured))
      (should-not (string-match-p "(near)" captured)))))

(ert-deftest tip-test-eldoc-proximity-same-line ()
  "With default `tip-error-eldoc-proximity' = `same-line', cursor
on the same line as an error fragment surfaces the error tagged
with `(near)'."
  (with-temp-buffer
    (insert "aaaaa bbbbb ccccc\nsecond line\n")
    (tip-test--mk-error-overlay 7 12 'error "boom" nil)
    (let ((tip-error-eldoc-proximity 'same-line))
      ;; Same line, off the overlay.
      (goto-char 2)
      (let (captured)
        (tip--eldoc-error (lambda (msg &rest _) (setq captured msg)))
        (should captured)
        (should (string-match-p "boom" captured))
        (should (string-match-p "(near)" captured)))
      ;; Different line: nothing.
      (goto-char 20)
      (let (captured)
        (tip--eldoc-error (lambda (msg &rest _) (setq captured msg)))
        (should-not captured)))))

(ert-deftest tip-test-eldoc-multiple-errors-same-line ()
  "When several error overlays sit on the same line, eldoc reports
the closest one and tags the message with `+N more' so the user
knows others exist on the line."
  (with-temp-buffer
    (insert "$bad1$ ok ok $bad2$ ok $bad3$\n")
    (tip-test--mk-error-overlay 1 7  'error "first"  nil)
    (tip-test--mk-error-overlay 14 20 'error "second" nil)
    (tip-test--mk-error-overlay 24 30 'error "third"  nil)
    (let ((tip-error-eldoc-proximity 'same-line))
      ;; Cursor inside the second fragment — closest is "second",
      ;; "+2 more" naming the other two.
      (goto-char 17)
      (let (captured)
        (tip--eldoc-error (lambda (msg &rest _) (setq captured msg)))
        (should captured)
        (should (string-match-p "second" captured))
        (should (string-match-p "\\+2 more" captured)))
      ;; Cursor between fragment 2 and 3 — closest by distance is one
      ;; of them, others surface in the count.
      (goto-char 22)
      (let (captured)
        (tip--eldoc-error (lambda (msg &rest _) (setq captured msg)))
        (should captured)
        (should (string-match-p "(near, \\+2 more)" captured))))))

(ert-deftest tip-test-eldoc-proximity-at-point-disables-fallback ()
  "Setting `tip-error-eldoc-proximity' to `at-point' restores the
legacy strict-overlap behavior."
  (with-temp-buffer
    (insert "aaaaa bbbbb ccccc")
    (tip-test--mk-error-overlay 7 12 'error "boom" nil)
    (let ((tip-error-eldoc-proximity 'at-point))
      (goto-char 2)
      (let (captured)
        (tip--eldoc-error (lambda (msg &rest _) (setq captured msg)))
        (should-not captured)))))

(ert-deftest tip-test-flymake-backend-reports-all-errors ()
  "The Flymake backend emits one flymake-diagnostic per error overlay."
  (require 'flymake)
  (with-temp-buffer
    (insert "aaaaa bbbbb ccccc")
    (tip-test--mk-error-overlay 1 6 'error "E1" "hint-1")
    (tip-test--mk-error-overlay 7 12 'warning "W1" nil)
    (let (captured)
      (tip-compile-diagnostics (lambda (diags) (setq captured diags)))
      (should (= 2 (length captured)))
      (let ((d1 (car captured)))
        (should (eq :error (flymake-diagnostic-type d1)))
        (should (string-match-p "E1" (flymake-diagnostic-text d1)))
        (should (string-match-p "hint-1" (flymake-diagnostic-text d1))))
      (let ((d2 (cadr captured)))
        (should (eq :warning (flymake-diagnostic-type d2)))))))

;;; * cascade detection

(defun tip-test--mk-frag-result (start end &optional err-msg)
  "Construct a fake FragmentResult alist for cascade-detection tests."
  `((start . ,start) (end . ,end)
    (svg . "<svg/>") (height_pt . 7.0) (depth_pt . 0.0) (width_pt . 10.0)
    ,@(when err-msg
        `((error . ,err-msg)
          (error_detail . ((severity . error) (message . ,err-msg)))))))

(ert-deftest tip-test-cascade-all-same-message ()
  "Dominant-message + high error rate → cascade detected at first error."
  (let ((results
         (list
          (tip-test--mk-frag-result 0 10)                         ; ok
          (tip-test--mk-frag-result 11 20 "Missing $ inserted")
          (tip-test--mk-frag-result 21 30 "Missing $ inserted")
          (tip-test--mk-frag-result 31 40 "Missing $ inserted")
          (tip-test--mk-frag-result 41 50 "Missing $ inserted"))))
    ;; 4/5 errored (> 0.4), all same message (1.0 > 0.7) → cascade, root = 1.
    (should (equal 1 (tip--detect-cascade results)))))

(ert-deftest tip-test-cascade-heterogeneous-errors-not-cascade ()
  "Different error messages in each fragment → not a cascade."
  (let ((results
         (list
          (tip-test--mk-frag-result 0 10 "Undefined control sequence")
          (tip-test--mk-frag-result 11 20 "Missing } inserted")
          (tip-test--mk-frag-result 21 30 "LaTeX Error: some env")
          (tip-test--mk-frag-result 31 40 "Extra \\right")
          (tip-test--mk-frag-result 41 50 "Font not found"))))
    ;; 5/5 errored BUT all different messages → no dominant pattern → nil.
    (should (null (tip--detect-cascade results)))))

(ert-deftest tip-test-cascade-low-error-rate-not-cascade ()
  "Only one error in a large batch → no cascade."
  (let ((results
         (list
          (tip-test--mk-frag-result 0 10)
          (tip-test--mk-frag-result 11 20)
          (tip-test--mk-frag-result 21 30)
          (tip-test--mk-frag-result 31 40)
          (tip-test--mk-frag-result 41 50 "Missing $ inserted"))))
    (should (null (tip--detect-cascade results)))))

(ert-deftest tip-test-cascade-tiny-batch-not-cascade ()
  "Even 100% errors in a batch of 2-3 isn't treated as cascade."
  (let ((results
         (list (tip-test--mk-frag-result 0 10 "Missing $ inserted")
               (tip-test--mk-frag-result 11 20 "Missing $ inserted"))))
    (should (null (tip--detect-cascade results)))))

(ert-deftest tip-test-next-error-skips-cascade-victims ()
  (with-temp-buffer
    (insert "aaaaa bbbbb ccccc ddddd")
    ;; Root at 1; victims at 7, 13.
    (let ((ov1 (tip-test--mk-error-overlay 1 6 'error "Missing $"))
          (ov2 (tip-test--mk-error-overlay 7 12 'error "Missing $"))
          (ov3 (tip-test--mk-error-overlay 13 18 'error "Missing $")))
      (overlay-put ov2 'tip-cascade t)
      (overlay-put ov3 'tip-cascade t))
    (goto-char 1)
    ;; With default (skip cascades) and no non-cascade errors after root → wrap.
    (tip-next-error)
    (should (= 1 (point)))
    ;; With include-cascade, victims are visited.
    (let ((tip-next-error-include-cascade t))
      (goto-char 1)
      (tip-next-error)
      (should (= 7 (point))))))

(ert-deftest tip-test-flymake-mode-toggles-backend ()
  (require 'flymake)
  (with-temp-buffer
    (tip-flymake-mode 1)
    (should (memq #'tip-compile-diagnostics flymake-diagnostic-functions))
    (tip-flymake-mode -1)
    (should-not (memq #'tip-compile-diagnostics flymake-diagnostic-functions))))

(ert-deftest tip-test-compile-cache-basic-roundtrip ()
  "put → get should return the same plist with an updated :ts."
  (with-temp-buffer
    (tip-clear-compile-cache)
    (tip--cache-put "$x$" "#000000" '(:svg "<svg/>" :height-pt 7.0))
    (let ((got (tip--cache-get "$x$" "#000000")))
      (should got)
      (should (equal (plist-get got :svg) "<svg/>"))
      (should (numberp (plist-get got :ts))))))

(ert-deftest tip-test-compile-cache-hit-across-colors ()
  "Color changes should HIT the cache: SVGs bake `currentColor' as a
sentinel and `tip--recolor-overlays' rewrites it at display time, so
the cache key no longer needs to vary by color.  A hit on the same
fragment text under any color is correct."
  (with-temp-buffer
    (tip-clear-compile-cache)
    (tip--cache-put "$x$" "#000000" '(:svg "black"))
    (let ((hit (tip--cache-get "$x$" "#ffffff")))
      (should hit)
      (should (equal (plist-get hit :svg) "black")))))

(ert-deftest tip-test-compile-cache-lru-eviction ()
  "Exceeding tip-cache-max-entries drops the LRU entry."
  (with-temp-buffer
    (tip-clear-compile-cache)
    (let ((tip-cache-max-entries 3))
      (tip--cache-put "a" "#000" '(:svg "A"))
      (tip--cache-put "b" "#000" '(:svg "B"))
      (tip--cache-put "c" "#000" '(:svg "C"))
      ;; Touch "a" so it's not the LRU.
      (tip--cache-get "a" "#000")
      (tip--cache-put "d" "#000" '(:svg "D"))
      ;; "b" was the LRU at insertion time → evicted.
      (should (tip--cache-get "a" "#000"))
      (should (null (tip--cache-get "b" "#000")))
      (should (tip--cache-get "c" "#000"))
      (should (tip--cache-get "d" "#000")))))

(ert-deftest tip-test-compile-cache-is-buffer-local ()
  "Each buffer has its own cache."
  (let ((bufA (generate-new-buffer " tip-cache-A"))
        (bufB (generate-new-buffer " tip-cache-B")))
    (unwind-protect
        (progn
          (with-current-buffer bufA
            (tip--cache-put "$x$" "#000" '(:svg "A")))
          (with-current-buffer bufB
            (should (null (tip--cache-get "$x$" "#000")))))
      (kill-buffer bufA)
      (kill-buffer bufB))))

(ert-deftest tip-latex-test-collects-all-math-including-blank ()
  "The elisp collector returns every math fragment in range, including
whitespace-only ones (`$ $', `\\[ \\]', empty env).  Filtering moved
server-side: the server classifier sees the blank text and decides
not to render it (returns an empty SVG / no result).  This keeps the
client purely structural — it doesn't have to encode \"empty math\"
rules."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "Real $a$\nblank1 $ $\nblank2 \\[  \\]\n"
            "blank3 \\(  \\)\n"
            "blank4 \\begin{equation}  \\end{equation}\nreal2 $b$\n")
    (let ((texts (mapcar
                  (lambda (frag)
                    (let ((sb (1+ (alist-get "start" frag nil nil #'equal)))
                          (eb (1+ (alist-get "end"   frag nil nil #'equal))))
                      (buffer-substring-no-properties
                       (byte-to-position sb) (byte-to-position eb))))
                  (tip-latex-collect-fragments (point-min) (point-max)))))
      ;; All six fragments collected — real and blank alike.
      (should (= 6 (length texts)))
      (should (member "$a$" texts))
      (should (member "$b$" texts)))))

(ert-deftest tip-latex-test-commented-include-allowed ()
  "A \\input inside a comment must NOT disable previewing."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "\\documentclass{article}\n")
    (insert "% \\input{macros}  -- disabled\n")
    (insert "\\begin{document}\n")
    (insert "$x + y$\n")
    (insert "\\end{document}\n")
    (let ((frags (tip-latex-collect-fragments (point-min) (point-max))))
      (should (= 1 (length frags))))))

(ert-deftest tip-latex-test-nested-dollar-in-text ()
  "An inner `$...$' inside `\\text{}' must not close the outer `$...$'.
The classic case: $oeuo \\text{$a$}$.  Brace-aware close scanning
should keep the whole expression as one fragment."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "x $oeuo \\text{$a$}$ and $b$ z.\n")
    (let ((texts (mapcar (lambda (f)
                           (let ((sb (1+ (alist-get "start" f nil nil #'equal)))
                                 (eb (1+ (alist-get "end"   f nil nil #'equal))))
                             (buffer-substring-no-properties
                              (byte-to-position sb) (byte-to-position eb))))
                         (tip-latex-collect-fragments (point-min) (point-max)))))
      (should (equal texts '("$oeuo \\text{$a$}$" "$b$"))))))

(ert-deftest tip-latex-test-nested-dollar-double ()
  "Inner `$...$' inside a `$$...$$' display fragment."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "$$ \\text{inner $x$ here} $$\n")
    (let ((texts (mapcar (lambda (f)
                           (let ((sb (1+ (alist-get "start" f nil nil #'equal)))
                                 (eb (1+ (alist-get "end"   f nil nil #'equal))))
                             (buffer-substring-no-properties
                              (byte-to-position sb) (byte-to-position eb))))
                         (tip-latex-collect-fragments (point-min) (point-max)))))
      (should (= 1 (length texts)))
      (should (string-prefix-p "$$" (car texts)))
      (should (string-suffix-p "$$" (car texts))))))

(ert-deftest tip-latex-test-nested-paren-in-text ()
  "`\\(x\\)' nested inside `\\text{}' inside an outer `\\(...\\)'.
Compilable LaTeX; must collect as ONE whole fragment, not close at
the inner `\\)'."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "pre \\(a + \\text{\\(x + 1\\)} + b\\) post\n")
    (let ((texts (mapcar (lambda (f)
                           (let ((sb (1+ (alist-get "start" f nil nil #'equal)))
                                 (eb (1+ (alist-get "end"   f nil nil #'equal))))
                             (buffer-substring-no-properties
                              (byte-to-position sb) (byte-to-position eb))))
                         (tip-latex-collect-fragments (point-min) (point-max)))))
      (should (equal texts '("\\(a + \\text{\\(x + 1\\)} + b\\)"))))))

(ert-deftest tip-latex-test-comment-skip-in-closer ()
  "A `%'-comment inside a math fragment can contain a fake closer
(e.g. `\\)' or `\\end{equation}') and must be skipped by the closer
scanner, not mistaken for the real end."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "pre \\(a % fake \\) close\n + b\\) post\n")
    (let ((texts (mapcar (lambda (f)
                           (let ((sb (1+ (alist-get "start" f nil nil #'equal)))
                                 (eb (1+ (alist-get "end"   f nil nil #'equal))))
                             (buffer-substring-no-properties
                              (byte-to-position sb) (byte-to-position eb))))
                         (tip-latex-collect-fragments (point-min) (point-max)))))
      (should (= 1 (length texts)))
      (should (string-suffix-p "+ b\\)" (car texts))))))

(ert-deftest tip-latex-test-env-with-inner-aligned ()
  "`\\begin{aligned}...\\end{aligned}' nested inside `\\[...\\]' or
`\\begin{equation}...\\end{equation}' is a compilable LaTeX pattern.
`aligned' is NOT a top-level math opener, so the detector must not
split it out — one outer fragment, inner aligned stays inside."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "\\[\n\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}\n\\]\n")
    (insert "\\begin{equation}\n\\begin{aligned} x &= y \\end{aligned}\n\\end{equation}\n")
    (let ((frags (tip-latex-collect-fragments (point-min) (point-max))))
      (should (= 2 (length frags))))))

(ert-deftest tip-latex-test-regression-subrange-midfragment ()
  "When collect-fragments is called with a range that starts INSIDE
an existing `$...$' fragment, the first `$' seen must NOT be treated
as an opener (it's the closing delimiter of a fragment whose opener
sits before BEG).  Regression for a bug where tip-send-nbd's window
range cut through a fragment and fused two fragments together."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "Fragment one: $a + b$ and Fragment two: $x + y$ done.\n")
    (let* ((mid (save-excursion
                  (goto-char (point-min))
                  (search-forward "a + b")
                  (point)))
           (tail (point-max))
           (frags (tip-latex-collect-fragments mid tail))
           (texts (mapcar (lambda (f)
                            (let ((sb (1+ (alist-get "start" f nil nil #'equal)))
                                  (eb (1+ (alist-get "end"   f nil nil #'equal))))
                              (buffer-substring-no-properties
                               (byte-to-position sb) (byte-to-position eb))))
                          frags)))
      ;; The sub-range starts inside `$a + b$' but the detector should
      ;; still return BOTH whole fragments (since fragment one overlaps
      ;; the sub-range at its tail), NOT a fused garbage fragment.
      (should (= 2 (length texts)))
      (should (equal texts '("$a + b$" "$x + y$"))))))

(ert-deftest tip-latex-test-regression-syntax-ppss-moves-point ()
  "Buffer mixing fragments + commented-out environments must not hang.
Regression for the `syntax-ppss' side-effect bug: when called with a POS
argument, `syntax-ppss' moves point to POS, which made the collector
re-match the same regex hit forever if the second call rewound point to
a position before the most recent match-end."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "Before $a$ and\n"
            "% \\begin{equation*}\n"
            "% \\mathrm{commented}\n"
            "% \\end{equation*}\n"
            "then $b$ and $c$ end.\n")
    (let ((t0 (float-time))
          (frags (tip-latex-collect-fragments (point-min) (point-max))))
      ;; Must complete quickly (no infinite loop).
      (should (< (- (float-time) t0) 0.5))
      (should (= 3 (length frags))))))

(ert-deftest tip-latex-test-preamble-ignores-comments ()
  "A `%' comment in the preamble mentioning `\\\\begin{document}' must
NOT terminate preamble extraction early.  Regression for a demo file
whose header comment described the preamble's span — the literal
`\\\\begin{document}' inside the comment fooled the scanner, dropping
every `\\\\newcommand' declared below the comment."
  (with-temp-buffer
    (delay-mode-hooks (latex-mode))
    (insert "\\documentclass{article}\n")
    (insert "% preamble spans up to \\begin{document}\n")
    (insert "\\newcommand{\\D}{d}\n")
    (insert "\\begin{document}\n")
    (insert "Body: $\\D f$\n")
    (insert "\\end{document}\n")
    (let ((pre (tip-latex-build-preamble)))
      ;; The real \begin{document} is what should terminate the preamble,
      ;; not the one in the comment — so \newcommand must be captured.
      (should (string-match-p "\\\\newcommand" pre)))))

(ert-deftest tip-latex-test-backend-registered ()
  (let ((b (alist-get 'latex tip-backends)))
    (should b)
    (should (memq 'latex-mode (tip-backend-major-modes b)))
    (should (memq 'LaTeX-mode (tip-backend-major-modes b)))
    (should (eq (tip-backend-collect-fragments-fn b)
                #'tip-latex-collect-fragments))
    (should (equal (tip-backend-server-executable b) "tip-server"))))

;;; Run tests

(when noninteractive
  (ert-run-tests-batch-and-exit))

;;; test-tip.el ends here
