# The Full-Document Approach: Compiling Once, Extracting Everything

## Status: Implemented (Opt-In)

`TIP_COMPILE_STRATEGY=full-doc` switches the Typst backend's batch
path (`compile_fragments`) to a single full-document compile +
per-fragment frame extraction.  Live preview (`compile_live`)
always uses the synthetic path regardless of strategy — see the
*Strategy Precedence Convention* below for why.  Default is still
`Synthetic` (one compile per fragment).  See `full_doc.rs` and
`typst_backend.rs::handle_compile_fragments` /
`handle_compile_live`.

This essay started as an architecture study (April 2026, while the
synthetic strategy was the only path).  It is now a post-
implementation record: what survived contact with Typst, where we
landed, the heuristics that needed eliminating (all eliminated as
of this revision), measured performance, and the dispatch policy.

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

## Heuristics — All Eliminated

The study's claim ("no baseline heuristics") survived contact with
reality after a few iterations.  All four numbered heuristics are
gone.  The remaining "magic numbers" are render slack and floating-
point tolerance, not layout decisions.

### [H1] Spatial neighborhood for detached glyphs — **eliminated**

Was: `(neighborhood_x = max_text_size, neighborhood_y = 2 pt)` —
detached `TextItem`s (`span.id() == None`, math-scope synthesized
glyphs like `dif`, `pi`, accents) were pulled in if their absolute
position lay within that window.  Empirical, fragile.

Now: **run-based detection**.  Walk leaves in iteration order with
a state machine — InRange leaves anchor the run, Detached leaves
join an active run (back-fill if before the first InRange),
OutAttached leaves end the run and clear pending Detached.  No
distance, no angle, no spatial guess.

Implemented in `flatten_leaves` + the linear pass in
`extract_from_index`.

### [H2] External-baseline tolerance — **scaled**

Was: fixed 6 pt window for "same line as fragment".  Catastrophic at
1 pt body where the next paragraph's text falls within 6 pt.

Now: `line_tol = max(0.5 pt, max_text_size × 0.5)` — half an em,
which is half a default line height.  Scales with the fragment's
own font size, never spans lines at any sane body size.

### [H3] `SHIFT_THRESHOLD` — **deleted (dead code)**

Was: 2 pt threshold to distinguish "fragment-own baseline ~= line
baseline" from "fragment is sub/super-shifted".

Now: redundant.  The picker priority is:

  1. Outermost Group baseline (canonical math equation baseline,
     present for every wrapped math equation including sub/super
     towers and continued fractions);
  2. External (surrounding-text line baseline) — fires for inlined
     math without a Group, and for sub/super-shifted fragments
     whose own baselines are far from the line;
  3. Fragment-own max baseline — for display math without
     surrounding text.

Once we always pick the OUTERMOST Group (post-order, last entry),
inner sub/sup-shifted Groups never compete.  Threshold not needed.

### [H4] Font-size lookup tolerance — **unified with [H2]**

Now uses the same `line_tol` as the baseline picker.  No separate
tunable.

### Remaining "magic numbers" (not heuristics)

- **`pad = 0.5 pt`** — anti-aliasing slack around the cropped frame.
  Not a layout decision; both synth and full-doc use it.
- **`line_tol = 0.5 × max_text_size`** factor — half an em is half a
  default line height (Typst's default `leading: 0.6em`).  Could be
  refined by reading actual `leading` from the resolved paragraph
  style, but the approximation is sound.

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
(linear scan over a pre-flattened leaf vec + `svg_frame` on a small
frame).  Typst's internal layout parallelism kicks in for the
single full-document compile.

### Measured (release, math-heavy random corpus)

#### Batch render (`compile_fragments`)

| Lines | Fragments | Synth        | Full-doc | Speedup |
|-------|-----------|--------------|----------|---------|
| 50    | 110       | 70 ms        | 21 ms    | 3×      |
| 500   | 1018      | 1.3 s        | 660 ms   | 2×      |
| 1000  | 1973      | 4.8 s        | ~1 s     | 5×      |
| 2000  | 3931      | 19 s         | 8.9 s    | 2×      |
| 5000  | 9969      | ~120 s (extp)| 1.67 s   | 75×     |

Synth's per-fragment cost grows linearly with content size (its
synthetic skeleton extraction re-parses the whole document each
time), so it's quadratic in N×L.  Full-doc has the same linear scan
per fragment but the page is flattened ONCE — bottleneck went from
51 s/page (calling `Source::range` 100k times) to 5 ms after
indexing spans up front.

The 75× gap at 5000 lines is the headline: at this scale synth
becomes unusable for batch render.

#### Live-edit latency (`compile_live`-equivalent path)

Per-keystroke cost (ms) typing a fresh fragment after an N-line doc:

| N lines | Strategy | avg  | p50  | p90    | p99    | max     |
|---------|----------|------|------|--------|--------|---------|
| 100     | full-doc | 11.5 | 0.5  | 33.7   | 35.7   | 35.7    |
|         | synth    | 0.4  | 0.3  | 0.5    | 0.8    | 0.8     |
| 1000    | full-doc | 67   | 4.8  | 273    | 286    | 286     |
|         | synth    | 3.0  | 2.9  | 3.4    | 5.4    | 5.4     |
| 2000    | full-doc | 175  | 13   | 699    | 720    | 720     |
|         | synth    | 8.1  | 8.1  | 9.7    | 10.4   | 10.4    |
| 5000    | full-doc | 1485 | 39   | **5549** | 5795 | 5795    |
|         | synth    | 28.9 | 28.7 | 30.6   | 32.1   | 32.1    |

Synth: linear in doc size, no outliers, sub-30 ms even at 5000
lines.

Full-doc median is competitive (sub-40 ms even at 5000), but the
**tail** is catastrophic — p99 climbs from 36 ms to 5.7 s as the
doc grows.  comemo cache misses on mid-edit syntax errors trigger
full re-layout.  Unsuitable for keystroke-rate workloads on large
docs.

## Strategy Precedence Convention

The two strategies are not mutually exclusive — they shine in
different regimes.  The dispatch should match the call site's
latency budget:

| Call site                  | Budget                | Strategy |
|----------------------------|-----------------------|----------|
| `compile_fragments` (batch / cursor-transition / explicit re-render) | 200 ms tolerable, occasional 1–5 s on tail acceptable | **full-doc** (synth fallback on doc-level Err) |
| `compile_live` (per-keystroke childframe preview) | 30 ms hard ceiling | **synth** always |
| (any) document doesn't compile | — | **synth fallback** for per-fragment error reporting |

Encoded in `tip-server/crates/tip-server/src/typst_backend.rs`:

- `handle_compile_fragments`: tries full-doc, falls back to synth
  on document-level error.
- `handle_compile_live`: always synth (regardless of
  `TIP_COMPILE_STRATEGY`).  See commit `9f09287` and the bench
  data above for the data-driven decision.

### Why these choices

- **Correctness > tail latency for batch.**  The phantom-base
  superscript, mixed-size sections, and external-baseline cases
  all need full-doc; they only get rendered correctly when the
  user leaves the fragment and the batch path runs.
- **Latency > correctness for live.**  Synth's worst case is
  consistent (linear in doc size); full-doc's worst case is
  multi-second.  Live preview tolerates approximation; it does
  NOT tolerate freezing the editor.
- **Synth fallback IS the error-handling path.**  `typst::compile`
  is all-or-nothing — no partial output.  When the doc has any
  syntax error, full-doc returns Err.  The fallback compiles each
  fragment in its own synthetic page where individual errors
  produce per-fragment `error_detail` overlays (line, hint,
  severity).  The user sees the broken fragment marked, the rest
  rendered.  No per-fragment error info from full-doc itself.

Future enhancement (not yet implemented): map typst's
`SourceDiagnostic` byte ranges to fragments and decorate
`FragmentResult.error_detail` with them — useful for flymake /
eldoc on systems without an LSP.  Lower priority because LSP-using
setups already see the diagnostics directly.

## Readiness Checklist Before Default

| Item | Status |
|---|---|
| **[H1]–[H4] heuristic elimination** | ✅ All four eliminated or scaled |
| **Performance bench** | ✅ Done (see Performance section above) |
| **Synth-vs-full-doc comparison sweep** | ✅ 8-fixture sweep agrees to 0% height / ≤2% width |
| **Live-edit dispatch decided** | ✅ synth for live, full-doc for batch |
| **Span-index optimization** | ✅ 32× speedup; flatten under 100ms even at 5000 lines |
| **Multi-page fragment split** | ❌ `extract_fragment_svg` returns on first matching page; mid-page-break fragment gets truncated |
| **Diagram (CeTZ/Fletcher) Shape geometry** | ❌ Shape items contribute 1-pt bbox; figure-wrapped diagrams report bogus widths |
| **Real-corpus sweep (arxiv, kodama)** | ❌ Synthetic random corpus only; no real-doc fixtures yet |
| **Synth math-axis baseline audit** | ❌ Synth's `find_group_baseline` likely picks math-axis instead of line-baseline; benign for shallow math, visible for towers (we corrected full-doc but not synth) |
| **Diagnostic mapping for non-LSP users** | ❌ Optional — typst `SourceDiagnostic` → fragment `error_detail` |

The first two ❌ items are the substantive blockers for flipping
the default.  Multi-page is rare in inline math but real for
display equations on a page boundary.  Diagram support is a
fragment-class gap (Shape geometry).

The last three ❌ items are nice-to-haves: real-corpus testing
catches edge cases earlier; synth audit cleans up a latent bug;
diagnostic mapping helps users without an LSP.

**Switching the default**: when the first two ship, set
`CompileStrategy::default = FullDoc` in `tip-core-typst/src/lib.rs`
and update CLAUDE.md.  Synth stays as the fallback path for
document-level compile errors.

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
