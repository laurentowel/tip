# The Full-Document Approach: Compiling Once, Extracting Everything

## Status: Implemented (Opt-In)

`TIP_COMPILE_STRATEGY=full-doc` switches the Typst backend to a single
full-document compile + per-fragment frame extraction.  Default is still
`Synthetic` (one compile per fragment).  See `tip-server/crates/tip-core-typst/src/full_doc.rs`.

This essay started as an architecture study (June 2026, while the
synthetic strategy was the only path).  It is now a post-implementation
record: what survived contact with Typst, where we landed, and the
heuristics still on the page that we want to eliminate.

## The Core Insight

When Typst compiles a document, every element in the output frame tree
carries a `Span` — a reference back to the source position that produced
it.  Math equations are laid out as `Group` frames with explicit
`baseline` values set by the math layout engine.  And `typst_svg::svg_frame()`
can render any frame to SVG.

Three facts together: compile the document **once**, walk the frame
tree, find math frames by source span, render per-fragment SVGs.  No
synthetic documents, no scope skeletons, no skeleton-extraction bugs.

The synthetic approach builds N synthetic single-page documents and
calls `compile()` N times.  comemo caches per-input — N different
inputs means N cache misses.  The full-doc approach gets Typst's
internal layout parallelism for free, because it's one `compile()`
call.

## How Spans Flow Through Typst (verified)

The span chain from source to rendered output, with Typst 0.14.2
file references:

### 1. Parsing: Source → AST

```
$a + b$
 ↓ parse
ast::Equation { span: Span(file_id, byte_range) }
```

Every AST node carries a `Span` recording which file and byte range
produced it.

### 2. Evaluation: AST → Content

```
ast::Equation::eval()
 ↓
EquationElem::pack().with_span(equation_span)
 ↓
Packed<EquationElem> { span: Span(...) }
```

### 3. Layout: Content → Frame

Math layout (`typst-layout/src/math/`) does several things:

**Glyph-level span tracking** (`fragment.rs`):
```rust
glyph.span = (span, 0);  // each math glyph remembers its source span
```

**Span mapping during shaping** (`collect.rs`):
```rust
collector.spans.push(len, child.span());
let span = spans.span_at(shaped.range.start);
```

**Baseline setting** (`fraction.rs`, `scripts.rs`, `run.rs`):
```rust
let baseline = line_pos.y + axis;
let mut frame = Frame::soft(size);
frame.set_baseline(baseline);
```

### 4. The Frame Tree

```rust
pub struct Frame {
    size: Size,
    baseline: Option<Abs>,
    items: Vec<(Point, FrameItem)>,
    kind: FrameKind,
}

pub enum FrameItem {
    Group(GroupItem),
    Text(TextItem),
    Shape(Shape, Span),
    Image(Image, Size, Span),
    Link(Destination, Size),
    Tag(Tag),
}
```

`FrameItem::Text` contains a `TextItem` whose `Glyph` structs each have
`pub span: (Span, u16)`.

### 5. SVG Rendering

```rust
pub fn svg(page: &Page) -> String;          // full page
pub fn svg_frame(frame: &Frame) -> String;  // single frame ← the API we rely on
```

`svg_frame` renders any frame to a standalone SVG.  No need to wrap it
in a synthetic page.

## What Surprised Us in Practice

The architecture study was correct on every point — Typst really does
preserve spans through layout, frames really do carry baselines, and
`svg_frame` really does render a frame to SVG.  But several
implementation details turned out to need extra care:

### Detached spans (`span.id() == None`)

The study assumed every glyph traces back to a source byte range.
Wrong.  Typst synthesizes glyphs for math-scope identifiers (`dif`,
`pi`, accents, operators, auto-spacing, super/sub markers) through
scope resolution; the resulting `TextItem`s carry spans whose
`id() == None`.  No file, no byte range, nothing to look up.

The first naive filter ("glyph span overlaps fragment range") dropped
all of these.  `$dif x$` rendered as `$x$`, `$sqrt(pi)$` as `$sqrt$`.

The fix shipped as a "neighborhood pass" (current code): a second walk
that picks up detached `TextItem`s whose absolute position is within
~1 em of the fragment's bbox.  This works empirically but is exactly
the kind of magic-distance heuristic the study claimed to eliminate.
**[H1]** below.

### Simple math expressions are *inlined* into the page frame

The study assumed every `$...$` becomes a `FrameItem::Group` with
`has_baseline()=true`.  In Typst 0.14, simple expressions (single
identifiers, plain `a+b`, subscripts, accents) are inlined directly
into the page frame — their TextItems sit alongside surrounding
prose.  No Group, no explicit baseline.

Complex expressions (matrices, fractions, big operators with limits,
sized delimiters, cases) DO produce Groups with baselines.  The
distinction is empirical and not part of the public API, so future
Typst versions could change it.

This forced the baseline picker to fall back to TextItem `pos.y` for
inlined cases — and that's where another wrinkle showed up.

### Math TextItem `pos.y` ≠ paragraph line baseline

In a paragraph, math content is positioned with its math-axis aligned
to the line's math axis.  The math baseline is shifted ~0.5 pt above
the surrounding-text baseline (at 11 pt).  Using the math TextItem's
`pos.y` directly underreports depth by 0.5 pt and the displayed image
floats above the line.

Synthetic doesn't hit this because its synthetic page contains only
math — no surrounding text — so the math baseline IS the page's only
baseline.

### Sub/super-only fragments (e.g. `$phantom(a)^2$`)

When the user uses `hide()` or otherwise produces a fragment whose
visible content is entirely sub or super-shifted, the fragment's only
glyphs sit far above the line baseline.  Without the surrounding
paragraph's baseline as a reference, the cropped image looks
baseline-aligned on the superscript itself — losing the "high up"
appearance.  This was the original architectural motivation for
full-doc.  It works, but the picker has to KNOW it's in this case to
escape to external text — adding another threshold.

### Font size scales with paragraph context

Typst respects `#set text(size: 14pt)` for math — equation glyphs
inherit the surrounding text size.  Full-doc captures this correctly
via `TextItem::size`.  But for sub/super-only fragments, the only
visible glyph is sup-scaled (~7 pt at 11 pt body), and Emacs's
`tip-scale='auto'` would scale the preview ~1.6×.  We have to reach
out to surrounding text to recover the paragraph's text size.

### The bottom-pad off-by-half-pt

Pure crop math is simple — bbox top to bbox bottom.  But the cropped
frame extends 0.5 pt below ink to give SVG renderers some
anti-aliasing slack.  That extra 0.5 pt has to be included in the
reported `depth_pt`, otherwise `:ascent` underestimates the
below-baseline region by 0.5 pt and the displayed image floats up.
Synthetic accounts for this in `cropped_height - baseline_in_crop`;
full-doc has to match the arithmetic.

## Algorithm (as implemented)

```rust
fn extract_fragment_svg(world, doc, byte_start, byte_end) -> Option<FragmentRender> {
    for each page:
        // Pass 1: collect items whose source span overlaps [start, end).
        let (items, bounds, max_size, group_baselines) = walk(page, in_range);

        if items.empty: continue;

        // Pass 2: pick up detached-span items in the spatial neighborhood
        // of the in-range cluster.  HEURISTIC [H1].
        absorb_detached_neighbors(page, items, bounds, max_size);

        // Baseline picker (priority order):
        //   1. Group baseline if any in-range Group has set one
        //   2. Fragment's own bottommost TextItem baseline (frag_max)
        //   3. External (surrounding-text) baseline within tol when the
        //      fragment is sub/super-shifted relative to the line.
        //      HEURISTICS [H2], [H3].
        //   4. ink bottom (Shape-only fragments)
        let baseline_y = pick_baseline(group_baselines, frag_baselines, external);

        // Crop bounds: extend to include baseline so the image's
        // bottom edge IS the baseline.  +0.5 pt pad for AA slack
        // (and reported in depth_pt to match).
        let crop = bounds.expand_to_y(baseline_y).pad(0.5pt);

        // Rebuild a Frame at cropped origin and render.
        let mut out = Frame::soft(crop.size);
        for (pos, item) in items: out.push(pos - crop.origin, item);
        let svg = svg_frame(&out);

        let depth = (crop.max_y - baseline_y) + 0.5pt;
        let height = crop.max_y - crop.min_y + 1.0pt;

        // Font size: paragraph-context (max of fragment's own + surrounding line).
        // HEURISTIC [H4].
        let font_size = max(max_text_size, external_max_size_on_line);

        return Some(FragmentRender { svg, height, depth, width, font_size });
    None
}
```

## The Heuristics We Want to Eliminate

The study's claim ("no baseline heuristics") didn't survive contact
with reality.  But each of the tunables below has a principled
replacement waiting — listed in priority order.

### [H1] Spatial neighborhood for detached glyphs

**What it is:** detached-span TextItems (math-scope synthesized glyphs)
are pulled in if their absolute position lies within (`max_text_size`,
`2 pt`) of the in-range cluster's bbox.

**Why it's heuristic:** the (`one em`, `2 pt`) window is empirical.
Adjacent fragments on the same line within `one em` of each other
would be incorrectly co-opted (the same line normally has > 1 em of
prose between math fragments, but it's not guaranteed).

**Principled replacement: Group containment.**  If any descendant of a
`FrameItem::Group` has an in-range span, the Group represents a math
equation belonging to the fragment, and ALL of its descendants belong
to the fragment.  No distance threshold needed.

**Catch:** simple math is inlined directly into the page frame — no
Group wrapping it.  For inlined math, we'd need to identify the math
*run* — a contiguous sequence of TextItems on the same y, mixing
in-range and detached spans, separated from other content by
non-math TextItems with valid spans.

**Implementation sketch:**
1. Walk frame items in iteration order, recording each leaf's
   `(pos, span, span_status)`.
2. Form *runs*: maximal sequences of consecutive leaves on the same y
   (within ~0.1 pt — floating-point tol, not a layout heuristic).
3. A run "belongs to" a fragment if any leaf has an in-range span and
   no leaf has a non-detached out-of-range span.
4. Include the whole run.

This eliminates `neighborhood_x` and `neighborhood_y` and replaces
them with a frame-traversal property.

### [H2] External-baseline tolerance for sub/super-only fragments

**What it is:** when no Group baseline is available and the fragment's
own TextItems are all super-shifted (no item near line baseline), we
look at OUT-OF-FRAGMENT TextItems within 6 pt vertical of any fragment
baseline and take the maximum y as the line baseline.

**Why it's heuristic:** 6 pt was chosen empirically — narrower than the
default 13 pt line spacing, wider than the ~5 pt super-shift.  At
unusual line spacings (e.g. `#set par(leading: 0.4em)` at 11 pt body
gives ~4.4 pt spacing) the tolerance could span lines.  At very large
font sizes the super-shift may exceed 6 pt.

**Principled replacement: derive from layout.**

Option A — **walk for the math line break**.  Math is laid out within
a paragraph, and the paragraph has a known leading.  Read it from the
World's resolved style at the math's source position and use
`leading × 0.5` as the same-line tolerance.  Concrete, scales with
the doc.

Option B — **prefer Group baseline always**.  Force-wrap math frames
in Groups during a custom layout pass so we always get
`frame.has_baseline()`.  Requires reaching into Typst's math layout —
larger change, may conflict with future Typst.

Option A is incremental and fits today's architecture.

### [H3] `SHIFT_THRESHOLD = 2 pt` for "fragment is sub/super-shifted"

**What it is:** when both `frag_max` (fragment's bottommost baseline)
and `external` (surrounding-text baseline) are available, prefer
external when `external - frag_max > 2 pt`.

**Why it's heuristic:** 2 pt distinguishes "0.5 pt math-axis offset"
(prefer fragment) from "5 pt super-shift" (prefer external).  Works
at 11 pt body but the scale is hardcoded.

**Principled replacement: scale with font size.**  The math-axis
offset is a fraction of font size (~0.05 em).  The super-shift is a
larger fraction (~0.4 em).  `SHIFT_THRESHOLD = 0.2 × font_size` would
scale correctly across body sizes.

Better yet, **make the picker monotonic in evidence quality**:

1. Group baseline (canonical math layout baseline)
2. External line baseline (surrounding prose's `pos.y`)
3. Fragment-own max baseline

If we ever have an external baseline, it's always at least as
authoritative as fragment-own — line baselines are paragraph
properties, not math properties.  Drop the threshold and just prefer
in priority order.  This is closer to the synthetic compiler's
behavior already.

### [H4] Font-size lookup tolerance

**What it is:** `find_external_line_size` uses the same 6 pt vertical
tolerance as the baseline picker to find the surrounding paragraph's
text size.

**Why it's heuristic:** same reason as [H2].

**Principled replacement:** unify with [H2].  When we know the line
baseline, the line's text size is the size of any TextItem at that y.
Same code path, no separate tolerance.

## What Was Eliminated as Promised

| Synthetic machinery | Status |
|---|---|
| `extract_scope_skeleton` | Eliminated (full-doc has no synthetic source) |
| `collect_scope_nodes` | Eliminated |
| `compute_closing_delimiters` | Eliminated (was buggy in synthetic too) |
| `build_scoped_source` | Eliminated |
| `crop_svg_viewbox` | Eliminated (`svg_frame` renders at exact size) |
| Scope-skeleton bugs (html, delimiters, kodama wrappers) | Eliminated |

## What We Use Falls Through to Synthetic

Full-doc is **all-or-nothing**.  Typst's `compile()` returns
`SourceResult<PagedDocument>` — on any error, no document is produced.
A typo anywhere in the user's source poisons the entire response.

The dispatch in `TypstBackend::handle_compile_fragments` (and
`handle_compile_live`) tries full-doc first when configured; on
`Err`, falls through to the existing per-fragment synthetic loop.
Synthetic isolates each fragment in its own synthetic page, so a
single bad fragment doesn't poison the rest.

The user briefly loses paragraph-context font size and external
baseline while the source has an error.  Once the source parses
again, full-doc kicks back in.

## Performance

**Theoretical**: one compile vs N.  Per-fragment extraction is cheap
(frame walk + svg_frame on a small frame).  Typst's internal layout
parallelism kicks in for the single full-document compile.

**Measured**: not yet.  This is the largest unmeasured claim in the
feature.  Need:

- Cold-cache compile cost on a 50-page paper
- Warm-cache (one-character-edit) cost on the same doc
- Comparison against synthetic per-fragment cost on the same fragments

## Readiness Checklist Before Default

Not ready as default yet.  Outstanding:

1. **Comparison sweep over the existing visual-test corpus.**  The one
   diag test compares synthetic and full-doc on `$a+b=c$`.  We need
   the same comparison across matrices, fractions, big operators,
   accents, sized delimiters, kodama trees, html-targeting docs, and
   the arxiv corpus.
2. **Multi-page fragment handling.**  `extract_fragment_svg` returns
   on the first page that matches.  A fragment split across a page
   break gets truncated.
3. **Diagram (CeTZ/Fletcher) Shape geometry.**  Shape items currently
   contribute a 1-point bbox.  Diagram-only fragments report bogus
   widths.
4. **Performance bench** (above).
5. **Heuristic elimination [H1]–[H4]** — at least [H1] (Group/run
   containment) and the priority simplification in [H3].

A week of polish, not a structural rewrite.

## Appendix: Tinymist's Approach (for Reference)

Tinymist's jump-from-click (`tinymist-query/src/jump.rs`) walks the
frame tree similarly:

```rust
fn jump_from_click(frames: &[Frame], point: Point) -> Option<SourceSpan> {
    // Walk frame items at the click position
    // Find the deepest FrameItem whose span matches
    // Return the source location
}
```

Different direction (point → span) but same traversal.  Tinymist's
`SourceSpanOffset` and span-walking helpers in
`tinymist-world/src/debug_loc.rs` are a useful reference for the
reverse map (span → frame item).

## Files

| File | Role |
|---|---|
| `tip-server/crates/tip-core-typst/src/full_doc.rs` | Full-doc strategy: compile, walk, extract |
| `tip-server/crates/tip-core-typst/src/lib.rs` | `CompileStrategy` enum + `from_env` |
| `tip-server/crates/tip-server/src/typst_backend.rs` | Dispatch (compile_fragments + compile_live) |
| `tip-server/crates/tip-core-typst/src/compiler.rs` | Synthetic strategy (fallback path) |
