;;; test-server.el --- elisp ↔ tip-server integration tests -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Tests that spawn the real Rust tip-server binary and exchange
;; JSON-RPC over stdio.  Skipped silently when the binary isn't built
;; (`tip-server/target/debug/tip-server' missing).
;;
;; Run with:
;;
;;   cd tip-server && cargo build  # or release
;;   emacs --batch -l test/elisp-rs-integration/test-server.el
;;
;; Pure-elisp unit tests live under `test/elisp-client/'.

;;; Code:

(require 'ert)
(load (expand-file-name "../setup.el" (file-name-directory load-file-name)))
(load (expand-file-name "tip.el" tip-test-lisp-dir))


(ert-deftest tip-test-server-spawn-and-shutdown ()
  "Should spawn tip-server, communicate, and shut down cleanly."
  (let* ((tip-server-executable tip-test-server-binary)
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
  (let* ((tip-server-executable tip-test-server-binary)
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
  (let* ((tip-server-executable tip-test-server-binary)
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

;;; Run tests

(when noninteractive
  (ert-run-tests-batch-and-exit))

;;; test-server.el ends here
