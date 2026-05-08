//! Geometry helpers shared between the bottom-up and top-down compile
//! strategies: ink-extent walking, baseline picking, font ascent.
//!
//! Both strategies eventually need the same answers — "where does the
//! ink sit on this frame?" and "what's the line baseline?" — but
//! operate on different inputs (a synthetic single-fragment frame for
//! bottom-up, a flattened leaf list sliced from the real document for
//! top-down).  This module collects the bottom-up–side helpers; the
//! top-down side has its own, structurally different versions in
//! `top_down/extract.rs`.

use typst::layout::{Frame, FrameItem, Point};
use typst::visualize::Geometry;

use crate::geometry::text_item_frame_bbox;

/// Ink bounds in page-frame coordinates (points, y-down).
#[derive(Debug, Clone, Copy)]
pub struct InkBounds {
    pub min_x: f64,
    pub max_x: f64,
    pub min_y: f64,
    pub max_y: f64,
}

impl InkBounds {
    pub fn empty() -> Self {
        InkBounds {
            min_x: f64::MAX,
            max_x: f64::MIN,
            min_y: f64::MAX,
            max_y: f64::MIN,
        }
    }
    pub fn is_empty(&self) -> bool {
        self.min_y > self.max_y
    }
    pub fn width(&self) -> f64 {
        (self.max_x - self.min_x).max(0.0)
    }
}

/// Walk a frame tree and find the ink extent.  Uses `TextItem::bbox()`
/// for exact glyph bounds (critical for tall delimiters like `[`),
/// and `Geometry::{Line, Rect, Curve}` for shapes.
pub fn find_ink_extent(frame: &Frame, x_offset: f64, y_offset: f64) -> InkBounds {
    let mut bounds = InkBounds::empty();
    walk_ink(frame, x_offset, y_offset, &mut bounds);
    if bounds.is_empty() {
        InkBounds {
            min_x: 0.0,
            max_x: 0.0,
            min_y: 0.0,
            max_y: 0.0,
        }
    } else {
        bounds
    }
}

fn walk_ink(frame: &Frame, x_off: f64, y_off: f64, bounds: &mut InkBounds) {
    for (pos, item) in frame.items() {
        let item_x = x_off + pos.x.to_pt();
        let item_y = y_off + pos.y.to_pt();
        match item {
            FrameItem::Text(text) => {
                let (lx, ly, hx, hy) =
                    text_item_frame_bbox(text, Point::new(typst::layout::Abs::pt(item_x),
                                                          typst::layout::Abs::pt(item_y)));
                bounds.min_x = bounds.min_x.min(lx.to_pt());
                bounds.max_x = bounds.max_x.max(hx.to_pt());
                bounds.min_y = bounds.min_y.min(ly.to_pt());
                bounds.max_y = bounds.max_y.max(hy.to_pt());
            }
            FrameItem::Group(group) => {
                walk_ink(&group.frame, item_x, item_y, bounds);
            }
            FrameItem::Shape(shape, _) => match &shape.geometry {
                Geometry::Line(target) => {
                    let tx = item_x + target.x.to_pt();
                    let ty = item_y + target.y.to_pt();
                    bounds.min_x = bounds.min_x.min(item_x.min(tx));
                    bounds.max_x = bounds.max_x.max(item_x.max(tx));
                    bounds.min_y = bounds.min_y.min(item_y.min(ty));
                    bounds.max_y = bounds.max_y.max(item_y.max(ty));
                }
                Geometry::Rect(size) => {
                    bounds.min_x = bounds.min_x.min(item_x);
                    bounds.max_x = bounds.max_x.max(item_x + size.x.to_pt());
                    bounds.min_y = bounds.min_y.min(item_y);
                    bounds.max_y = bounds.max_y.max(item_y + size.y.to_pt());
                }
                Geometry::Curve(_) => {
                    bounds.min_x = bounds.min_x.min(item_x);
                    bounds.max_x = bounds.max_x.max(item_x);
                    bounds.min_y = bounds.min_y.min(item_y);
                    bounds.max_y = bounds.max_y.max(item_y);
                }
            },
            _ => {}
        }
    }
}

/// Walk the frame tree post-order and return the **outermost** Group
/// with `has_baseline()=true`.  Outermost matters for nested math
/// towers: Typst's inner Groups (sub/sup/frac) carry math-axis–shifted
/// baselines, while the outer math.equation Group has the canonical
/// line baseline.  Picking the inner one mis-aligns the preview by
/// half an x-height or so on towers like `$x_y_z_w$`.
///
/// Implementation: recurse first, then check.  If the recursion found
/// a baseline, prefer it; otherwise fall back to this Group's own
/// baseline if set.  Net effect: deepest-having-a-baseline ancestor
/// is returned for each branch — but since we explore each top-level
/// Group separately, the **first sibling chain** wins.  For typical
/// math (single equation per page), there's only one branch.
pub fn find_outermost_group_baseline(frame: &Frame, y_offset: f64) -> Option<f64> {
    for (pos, item) in frame.items() {
        if let FrameItem::Group(g) = item {
            let gy = y_offset + pos.y.to_pt();
            // Outer-first: prefer the OUTER Group's baseline over any
            // inner one.  Typst's math.equation Group sits at the top
            // of the math subtree and carries the line baseline; inner
            // Groups (sub/sup/frac) carry math-axis–shifted baselines
            // that misalign the preview.
            if g.frame.has_baseline() {
                return Some(gy + g.frame.baseline().to_pt());
            }
            if let Some(bl) = find_outermost_group_baseline(&g.frame, gy) {
                return Some(bl);
            }
        }
    }
    None
}

/// Recursively collect text items as `(font_size_pt, y_from_page_top)`.
/// Used only by the single-glyph fallback in `find_baseline_depth';
/// see `legacy-baseline-heuristics' tag for the older multi-text-item
/// heuristic that this replaced.
pub fn collect_text_items(frame: &Frame, y_offset: f64, out: &mut Vec<(f64, f64)>) {
    for (pos, item) in frame.items() {
        match item {
            FrameItem::Text(text) => {
                out.push((text.size.to_pt(), y_offset + pos.y.to_pt()));
            }
            FrameItem::Group(group) => {
                let child_y = y_offset + pos.y.to_pt();
                collect_text_items(&group.frame, child_y, out);
            }
            _ => {}
        }
    }
}
