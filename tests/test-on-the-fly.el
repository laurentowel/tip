;;; test-on-the-fly.el --- Automated on-the-fly editing test -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests that moving out of a math fragment triggers recompilation.
;; Run with:
;;   emacs --batch --init-directory /workspace/tip-improve/tip-server/test-output/emacs-sandbox -l /workspace/tip-improve/tip-server/test-output/test-on-the-fly.el

;;; Code:

(require 'package)
(package-initialize)

;; No littering
(setq create-lockfiles nil)
(setq make-backup-files nil)
(setq auto-save-default nil)

;; Copy grammar from shared cache if available
(let ((shared-grammar "/workspace/tip-improve/tip-server/test-output/emacs-sandbox/tree-sitter/libtree-sitter-typst.so")
      (local-ts-dir (expand-file-name "tree-sitter/" user-emacs-directory)))
  (when (and (file-exists-p shared-grammar)
             (not (file-exists-p (expand-file-name "libtree-sitter-typst.so" local-ts-dir))))
    (make-directory local-ts-dir t)
    (copy-file shared-grammar local-ts-dir t)))

;; Install typst-ts-mode if needed
(unless (package-installed-p 'typst-ts-mode)
  (package-vc-install
   '(typst-ts-mode :url "https://codeberg.org/meow_king/typst-ts-mode")))
(require 'typst-ts-mode)

;; Install grammar if needed
(unless (treesit-language-available-p 'typst)
  (setq treesit-language-source-alist
        '((typst "https://github.com/uben0/tree-sitter-typst")))
  (treesit-install-language-grammar 'typst))

;; Load tip
(let ((base (file-name-directory load-file-name)))
  (setq tip-server-executable
        (expand-file-name "../../tip-server/target/release/tip-server" base))
  (unless (file-executable-p tip-server-executable)
    ;; Fall back to debug build
    (setq tip-server-executable
          (expand-file-name "../../tip-server/target/debug/tip-server" base)))
  (add-to-list 'load-path (expand-file-name ".." base))
  (load (expand-file-name "../tip.el" base)))

(setq tip-enable-debug t)

;; Track what happened
(defvar test--overlays-created 0)
(defvar test--compile-requests 0)

;; Advice to count compile requests
(advice-add 'tip--send-request :before
            (lambda (method &rest _)
              (when (member method '("compile_fragments" "compile_live"))
                (cl-incf test--compile-requests)
                (message "TEST: compile request #%d (method=%s)"
                         test--compile-requests method))))

;; --- Test ---

(let* ((test-file (make-temp-file "tip-test-" nil ".typ"))
       (test-content "#let bb = sym.beta\nSome text here\n"))

  ;; Write initial content (trailing newline so we can move past math)
  (with-temp-file test-file
    (insert test-content)
    (insert "\n"))

  ;; Open in typst-ts-mode
  (find-file test-file)
  (typst-ts-mode)
  (tip-mode 1)

  ;; Wait for server
  (sleep-for 1)
  (message "TEST: server live=%S" (and tip--server-process
                                       (process-live-p tip--server-process)))

  ;; === Scenario 1: Type $bb$ and move out ===
  (message "\n=== Scenario 1: Type math and move out ===")

  ;; Insert math with trailing text so we can move past it
  (goto-char (point-max))
  (insert "$bb$ end\n")
  (message "TEST: parsers=%S" (treesit-parser-list))
  (message "TEST: buffer=%S" (buffer-substring-no-properties (point-min) (point-max)))
  ;; Force reparse by querying the tree
  (let ((ranges (treesit-query-range 'typst "((math) @math)")))
    (message "TEST: math ranges after insert=%S" ranges))
  (message "TEST: inserted $bb$, point=%d" (point))

  ;; Move inside the math: find $bb$ and go inside it
  (goto-char (point-min))
  (search-forward "$bb")
  (backward-char 1) ;; now at $b|b$
  (message "TEST: inside math, point=%d" (point))

  ;; Simulate pre-command hook (as if user is about to press C-f)
  (let ((this-command 'forward-char))
    (tip-auto--handle-pre-cursor))
  (message "TEST: pre-cursor done, from-overlay=%S" tip--from-overlay)

  ;; Move to end of math then past closing $
  (search-forward "$")
  (message "TEST: moved past closing $, point=%d" (point))

  ;; Simulate post-command hook
  (let ((this-command 'forward-char))
    (tip-auto--handle-post-cursor))
  (message "TEST: post-cursor done")

  ;; Wait for async response
  (message "TEST: waiting for compilation response...")
  (let ((deadline (+ (float-time) 10))
        (initial-requests test--compile-requests))
    ;; Accept process output until we get a compile request or timeout
    (while (and (< (float-time) deadline)
                (= test--compile-requests initial-requests)
                tip--server-process
                (process-live-p tip--server-process))
      (accept-process-output tip--server-process 0.1)))

  (message "TEST: compile requests so far: %d" test--compile-requests)

  ;; Wait a bit more for the response
  (when (and tip--server-process (process-live-p tip--server-process))
    (accept-process-output tip--server-process 3))

  ;; Check overlays
  (let ((ovs (seq-filter
              (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
              (overlays-in (point-min) (point-max)))))
    (message "TEST: tip overlays found: %d" (length ovs))
    (dolist (ov ovs)
      (message "TEST:   overlay %d..%d display=%S"
               (overlay-start ov) (overlay-end ov)
               (not (null (overlay-get ov 'display))))))

  ;; === Scenario 2: Edit existing math and move out ===
  (message "\n=== Scenario 2: Edit existing math, move out ===")

  ;; Clear overlays so we test fresh
  (tip-clear-buffer)

  ;; Find the $bb$ we just inserted and go inside it
  (goto-char (point-min))
  (search-forward "$bb")
  (backward-char 2) ;; inside $|bb$
  (message "TEST: inside math at point=%d" (point))

  ;; Type something
  (insert " + 1")
  (message "TEST: edited to $bb + 1$, point=%d" (point))

  ;; Move to end of math then out
  (search-forward "$")
  (message "TEST: at closing $, point=%d" (point))

  ;; pre-command (about to move forward)
  (let ((this-command 'forward-char))
    (tip-auto--handle-pre-cursor))
  (message "TEST: pre-cursor, from-overlay=%S" tip--from-overlay)

  ;; move out
  (forward-char 1)
  (let ((this-command 'forward-char))
    (tip-auto--handle-post-cursor))
  (message "TEST: post-cursor done, now outside math")

  ;; Wait for response
  (when (and tip--server-process (process-live-p tip--server-process))
    (accept-process-output tip--server-process 5))

  (let ((ovs (seq-filter
              (lambda (ov) (eq (overlay-get ov 'tip) 'tip))
              (overlays-in (point-min) (point-max)))))
    (message "TEST: tip overlays after edit: %d" (length ovs))
    (dolist (ov ovs)
      (message "TEST:   overlay %d..%d has-display=%S"
               (overlay-start ov) (overlay-end ov)
               (not (null (overlay-get ov 'display))))))

  ;; Cleanup
  (when tip--server-process
    (tip-shutdown))
  (kill-buffer)
  (delete-file test-file)

  ;; Summary
  (message "\n=== SUMMARY ===")
  (message "Total compile requests: %d" test--compile-requests)
  (if (>= test--compile-requests 2)
      (message "PASS: on-the-fly recompilation triggered")
    (message "FAIL: expected at least 2 compile requests")))
