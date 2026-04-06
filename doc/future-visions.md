# Future Visions

Ideas that came up during development. Some are near-term, some are far out.

## 1. Full-Document Compilation (Near-term)

See `full-document-approach.md`. Compile once, walk frame tree, extract per-fragment SVGs with exact baselines. Eliminates scope skeleton machinery.

**Open tension**: The full-doc approach renders fragments exactly as they appear in the PDF — including the document's font size choices. But for Emacs inline preview, we want uniform sizing (all fragments at the same visual scale regardless of document context). The current per-fragment approach lets us override text size. The full-doc approach doesn't.

Possible resolution: a hybrid where we compile the full document for baseline/position information but still render fragments in isolation with controlled text size.

## 2. Emacs as a Typst Render Target (Medium-term)

Instead of fighting the mismatch between Typst's layout and Emacs's display, make Emacs a first-class Typst target. The idea:

- Typst text → Emacs text (with matching face properties)
- Typst math → SVG overlays (current TIP approach)
- Typst headings → Emacs headings (variable-pitch faces, scale)
- Typst lists → Emacs display properties
- Typst page layout → ignored (Emacs is a single-column editor)

This would mean: the Emacs buffer IS the rendered document. Font sizes from `#set text(size: 14pt)` would set the buffer's face `:height`. Math fragments would scale to match their surrounding text face.

This is essentially what org-mode does for LaTeX — org headings are rendered with variable-pitch faces, LaTeX fragments are SVG overlays, and the buffer approximates the final document's appearance.

**Key challenge**: Typst's layout model is fundamentally page-oriented (2D flow with columns, floats, page breaks). Emacs is fundamentally line-oriented (1D character flow with display properties). The mapping is lossy. But for mathematical writing (mostly prose + equations), the loss is acceptable.

**Prerequisite**: The full-document compilation approach. We need the compiled frame tree to know what font size each text region uses.

## 3. Rust Game Engine WYSIWYG Editor (Far-term)

A dedicated Typst editor built on a Rust game engine framework (bevy, iced, egui, or similar). Unlike Emacs, this would be a true 2D canvas:

- Render the Typst document page as the editor surface
- Click on text to edit it (like Figma or Notion)
- Math fragments are live-editable in place
- Page layout is real (columns, floats, page breaks visible)
- GPU-accelerated rendering

**Why a game engine?** Typst documents are fundamentally 2D layout. A game engine gives you a 2D canvas with GPU rendering, text layout, event handling, and 60fps updates. The Typst compiler already produces a frame tree — the game engine just renders it.

**Comparison with existing tools**:
- VS Code + tinymist: split-pane, preview in webview. Not WYSIWYG.
- Overleaf: split-pane, preview in iframe. Not WYSIWYG.
- LyX: closest to WYSIWYG for LaTeX, but clunky and abandoned.
- This: direct on-page editing like Google Docs, but for Typst.

**Why it might work**: Typst's incremental compilation (comemo) is fast enough for real-time editing. The frame tree can be rendered directly. Source mapping (spans) enables click-to-edit. The hard parts are text input handling (IME, bidi, cursor movement in 2D) and collaborative editing.

**Why it might not**: Text editors are extremely hard to build well. Emacs has 40 years of keyboard-driven editing refinement. A game engine editor would need to replicate: undo/redo, kill ring, macros, search/replace, multiple cursors, mode-line, minibuffer, package ecosystem. Starting from scratch is a multi-year effort.

**Pragmatic middle ground**: Build the WYSIWYG renderer as a **preview pane** alongside an existing text editor (Emacs, Neovim, VS Code). Click on the preview to jump to source. Edit in the text editor, see changes in the preview. This is what tinymist already does, but with tighter integration.

## 4. Reusable Elisp Abstractions

preview-toggle.el proved that extracting a generic framework from TIP-specific code makes both the framework and TIP cleaner. Other patterns in TIP that could be extracted when a second consumer appears:

**subprocess-rpc.el** — The most valuable. `tip--process-filter` (response buffering, partial line handling), `tip--send-request` (id generation, callback dispatch via hash table), `tip-ensure` (lifecycle management). This is a generic "stdio JSON-RPC child process" pattern. Any Emacs package talking to a long-running subprocess via JSON over stdio does exactly this — LSP clients, formatters, linters. ~100 lines, subtle edge cases (partial output chunks, EOF handling, error recovery).

**theme-aware-overlays.el** — Store rendering parameters on overlays (`tip-fg`, `tip-bg`), string-replace cached display data on theme change. Any package rendering colored images as overlays would want this. The key insight: recolor is 30x faster than re-render.

**fragment-collect.el** — Query tree-sitter → filter by region → exclude nested → convert to byte offsets. The nesting filter (keep only outermost) is generic. A LaTeX preview would do the same with `\(...\)` and `\[...\]`.

**stale-overlay-cleanup.el** — Delete zero-width overlays in `after-change-functions`. Every overlay-based preview system has this problem (text deleted under an overlay leaves a zero-width ghost).

Principle: don't extract until there's a second user. Premature abstraction is worse than duplication.

## 5. Relationship Between These Visions

```
Current TIP (per-fragment, Emacs overlays)
    │
    ├── Full-doc compilation (exact baselines, one compile)
    │       │
    │       ├── Emacs as render target (faces match typst text)
    │       │       │
    │       │       └── ...getting close to WYSIWYG in Emacs
    │       │
    │       └── Rust WYSIWYG editor (game engine, true 2D)
    │
    └── (current approach continues to work independently)
```

Each step builds on the previous, but the current approach is a viable endpoint on its own. The full-doc approach is the critical next step that enables both the Emacs-as-target and the WYSIWYG directions.
