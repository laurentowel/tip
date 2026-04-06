;;; inspect-nodes.el --- Dump tree-sitter call nodes -*- lexical-binding: t; -*-
(require 'package)
(package-initialize)
(setq create-lockfiles nil make-backup-files nil auto-save-default nil)
(require 'typst-ts-mode)

(let ((base (file-name-directory load-file-name)))
  (find-file (expand-file-name
              "../tip-server/crates/tip-core/tests/fixtures/diagrams.typ" base)))
(typst-ts-mode)
(sleep-for 0.5)

(defun walk-tree (node result)
  (when (equal (treesit-node-type node) "call")
    (let ((c0 (treesit-node-child node 0)))
      (push (format "call %d..%d child0=%S text=%S"
                    (treesit-node-start node)
                    (treesit-node-end node)
                    (and c0 (treesit-node-type c0))
                    (and c0 (substring (treesit-node-text c0 t)
                                       0 (min 40 (length (treesit-node-text c0 t))))))
            result)))
  (dotimes (i (treesit-node-child-count node))
    (setq result (walk-tree (treesit-node-child node i) result)))
  result)

(let* ((root (treesit-buffer-root-node 'typst))
       (calls (nreverse (walk-tree root nil))))
  (with-temp-file (expand-file-name "56-inspect-nodes-results.txt"
                                    (file-name-directory load-file-name))
    (insert (format "Found %d call nodes:\n" (length calls)))
    (dolist (c calls)
      (insert c "\n"))))

(kill-emacs 0)
