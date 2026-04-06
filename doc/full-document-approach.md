# The Full-Document Approach: Compiling Once, Extracting Everything

## Status: Not Yet Implemented — Architecture Study

This document describes a future approach that would replace TIP's current per-fragment synthetic compilation with a single full-document compilation. It is based on studying the typst and tinymist source code.

## The Core Insight

When Typst compiles a document, every element in the output frame tree carries a `Span` — a reference back to the source position that produced it. Math equations are laid out as `Group` frames with exact `baseline` values set by the math layout engine. And `typst_svg::svg_frame()` can render any single frame to SVG.

These three facts together mean: compile the document once, walk the frame tree, find math equation frames by their source spans, extract exact baselines, render per-frame SVGs. No synthetic documents, no scope skeletons, no baseline heuristics.

## How Spans Flow Through Typst

The span chain from source to rendered output:

### 1. Parsing: Source → AST

```
$a + b$
 ↓ parse
ast::Equation { span: Span(file_id, byte_range) }
```

Every AST node carries a `Span` recording which file and byte range produced it.

### 2. Evaluation: AST → Content

```
ast::Equation::eval()
 ↓
EquationElem::pack().with_span(equation_span)
 ↓
Packed<EquationElem> { span: Span(...) }
```

The evaluated content element retains the span. `Packed<T>` is Typst's wrapper that carries type + span + fields.

### 3. Layout: Content → Frame

This is where it gets interesting. Math layout (`typst-layout/src/math/`) does several things:

**Glyph-level span tracking** (in `fragment.rs`):
```rust
glyph.span = (span, 0);  // each math glyph remembers its source span
```

**Span mapping during shaping** (in `collect.rs`):
```rust
// SpanMapper: maps byte ranges in shaped text to source Spans
collector.spans.push(len, child.span());
// Later, during shaping:
let span = spans.span_at(shaped.range.start);
```

**Baseline setting** (in `fraction.rs`, `scripts.rs`, `run.rs`, etc.):
```rust
let baseline = line_pos.y + axis;
let mut frame = Frame::soft(size);
frame.set_baseline(baseline);  // exact math baseline
```

### 4. The Frame Tree

After layout, the compiled `PagedDocument` contains pages, each with a frame tree:

```rust
pub struct Frame {
    size: Size,
    baseline: Option<Abs>,  // ← set by math layout
    items: Vec<(Point, FrameItem)>,
    kind: FrameKind,        // Hard (clip) or Soft (overflow ok)
}

pub enum FrameItem {
    Group(GroupItem),          // nested frame — recurse
    Text(TextItem),            // glyphs, each with (Span, u16)
    Shape(Shape, Span),        // fraction bars, etc.
    Image(Image, Size, Span),  // embedded images
    Link(Destination, Size),
    Tag(Tag),
}
```

Key: `FrameItem::Text` contains `TextItem` whose `Glyph` structs each have `pub span: (Span, u16)`. The `Span` identifies the source position; the `u16` is the character offset within that span.

`FrameItem::Group` contains a sub-`Frame` which may have its own `baseline`. Math equations produce `Group` items whose inner frames have baselines set.

### 5. SVG Rendering

```rust
// typst-svg public API (0.14.2)
pub fn svg(page: &Page) -> String;          // full page
pub fn svg_frame(frame: &Frame) -> String;  // single frame ← this is what we need
```

`svg_frame` renders any frame to a standalone SVG. No need to wrap it in a page.

## The Algorithm

### Step 1: Compile the Full Document

```rust
let document = compile::<PagedDocument>(world).output?;
```

One compilation. comemo caches everything — subsequent compilations after small edits reuse most intermediate results.

### Step 2: Build a Span-to-Fragment Map

On the Emacs side, we already know the byte ranges of all math fragments (from tree-sitter). Send these to the server alongside the document content.

On the Rust side, convert byte ranges to `Span` values:

```rust
// Simplified — actual Span construction requires the FileId
fn byte_range_to_span(source: &Source, start: usize, end: usize) -> Span {
    source.span_at(start)  // or similar API
}
```

Build a map: `HashMap<Span, FragmentInfo>` where `FragmentInfo` contains the byte range and any metadata.

### Step 3: Walk the Frame Tree

```rust
fn find_math_frames(
    frame: &Frame,
    position: Point,
    span_map: &HashMap<Span, FragmentInfo>,
    results: &mut Vec<FoundFragment>,
) {
    for (pos, item) in frame.items() {
        let abs_pos = position + pos;
        match item {
            FrameItem::Group(group) => {
                // Check if any glyph in this group matches a known fragment span
                if let Some(frag_span) = find_matching_span(&group.frame, span_map) {
                    // Found a math equation frame!
                    results.push(FoundFragment {
                        span: frag_span,
                        frame: group.frame.clone(),
                        position: abs_pos,
                        baseline: group.frame.baseline(),  // EXACT
                        has_baseline: group.frame.has_baseline(),
                    });
                }
                // Also recurse — math can be nested
                find_math_frames(&group.frame, abs_pos, span_map, results);
            }
            FrameItem::Text(text) => {
                // Text glyphs carry spans — check against our fragment map
                for glyph in &text.glyphs {
                    if span_map.contains_key(&glyph.span.0) {
                        // This glyph belongs to a known fragment
                        // (handled at Group level above for full equations)
                    }
                }
            }
            _ => {}
        }
    }
}

fn find_matching_span(
    frame: &Frame,
    span_map: &HashMap<Span, FragmentInfo>,
) -> Option<Span> {
    // Walk frame items, check if any text glyph's span matches
    for (_, item) in frame.items() {
        if let FrameItem::Text(text) = item {
            for glyph in &text.glyphs {
                if span_map.contains_key(&glyph.span.0) {
                    return Some(glyph.span.0);
                }
            }
        }
        if let FrameItem::Group(group) = item {
            if let Some(span) = find_matching_span(&group.frame, span_map) {
                return Some(span);
            }
        }
    }
    None
}
```

### Step 4: Extract Per-Fragment SVG and Baseline

```rust
for found in &results {
    let svg = typst_svg::svg_frame(&found.frame);
    let height = found.frame.height().to_pt();
    let baseline = found.frame.baseline().to_pt();
    let depth = height - baseline;  // exact, no heuristics
    
    // Return to Emacs
    fragment_results.push(FragmentResult {
        start: span_map[&found.span].start,
        end: span_map[&found.span].end,
        svg,
        height_pt: height,
        depth_pt: depth,
        error: None,
    });
}
```

## What This Eliminates

| Current machinery | Status with full-doc approach |
|-------------------|-------------------------------|
| `extract_scope_skeleton` | **Eliminated** — no synthetic docs |
| `collect_scope_nodes` | **Eliminated** |
| `compute_closing_delimiters` | **Already eliminated** (was buggy) |
| `find_baseline_depth` heuristic | **Replaced** by exact `frame.baseline()` |
| `find_ink_extent` approximation | **Replaced** by exact `frame.size()` |
| `crop_svg_viewbox` | **Eliminated** — `svg_frame` renders at exact size |
| `build_scoped_source` | **Eliminated** |
| Scope skeleton bugs (html, delimiters) | **Eliminated** |
| `DEFAULT_RENDERING_PREAMBLE` | Possibly eliminated (bounded() may not be needed) |

## The Hybrid: Full-Doc Baselines + Per-Fragment Rendering

The font-size tension (full-doc renders at document size, but Emacs wants uniform sizing) has a clean resolution: **ascent is a ratio, not an absolute quantity.**

`ascent = (height - depth) / height` is scale-invariant. A fraction compiled at 14pt and at 11pt has different absolute dimensions but the same ascent percentage — the baseline sits at the same relative position.

The hybrid approach:

1. **Full-doc compile** → walk frame tree → for each math frame, compute `ascent_ratio = baseline / height` from `frame.baseline()` and `frame.height()`. These are exact.
2. **Per-fragment compile** at fixed 11pt → get SVGs at uniform size (current approach, with scope skeletons).
3. **Apply** the exact ascent ratio from step 1 to the image spec from step 2.

Step 1 runs once per buffer sync. Step 2 runs per fragment as today. The per-fragment approach handles font size control and page setup. The full-doc approach provides exact baselines. Each does what it's good at.

This is an incremental improvement over the current approach — no architecture rewrite, just an additional compilation pass for baseline data.

## What Remains Unchanged

- The protocol: still JSON over stdio with `sync` + `compile_fragments`
- The Emacs side: `tip--make-image-spec` still computes `:ascent` from height/depth
- Fragment detection: tree-sitter still finds `$...$` positions
- Overlay management: preview-toggle.el unchanged
- Theme color substitution: still works on cached SVGs

## Open Questions

### 1. Span Construction from Byte Ranges

How do we create a `Span` from a byte range to look up in the frame tree? The typst `Source` struct has methods like `range(span)` (span → byte range) but we need the reverse. Options:
- Iterate all spans in the source and build a reverse map
- Use `Source::find` or similar if it exists
- Match by comparing byte ranges rather than span equality

### 2. Equation Frame Identification

How do we distinguish a math equation's Group frame from other Group frames (e.g., emphasis, text styling)? Options:
- Check if the group's frame has `has_baseline()` — math frames do, text frames usually don't
- Check if the group's source span corresponds to a `$...$` range
- Check the frame kind or other metadata

### 3. Inline vs Display

The current approach detects inline vs display math from the source text (`$ ...$` vs `$ ... $`). With full-doc compilation, we could also detect this from the layout context — inline equations are part of paragraph flow, display equations are separate blocks.

### 4. Diagram Fragments

CeTZ/Fletcher diagrams aren't math equations — they're function call results. Their frames won't have math baselines. We'd still need the span-matching approach to find them, and they'd use `:ascent center` as they do now.

### 5. Performance on Large Documents

A 1000-fragment document currently takes ~10s for initial compilation (10ms/fragment × 1000). Full-doc compilation would be faster (one compile, comemo caching) but the frame tree walk adds overhead. Benchmarking needed.

## Tinymist's Approach (for Reference)

Tinymist's jump-from-click (`tinymist-query/src/jump.rs`) walks the frame tree similarly:

```rust
fn jump_from_click(frames: &[Frame], point: Point) -> Option<SourceSpan> {
    // Walk frame items at the click position
    // Find the deepest FrameItem whose span matches
    // Return the source location
}
```

Key difference: tinymist searches by spatial position (click coordinates), while we'd search by source span (byte range). But the frame walking logic is the same.

Relevant files in tinymist:
- `tinymist-query/src/jump.rs` — frame traversal with span matching
- `tinymist-world/src/debug_loc.rs` — `SourceSpanOffset` wrapper
- `tinymist-query/src/analysis/` — higher-level analysis using spans

## Files (Current Implementation, for Comparison)

| File | Current Role | Full-doc replacement |
|------|-------------|---------------------|
| `compiler.rs:build_scoped_source` | Builds synthetic doc | Eliminated |
| `compiler.rs:extract_scope_skeleton` | AST walk for scope | Eliminated |
| `compiler.rs:find_baseline_depth` | Heuristic baseline | `frame.baseline()` |
| `compiler.rs:find_ink_extent` | Approximate ink bounds | `frame.size()` |
| `compiler.rs:crop_svg_viewbox` | SVG string rewriting | `svg_frame()` |
| `compiler.rs:compile_source` | Compile synthetic doc | Compile full doc once |
| `handler.rs:handle_compile_fragments` | Per-fragment dispatch | Frame tree walk |
