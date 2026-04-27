# Baseline Alignment: The Hardest Problem in TIP

## What We're Solving

When a math fragment `$a + b$` is displayed as an SVG overlay in Emacs, it must sit on the **same baseline** as the surrounding text. The bottom of "a" in the SVG must align with the bottom of "a" in Emacs's text rendering. If it's too high, math floats above the line. Too low, it sinks.

This sounds simple. It is not.

```
Wrong (floating):    Text ⟨a + b⟩ more text      ← SVG is above the line
                              ↑ gap

Wrong (sinking):     Text ⟨a + b⟩ more text      ← SVG is below the line
                          ↓ gap

Correct:             Text ⟨a + b⟩ more text      ← baselines match
```

The challenge: Emacs controls vertical positioning of images via a single parameter — `:ascent`, a percentage (0-100) specifying how much of the image is above the baseline. We must compute the right ascent for every expression, and it must be **consistent** across all expressions regardless of their content.

## What We Tried and Why It Failed

### Attempt 1: Fixed ascent

```elisp
:ascent 85  ;; works for $a + b$ but not for $a_b$ or fractions
```

Simple expressions look fine at 85%. But subscripts extend below the baseline, so `$a_b$` needs a different ascent than `$a$`. Fractions need yet another. No single number works.

### Attempt 2: Kodama's `bounded()` technique

Kodama (an HTML Typst framework) uses `text(top-edge: "bounds", bottom-edge: "bounds", eq)` to force Typst to use actual glyph ink bounds instead of nominal line metrics. This fixes **clipping** — deep subscripts and tall fractions are no longer cut off.

But it **breaks baseline consistency**. `bounded()` changes the coordinate system differently for each expression. Simple `$a + b$` gets baseline at 89% from top, but `$a_b$` gets 64%. The two groups are each internally consistent but offset from each other. Mixing them on the same line produces visible misalignment.

### Attempt 3: Typst's frame `baseline()` field

Typst's `Frame` struct has a `baseline` field, but it's only set on inner content frames, not page frames. Calling `frame.has_baseline()` on the compiled page returns `false` for math output. Walking the frame tree to find `has_baseline()` returns `None` for all frames in our compiled output.

> **Remark (future direction):** The baseline field IS set on math equation frames when the **full document** is compiled — not on the page frame, but on the inner `Group` frames that contain each equation. This means compiling the entire document once and walking the frame tree could give exact baselines without any heuristics. See the "Future: Full-Document Compilation" section at the end of this essay.

### Attempt 4: First text item y-position

Text items in the SVG frame are positioned at their baseline y-coordinate. Using the first text item's y-position as the baseline works for simple expressions. But with `bounded()` active, the coordinate origin shifts per expression, making the y-positions incomparable across different fragments.

### Attempt 5: org-latex-preview's formula

org-latex-preview computes `:ascent` as `round(100 * (1 - depth/height))` where LaTeX's `preview.sty` reports height (above baseline) and depth (below baseline) per fragment. This is correct for LaTeX because `preview.sty` gives exact metrics. But getting equivalent metrics from Typst is the hard part.

## The Working Approach: Render → Crop → Align

The solution combines three insights:

### Insight 1: Without `bounded()`, the baseline position is constant

When you compile `$a + b$` and `$a_b$` and `$\frac{a}{b}$` with standard Typst text metrics (no `bounded()`), all three have the math baseline at the **same y-position from the page top**:

```
page top
  │ 20pt margin
  │ ~7.5pt font ascent
  ▼
  ─────── baseline (constant at ~27.5pt) ──────
```

This position = `margin_top + font_ascent` and it's the same for ALL expressions. The expressions differ in how far they extend above and below this line (tall fractions go higher, subscripts go lower), but the baseline itself doesn't move.

This is the critical invariant that `bounded()` breaks.

### Insight 2: Generous margins prevent clipping

Without `bounded()`, Typst uses nominal line metrics for the page box. Deep subscripts or tall fractions can extend beyond the page. Solution: render with **20pt top and bottom margins**. This is enough room for any reasonable math expression. Nothing gets clipped.

### Insight 3: Post-render SVG cropping preserves baseline math

After compilation, we have a page with large margins and the math fragment somewhere in the middle. We:

1. **Find the ink extent** — walk the frame tree, compute the actual min/max y-positions of all rendered content (text items, shape items for fraction bars, etc.)
2. **Crop the SVG viewBox** — rewrite the SVG's `viewBox` and `height` attributes to show only the ink region + 0.5pt padding
3. **Compute ascent from the baseline position within the cropped region**

```
Before cropping:                After cropping:
┌──────────────────┐
│    20pt margin    │
│                   │            ┌──────────────┐
│   ───a + b───    │  ──crop──▶ │  ───a + b─── │ height = ink extent
│                   │            └──────────────┘
│    20pt margin    │
└──────────────────┘
```

The baseline position within the cropped image:

```
baseline_in_crop = baseline_y - crop_top
ascent_pct = baseline_in_crop / cropped_height * 100
```

Since `baseline_y` is constant (~27.5pt), different expressions produce different ascent percentages — but the **absolute pixel position** of the baseline is the same for all of them.

## The Implementation

### Step 1: Compile with margins (Rust)

The page setup for inline math:

```rust
"#set page(height: auto, width: auto,
           margin: (top: 20pt, bottom: 20pt, rest: 0pt),
           fill: none, header: none, footer: none)"
```

`height: auto` means the page is exactly as tall as the content + margins.

### Step 2: Find the baseline (Rust)

`find_baseline_depth` in `compiler.rs`:

```rust
fn find_baseline_depth(frame: &Frame, y_offset: f64) -> Option<f64> {
    // Check if the frame reports a baseline directly
    if frame.has_baseline() {
        return Some(y_offset + frame.baseline().to_pt());
    }
    // Otherwise: find the text item with the largest font size
    // Its y-position IS the math baseline
    collect_text_baselines(frame, y_offset, page_mid, &mut best);
    // Only accept if the text is primary size (>=9pt)
    best.and_then(|(size, _, y)| if size >= 9.0 { Some(y) } else { None })
}
```

The heuristic: the **largest font-size text item** is the primary math content (not sub/superscripts, which are smaller). Its y-position from the page top is the baseline.

On font-size ties (e.g., `$a + b$` where all glyphs are the same size), prefer the item **closest to the page's vertical midpoint**. This handles fractions correctly — the midpoint is near the fraction bar, which is the correct baseline reference.

For fractions where ALL text is reduced size (~7.7pt, below the 9pt threshold), the function returns `None` and the caller uses the constant fallback baseline (27.5pt = 20pt margin + 7.5pt font ascent at 11pt).

### Step 3: Find ink extent (Rust)

`find_ink_extent` walks the frame tree:

```rust
fn find_ink_extent(frame: &Frame, y_offset: f64) -> (f64, f64) {
    for (pos, item) in frame.items() {
        match item {
            Text(text) => {
                // Text positioned at baseline. Ascent above, descent below.
                let ascent = font_size * 0.8;
                let descent = font_size * 0.25;
                min_y = min(min_y, item_y - ascent);
                max_y = max(max_y, item_y + descent);
            }
            Group(group) => recurse,
            Shape(_, _) => small extent around position,
        }
    }
}
```

The ascent/descent estimates (80%/25% of font size) are approximations. They're intentionally generous — better to include a bit of extra space than to clip content.

### Step 4: Crop SVG (Rust)

`crop_svg_viewbox` rewrites the SVG string:

```rust
// Original: viewBox="0 0 W H"
// Cropped:  viewBox="0 crop_top W cropped_height"
// Also update: height="Xpt" → height="cropped_height_pt"
```

This is a string operation on the SVG — no re-rendering. The SVG coordinate system shifts so only the ink region is visible.

### Step 5: Compute ascent (Emacs)

```elisp
(let* ((raw (* 100.0 (/ (- height-pt depth-pt) height-pt)))
       (ascent (max 0 (min 100 (round (- raw tip-baseline-offset))))))
  ;; ascent goes into the image spec as :ascent
  )
```

Where:
- `height-pt` = cropped SVG height
- `depth-pt` = distance from baseline to bottom of cropped region
- `height-pt - depth-pt` = distance from top of cropped region to baseline
- `raw` = percentage of image above the baseline
- `tip-baseline-offset` = user tuning knob (default -2)

## Why This Works

The key property: **`baseline_y` is constant across all expressions.**

For `$a$` (simple, no subscript):
- ink extends from ~20pt to ~28pt (just the glyph)
- crop: [19.5, 28.5], height = 9pt
- baseline at 27.5pt, in crop: 27.5 - 19.5 = 8pt from top
- ascent = 8/9 * 100 = 89%

For `$a_b$` (with subscript):
- ink extends from ~20pt to ~31pt (subscript goes deeper)
- crop: [19.5, 31.5], height = 12pt
- baseline at 27.5pt, in crop: 27.5 - 19.5 = 8pt from top
- ascent = 8/12 * 100 = 67%

Different ascent percentages, but in both cases the baseline is **8pt from the top of the cropped image**. Since Emacs positions images using ascent percentage × image height, and both images have the same baseline distance from top, the baselines align:

```
$a$:    ascent=89%, height=9pt  → baseline at 89% × 9 = 8pt from top
$a_b$:  ascent=67%, height=12pt → baseline at 67% × 12 = 8pt from top
```

8pt = 8pt. Baselines match.

## The Tuning Knob: `tip-baseline-offset`

Emacs font metrics don't exactly match Typst's. The `tip-baseline-offset` defcustom (default -2) applies a uniform correction:

```elisp
(setq tip-baseline-offset -2)  ;; shift math down by 2 ascent percentage points
```

Positive values shift math down, negative shift up. The default of -2 works well for common monospace fonts at typical sizes. Users can calibrate visually with `M-x tip-calibrate` which shows a grid of scale × offset combinations.

## Display Math: No Baseline Needed

For displayed (block) equations — multi-line math or `$ ... $` with spaces — baseline alignment is irrelevant. These are block elements centered in the line:

```elisp
(if display-p 'center ...)  ;; :ascent 'center for display math
```

The server returns `depth_pt = 0.0` for display math and skips the cropping step.

## What `bounded()` Is Still Used For

Although `bounded()` breaks baseline consistency, it IS included in the default rendering preamble:

```typst
#let bounded(content) = text(top-edge: "bounds", bottom-edge: "bounds", content)
```

It's available for future use (e.g., measuring glyph bounds for special purposes) but is NOT applied to the math fragment during compilation. The anti-clipping is handled by generous margins + SVG cropping instead.

## Future: Full-Document Compilation

The current approach compiles each math fragment in isolation via a synthetic document. This works but requires scope skeleton extraction, closing delimiter tracking, and baseline heuristics. There is a fundamentally better approach that we haven't implemented yet.

### The Idea

Compile the **full document** once as a `PagedDocument`. The resulting frame tree contains every math equation as a nested content frame. These inner frames have:

- `frame.baseline()` — the **exact** baseline position, set by the math layout engine
- `frame.width()` / `frame.height()` — exact bounding box
- Position within the page — where the equation sits in the document

Instead of building N synthetic documents and estimating baselines, we:

1. Compile the full document once (comemo caches intermediate results)
2. Walk the frame tree to find all math equation frames
3. For each math frame, read `baseline()` and bounds directly
4. Render each frame to SVG individually

### Why This Would Be Better

| Aspect | Current (per-fragment) | Full-document |
|--------|----------------------|---------------|
| Compilations | N synthetic docs | 1 real doc |
| Baselines | Heuristic (largest text item) | Exact from layout engine |
| Scope | Skeleton extraction + closers | Natural (it's the real doc) |
| Correctness | Approximation | Exact |
| Complexity | High (skeleton bugs, delimiter issues) | Lower (no synthetic docs) |

### Challenges

**Source-to-frame mapping.** The frame tree is spatial (page coordinates), not indexed by source byte range. Mapping each math frame back to its `$...$` in the source requires source mapping infrastructure. Tinymist does this for click-to-jump (`source_mapping`, `jump_from_click`). The typst crate likely has the primitives but they may not be in the published API.

**Per-frame SVG export.** `typst_svg::svg()` renders an entire page. We'd need to render individual frames. Options:
- `typst_svg` may expose frame-level rendering
- We could create a single-page document containing just one frame and render that
- We could render the full page and crop per-equation (similar to current SVG cropping but with exact coordinates)

**Page boundaries.** A long document spans multiple pages. Math equations on different pages have different frame coordinates. The frame tree walker needs to iterate all pages.

**Incremental updates.** When the user edits one fragment, recompiling the entire document is more expensive than recompiling one synthetic doc. However, comemo should make this fast — only the changed region and its dependents get recomputed.

### Research Pointers

| What | Where |
|------|-------|
| Tinymist source mapping | `.ref/tinymist-ref/crates/tinymist-query/src/` |
| Tinymist click-to-jump | `.ref/tinymist-ref/crates/tinymist-query/src/jump/` |
| Typst Frame struct | `typst::layout::Frame` (published crate) |
| Frame.baseline() | Returns `Abs` if set, used by inner math frames |
| typst-svg per-page rendering | `typst_svg::svg()` takes a `&Page` |

### Migration Path

This doesn't need to be all-or-nothing. A hybrid approach:

1. **Phase 1 (current):** Per-fragment synthetic compilation with heuristic baselines. Works today.
2. **Phase 2:** Compile full document, use frame tree for baseline/bounds, but still render per-fragment SVGs via cropping. Gets exact baselines without changing the SVG rendering pipeline.
3. **Phase 3:** Per-frame SVG rendering. Eliminates SVG cropping entirely.

Phase 2 is the sweet spot — exact baselines with minimal architecture change.

## Files

| File | Role |
|------|------|
| `tip-core/src/compiler.rs` | `compile_source`, `find_baseline_depth`, `find_ink_extent`, `crop_svg_viewbox`, `collect_text_baselines` |
| `tip.el` | `tip--make-image-spec` — converts height_pt/depth_pt to `:ascent` |
| `CLAUDE.md` | Full history of what was tried and why it failed |
| `doc/scope-resolution.md` | How the synthetic document is built before compilation |
