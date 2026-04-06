;;; tip-kodama.el --- Kodama compatibility for TIP -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Integration between TIP (Typst Inline Preview) and Kodama-based
;; knowledge forests.  Activates automatically when a Kodama.toml is
;; detected in a parent directory.
;;
;; Kodama files target HTML export and use patterns that need special
;; handling for paged-mode preview:
;;
;; - `html.elem`, `html.frame` are no-ops in paged mode
;; - `#let canvas(..args) = html.elem(...)[cetz.canvas(..args)]`
;;   wraps CeTZ calls for HTML centering — in paged mode TIP should
;;   preview the wrapper call, not the inner cetz.canvas
;; - `#show: kodama` sets page layout that TIP's page_setup overrides
;;
;; Currently this mode just notifies the user that kodama integration
;; is active.  Future work: html feature flag support, custom preamble.

;;; Code:

(defun tip-kodama--find-toml ()
  "Walk up from `default-directory' looking for Kodama.toml.
Returns the directory containing it, or nil."
  (let ((dir (if buffer-file-name
                 (file-name-directory buffer-file-name)
               default-directory)))
    (locate-dominating-file dir "Kodama.toml")))

;;;###autoload
(define-minor-mode tip-kodama-mode
  "Kodama compatibility for TIP.
Activates when editing Typst files in a Kodama project (Kodama.toml
found in a parent directory).  Adjusts fragment detection and
compilation for files targeting HTML export."
  :init-value nil
  :lighter " TIP-kodama"
  (when tip-kodama-mode
    (message "TIP: kodama integration active (project: %s)"
             (abbreviate-file-name (or (tip-kodama--find-toml) "?")))))

;;;###autoload
(defun tip-kodama-maybe-enable ()
  "Enable `tip-kodama-mode' if current file is in a Kodama project."
  (when (and (derived-mode-p 'typst-ts-mode)
             (tip-kodama--find-toml))
    (tip-kodama-mode 1)))

(provide 'tip-kodama)

;;; tip-kodama.el ends here
