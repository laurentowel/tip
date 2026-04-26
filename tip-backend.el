;;; tip-backend.el --- Backend interface for tip (Typst, LaTeX, ...) -*- lexical-binding: t; -*-

;;; Commentary:

;; The per-markup-language contract: each backend module builds a
;; `tip-backend' struct and registers it with `tip-register-backend'.
;; The rest of tip calls into the active backend via the accessor
;; shims (`tip-collect-fragments', `tip-bounds-at-point',
;; `tip-build-preamble', `tip-classify-fragment',
;; `tip-server-executable-name') so nothing else needs to know the
;; concrete backend.
;;
;; Dispatch is by major mode, cached buffer-locally.  A LaTeX backend
;; registers for `latex-mode' / `LaTeX-mode' alongside the existing
;; Typst backend — the two do not need to cooperate.

;;; Code:

(require 'cl-lib)
(require 'seq)

(cl-defstruct tip-backend
  "A tip backend description.

Fields:

  NAME                   symbol identifying the backend (e.g. `typst').
  MAJOR-MODES            list of major-mode symbols this backend applies to.
  COLLECT-FRAGMENTS-FN   (BEG END &optional AVOID-POS) → list of alists with
                         keys \"start\"/\"end\" (byte offsets).
  BOUNDS-AT-POINT-FN     (POS) → (BEG . END) of the fragment at POS, or nil.
  BUILD-PREAMBLE-FN      () → string, prepended to each compiled fragment.
  CLASSIFY-FRAGMENT-FN   (TEXT) → one of the symbols `inline',
                         `display-single' (gets an indicator), `display-multi',
                         or `block'.
  SERVER-EXECUTABLE      string (binary name on PATH) or a zero-arg function
                         returning a path.
  SHOW-SKELETON-FN       optional zero-arg function that displays the
                         backend-specific skeleton or preamble for the
                         current buffer (Typst: scope at point; LaTeX:
                         the assembled root preamble).  Called by
                         `tip-show-skeleton-at-point' when the user runs
                         it.  When nil, the command messages
                         \"not supported by BACKEND\"."
  name
  major-modes
  collect-fragments-fn
  bounds-at-point-fn
  build-preamble-fn
  classify-fragment-fn
  server-executable
  show-skeleton-fn)

(defvar tip-backends nil
  "Alist mapping backend name → `tip-backend' struct.")

(defun tip-register-backend (backend)
  "Register BACKEND in `tip-backends', replacing any entry with the same name.
Refuses stale structs left over from an older `cl-defstruct' layout —
re-`load' the backend's .el file when this fires."
  (condition-case _
      ;; Touch every accessor so a struct missing newly-added slots
      ;; fails here with a clear message rather than later from a
      ;; cryptic `args-out-of-range' deep in dispatch.
      (let ((name (tip-backend-name backend)))
        (ignore (tip-backend-major-modes backend)
                (tip-backend-collect-fragments-fn backend)
                (tip-backend-bounds-at-point-fn backend)
                (tip-backend-build-preamble-fn backend)
                (tip-backend-classify-fragment-fn backend)
                (tip-backend-server-executable backend)
                (tip-backend-show-skeleton-fn backend))
        (setf (alist-get name tip-backends) backend))
    (args-out-of-range
     (error "tip-register-backend: stale `tip-backend' struct (older slot \
layout); re-load the backend's source file"))))

(defvar-local tip--active-backend nil
  "Cached active backend for this buffer.  Reset when major mode changes.")

(defun tip-active-backend ()
  "Return the `tip-backend' active in the current buffer, or nil.
The result is cached buffer-locally; call `tip-active-backend-reset' if
you need to re-dispatch (e.g. after changing major mode)."
  (or tip--active-backend
      (setq tip--active-backend
            (seq-find (lambda (b)
                        (apply #'derived-mode-p
                               (tip-backend-major-modes b)))
                      (mapcar #'cdr tip-backends)))))

(defun tip-active-backend-reset ()
  "Clear the cached active backend so the next lookup re-dispatches."
  (setq tip--active-backend nil))

;;; * accessor shims

(defun tip-collect-fragments (beg end &optional avoid-pos)
  "Call the active backend's fragment collector on BEG..END.
Returns nil if no backend is active in this buffer."
  (when-let* ((b (tip-active-backend)))
    (funcall (tip-backend-collect-fragments-fn b) beg end avoid-pos)))

(defun tip-bounds-at-point (pos)
  "Call the active backend's bounds-at-point lookup for POS."
  (when-let* ((b (tip-active-backend)))
    (funcall (tip-backend-bounds-at-point-fn b) pos)))

(defun tip-build-preamble ()
  "Call the active backend's preamble builder."
  (when-let* ((b (tip-active-backend)))
    (funcall (tip-backend-build-preamble-fn b))))

(defun tip-classify-fragment (text)
  "Classify fragment TEXT via the active backend.
Returns `inline' when no backend is active."
  (if-let* ((b (tip-active-backend)))
      (funcall (tip-backend-classify-fragment-fn b) text)
    'inline))

(defun tip-server-executable-name ()
  "Return the server binary name/path for the active backend, or nil.
The returned value may be a simple name to look up on PATH, or an
absolute path if the backend's `server-executable' field is a function
that resolves one."
  (when-let* ((b (tip-active-backend)))
    (let ((exe (tip-backend-server-executable b)))
      (if (functionp exe) (funcall exe) exe))))

(provide 'tip-backend)

;;; tip-backend.el ends here
