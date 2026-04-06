# TIP — Typst Inline Preview

Inline math and diagram preview for [typst-ts-mode](https://codeberg.org/meow_king/typst-ts-mode). Renders Typst fragments as SVG overlays directly in the buffer.

## Features

- **Inline math preview** with baseline-aligned rendering — `$a + b$` becomes a crisp SVG sitting on the text baseline
- **Displayed math** — multi-line `$ ... $` blocks render as centered images
- **CeTZ and Fletcher diagram preview** — `#cetz.canvas(...)` and `#diagram(...)` calls render inline
- **Scope-aware compilation** — fragments see `#let`, `#import`, `#set`, `#show` from their scope context
- **Auto-toggle overlays** — cursor entering a fragment reveals source, leaving recompiles
- **Live preview** in a childframe while editing (`M-x tip-live-setup`)
- **Indirect edit** — `C-c '` opens a dedicated edit buffer with live preview
- **Jump to fragment** — `M-x tip-jump` for avy-style selection
- **Error highlighting** — fragments that fail to compile get a subtle background highlight
- **Theme tracking** — overlays recompile automatically when you switch themes
- **Zero-config** — single Rust binary, auto-started, no Python/pip/ports

## Quickstart

```elisp
(use-package tip
  :hook (typst-ts-mode . tip-mode))
```

On first activation, TIP will prompt to compile the `tip-server` binary from source (requires Rust toolchain) or pull a Docker image.

## Commands

| Command | Key | Description |
|---------|-----|-------------|
| `tip-mode` | | Toggle inline preview minor mode |
| `tip-render-all` | | Compile all fragments in buffer |
| `tip-send-nbd` | | Compile visible fragments (avoiding point) |
| `tip-jump` | | Avy-style jump to a fragment |
| `tip-edit` | `C-c '` | Edit fragment in indirect buffer with live preview |
| `tip-live-setup` | | Enable childframe live preview |
| `tip-live-teardown` | | Disable live preview |
| `tip-open` | | Reveal source at point |
| `tip-clear-buffer` | | Remove all overlays |

## Configuration

```elisp
;; Scaling (1.0 = match surrounding text size)
(setq tip-scale 1.0)

;; Baseline fine-tuning (adjust if math sits too high/low)
(setq tip-baseline-offset -2)

;; Diagram function names to recognize for preview
(setq tip-diagram-functions
      '("cetz.canvas" "canvas" "diagram" "comm-diag" "fletcher.diagram"))
```

## Dependencies

- Emacs 29.1+ (for tree-sitter support)
- [typst-ts-mode](https://codeberg.org/meow_king/typst-ts-mode)
- Rust toolchain (to compile `tip-server`) or Docker

## Architecture

TIP consists of two parts:

**tip.el** — Emacs package handling fragment detection (via tree-sitter), overlay management, and user interaction.

**tip-server** — A Rust binary that maintains full document state and compiles fragments on demand. Communicates with Emacs via JSON over stdio (same pattern as LSP servers). Returns inline SVG data with baseline metrics.

The compilation approach: for each math fragment, tip-server builds a synthetic Typst document that preserves the fragment's scope context (all `#let`, `#import`, `#set`, `#show` bindings visible at that position), compiles it via the typst crate, then crops the SVG to ink bounds and measures the baseline.

## Fragment Detection Subtleties

**Diagram calls inside `#let` are skipped.** If you write `#let canvas(..args) = cetz.canvas(..args)`, the `cetz.canvas` in the definition body is not treated as a renderable fragment — only actual invocations like `#canvas(...)` in the document body are previewed.

**Project root detection.** tip-server walks up from the file's directory to find `typst.toml`, `Kodama.toml`, or `.git` as the project root (checked in that order). The main file's virtual path is set relative to this root, so relative imports like `#import "../_lib/kodama.typ"` resolve correctly even from subdirectories. If no marker is found, the file's parent directory is used.

**Nested math filtering.** Tree-sitter returns all math nodes including nested ones (e.g., `$a + #text[$b$]$` returns both outer and inner). TIP filters to only compile outermost fragments. Math inside diagram calls (e.g., `node((0,0), $A$)`) is part of the diagram, not a separate fragment.

**Empty math skipped.** `$$` and `$ $` (empty or whitespace-only math) are never sent to the server.

## HTML-Targeting Documents and Kodama Compatibility

TIP supports Typst documents targeting HTML export (`html.elem`, `html.frame`, etc.). This required several non-obvious design choices:

### tip-server side

- **HTML feature enabled.** The Typst `Library` is built with `Feature::Html` so `html.elem`, `html.frame`, etc. are defined. Without this, any scope skeleton containing `html.*` references (common in kodama files) would fail with "unknown variable: html". In paged export mode these are no-ops but must still parse.
- **Kodama.toml as root marker.** `find_project_root` checks for `Kodama.toml` alongside `typst.toml` and `.git`. This is critical: kodama projects have files in `trees/references/` that import `../_lib/kodama.typ` — the root must be above `trees/` for relative imports to resolve.
- **Main file vpath.** The synthetic compilation document uses a fake `FileId` whose virtual path matches the real file's position relative to root. Without this, relative imports in the scope skeleton resolve against `/tip-main.typ` (root dir) instead of the actual file's subdirectory.

### tip.el side

- **`#let` body filtering.** Diagram calls inside `#let` bindings are skipped — they're function definitions, not rendered content. This prevents false positives from patterns like `#let canvas(..args) = html.elem(...)[cetz.canvas(..args)]` where both `canvas(..args)` (pattern) and `cetz.canvas(..args)` (body) would otherwise match `tip-diagram-functions`.
- **Wrapper call detection.** The user-defined `#canvas(...)` wrapper IS detected as a diagram (its name matches `tip-diagram-functions`). In paged mode, `html.elem` is a no-op, so the wrapper simply calls through to `cetz.canvas` and produces the expected output.

### tip-kodama.el

Separate file for kodama-specific integration. `tip-kodama-mode` auto-enables when `Kodama.toml` is found in a parent directory (shown as `TIP-kodama` in the mode line). Currently notifies the user; future work: custom preamble, html-aware page setup.

```elisp
(require 'tip-kodama) ;; or autoloaded via tip-mode
```

## Security and Network Access

**tip-server needs internet access** to download Typst packages (`@preview/cetz`, `@preview/fletcher`, etc.) on first use. These are fetched from the official Typst package registry, the same way `typst compile` does. After initial download, packages are cached locally.

If your documents only use `@local/` packages or no imports at all, no network access is needed.

**About the codebase**: This project was substantially written with LLM assistance (Claude). All code is open source and auditable. The tip-server binary is a straightforward Typst compiler wrapper — it reads stdin, compiles Typst fragments, and writes SVG to stdout. It makes no network connections except for Typst package resolution. If you'd rather not trust a pre-built binary, build from source:

```bash
cd tip-server && cargo build --release
```

You can audit the full dependency tree with `cargo tree`.

**Network monitoring**: To verify what tip-server does on the network, run it in a no-network sandbox:
```bash
unshare --net tip-server   # blocks all network — works if packages are cached
```
Or monitor connections with strace:
```bash
strace -f -e trace=network tip-server 2>/tmp/tip-net.log
```

## Acknowledgements

TIP builds on ideas and code from several projects:

**[org-latex-preview](https://code.tecosaur.net/tec/org-mode)** (Karthik Chikmagalur and contributors) — The original inspiration. TIP's overlay auto-toggle system, baseline alignment approach (ascent percentage from height/depth), and the general architecture of "compile fragment, display as overlay" all descend from org-latex-preview. The key insight that `ascent = 100 * (1 - depth/height)` produces correct baseline alignment came directly from studying org-latex-preview's implementation.

**[typst-py](https://github.com/messense/typst-py)** (messense) — The original TIP v1 used typst-py's Python bindings to compile fragments. typst-py demonstrated that Typst's Rust compiler could be wrapped as a library and called from other languages, which gave us the confidence to build a native Rust server. The v1 Python server's comemo-powered 3ms/fragment performance set the bar that tip-server had to match.

**[tinymist](https://github.com/Myriad-Dreamin/tinymist)** (Myriad-Dreamin) — tinymist's architecture deeply influenced tip-server. The `TipWorld` implementation follows patterns from tinymist's `CompilerUniverse` — in-memory VFS overlay, font discovery via `FontSearcher`, package resolution for `@local/` and `@preview/` packages. tinymist's scope resolution code (`previous_decls`, `scope_defs`) informed our scope skeleton extraction approach, though we took a different path (AST walk collecting scope-defining nodes rather than full semantic analysis).

**[kodama](https://github.com/Andrew15-5/kodama)** (Andrew15-5) — kodama's `bounded()` technique (`text(top-edge: "bounds", bottom-edge: "bounds", eq)`) taught us how to prevent SVG clipping on expressions with deep subscripts or tall fractions. While we ultimately don't use `bounded()` for baseline alignment (it breaks baseline consistency across expressions), the technique remains valuable and is referenced in the server's anti-clipping preamble. kodama's two-pass baseline measurement approach (measure + position introspection) was also studied extensively.

**[Typst](https://github.com/typst/typst)** (Typst GmbH) — TIP compiles fragments using the typst crate (v0.14.2) as a library, with typst-svg for SVG export. The `World` trait design makes it possible to embed the compiler in a long-running server with an in-memory VFS.

## Contributors

- Elio Azuray — original author
- [dekuofa1995](https://github.com/dekuofa1995) — v1 contributions

## License

GPL-3.0
