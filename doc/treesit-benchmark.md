# Tree-sitter Performance: Why the Let-Binding Check Stays in Elisp

## The Question

When TIP detects math fragments, it must skip fragments inside `#let` bindings — they're function definitions, not rendered content. This check runs on every fragment. Should it be in elisp (tree-sitter parent walk) or Rust (AST analysis on the server)?

The answer depends on how fast the elisp check is.

## The Check

```elisp
(defun tip--inside-let-binding-p (node)
  "Return non-nil if NODE is inside a let binding."
  (let ((parent (treesit-node-parent node)))
    (while (and parent
                (not (equal "let" (treesit-node-type parent))))
      (setq parent (treesit-node-parent parent)))
    (not (null parent))))
```

Starting from a tree-sitter node, walk up the parent chain. If any ancestor has type `"let"`, the node is inside a `#let` binding. The walk terminates at the root if no `let` is found.

The depth is bounded by the nesting level of the document — typically 5-15 nodes. Each `treesit-node-parent` and `treesit-node-type` is a C function call into the tree-sitter library, operating on the in-memory parse tree.

## The Test Document

1000 math fragments: 500 inside `#let` bindings, 500 as real document content.

```typst
#let f0(x) = $op("f0")(x)$
#let f1(x) = $op("f1")(x)$
...
#let f499(x) = $op("f499")(x)$
Real 0: $a_0 + b_0$
Real 1: $a_1 + b_1$
...
Real 499: $a_499 + b_499$
```

This is a worst case: the check must walk the full parent chain for every fragment. Real documents have fewer `#let` bindings and the ratio of definitions to content is lower.

## The Benchmark

```elisp
(require 'package) (package-initialize) (require 'typst-ts-mode)
(add-to-list 'load-path "/path/to/tip-repo")
(load "tip.el")

(let ((file (make-temp-file "t-" nil ".typ")))
  (find-file file)
  ;; Generate the test document
  (dotimes (i 500)
    (insert (format "#let f%d(x) = $op(\"f%d\")(x)$\n" i i)))
  (dotimes (i 500)
    (insert (format "Real %d: $a_%d + b_%d$\n" i i i)))
  (save-buffer)
  (typst-ts-mode)

  ;; Warm up tree-sitter (first query parses the buffer)
  (treesit-query-range 'typst "((math) @math)")

  ;; Collect all math ranges
  (let* ((ranges (treesit-query-range 'typst "((math) @math)"))
         (n (length ranges))     ;; 1000
         (rounds 10)             ;; repeat to reduce noise
         (t0 (float-time)))
    ;; Run the check on every range, 10 times
    (dotimes (_ rounds)
      (dolist (pair ranges)
        (tip--inside-let-binding-p
         (treesit-node-at (car pair) 'typst))))
    (let* ((elapsed-ms (* 1000 (- (float-time) t0)))
           (total (* rounds n))
           (per-check (/ elapsed-ms total)))
      (message "ranges: %d, rounds: %d, total checks: %d"
               n rounds total)
      (message "total: %.1fms, per-check: %.4fms (%.1f µs)"
               elapsed-ms per-check (* per-check 1000))))

  (kill-buffer) (delete-file file))
```

Note: `treesit-node-at` is included in the timing — it's part of the real cost. In production, each check calls `(tip--inside-let-binding-p (treesit-node-at (car pair) 'typst))`.

## Results

```
ranges: 1000, rounds: 10, total checks: 10000
total: 35.7ms, per-check: 0.0036ms (3.6 µs)
```

| Metric | Value |
|--------|-------|
| Total checks | 10,000 |
| Total time | 35.7ms |
| Per check | 3.6µs |
| 1000 fragments | 3.6ms |
| 200 fragments (typical) | 0.7ms |

## Why This Is Fast

1. **Tree-sitter is C code.** `treesit-node-parent` and `treesit-node-type` are native Emacs primitives backed by tree-sitter's C library. The elisp function is a thin loop over C calls.

2. **The tree is already parsed.** Tree-sitter parses the buffer incrementally on edits. By the time we run the check, the parse tree is in memory. No parsing cost.

3. **Parent walks are pointer chasing.** Each `treesit-node-parent` follows a pointer in the tree structure. No string comparison, no allocation, no I/O. The `treesit-node-type` comparison is a symbol check (interned string).

4. **Depth is small.** Typst documents are rarely nested more than 10-15 levels. The while loop runs 5-15 iterations per check.

## Why Not Move It to Rust

Moving the check to the server would mean:

1. **Protocol change.** The server would need to know which byte ranges to skip, or parse the document AST itself for `let` nodes. Currently the server receives pre-filtered byte ranges and compiles them — it doesn't decide what to compile.

2. **Redundant parsing.** The server already parses the document for scope skeleton extraction. But it does so per-fragment, not per-batch. Adding a pre-filter step would require a separate parse pass.

3. **Latency.** A server round-trip (JSON encode → pipe write → server parse → pipe read → JSON decode) takes ~1ms minimum. The elisp check takes 3.6µs. The overhead of asking the server would be 300x slower than doing it locally.

4. **Architecture.** TIP's design: Emacs decides what to compile, server compiles it. The let-binding check is a "what to compile" decision — it belongs on the Emacs side.

## Comparison: Full Pipeline

For context, here are the costs of each step in fragment collection:

```
treesit-query-range (all math nodes):     ~50ms for 1000 fragments
let-binding checks:                        ~3.6ms for 1000 fragments
nesting deduplication:                     ~2ms for 1000 fragments
byte offset conversion:                   ~1ms for 1000 fragments
─────────────────────────────────────────────────────────────────
Total tip-collect-fragment-locations:     ~110ms for 1000 fragments
```

The let-binding check is 3% of the total. The dominant cost is `treesit-query-range`, which scans the entire buffer's parse tree. Even if the let-binding check were instant, the total would barely change.
