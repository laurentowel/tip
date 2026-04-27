# Bottom-up baseline geometry

## Why is `baseline.rs` not under `bottom_up/`?

It looks asymmetric next to `top_down/` (which is a folder with
`mod.rs`, `flatten.rs`, `extract.rs`, `tests.rs`).  History:

- `baseline.rs` was extracted from `bottom_up.rs` with the *intent*
  of sharing geometry helpers between the bottom-up and top-down
  strategies.
- Top-down ended up needing structurally different code — `Abs`
  rather than `f64`, a flattened `FlatLeaf` list rather than a live
  `Frame`, post-order walks rather than pre-order — so it kept its
  own copies in `top_down/extract.rs`.
- Net: nothing in top-down imports from `baseline.rs`.  It is
  effectively a bottom-up–only module living at the crate root.

The honest fix is to convert `bottom_up.rs` → `bottom_up/{mod.rs,
baseline.rs}` and have:

```rust
// lisp/...nope, src/lib.rs
pub mod bottom_up;       // bottom_up/mod.rs re-exports public surface
pub mod top_down;
```

Then `baseline` becomes `bottom_up::baseline`, an internal helper
module that clearly belongs to one strategy.  See the open
todo (this file) — not done yet because it touches every callsite of
`crate::baseline::*`.

If a future refactor genuinely shares geometry between the two
strategies (e.g., a unified `ItemBounds` over a generic numeric
type), `baseline` graduates back to a top-level module.  Until then
the bottom-up location is more honest.

## The geometry `find_ink_extent` walks

`find_ink_extent` recurses through a `Frame` tree, accumulating
offsets and folding each leaf's contribution into an `InkBounds`
rectangle.  Inputs:

- `frame: &Frame` — the current node.
- `x_offset, y_offset: f64` — the offset of `frame`'s origin in
  page coordinates.  Starts at `(0, 0)` for the page frame; grows
  by `pos.x, pos.y` each time we recurse into a child `Group`.

Coordinate convention: **y-down**.  `min_y` is *above*; `max_y` is
*below*.  Glyph bboxes use a flipped y (the comment in the source
calls this out).

### Per-leaf contribution

| Leaf type | Contribution to `InkBounds` |
|---|---|
| `Text(text)` | `(item_x + bbox.min.x, item_y + bbox.max.y)` to `(item_x + bbox.max.x, item_y + bbox.min.y)`. The y-flip happens here: glyph-coord `bbox.max.y` is above the baseline (becomes our `min_y`); glyph-coord `bbox.min.y` is below (becomes our `max_y`). |
| `Group(g)` | Recurse with `(item_x, item_y)` as the new offset. |
| `Shape::Line(target)` | Endpoints `(item_x, item_y)` and `(item_x + target.x, item_y + target.y)`. Both contribute. |
| `Shape::Rect(size)` | `(item_x, item_y)` to `(item_x + size.x, item_y + size.y)`. |
| `Shape::Curve(_)` | Treated as a single point at `(item_x, item_y)` — full curve bbox would require walking segments. |

### Diagram

A CeTZ figure that shows offset accumulation, the glyph bbox y-flip,
the two `Shape` cases, and the resulting `InkBounds` envelope.
Compile with `typst compile this-file.typ` (after extracting the
block to a `.typ`):

```typst
#import "@preview/cetz:0.4.0"

#cetz.canvas(length: 0.95cm, {
  import cetz.draw: *

  // Page frame (y-down)
  rect((0, 0), (14, -10), stroke: 0.4pt + gray, name: "page")
  content((0, 0), anchor: "south-west", padding: 3pt,
          text(8pt, fill: gray.darken(40%))[Page frame · y-down])
  line((0.4, -0.4), (0.4, -1.7), mark: (end: "stealth"), stroke: 0.5pt)
  content((0.4, -1.9), anchor: "north", text(7pt)[y])
  line((0.4, -0.4), (1.7, -0.4), mark: (end: "stealth"), stroke: 0.5pt)
  content((1.9, -0.4), anchor: "west", text(7pt)[x])

  // (x_off, y_off) accumulation: offset to the inner Group's origin.
  let gx = 3.0
  let gy = -2.2
  line((0.4, -0.4), (gx, gy), stroke: 0.6pt + green.darken(10%),
       mark: (end: "stealth"))
  content((gx/2, gy/2), anchor: "south",
          text(7pt, fill: green.darken(30%))[`(x_off, y_off)`])

  // The recursed-into Group.
  rect((gx, gy), (gx + 9.5, gy - 6.5), stroke: 0.55pt + blue.darken(20%))
  content((gx, gy), anchor: "south-west", padding: 3pt,
          text(7pt, fill: blue.darken(30%))[`FrameItem::Group`])

  // Text item inside the group.
  let item_x = gx + 2.0
  let item_y = gy - 2.5
  line((gx, gy), (item_x, item_y), stroke: 0.5pt + orange,
       mark: (end: "stealth"))
  content((gx + 1.0, gy - 1.4), anchor: "south",
          text(7pt, fill: orange.darken(20%))[`pos.{x, y}`])

  // Baseline marker.
  line((item_x - 0.6, item_y), (item_x + 1.5, item_y),
       stroke: (paint: red, dash: "dashed", thickness: 0.4pt))
  circle((item_x, item_y), radius: 0.07, fill: red)
  content((item_x + 1.6, item_y), anchor: "west",
          text(7pt, fill: red.darken(20%))[baseline = `(item_x, item_y)`])

  // Glyph bbox (note y-flip: bbox.max.y is the upper edge in our coords).
  let bb_l = item_x - 0.06
  let bb_r = item_x + 0.7
  let bb_top = item_y + 0.95   // bbox.max.y in glyph coords → above baseline
  let bb_bot = item_y - 0.2    // bbox.min.y in glyph coords → below baseline
  rect((bb_l, bb_top), (bb_r, bb_bot),
       stroke: (paint: red, dash: "dotted", thickness: 0.5pt))
  line((item_x - 0.35, item_y), (item_x - 0.35, bb_top),
       stroke: 0.5pt + red.darken(10%), mark: (end: "stealth"))
  content((item_x - 0.45, (item_y + bb_top)/2), anchor: "east",
          text(7pt, fill: red.darken(20%))[`bbox.max.y`])
  line((item_x - 0.35, item_y), (item_x - 0.35, bb_bot),
       stroke: 0.5pt + red.darken(10%), mark: (end: "stealth"))
  content((item_x - 0.45, (item_y + bb_bot)/2), anchor: "east",
          text(7pt, fill: red.darken(20%))[`bbox.min.y`])

  // Shape::Line — endpoints (item_x, item_y) and + target.
  let lx = gx + 5.5
  let ly = gy - 4.5
  let tx = lx + 1.8
  let ty = ly - 1.2
  circle((lx, ly), radius: 0.07, fill: purple.darken(10%))
  line((lx, ly), (tx, ty), stroke: 0.7pt + purple.darken(10%),
       mark: (end: "stealth"))
  content((lx, ly), anchor: "north-east", padding: 1pt,
          text(7pt, fill: purple.darken(30%))[`(item_x, item_y)`])
  content((tx, ty), anchor: "north-west", padding: 1pt,
          text(7pt, fill: purple.darken(30%))[`+ target.{x, y}`])

  // Shape::Rect — top-left (item_x, item_y), bottom-right + size.
  let rx = gx + 6.5
  let ry = gy - 1.5
  rect((rx, ry), (rx + 2, ry - 1.5),
       stroke: 0.5pt + teal.darken(10%), fill: teal.lighten(85%))
  content((rx, ry), anchor: "south-west", padding: 1pt,
          text(7pt, fill: teal.darken(30%))[`(item_x, item_y)`])
  content((rx + 2, ry - 1.5), anchor: "north-west", padding: 1pt,
          text(7pt, fill: teal.darken(30%))[`+ size.{x, y}`])

  // InkBounds envelope: minimal rectangle covering all contributions.
  let ib_l = bb_l - 0.25
  let ib_r = calc.max(rx + 2.0, tx) + 0.25
  let ib_t = calc.max(bb_top, ry) + 0.2
  let ib_b = calc.min(bb_bot, ty) - 0.2
  rect((ib_l, ib_t), (ib_r, ib_b),
       stroke: (paint: black, dash: "dashed", thickness: 0.7pt))
  content((ib_r, ib_t), anchor: "south-west", padding: 2pt,
          text(8pt, fill: black, weight: "bold")[`InkBounds`])
})
```

Reading from the figure:

- The **green** vector is `(x_offset, y_offset)` — accumulated from
  the page origin to the current `Group`.
- The **orange** vector is the leaf's local `pos.{x, y}` from the
  group origin.  `(item_x, item_y) = (x_off + pos.x, y_off + pos.y)`.
- The **red** dot is the text item's baseline.  The dashed red
  rectangle is the glyph `bbox` reported by the font; note that
  `bbox.max.y` ends up *above* the baseline in our y-down coords
  (this is the comment's "flip y" note).
- The **purple** vector is `Shape::Line` — endpoints
  `(item_x, item_y)` and `+ target`.  Both are folded into bounds
  via `min`/`max`.
- The **teal** rectangle is `Shape::Rect` — top-left
  `(item_x, item_y)`, dimensions from `size`.
- The **black dashed rectangle** is the resulting `InkBounds`,
  covering every contribution.  This is what the bottom-up strategy
  hands to the SVG cropper.

## Why the y-flip matters

Typst's `TextItem::bbox()` is in **glyph coordinates** (y-up: max
above baseline, min below).  Our `InkBounds` lives in **frame
coordinates** (y-down: min above, max below).  So the loop body
deliberately swaps:

```rust
bounds.min_y = bounds.min_y.min(item_y + bbox.max.y.to_pt());  // upper edge
bounds.max_y = bounds.max_y.max(item_y + bbox.min.y.to_pt());  // lower edge
```

Without the swap, tall delimiters like `[` would appear to extend
*below* the line they sit on, the SVG crop would clip the top of
the glyph, and the bottom-up baseline picker would misfire.

## Related

- `find_outermost_group_baseline` — picks the OUTER `Group`'s
  declared baseline when one exists.  See `baseline.rs` line 116;
  outer matters for nested math towers (sub/sup carry math-axis
  baselines, only the outermost math.equation has the line
  baseline).
- `pick_baseline_y` — fallback heuristic when no Group baseline is
  present.  See line 187; covers the inline-math case where the
  fragment's content gets inlined into the page frame.
- `top_down/extract.rs` — does conceptually similar work but
  operates on a flattened `FlatLeaf` list rather than recursing
  through `Frame` nodes.  Uses `Abs` arithmetic (Typst's typed
  unit) end-to-end.
