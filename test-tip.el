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

(ert-deftest tip-latex-test-refuse-when-includes-present ()
  "Any live \\input/\\include/\\subimport anywhere in the buffer disables
the backend — collect returns nil, bounds-at-point returns nil."
  (dolist (cmd '("\\input{macros}" "\\include{chap1}" "\\subimport{sub}{file}"))
    (with-temp-buffer
      (delay-mode-hooks (latex-mode))
      (insert "\\documentclass{article}\n")
      (insert "\\begin{document}\n")
      (insert "$x$ before " cmd " $y$ after.\n")
      (insert "\\end{document}\n")
      ;; Both entry points must short-circuit.
      (should (null (tip-latex-collect-fragments (point-min) (point-max))))
      (goto-char (point-min))
      (search-forward "$x$")
      (should (null (tip-latex-bounds-at-point (1- (point))))))))

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
  "A \\input in the preamble should still trigger refuse even when the
user has narrowed to a section below \\begin{document}."
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
      ;; Refuse must fire even though `\input' lies outside the narrow.
      (should (tip-latex--buffer-has-includes-p))
      (should (null (tip-latex-collect-fragments (point-min) (point-max)))))))

(ert-deftest tip-test-compile-cache-basic-roundtrip ()
  "put → get should return the same plist with an updated :ts."
  (with-temp-buffer
    (tip-clear-compile-cache)
    (tip--cache-put "$x$" "#000000" '(:svg "<svg/>" :height-pt 7.0))
    (let ((got (tip--cache-get "$x$" "#000000")))
      (should got)
      (should (equal (plist-get got :svg) "<svg/>"))
      (should (numberp (plist-get got :ts))))))

(ert-deftest tip-test-compile-cache-miss-different-color ()
  "Color changes should miss the cache."
  (with-temp-buffer
    (tip-clear-compile-cache)
    (tip--cache-put "$x$" "#000000" '(:svg "black"))
    (should (null (tip--cache-get "$x$" "#ffffff")))))

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

(ert-deftest tip-latex-test-skip-blank-fragments ()
  "Whitespace-only math (`$ $', `\\[ \\]', empty env) must not produce fragments."
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
      (should (equal texts '("$a$" "$b$"))))))

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

(ert-deftest tip-latex-test-backend-registered ()
  (let ((b (alist-get 'latex tip-backends)))
    (should b)
    (should (memq 'latex-mode (tip-backend-major-modes b)))
    (should (memq 'LaTeX-mode (tip-backend-major-modes b)))
    (should (eq (tip-backend-collect-fragments-fn b)
                #'tip-latex-collect-fragments))
    (should (equal (tip-backend-server-executable b) "tip-server-latex"))))

;;; Run tests

(when noninteractive
  (ert-run-tests-batch-and-exit))

;;; test-tip.el ends here
