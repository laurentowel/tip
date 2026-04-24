# arxiv-sampler

Random-sample recent arxiv math papers and run `tip-mode` against each.
The point is to find real failure modes — missing class files,
non-standard macro usage, mid-document `\newcommand` blocks, etc. —
that `/tmp/tip-multifile-demo` won't surface.

## Running

```sh
# defaults: 10 papers from math.AP, 180s per paper
./sample.py

# smoke-test 3 papers
./sample.py --n 3

# try a different subject class
./sample.py --category math.GT --n 5
```

Requires `emacs`, `latex`, `dvisvgm`, `tip-server` on PATH. Builds of
the server live at `../tip-server/target/release/tip-server` by default;
override with `TIP_SERVER_EXECUTABLE=...`.

## What you get

- Markdown summary table to stdout: (id, detected, rendered, errored,
  elapsed, first-error) per paper, plus an overall pass rate.
- JSON blob of the raw rows at the end for machine consumption.

## Conventions

- **Never delete recordings** (`CLAUDE.md` memory). The `tmp/` workdir
  is auto-cleaned by `tempfile.TemporaryDirectory`, but source tarballs
  are gone after the run. Don't cache them long-term without explicit
  opt-in — arxiv etiquette.
- Sleeps 3s between tarball fetches. Don't tighten without reading
  [arxiv's abuse policy](https://info.arxiv.org/help/api/tou.html).
- Every paper is its own tmpdir + tip-server subprocess, so one
  pathological paper doesn't poison the next.
