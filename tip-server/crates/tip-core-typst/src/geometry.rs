//! Shared geometry helpers used by both compile strategies.
//!
//! The two strategies (`bottom_up` and `top_down`) walk frame trees
//! with different coordinate types — `f64` and `Abs` respectively —
//! and different bounds structs.  But they share one detail that's
//! genuinely subtle: glyph-coord → frame-coord y-flip when extracting
//! a `TextItem`'s bbox.  Centralizing it here so the rule lives in one
//! place.

use typst::layout::{Abs, Point};
use typst::text::TextItem;

/// Return `(min_x, min_y, max_x, max_y)` of `t`'s glyph bbox,
/// translated by `pos`, in **frame coordinates** (y-down).
///
/// Typst's `TextItem::bbox()` is in glyph coordinates (y-up: `max.y`
/// is above the baseline).  Frame coordinates are y-down (smaller y
/// is above).  This helper performs the y-flip: the returned `min_y`
/// uses the glyph's `bbox.max.y` (upper edge in frame coords) and
/// `max_y` uses `bbox.min.y` (lower edge in frame coords).
///
/// Critical for tall delimiters like `[` whose ink extends well
/// beyond the nominal text bounds.
pub fn text_item_frame_bbox(t: &TextItem, pos: Point) -> (Abs, Abs, Abs, Abs) {
    let bbox = t.bbox();
    (
        pos.x + bbox.min.x,
        pos.y + bbox.max.y,
        pos.x + bbox.max.x,
        pos.y + bbox.min.y,
    )
}
