# IPC Benchmark: Emacs ↔ tip-server Round-Trip Cost

## The Question

How much does it cost to talk to the server? This matters for deciding what should be computed in elisp (tree-sitter) vs delegated to Rust (tip-server).

## Setup

A minimal Typst buffer with `$a + b$`. The server is already running and warmed up (first sync completed). We measure two operations:

1. **Sync**: send buffer content, receive `{"ok": true}`. No compilation — pure IPC overhead.
2. **Compile**: send one tiny fragment (`$a$`), receive SVG. IPC + compilation + SVG generation.

## The Benchmark

```elisp
(require 'package) (package-initialize) (require 'typst-ts-mode)
(add-to-list 'load-path "/path/to/tip-repo")
(load "tip.el")

(let ((file (make-temp-file "t-" nil ".typ")))
  (find-file file)
  (insert "$a + b$")
  (save-buffer)
  (typst-ts-mode)
  (tip-mode 1)
  (sleep-for 1)

  ;; Warm up
  (tip--sync-buffer)
  (let ((deadline (+ (float-time) 3)))
    (while (and (< (float-time) deadline)
                (> (hash-table-count tip--pending-callbacks) 0))
      (accept-process-output tip--server-process 0.1)))

  ;; --- Sync round-trip ---
  (let ((t0 (float-time))
        (n 100)
        (done 0))
    (dotimes (_ n)
      (tip--send-request
       "sync"
       `(("uri" . ,(buffer-file-name))
         ("content" . "$a$"))
       (lambda (_) (cl-incf done))))
    (let ((deadline (+ (float-time) 10)))
      (while (and (< (float-time) deadline) (< done n))
        (accept-process-output tip--server-process 0.01)))
    (let ((elapsed-ms (* 1000 (- (float-time) t0))))
      (message "SYNC: %d calls, %.1fms total, %.2fms per call"
               n elapsed-ms (/ elapsed-ms (float n)))))

  ;; --- Compile round-trip ---
  (let ((t0 (float-time))
        (n 50)
        (done 0))
    (dotimes (_ n)
      (tip--send-request
       "compile_fragments"
       `(("uri" . ,(buffer-file-name))
         ("fragments" . ,(vector '(("start" . 0) ("end" . 3))))
         ("color" . "#000000")
         ("preamble" . ""))
       (lambda (_) (cl-incf done))))
    (let ((deadline (+ (float-time) 10)))
      (while (and (< (float-time) deadline) (< done n))
        (accept-process-output tip--server-process 0.01)))
    (let ((elapsed-ms (* 1000 (- (float-time) t0))))
      (message "COMPILE: %d calls, %.1fms total, %.2fms per call"
               n elapsed-ms (/ elapsed-ms (float n)))))

  (tip-shutdown)
  (sleep-for 0.3)
  (kill-buffer) (delete-file file))
```

Each call is independent — we fire N requests, then drain all responses. This measures the amortized per-call cost including JSON encode/decode, pipe I/O, server processing, and callback dispatch.

## Results

```
SYNC: 100 calls, 2.3ms total, 0.02ms per call (23 µs)
COMPILE: 50 calls, 3.4ms total, 0.07ms per call (68 µs)
```

| Operation | Total | Per call | What it includes |
|-----------|-------|----------|------------------|
| Sync | 2.3ms / 100 | 23µs | json-encode, pipe write, server parse, server store, server respond, pipe read, json-parse-string, callback dispatch |
| Compile | 3.4ms / 50 | 68µs | All of sync + scope skeleton extraction + typst::compile + SVG export + SVG cropping + baseline measurement |

## What This Means

The **minimum cost of asking the server anything** is 23µs. This is the floor — even if the server did zero work, the IPC machinery costs 23µs per round-trip.

For comparison, operations that can be done in elisp via tree-sitter:

| Elisp operation | Per call | vs IPC floor |
|----------------|----------|--------------|
| `tip--inside-let-binding-p` (parent walk) | 2.4µs | 10x faster |
| `tip--get-bounds-of-math-at-point` (parent walk) | ~3µs | 8x faster |
| `treesit-node-at` + `treesit-node-type` | ~0.5µs | 46x faster |

Any check that can be expressed as a tree-sitter parent walk should stay in elisp. The server should only handle work that requires the Typst compiler (scope extraction, compilation, SVG rendering).

## The Full Pipeline (measured)

Realistic 200-fragment document: imports, `#let` bindings, `#set`/`#show` rules,
mix of simple inline (`$a_i + b_i$`), medium (`$integral ... + sum ...$`),
complex (`$frac(alpha^2 + beta, gamma) dot score(i)$`), and display math
(multi-line with limits and integrals). 13KB document.

```
Benchmark: 200 realistic fragments
  Initial compile:        715ms total, 3.6ms/fragment
  Second compile (warm):  706ms total, 3.5ms/fragment
```

The IPC overhead (23µs per round-trip) is negligible compared to the 715ms
total — one batch request, one batch response. The dominant cost is scope
skeleton extraction + typst::compile on the server side, which is exactly
where it should be.

Note: comemo caching provides only ~1% speedup on the second compile here
because each fragment has a different scope skeleton. On documents where
fragments share similar scopes (e.g., all at the top level), comemo is
more effective (~50% speedup observed in earlier benchmarks).
