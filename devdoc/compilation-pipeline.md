# The TIP Compilation Pipeline: From Keystroke to SVG

This essay traces the full path a math fragment takes from when you press `M-x tip-show-skeleton-at-point` in Emacs to when the Rust backend produces an SVG image. The same pipeline powers every inline preview — `tip-show-skeleton-at-point` just stops before compilation and shows you the intermediate source.

Understanding this pipeline also serves as a practical introduction to the Typst library API, since tip-server is essentially a small program that calls Typst as a library.

## Step 1: Emacs detects the fragment

`tip-show-skeleton-at-point` (`tip.el:658`) starts by finding what math fragment the cursor is in:

```elisp
(let ((bounds (tip--get-bounds-of-math-at-point (point))))
```

This uses tree-sitter to walk up from the cursor's AST node until it finds a `math` parent, returning a `(BEG . END)` cons pair of character positions. The positions are then converted to byte offsets (Typst and tip-server work in bytes, Emacs works in characters — they differ for multi-byte characters like `ℙ` or `ℝ`):

```elisp
(let ((byte-start (1- (position-bytes (car bounds))))
      (byte-end   (1- (position-bytes (cdr bounds)))))
```

The `1-` adjusts from Emacs's 1-indexed positions to 0-indexed byte offsets.

## Step 2: Emacs syncs and sends the request

Before asking for the skeleton, Emacs sends the full buffer content to the server:

```elisp
(tip--sync-buffer)
```

This sends a `sync` message with the file path (URI) and the complete buffer text. The server stores it in its `DocumentStore` (`document.rs:15`) — a `HashMap<String, String>` keyed by file path. This ensures the server has the latest unsaved edits, not the stale file on disk.

Then Emacs sends the `debug_skeleton` request:

```json
{"id": 3, "method": "debug_skeleton", "params": {"uri": "/path/to/file.typ", "start": 42, "end": 55}}
```

## Step 3: The handler dispatches

`Handler::handle` (`handler.rs:27`) pattern-matches the request:

```rust
Request::DebugSkeleton(params) => self.handle_debug_skeleton(params),
```

`handle_debug_skeleton` (`handler.rs:172`) retrieves the document content from the store and calls:

```rust
FragmentCompiler::debug_scoped_source(&content, params.start, params.end)
```

For actual rendering (not debug), the handler calls `compile_fragment_scoped` instead, which does the same source assembly but then continues to compilation. The debug path stops after assembly and returns the source string.

## Step 4: Parsing the document AST

`build_scoped_source` (`compiler.rs:347`) begins by parsing the full document:

```rust
let root = typst::syntax::parse(document_source);
```

**`typst::syntax::parse`** is Typst's parser. It takes a `&str` and returns a `SyntaxNode` — the root of a concrete syntax tree (CST, not an abstract syntax tree). The CST preserves every token including whitespace and comments, which matters because we need to extract source text verbatim.

A `SyntaxNode` has three key methods:
- **`.kind()`** → `SyntaxKind` enum — what type of node this is (`LetBinding`, `SetRule`, `Math`, `Markup`, etc.)
- **`.children()`** → iterator of child `SyntaxNode`s
- **`.len()`** → byte length of this node's source text (NOT the number of children)

Node positions are implicit: you track them by summing `.len()` as you walk children. The root node starts at byte offset 0. For each child, its offset is the parent's offset plus the lengths of all preceding siblings. This is how `collect_scope_nodes` uses `offset` and `child_offset`.

## Step 5: Skeleton extraction — the clever part

`extract_scope_skeleton` (`compiler.rs:408`) walks the parsed tree and keeps only what defines scope. The idea: to compile `$x + y$` with the correct context, we don't need the surrounding text or other math fragments. We only need the `#let`, `#set`, `#show`, and `#import` statements that are visible at that position.

```rust
fn extract_scope_skeleton(
    root: &typst::syntax::SyntaxNode,
    source: &str,
    frag_start: usize,
) -> (String, String)
```

It returns two strings: the skeleton (scope-defining statements) and the closers (matching `}` and `]` for blocks that the skeleton opened).

The recursive walker `collect_scope_nodes` (`compiler.rs:426`) handles each node by comparing its byte range `[offset, offset + node.len())` against `frag_start`:

**Case 3 — Node starts at or after the fragment (line 437):** Skip entirely. Nothing after the fragment can affect its scope.

```rust
if offset >= frag_start { return; }
```

**Case 1 — Node is entirely before the fragment (line 442):** Check if it's scope-defining. The `SyntaxKind` enum tells us:

```rust
match node.kind() {
    SyntaxKind::LetBinding       // #let x = 42
    | SyntaxKind::SetRule        // #set text(fill: red)
    | SyntaxKind::ShowRule       // #show heading: it => ...
    | SyntaxKind::ModuleImport   // #import "lib.typ": *
    | SyntaxKind::ModuleInclude  // #include "other.typ"
    => {
        // Include in skeleton
    }
    _ => {}  // Skip: text, other math, comments, etc.
}
```

When including a scope-defining node, we extract its source text directly from the original document string using the byte range. There's one subtlety: in Typst's CST, the `#` that introduces a code statement is a separate `Hash` sibling node, not part of the `LetBinding` node itself. So we check if the byte before the node is `#` and include it:

```rust
let start = if offset > 0 && source.as_bytes().get(offset - 1) == Some(&b'#') {
    offset - 1
} else {
    offset
};
result.push_str(&source[start..node_end]);
```

**Case 2 — Node contains the fragment (line 464):** This is where nesting matters. The node spans across `frag_start`, so the fragment is somewhere inside it. We need to preserve the block structure while recursing into children.

Different node kinds get different treatment:

- **`Markup` and `Code`** (transparent containers): just recurse into children. These don't create scope boundaries on their own.

- **`CodeBlock` (`{ ... }`)**: emit `{` into the skeleton, push `}` onto the closers stack, then recurse. The fragment is inside this code block, so the skeleton must open it and the closers must close it.

  ```rust
  SyntaxKind::CodeBlock => {
      result.push_str("{\n");
      closers.push("}");
      // recurse into children...
  }
  ```

- **`ContentBlock` (`[ ... ]`)**: similar, but only emit the bracket if the block contains scope-defining children. A content block with just text (like `#box[hello]`) doesn't need to be preserved. But `#box[#set text(red); $x$]` does, because the `#set` inside affects the fragment.

  ```rust
  SyntaxKind::ContentBlock => {
      let has_scope_children = node.children().any(|child| {
          matches!(child.kind(),
              SyntaxKind::LetBinding | SyntaxKind::SetRule | ...)
      });
      if has_scope_children {
          result.push_str("[\n");
          closers.push("]");
      }
      // recurse...
  }
  ```

- **Everything else** (function calls, arguments, etc.): strip the container, recurse only into the child that contains the fragment. This handles deeply nested structures without emitting irrelevant syntax.

Finally, the closers are reversed (line 416) because they were pushed in opening order but need to close in reverse:

```rust
closers.into_iter().rev().collect::<Vec<_>>().join("")
// ["{", "["] → "]}"
```

### Skeleton example

Given this document with the cursor on `$x + y$`:

```typst
#import "utils.typ": *
#let foo = 42
Some text $a+b$
#set text(fill: red)
{
  #let bar = 7
  More text
  $x + y$
}
```

The skeleton extracts:

```
#import "utils.typ": *
#let foo = 42
#set text(fill: red)
{
#let bar = 7
```

And the closers are `}`. The `Some text`, `$a+b$`, and `More text` are discarded — they're not scope-defining. The `{` is preserved because the fragment lives inside it, and `#let bar = 7` is included because it's visible at the fragment's position.

## Step 6: Source assembly

Back in `build_scoped_source` (`compiler.rs:386`), the skeleton is combined with page setup, preamble, the fragment itself, and closers:

```rust
let sections: Vec<&str> = [
    DEFAULT_RENDERING_PREAMBLE,   // currently empty, reserved for future use
    skeleton.trim(),               // #import, #let, #set, #show...
    preamble_override              // client-specified color rules
        .unwrap_or("").trim(),
    page_setup.trim(),             // #set page(...), #show math.equation: set text(size: 11pt)
    fragment,                      // the actual $x + y$
    closing.as_str(),              // matching } ]
].into_iter().filter(|s| !s.is_empty()).collect();
let source = sections.join("\n") + "\n";
```

The ordering is deliberate. The skeleton comes first because it's the document's own rules. The preamble and page setup come AFTER the skeleton so they override document-level settings. For example, if the document says `#set page(fill: blue)`, our page setup's `fill: none` overrides it.

The page setup varies by fragment type (lines 361-382):
- **Inline math**: `height: auto, width: auto, margin: (top: 20pt, bottom: 20pt)` — generous vertical margins to avoid clipping subscripts, auto width to fit content
- **Multi-line display**: `width: 16cm` — fixed width for alignment, auto height
- **Single-line display**: `width: auto, margin: 0pt` — tight fit

HTML-targeting documents (detected by `html.elem`/`html.frame`/`html.figure` in the skeleton) skip the `#show math.equation: set text(size: 11pt)` rule because Typst forbids setting text size in HTML export mode.

**For `debug_skeleton`**, the assembled source is returned directly to Emacs and displayed in a `*tip-skeleton*` buffer. The remaining steps only apply to actual compilation.

## Step 7: Feeding the source to the Typst compiler

`compile_source` (`compiler.rs:107`) takes the assembled source and drives the Typst compiler.

First, it stores the source as the main file in the world:

```rust
world.set_main_source(source);
```

This creates a **`typst::syntax::Source`** (not to be confused with the raw `&str` — `Source` is Typst's wrapper that pairs source text with a `FileId` for diagnostics and caching) and inserts it into the world's in-memory `HashMap<FileId, Source>`.

Then the actual compilation:

```rust
let warned = compile::<PagedDocument>(world);
```

**`typst::compile`** is the entire Typst compiler in one function call. It takes a `&dyn World` (anything implementing the `World` trait) and does everything: parse, evaluate, layout. The generic parameter `<PagedDocument>` tells it to produce paginated output (as opposed to `<HtmlDocument>` for HTML export).

During compilation, Typst calls back into the world:
- `world.source(id)` — to read the main file and any `#import`ed files
- `world.file(id)` — to read binary files (images, etc.)
- `world.font(index)` — to load font data for shaping text
- `world.book()` — to search the font catalog by name

The return type is `Warned<Result<PagedDocument, EcoVec<SourceDiagnostic>>>`. `Warned` wraps the result with any non-fatal warnings. The `Result` is either a compiled document or a vector of errors.

Error handling (lines 111-119) extracts the error messages:

```rust
let document = warned.output.map_err(|errors| {
    errors.into_iter()
        .map(|e| e.message.to_string())
        .collect::<Vec<_>>()
        .join("; ")
})?;
```

**`SourceDiagnostic`** has `.message` (an `EcoString` with the error text), `.span` (a `Span` pointing to the source location), and `.severity` (error vs warning). We just concatenate the messages — the span information isn't useful to the user since the source is a synthetic document, not their actual file.

## Step 8: Extracting the SVG and page geometry

The compiled document gives us access to the layout result:

```rust
let pages = &document.pages;      // Vec<Page>
let page = &pages[0];             // our fragment is always one page
let svg_string = svg(page);       // typst_svg::svg — renders Page → SVG string
let page_height = page.frame.height().to_pt();
let page_width = page.frame.width().to_pt();
```

Key types from the Typst API:

- **`PagedDocument`** — the compilation result. Its `.pages` field is a `Vec<Page>`.
- **`Page`** — represents one page. Has `.frame` (a `Frame` — the layout tree) and metadata like page number.
- **`Frame`** — a rectangle containing positioned items. This is the core layout primitive. Has `.height()` and `.width()` (returning `Abs` — Typst's absolute length type) and `.items()` (an iterator yielding `(Point, &FrameItem)` pairs).
- **`Abs`** — an absolute length. Call `.to_pt()` to get an `f64` in points.
- **`Point`** — an `(x: Abs, y: Abs)` coordinate within a frame.

**`typst_svg::svg(&Page)`** is from the `typst-svg` crate (separate from the compiler). It takes a `Page` and renders it to an SVG string. This is the same renderer that `typst compile --format svg` uses. The SVG has a `viewBox` and `height`/`width` attributes matching the page dimensions.

## Step 9: Measuring ink bounds

The SVG from step 8 includes the full page, including any generous margins. For inline math, we want to crop the image tightly around the actual content. To do this, we need to know where the ink actually is.

```rust
let ink = find_ink_extent(&page.frame, 0.0, 0.0);
```

`find_ink_extent` (`compiler.rs:194`) walks the `Frame` tree recursively. **`frame.items()`** yields `(Point, &FrameItem)` pairs — each item has a position relative to its parent frame. By accumulating offsets as we recurse, we track absolute positions from the page origin.

`FrameItem` is an enum with several variants:

```rust
match item {
    FrameItem::Text(text) => { ... }
    FrameItem::Group(group) => { ... }
    FrameItem::Shape(_, _) => { ... }
    _ => {}
}
```

**`FrameItem::Text`** — rendered text. The `TextItem` struct has:
- `.size` — the font size (`Abs`)
- `.font` — the `Font` used for shaping
- `.glyphs` — a `Vec` of `Glyph`, each with `.x_advance` (how much horizontal space it takes) and `.id` (glyph ID in the font)
- `.bbox()` — computes the exact ink bounding box by querying `font.ttf().glyph_bounding_box()` for each glyph

The y-position of a text item is its **baseline** — that's how font rendering works. Ink extends above (ascent) and below (descent) the baseline. We use `text.bbox()` to get the exact ink extent from actual glyph outlines in the font. This is essential for math — tall delimiters like brackets `[` extend far beyond the normal font ascent, and any estimate based on font size alone (e.g. `0.8 * font_size`) would clip them.

One subtlety: `bbox()` internally uses glyph coordinates (y-up) and flips to frame coordinates (y-down) at the end. After the flip, `bbox.max.y` is the **top** of the ink (negative, above baseline) and `bbox.min.y` is the **bottom** (positive, below baseline). So the code swaps them:

```rust
let bbox = text.bbox();
bounds.min_y = bounds.min_y.min(item_y + bbox.max.y.to_pt());  // top of ink
bounds.max_y = bounds.max_y.max(item_y + bbox.min.y.to_pt());  // bottom of ink
```

**`FrameItem::Group`** — a nested frame. Contains a `.frame` field that we recurse into, adding the group's position to the running offset.

**`FrameItem::Shape`** — lines, rules, fraction bars. We approximate their bounds as a small point since they're thin.

The result is an `InkBounds` struct with `min_x`, `max_x`, `min_y`, `max_y` — the bounding box of all visible content on the page.

## Step 10: Finding the baseline

For inline math, Emacs needs to know where the mathematical baseline is so it can vertically align the SVG image with the surrounding text. This is the "hard problem" described in CLAUDE.md.

```rust
let baseline_y = find_baseline_depth(&page.frame, 0.0).unwrap_or(27.5);
```

`find_baseline_depth` (`compiler.rs:281`) first checks if the frame has a built-in baseline:

```rust
if frame.has_baseline() {
    return Some(y_offset + frame.baseline().to_pt());
}
```

**`Frame::has_baseline()`** and **`Frame::baseline()`** — Typst sets this on inner content frames but not on the top-level page frame. So this early return rarely triggers for our use case.

The fallback walks all text items via `collect_text_baselines` (`compiler.rs:304`) and picks the one most likely to be on the math baseline. The heuristic: **prefer the largest font size**. In a math expression like `$a + frac(b, c)$`, the `a` and `+` are at full size (~11pt) while the fraction's numerator and denominator are reduced (~7.7pt). The full-size items sit on the true baseline.

```rust
let is_better = match best {
    Some((best_size, best_dist, _)) => {
        if size > *best_size {
            true                          // larger font → better candidate
        } else if (size - *best_size).abs() < 0.1 {
            dist < *best_dist             // same size → prefer closer to page midpoint
        } else {
            false
        }
    }
    None => true,
};
```

On font-size ties (e.g., a fraction where both numerator and denominator are reduced), it prefers the y-position closest to the page's vertical midpoint. This midpoint is near the fraction bar — the correct visual baseline for fractions.

If all text items are small (below 9pt), the function returns `None` and the caller uses a constant fallback of `27.5pt` (= 20pt margin + ~7.5pt font ascent). This handles edge cases like deeply nested fractions where everything is reduced size.

## Step 11: Cropping the SVG

For inline math (lines 144-164):

```rust
let crop_top = (ink.min_y - pad).max(0.0);
let crop_bottom = (ink.max_y + pad).min(page_height);
let cropped_height = crop_bottom - crop_top;
let baseline_in_crop = baseline_y - crop_top;
let depth_pt = (cropped_height - baseline_in_crop).max(0.0);

let cropped_svg = crop_svg_viewbox(&svg_string, page_width, page_height, crop_top, cropped_height);
```

We compute `depth_pt` — how far below the baseline the image extends. Emacs uses this (together with `height_pt`) to compute the `:ascent` percentage for the image, which controls vertical alignment.

`crop_svg_viewbox` (`compiler.rs:245`) does string surgery on the SVG. It rewrites two attributes:

1. **`viewBox="0 0 W H"`** → **`viewBox="0 crop_top W new_height"`** — shifts the visible region down to the ink area
2. **`height="Xpt"`** → **`height="new_height_pt"`** — matches the new visible height

No re-rendering happens. The full SVG data is still there — we're just changing which rectangle is visible, like scrolling a window. This is why cropping is essentially free.

For display math (lines 166-174), no cropping is applied. The page setup already uses `margin: 0pt`, so the page dimensions match the content dimensions.

## Step 12: The response

The compiled result is packed into a `FragmentOutput`:

```rust
Ok(FragmentOutput {
    svg: cropped_svg,          // the SVG string
    height_pt: cropped_height, // total image height in points
    depth_pt,                  // depth below baseline in points
    width_pt: ink.width(),     // ink width in points
})
```

This travels back through the handler, gets serialized as JSON, sent over stdout to Emacs, and Emacs creates an overlay with the SVG as a display image. The `height_pt` and `depth_pt` are used to compute the `:ascent` property so the image sits on the correct baseline.

## The Typst API surface

To summarize the Typst library APIs used throughout this pipeline:

| Function / Type | Crate | Purpose |
|---|---|---|
| `typst::syntax::parse(&str)` | `typst` | Parse source text → `SyntaxNode` (CST root) |
| `SyntaxNode::{kind(), children(), len()}` | `typst` | Walk the concrete syntax tree |
| `SyntaxKind::LetBinding`, `SetRule`, ... | `typst` | Identify node types |
| `Source::new(FileId, String)` | `typst` | Create a source file object |
| `FileId::new_fake(VirtualPath)` | `typst` | Create an in-memory file identity |
| `compile::<PagedDocument>(&world)` | `typst` | The full compiler: parse → eval → layout |
| `PagedDocument { pages: Vec<Page> }` | `typst` | Compilation result |
| `Page { frame: Frame }` | `typst` | One page of output |
| `Frame::{items(), height(), width(), has_baseline(), baseline()}` | `typst` | Layout tree node |
| `FrameItem::{Text, Group, Shape, ...}` | `typst` | Layout tree items |
| `TextItem::{size, font, glyphs, bbox()}` | `typst` | Rendered text with font metrics and exact ink bounds |
| `Abs::to_pt()` | `typst` | Convert absolute length → `f64` points |
| `typst_svg::svg(&Page)` | `typst-svg` | Render a page to SVG |
| `FontSearcher::new().search_with(dirs)` | `typst-kit` | Discover system/custom fonts |
| `World` trait | `typst` | Interface the compiler calls back into |
