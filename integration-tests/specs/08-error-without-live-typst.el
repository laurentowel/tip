;;; error-without-live.el --- Compile errors surface even with live preview off  -*- lexical-binding: t; -*-

;; Ported from legacy 05-error-without-live-preview.el.  With
;; `tip-live-mode' disabled, an invalid math fragment leaving the
;; cursor must still trigger a server compile — the resulting
;; diagnostic must NOT be silently swallowed.  In Typst math,
;; multi-char identifiers resolve from scope; bare `$xxxxx$' yields
;; "unknown variable: xxxxx".  We assert the fragment ends up with
;; NO image overlay (error keeps it raw) rather than a rendered one.

(tip-test-deftest error-without-live-preview-suppresses-image
  :doc "Invalid Typst math with live off: no image overlay is produced."
  :tags (error)
  (tip-test-with-fresh-typst-buffer "Hello world $xxxxx$ trailing\n"
    (tip-render-all)
    (tip-test-wait-for-pending 15)
    (let* ((ranges (tip-test-fragment-ranges))
           (frag   (car ranges))
           (inside (1+ (car frag))))
      (should ranges)
      ;; A successful render would leave a display image at `inside'.
      ;; An error must not — the fragment stays as source.
      (should-not (tip-test-overlay-showing-image-p inside)))))
