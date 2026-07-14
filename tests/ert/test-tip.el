;;; test-tip.el --- Pure-elisp tests for tip.el -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Unit-level tests that don't spawn the Rust server.  Run with:
;;
;;   emacs --batch -l test/elisp-client/test-tip.el
;;
;; Server-spawning integration tests live under
;; `test/elisp-rs-integration/' alongside this file's parent.

;;; Code:

(require 'ert)
(load (expand-file-name "../setup.el" (file-name-directory load-file-name)))
(load (expand-file-name "tip.el" tip-test-lisp-dir))

;;; * Byte compilation

(ert-deftest tip-test-byte-compile ()
  "tip.el should byte-compile without errors or warnings."
  (let ((byte-compile-error-on-warn t)
        (tip-el (expand-file-name "tip.el" tip-test-lisp-dir)))
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

(ert-deftest tip-test-insert-before-rendered-overlay-does-not-open-it ()
  "Typing before a rendered fragment must not reveal that next fragment."
  (with-temp-buffer
    (insert "foo $a$ bar")
    (tip--apply-fragment-results
     (vector `((start . ,(1- (position-bytes 5)))
               (end . ,(1- (position-bytes 8)))
               (svg . "<svg width=\"1pt\" height=\"1pt\" viewBox=\"0 0 1 1\"></svg>")
               (height_pt . 1.0)
               (depth_pt . 0.0)
               (width_pt . 1.0)
               (font_size_pt . 11.0))))
    (let ((ov (seq-find (lambda (o) (eq (overlay-get o 'tip) 'tip))
                        (overlays-in (point-min) (point-max)))))
      (should ov)
      (setq-local preview-toggle-type 'tip)
      (setq-local preview-toggle-region-at-point-fn
                  (lambda (pos)
                    (save-excursion
                      (goto-char (point-min))
                      (when (search-forward "$a$" nil t)
                        (let ((beg (match-beginning 0))
                              (end (match-end 0)))
                          (when (and (<= beg pos) (< pos end))
                            (cons beg end)))))))
      (setq-local preview-toggle-compile-region-fn #'ignore)
      (preview-toggle-mode 1)
      (goto-char (overlay-start ov))
      (let ((this-command 'self-insert-command))
        (run-hooks 'pre-command-hook)
        (insert "X")
        (run-hooks 'post-command-hook))
      (should (= (overlay-start ov) 6))
      (should (preview-toggle--overlay-shows-image-p ov)))))

(defface tip-test-warning-derived-face
  '((t :inherit font-lock-warning-face))
  "Test face that models a mode-specific syntax-error face.")

(ert-deftest tip-test-image-face-auto-filters-inherited-warning-face ()
  "`tip-image-face' auto should ignore transient syntax warning faces."
  (with-temp-buffer
    (insert "x$a$ y")
    (put-text-property 1 2 'face '(bold tip-test-warning-derived-face))
    (let ((tip-image-face 'auto)
          (tip-image-face-blocklist '(font-lock-warning-face)))
      (should (equal (tip--resolve-image-face 2 5) '(bold default))))))

(ert-deftest tip-test-image-face-auto-filters-typst-quote-face ()
  "`tip-image-face' auto should ignore Typst quote marker faces."
  (with-temp-buffer
    (insert "x$a$ y")
    (put-text-property 1 2 'face '(bold typst-ts-markup-quote-face))
    (let ((tip-image-face 'auto)
          (tip-image-face-blocklist '(typst-ts-markup-quote-face)))
      (should (equal (tip--resolve-image-face 2 5) '(bold default))))))

(ert-deftest tip-test-mode-disable-clears-error-markups ()
  "Disabling `tip-mode' removes stale in-buffer error overlays."
  (with-temp-buffer
    (insert "bad $\\bet$ ok")
    (let ((err (make-overlay 5 10))
          (other (make-overlay 1 4)))
      (overlay-put err 'tip 'tip)
      (overlay-put err 'tip-error-severity 'error)
      (overlay-put err 'face 'tip-error-face)
      (overlay-put other 'face 'bold)
      (cl-letf (((symbol-function 'tip-ensure) #'ignore)
                ((symbol-function 'preview-toggle-mode)
                 (lambda (&optional arg)
                   (setq preview-toggle-mode
                         (> (prefix-numeric-value (or arg 1)) 0))))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (&rest _args) 'tip-test-timer))
                ((symbol-function 'run-with-timer)
                 (lambda (&rest _args) nil))
                ((symbol-function 'cancel-timer) #'ignore))
        (tip-mode 1)
        (should (seq-some (lambda (ov)
                            (overlay-get ov 'tip-error-severity))
                          (overlays-in (point-min) (point-max))))
        (tip-mode -1))
      (should-not
       (seq-some (lambda (ov)
                   (overlay-get ov 'tip-error-severity))
                 (overlays-in (point-min) (point-max))))
      (should (overlay-buffer other)))))

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

(ert-deftest tip-test-collect-avoid-pos-after-outermost-filter ()
  "`tip-collect-fragment-locations' must apply AVOID-POS after the
outermost-filter, not during initial collection.  If applied during
collection, an enclosing outer math whose body contains AVOID-POS
is dropped first, leaving a nested inner math (which does NOT
contain AVOID-POS itself) to survive as if it were top-level — and
`tip-send-nbd' then renders that inner fragment in isolation."
  (with-temp-buffer
    (tip-test--setup-typst-buffer
     "Text.\n$\n  #diagram(node((0,0), [${W_n (g)}_(n=1)^oo$]))\n$\nEnd.\n")
    ;; Point at the newline inside the outer `$ ... $' but outside the
    ;; inner `${W_n...}$' — outer contains point, inner does not.
    (goto-char (point-min))
    (search-forward "$")
    (forward-char)  ; just past the opening `$' onto the newline
    (let* ((frags (tip-collect-fragment-locations (point-min) (point-max) (point)))
           (texts (mapcar
                   (lambda (f)
                     (let ((sb (1+ (alist-get "start" f nil nil #'equal)))
                           (eb (1+ (alist-get "end"   f nil nil #'equal))))
                       (buffer-substring-no-properties
                        (byte-to-position sb) (byte-to-position eb))))
                   frags)))
      ;; Outer is skipped (contains point); inner must NOT leak out.
      (should-not (cl-some (lambda (s) (string-match-p "W_n" s)) texts)))))

(ert-deftest tip-test-bounds-at-point-outermost-math ()
  "Math nested inside another math fragment (e.g. inline `$x$' inside
a diagram node label inside outer display math) resolves to the
OUTERMOST math — matches `tip-collect-fragment-locations' which only
keeps outermost ranges."
  (with-temp-buffer
    (tip-test--setup-typst-buffer
     "$\n  #diagram(node((0,0), [${W_n (g)}_(n=1)^oo$]))\n$\n")
    (let ((tip-render-figure nil))
      (goto-char (point-min))
      (search-forward "W_n")
      (let* ((bounds (tip--get-bounds-of-math-at-point (point)))
             (text (and bounds
                        (buffer-substring-no-properties (car bounds) (cdr bounds)))))
        (should bounds)
        (should (string-match-p "diagram" text))
        (should (string-match-p "W_n" text))))))

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
    ;; Inside overlay → callback receives a tip[error/compile] line
    ;; matching tip-log--echo's format, no `(near)' tag.  No `:thing'
    ;; argument — eldoc's auto-prefix would conflict with our own.
    (goto-char 9)
    (let (captured thing)
      (tip--eldoc-error
       (lambda (msg &rest props)
         (setq captured msg
               thing (plist-get props :thing))))
      (should captured)
      (should (string-match-p "Undefined control sequence" captured))
      (should (string-match-p "tip\\[error/compile\\]:" captured))
      (should-not (string-match-p "(near)" captured))
      (should-not thing))))

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

(ert-deftest tip-latex-test-collector-filters-blank-fragments ()
  "The elisp collector drops whitespace-only math fragments (`$ $',
`\\[ \\]', empty env) — they produce empty SVGs and don't deserve a
server round-trip.  Real fragments pass through.  See
`tip-latex--fragment-blank-p'."
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
      (should (equal '("$a$" "$b$") texts)))))

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
