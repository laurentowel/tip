# tip-server-latex v1 perf baseline

Wall-clock measurements from `cargo test --release -p tip-server-latex --test perf_baseline`.
Host: Arch Linux, TeX Live 2026, single-process server, no precompile, no cache.

## Results

| scenario                       | frags | total     | per-fragment |
|--------------------------------|-------|-----------|--------------|
| light preamble (amsmath)       | 3     | 385 ms    | 128 ms       |
| heavy preamble (amsthm, bm, custom macros, DeclareMathOperator ×2) | 8 | 442 ms | 55 ms |
| warm (same batch repeated)     | 6     | 333 ms    | 56 ms        |
| cold (same batch first run)    | 6     | 380 ms    | 63 ms        |

## What the shape means

- **Fixed per-batch cost ≈ 300-350 ms.** This is latex startup + preamble
  parsing + font setup + DVI writer open. It's paid once per
  `compile_fragments` request, regardless of how many fragments are in
  it.
- **Marginal per-fragment cost ≈ 15-20 ms.** Each added fragment adds a
  `preview` environment to the batch `.tex` and a DVI page for
  dvisvgm to process. Additive and predictable.
- **Warm vs cold (Δ -47 ms)**: very small. The server process stays up
  between requests but re-invokes latex each time, so there's almost no
  in-process state worth keeping. This tells us the optimization target
  is the latex subprocess, not the server.

## Comparison with tip-server-typst

| |           typst       | latex (v1)    |
|-|-----------------------|---------------|
| single-fragment edit  | ~2-8 ms       | ~380 ms       |
| batch of 50 (full buffer) | ~100 ms  | ~700 ms est. |
| batch of 200           | ~1 s          | ~3 s est.    |

Typst is ~50× faster per-fragment because the compiler is in-process
(embedded Rust crate, warm between requests, comemo memoization on
unchanged inputs). LaTeX has to shell out. That gap is architectural;
closing it fully means a persistent format-file-loaded latex daemon —
which doesn't exist as a robust upstream.

## Where the improvements come from

### 1. `mylatexformat` precompile  (highest impact per LOC)

Dump the preamble into a `.fmt` format file on first compile; subsequent
compiles load the format with `&fmt_file` and skip preamble parsing.
Expected: **fixed per-batch cost drops from ~350 ms to ~80-100 ms** on
heavy preambles. The gap closes to ~3-5× slower than Typst for repeat
work, still much faster than re-parsing from scratch.

~30 LOC change: detect preamble hash, run latex with
`-ini -jobname=X "&latex" mylatexformat.ltx batch.tex` once, pass
`%&X` as the main compile's first line on subsequent runs.

### 2. SVG cache

sha1(preamble + fragment-text + color) → SVG on disk, keyed by
`tip-server-latex` cache dir. Before batching, filter out cached
fragments; only compile the misses. The "reopen a file with dozens of
unchanged fragments" case goes from ~seconds to zero.

~50 LOC. Most valuable once precompile is in (because a cold batch is
still amortized by not running it at all).

### 3. Streaming placement

Emit one `{fragment: {...}}` response line per SVG as `dvisvgm`
finishes it, rather than one batch response at the end. Doesn't
reduce total time, but surfaces partial progress to the user and lets
Emacs start placing overlays during compile instead of after.
Perceived latency drops on batches of 50+.

~80 LOC, biggest touchpoint: protocol-level "is this response
terminal?" flag.

### 4. Concurrent compilation (NOT worth it)

Splitting a batch across N latex processes doesn't help — each still
pays the 300 ms preamble cost. Would have to combine with precompile to
matter, at which point you're parallelizing ~80 ms jobs and the IPC
serialization overhead starts dominating. Skip.

## Expected end-state (with #1 + #2)

| scenario                          | v1    | +precompile | +cache |
|-----------------------------------|-------|-------------|--------|
| first open, 50 fragments          | 1.3 s | 900 ms      | 900 ms |
| reopen (no edits), 50 fragments   | 1.3 s | 900 ms      | ~5 ms  |
| edit one fragment                 | 380 ms| 120 ms      | 120 ms |
| edit preamble                     | 380 ms| 380 ms*     | 380 ms |

\* Editing the preamble invalidates the `.fmt`; first next compile
pays the full cost to regenerate it.

These are the right numbers for a single-user interactive preview
workflow. Further optimization (daemonized TeX, persistent processes)
is not worth the complexity.
