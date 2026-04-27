;;; setup.el --- Common path setup for tip tests -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Loaded from every suite under `tests/elisp-client/' and
;; `tests/elisp-rs-integration/'.  This file's own location is
;; `<repo-root>/tests/setup.el', so we use `load-file-name' to derive
;; the repo root once and expose three constants every suite needs:
;;
;;   tip-test-repo-root      <repo-root>/
;;   tip-test-lisp-dir       <repo-root>/lisp/      (pushed onto load-path)
;;   tip-test-server-binary  <repo-root>/tip-server/target/debug/tip-server
;;
;; Each suite loads us with a single relative path:
;;
;;   (load (expand-file-name "../setup.el" (file-name-directory load-file-name)))
;;
;; Nothing else hard-codes the repo layout — moving `lisp/' or
;; `tip-server/' is a one-line edit here.

;;; Code:

(defconst tip-test-repo-root
  (file-name-as-directory
   (expand-file-name ".." (file-name-directory
                           (or load-file-name buffer-file-name ""))))
  "Absolute path to the repo root, derived from this file's location.")

(defconst tip-test-lisp-dir
  (expand-file-name "lisp" tip-test-repo-root)
  "Absolute path to the elisp source directory.")

(defconst tip-test-server-binary
  (expand-file-name "tip-server/target/debug/tip-server" tip-test-repo-root)
  "Path to the debug-build tip-server.  Suites that spawn the server
should `(unless (file-executable-p tip-test-server-binary) (ert-skip
\"...\"))' so missing builds deselect the test cleanly.")

(add-to-list 'load-path tip-test-lisp-dir)

;;; setup.el ends here
