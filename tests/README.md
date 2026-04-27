# tip — Tests

Three buckets, picked by what kind of guarantee they give:

```
tests/
├── ert/          headless ERT — `emacs --batch -l <file>`
├── integration/  daemon-driven scenario specs — `./run.sh`
└── manual/       interactive / perf / visual — `emacs -Q -l <file>`
```

A shared `setup.el` resolves the repo root from its own location and
exports `tip-test-repo-root` / `tip-test-lisp-dir` /
`tip-test-server-binary` so individual files don't have to recompute
relative paths.

## Running everything

### With Nix (the easy path)

```bash
nix run .#test                        # cargo + ERT + integration --headless
nix run .#test-interactive            # list manual probes; pass a name to launch
nix run .#test-interactive -- 30-interactive-visual
```

`nix flake check` runs `cargo-test` + `emacs-batch-test` (ERT only — no
server binary in the sandbox).  Use `nix run .#test` for the full
matrix.

### Without Nix (FHS distros: Arch, Ubuntu, Fedora, Debian, …)

You'll need:

| Tool                       | Used by             | Install hint (Arch / Debian)                              |
|----------------------------|---------------------|-----------------------------------------------------------|
| Rust toolchain (1.77+)     | cargo / build       | `pacman -S rust` / `apt install cargo rustc`              |
| Emacs 28+                  | every elisp test    | `pacman -S emacs` / `apt install emacs`                   |
| LaTeX + dvisvgm            | latex specs         | `pacman -S texlive-most` / `apt install texlive-full dvisvgm` |
| `typst-ts-mode`            | typst specs         | install from melpa or fetch from codeberg.org/meow_king/typst-ts-mode |
| tree-sitter grammars       | typst / latex / md  | put `libtree-sitter-{typst,latex,markdown}.so` somewhere on `treesit-extra-load-path`; `M-x treesit-install-language-grammar` is the easiest way |

Build once, then run:

```bash
# Build the server (debug build is enough for the tests).
cd tip-server && cargo build && cd ..

# 1. Rust unit + integration tests (cargo).
(cd tip-server && cargo test --workspace)

# 2. Headless ERT.
for f in tests/ert/*.el; do
  echo "=== $f ==="
  emacs --batch -l "$f"
done

# 3. Daemon-driven integration specs.
#    --headless skips the visible frame (CI mode).
tests/integration/run.sh --headless

# 4. (Optional) interactive / perf probes — humans drive these.
emacs -Q -l tests/manual/30-interactive-visual.el
```

If `tests/integration/run.sh` complains that `tip-test-daemon-run`
never finished, the most common causes are: tip-server binary
missing from `$PATH` (point at `tip-server/target/debug/tip-server`),
or one of the tree-sitter grammars missing — set `TIP_IT_GRAMMAR_PATH`
/ `TIP_IT_MARKDOWN_GRAMMAR_PATH` / `TIP_IT_LATEX_GRAMMAR_PATH` to
directories containing `libtree-sitter-LANG.so`.

Filter specs by substring:

```bash
TIP_IT_TEST=multiline tests/integration/run.sh --headless
TIP_IT_TEST=katex     tests/integration/run.sh --headless
```

## ert/  — headless ERT

Plain ERT tests that run under `emacs --batch`.  Pure-elisp parsers,
helpers, render-pipeline data structures, plus `test-server.el` which
spawns the real Rust binary for a protocol round-trip + version-
handshake check.  `ert-skip` deselects gracefully when the binary
isn't built.

```bash
emacs --batch -l tests/ert/test-tip.el
emacs --batch -l tests/ert/test-tip-markdown.el
emacs --batch -l tests/ert/test-tip-latex-treesit.el
emacs --batch -l tests/ert/test-server.el
```

Run ALL ERT files in one go:

```bash
for f in tests/ert/*.el; do emacs --batch -l "$f"; done
```

## integration/  — daemon framework + specs

Long-lived emacs daemon, one spec at a time, real GUI / overlays /
treesit / typst-ts-mode / tree-sitter grammars.  Specs use the
`tip-test-deftest` macro from `lib/tip-test.el`.

```bash
tests/integration/run.sh                 # all specs, GUI window
tests/integration/run.sh --headless      # CI mode
TIP_IT_TEST=multiline tests/integration/run.sh   # filter by substring
```

The daemon needs:

  * `emacs` (28+) on PATH
  * `tip-server` built (`cd tip-server && cargo build`)
  * tree-sitter grammars for typst, latex, markdown (auto-installed
    on first run when running outside Nix; under Nix the wrapper
    sets `TIP_IT_GRAMMAR_PATH` etc.)

Add a new spec by dropping `<NN>-name-backend.el` into `specs/` and
calling `tip-test-deftest` inside it — `run.sh` discovers it on next
invocation.

## manual/  — humans look at it

Interactive scale/baseline tuning, batch perf benchmarks, latex GUI
visual stress.  Not regression tests; not part of CI.  Each file
opens an Emacs frame and either expects you to drive it or reports
numbers to a results file.

```bash
emacs -Q -l tests/manual/30-interactive-visual.el
emacs -Q -l tests/manual/40-batch-perf-benchmark.el  # writes perf-results.txt
```
