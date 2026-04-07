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

## The Pipeline

In a typical `tip-render-all` call on a 200-fragment document:

```
Elisp side:
  treesit-query-range (find all math):    ~10ms
  let-binding checks (200 × 2.4µs):       0.5ms
  nesting dedup:                           0.4ms
  byte conversion:                         0.2ms
  json-encode + pipe write:                0.5ms
                                          ─────
  Elisp total:                            ~12ms

Server side (1 batch request):
  JSON parse:                              0.1ms
  200 scope skeletons:                    ~50ms
  200 typst::compile (comemo cached):    ~100ms
  200 SVG export + crop:                  ~20ms
  JSON encode + pipe write:                2ms
                                          ─────
  Server total:                          ~170ms

Elisp callback:
  json-parse-string:                       1ms
  200 overlay creates:                    ~10ms
                                          ─────
  Callback total:                         ~11ms

Total: ~193ms for 200 fragments (~1ms/fragment)
```

The IPC is a small fraction. The dominant cost is compilation on the server side, which is where it belongs.
