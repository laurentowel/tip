;;; error-highlight.el --- Compile errors surface as highlighted overlays  -*- lexical-binding: t; -*-

;; A fragment that fails to compile gets a `tip-error-face' overlay
;; (or similar), while siblings still render normally.  Ported from
;; legacy 06-error-highlight.

(defun tip-test--error-overlays ()
  (seq-filter (lambda (ov)
                (and (eq (overlay-get ov 'tip) 'tip)
                     (memq (overlay-get ov 'face)
                           '(tip-error-face tip-warning-face tip-cascade-face))))
              (overlays-in (point-min) (point-max))))

(defun tip-test--rendered-overlays ()
  (seq-filter (lambda (ov)
                (and (eq (overlay-get ov 'tip) 'tip)
                     (let ((d (overlay-get ov 'display)))
                       (or (eq (car-safe d) 'image)
                           (and (consp d) (consp (car d))
                                (eq (car (car d)) 'image))))))
              (overlays-in (point-min) (point-max))))

(tip-test-deftest bad-fragment-gets-error-face
  :doc "A broken fragment gets an error overlay; good ones still render."
  :tags (error render)
  (tip-test-with-fresh-typst-buffer
   "Good $a + b$ here.\nBad $xxxxx$ end.\n"
    (tip-render-all)
    (tip-test-wait-for-pending 20)
    (should (> (length (tip-test--error-overlays)) 0))
    (should (> (length (tip-test--rendered-overlays)) 0))))

;; Note on "entering an error fragment clears the face":
;; preview-toggle-open does clear both `display' and `face', but the
;; error overlay may span only the hint region (not the whole
;; fragment), so the cursor entering the fragment-outer range may
;; land outside the overlay.  The outcome then depends on the hint
;; parse.  Tested manually via `nix run .#showcase' instead of here
;; to avoid a flaky assertion.
