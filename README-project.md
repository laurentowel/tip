# TIP — Typst Inline Preview

Render Typst math fragments as inline SVG previews in Emacs, like org-latex-preview for LaTeX.

## Screenshot

Open a `.typ` file, enable `tip-mode`, and math fragments render as SVG overlays:
- Inline math: baseline-aligned with surrounding text
- Display math: vertically centered, marked with **𝐃** indicator
- Move cursor into a preview → source revealed. Move out → recompiled automatically.

## Quick Start

```bash
# 1. Build the server
cd tip-server
cargo build --release

# 2. In Emacs (requires Emacs 29.1+, typst-ts-mode, tree-sitter grammar)
(add-to-list 'load-path "/path/to/tip-improve/tip")
(setq tip-server-executable "/path/to/tip-improve/tip-server/target/release/tip-server")
(require 'tip)
(add-hook 'typst-ts-mode-hook #'tip-mode)
```

That's it. Open a `.typ` file — fragments render automatically.

## Features

- **Scope-aware**: fragments see local `#let`, `#import`, `#set`, `#show` — not just a global preamble
- **All import types**: relative files, `@local/` packages, `@preview/` packages
- **Fast**: 2-14ms per fragment via persistent Typst World + incremental compilation
- **Zero-config**: single binary, auto-started, no Python/pip/port setup
- **Baseline-aligned**: inline math sits on the text baseline consistently
- **Auto-toggle**: cursor enters math → source shown. Cursor leaves → preview appears.
- **Live preview**: eldoc shows compiled preview while editing inside `$...$`
- **Theme-aware**: syncs Emacs foreground/background colors
- **Three rendering modes**:
  - Inline `$a+b$` — tight, baseline-aligned
  - Single-line display `$ integral f $` — centered, 𝐃 indicator
  - Multi-line display — wide block rendering

## Customization

```elisp
;; Scale previews (1.0 = match text size)
(setq tip-scale 1.0)

;; Fine-tune baseline alignment (eval and adjust until baselines match)
(progn (setq tip-baseline-offset -2) (tip-render-all))

;; Display math indicator (set nil to disable)
(setq tip-display-indicator nil)

;; Custom font directories for the server
;; (set via preamble or server args)
```

## Performance

Measured with Emacs 30.2, release build, real display (not batch mode):

| Document | Fragments | Batch compile | Per-fragment | Single edit |
|----------|-----------|---------------|-------------|-------------|
| 50 lines | 50 | 0.10s | **2.1ms** | ~2ms |
| 164 lines | 200 | 0.94s | **4.8ms** | ~5ms |
| 804 lines | 1000 | 13.8s | **14.1ms** | ~8ms |

- **Single edit latency**: time from leaving a fragment to overlay appearing (async, non-blocking)
- **Per-fragment cost** scales with document size (scope skeleton extraction)
- **Overlay creation + redisplay**: negligible (<15ms for 200 fragments)

## Architecture

```
Emacs (tip.el)          Rust (tip-server)
     │                        │
     │──── sync buffer ──────→│  TipWorld (in-memory VFS)
     │──── compile_fragments ─→│  Scope extraction (AST walk)
     │                        │  Typst compilation
     │←── SVG + baseline ─────│  SVG cropping + baseline measurement
     │                        │
     └── overlay display      └── Package resolution (@local, @preview)
         (preview-toggle.el)
```

Communication: JSON-RPC over stdio pipes. Same pattern as LSP.

## Testing

```bash
# Rust (120+ tests)
cd tip-server && cargo test

# Emacs unit tests (11 tests)
emacs --batch -l tip/test-tip.el

# Emacs integration (needs sandbox with typst-ts-mode)
emacs -Q --init-directory tip/tests/emacs-sandbox -l tip/tests/test-open-close.el
emacs -Q --init-directory tip/tests/emacs-sandbox -l tip/tests/test-stress-edit.el
emacs -Q --init-directory tip/tests/emacs-sandbox -l tip/tests/test-rapid-movement.el

# Interactive visual test
emacs -Q --init-directory tip/tests/emacs-sandbox -l tip/tests/visual-test.el

# Interactive scale/baseline tuning
emacs -Q --init-directory tip/tests/emacs-sandbox -l tip/tests/test-scale-slider.el
```

## Kodama Compatibility

TIP works with files targeting [kodama](https://github.com/kokic/kodama)'s HTML export. Files using `#show: kodama` compile math previews correctly — TIP's page setup overrides kodama's page settings so inline math stays tight.

## Roadmap

- [x] Inline math preview with baseline alignment
- [x] Scope-aware compilation (#let, #import, #set, #show)
- [x] All import types (relative, @local, @preview)
- [x] Math inside containers (#list, #box, #definition, #grid, etc.)
- [x] Kodama compatibility
- [ ] CeTZ diagram preview
- [ ] Fletcher diagram preview
- [ ] Baseline measurement refinement (font-metric-aware)
- [ ] Pre-built binary downloads

## Project Layout

```
tip-improve/
├── tip/                    Emacs package
│   ├── tip.el              Main package (MELPA-compliant)
│   ├── preview-toggle.el   Generic overlay auto-toggle (reusable)
│   └── tests/              Integration tests + sandbox
├── tip-server/             Rust server
│   ├── crates/
│   │   ├── tip-protocol/   Messages + stdio transport
│   │   ├── tip-core/       Typst World, compiler, scope extraction
│   │   └── tip-server/     Binary entry point
│   └── testkit/            Shared test utilities
├── ref/                    Reference repos (typst, tinymist, kodama, etc.)
└── legacy/                 Old Python-based implementation
```

See [CLAUDE.md](CLAUDE.md) for full architecture, baseline alignment deep-dive, and development guide.
