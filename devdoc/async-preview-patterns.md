# Async / throttle / debounce patterns for tip

Notes from reverse-engineering the live-preview machinery in tec's
`org-latex-preview.el`. Applicable to tip-live.el (existing) and to any
live-preview story for tip-latex.

## Emacs concurrency model

Emacs is single-threaded. Everything we call "async" is actually
**multi-process**: we spawn a subprocess and let Emacs pump its stdout via
a process filter between commands. True parallelism (when it happens) is in
the subprocess's own CPU work.

Implication: tip-live and tip-latex live-preview don't gain from threading
— they gain from **not blocking** the main Emacs loop while the compile
runs. Three levers:

1. `make-process :filter …` — read stdout as it arrives, update overlays
   progressively.
2. **Throttle / debounce** the trigger so we don't fire a fresh compile on
   every keystroke.
3. **Adaptive throttling** — let the throttle period grow or shrink based
   on actual observed compile time.

## `org-async-call` (org-macs.el:411)

Thin wrapper over `start-process` with:

- `:success` / `:failure` / `:filter` callbacks.
- A concurrency limit (`org-async-process-limit`) and an overflow queue.
- Callback chaining: a success callback can itself be another async task
  via `(org-async-task CMD …)`. The call site expresses the whole pipeline
  (latex → dvisvgm → finalize) as a tree, each node with its own filter
  for progressive handling.
- Process tuning defaults:
  ```
  process-adaptive-read-buffering nil   ; don't hoard output
  process-connection-type nil            ; use a pipe, not a pty
  read-process-output-max 65536          ; bigger stdout chunks
  ```
  These matter for latex + dvisvgm, which emit lots of stdout.

### Async tree for the dvisvgm pipeline

```
latex + stdout filter  (parse "Preview: Tightpage" + snippet markers)
   │                    → record per-fragment baseline + bbox
   ├─ success →  dvisvgm + stdout filter  (parse "output written to X.svg")
   │              │                        → read SVG, post-process colors,
   │              │                          place overlay immediately
   │              ├─ success → finalize (cleanup temps, check all done)
   │              └─ failure → remove overlays + message
   └─ failure →  remove overlays + message
```

Users see previews fill in progressively as dvisvgm writes each SVG,
rather than a "nothing for 3 seconds, then everything at once" batch.

## Throttle vs debounce

| behavior                | throttle                     | debounce                     |
|-------------------------|------------------------------|------------------------------|
| first call              | runs immediately             | queued                       |
| during burst            | ignored (flag set)           | timer reset each call        |
| end of burst            | runs once more               | runs once after quiet period |
| typical use             | live preview on movement     | "wait for user to stop typing" |

OLP uses **throttle** for live preview (leading + trailing edge) because
instant feedback matters; the trailing run handles "I stopped mid-fragment,
recompile with the final content."

OLP uses **debounce** for things like buffer-change tracking where only
the last state matters.

### Minimal implementations

```elisp
(defun tip--throttle (func duration-var)
  "Return a leading+trailing edge throttle of FUNC.
DURATION-VAR is a symbol whose value is the throttle duration in seconds;
re-read on each tick so adaptive updates take effect."
  (let ((waiting nil))
    (lambda (&rest args)
      (unless waiting
        (apply func args)
        (setq waiting t)
        (run-at-time (symbol-value duration-var) nil
                     (lambda ()
                       (setq waiting nil)
                       (apply func args)))))))

(defun tip--debounce (func duration)
  "Return a trailing-edge debounced FUNC."
  (let ((timer nil))
    (lambda (&rest args)
      (if (timerp timer)
          (timer-set-time timer (+ (float-time) duration))
        (setq timer
              (run-at-time duration nil
                           (lambda ()
                             (cancel-timer timer)
                             (setq timer nil)
                             (apply func args))))))))
```

## Adaptive throttle

`org-latex-preview-live--update-times` keeps a rolling window of the last 3
compile durations and sets the throttle period to their mean:

```elisp
(defvar-local tip--preview-times (make-vector 3 0.3))
(defvar-local tip--preview-times-index 0)
(defvar-local tip-live-throttle 0.3)

(defun tip--record-preview-time (seconds)
  (aset tip--preview-times
        (% (cl-incf tip--preview-times-index) 3)
        seconds)
  (setq-local tip-live-throttle
              (/ (apply #'+ (append tip--preview-times nil)) 3)))
```

**Why this matters**: a buffer with a tikz-heavy preamble might take 800ms
per compile. Firing at 300ms intervals queues work faster than we can
finish it. Adaptive throttle settles to ~800ms naturally, keeping the
server busy but not backlogged.

Hook this into the response path: when `tip--send-request`'s callback runs,
record `(- (float-time) start-time)`.

## Recommendations for tip

### `tip-live.el` (exists, could be better)

- Replace the fixed `(run-with-idle-timer 0.3 ...)` with a leading+trailing
  throttle driven by an adaptive `tip-live-throttle` variable.
- Record compile duration in the existing response callback; feed
  `tip--record-preview-time`.
- Net effect: better responsiveness on small buffers, back-pressure on
  heavy preambles.

### `tip-server-proc.el`

Apply OLP's process tuning when spawning the server:

```elisp
(let ((process-adaptive-read-buffering nil)
      (process-connection-type nil)
      (read-process-output-max 65536))
  (make-process ...))
```

Negligible downside; measurable improvement on stdout-heavy backends.
Worth doing before tip-latex lands (its streaming preview.sty output is
exactly the stdout-heavy case).

### Streaming placement (tip-latex)

When tip-server-latex ships, its `compile_fragments` response can be
**incremental** — emit one JSON line per fragment as its SVG finalizes,
rather than one batch at the end. This parallels OLP's dvisvgm filter
behavior and gives the same "overlays fill in as you watch" UX.

Protocol change is small: today `compile_fragments` returns one response
with `{fragments: [...]}`. Incremental form returns a stream of
`{fragment: {...}}` lines followed by a terminating `{done: true}` line.
The existing `tip--handle-response` already processes newline-delimited
JSON; adding a "progressive result" discriminator is a few lines. Defer
until tip-latex needs it, but the door is open.

### Concurrency limit (future)

If we ever run multiple servers (one per backend, as foreseen in
CLAUDE.md's "deferred per-backend process" note), a simple process-stack +
queue like `org-async--stack` handles the "user has 20 tip-mode buffers
across two languages" case. Not needed yet.

## What we don't need

- **Full `org-async-call`** — Emacs has `make-process` with sentinel + filter
  already. We don't need a framework, just a small helper that records
  start-time for adaptive throttle.
- **Threading**. See above: Emacs is single-threaded; the wins come from
  subprocess parallelism and non-blocking stdout handling.
- **Multi-step callback chaining** for tip-server-typst — its
  `compile_fragments` is one shot. For tip-server-latex the tree is
  two-deep (latex → dvisvgm) but both run in the server process; Emacs
  sees one request and one response. The tree is the server's problem,
  not Emacs's.
