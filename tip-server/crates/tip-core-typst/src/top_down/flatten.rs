//! Frame-tree → flat leaf list.  See `super` for the strategy overview.

use std::collections::HashMap;
use std::ops::Range;

use typst::layout::{Abs, Frame, FrameItem, Point};
use typst::syntax::{FileId, LinkedNode, Source, Span};

/// One leaf (Text or Shape) flattened from the frame tree.  Group
/// offsets are already accumulated into `pos`.  `ranges_in_main` and
/// `has_attached_non_main` together let `category_for(start, end)`
/// compute the fragment-membership category WITHOUT re-walking the
/// frame tree — critical for batch extraction over many fragments,
/// which would otherwise be O(fragments × content).
pub struct FlatLeaf {
    pub pos: Point,
    pub item: FrameItem,
    pub text_size: Option<Abs>,
    /// Resolved byte ranges in the main source for each attached-main
    /// span (one per glyph for TextItems, single entry for Shape).
    pub ranges_in_main: Vec<Range<usize>>,
    /// At least one span attached to a NON-main file id (imported
    /// module / external).
    pub has_attached_non_main: bool,
    /// Fast-path bounds covering all `ranges_in_main`: any
    /// `[start, end)` query disjoint from `[min_range, max_range)`
    /// short-circuits without iterating individual glyph ranges.
    /// `(usize::MAX, 0)` if `ranges_in_main` is empty.
    pub min_range: usize,
    pub max_range: usize,
}

impl FlatLeaf {
    pub fn category_for(&self, start: usize, end: usize) -> LeafCategory {
        // Fast path: union of ranges in main is fully outside [start, end).
        if !self.ranges_in_main.is_empty()
            && (self.max_range <= start || self.min_range >= end)
        {
            // None of our main-attached ranges overlap.  Decide
            // OutAttached vs Detached without scanning ranges.
            return LeafCategory::OutAttached;
        }
        // Slow path: check each range individually.
        let mut has_in = false;
        let mut has_out = self.has_attached_non_main;
        for r in &self.ranges_in_main {
            if r.start < end && r.end > start {
                has_in = true;
            } else {
                has_out = true;
            }
        }
        if has_in {
            LeafCategory::InRange
        } else if has_out {
            LeafCategory::OutAttached
        } else {
            LeafCategory::Detached
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeafCategory {
    /// At least one glyph/span overlaps the user's fragment range.
    InRange,
    /// All spans have `span.id() == None` (typst-synthesized: math
    /// symbol, accent, auto-spacing, fallback glyph).  Joins an
    /// active fragment-run; otherwise waits.
    Detached,
    /// At least one attached span is OUT-of-fragment (different file
    /// or different range).  Acts as a run barrier.
    OutAttached,
}

/// A `Group` we walked through and its (possibly set) baseline.
/// `leaf_range` is the slice of `FlatLeaf` indices contributed by
/// this Group's descendants — so we can ask "is any of these in
/// my fragment range?" without re-walking.
pub struct GroupRecord {
    pub baseline_y: Abs,
    pub leaf_range: Range<usize>,
}

/// Build a `Span → byte range` index for `source` by walking the
/// AST once.  `Source::range` is O(depth) per call (it does an AST
/// walk) so calling it 100k times during flatten is a 50× perf
/// regression.  This index turns each lookup into a single hash hit.
pub fn build_span_index(source: &Source) -> HashMap<Span, Range<usize>> {
    let mut map = HashMap::with_capacity(2048);
    fn walk(node: LinkedNode, map: &mut HashMap<Span, Range<usize>>) {
        map.insert(node.span(), node.range());
        for child in node.children() {
            walk(child, map);
        }
    }
    walk(LinkedNode::new(source.root()), &mut map);
    map
}

fn ranges_minmax(ranges: &[Range<usize>]) -> (usize, usize) {
    if ranges.is_empty() {
        return (usize::MAX, 0);
    }
    let mut lo = usize::MAX;
    let mut hi = 0usize;
    for r in ranges {
        if r.start < lo {
            lo = r.start;
        }
        if r.end > hi {
            hi = r.end;
        }
    }
    (lo, hi)
}

fn collect_text_spans(
    t: &typst::text::TextItem,
    main: FileId,
    span_index: &HashMap<Span, Range<usize>>,
) -> (Vec<Range<usize>>, bool) {
    let mut ranges = Vec::new();
    let mut has_other = false;
    for g in &t.glyphs {
        let span = g.span.0;
        match span.id() {
            None => {}
            Some(id) if id == main => {
                if let Some(r) = span_index.get(&span) {
                    ranges.push(r.clone());
                }
            }
            Some(_) => has_other = true,
        }
    }
    (ranges, has_other)
}

fn collect_shape_span(
    span: Span,
    main: FileId,
    span_index: &HashMap<Span, Range<usize>>,
) -> (Vec<Range<usize>>, bool) {
    match span.id() {
        None => (Vec::new(), false),
        Some(id) if id == main => match span_index.get(&span) {
            Some(r) => (vec![r.clone()], false),
            None => (Vec::new(), false),
        },
        Some(_) => (Vec::new(), true),
    }
}

/// Walk the frame tree depth-first, accumulating Group offsets.  Each
/// leaf becomes a `FlatLeaf` carrying its raw span data — no per-
/// fragment categorization yet.  Each Group with `has_baseline()`
/// becomes a `GroupRecord` whose `descendant_ranges` is the slice
/// of leaf ranges contributing to it (so per-fragment we can ask
/// "did this group hold any in-range leaf for me?" cheaply).
#[cfg(test)]
pub fn flatten_leaves(
    frame: &Frame,
    offset: Point,
    main: FileId,
    src: &Source,
    out_leaves: &mut Vec<FlatLeaf>,
    out_groups: &mut Vec<GroupRecord>,
) {
    let span_index = build_span_index(src);
    flatten_leaves_inner(frame, offset, main, &span_index, out_leaves, out_groups);
}

pub fn flatten_leaves_inner(
    frame: &Frame,
    offset: Point,
    main: FileId,
    span_index: &HashMap<Span, Range<usize>>,
    out_leaves: &mut Vec<FlatLeaf>,
    out_groups: &mut Vec<GroupRecord>,
) {
    for (pos, item) in frame.items() {
        let abs = Point::new(offset.x + pos.x, offset.y + pos.y);
        match item {
            FrameItem::Group(g) => {
                let before = out_leaves.len();
                flatten_leaves_inner(
                    &g.frame, abs, main, span_index, out_leaves, out_groups,
                );
                let after = out_leaves.len();
                if g.frame.has_baseline() {
                    out_groups.push(GroupRecord {
                        baseline_y: abs.y + g.frame.baseline(),
                        leaf_range: before..after,
                    });
                }
            }
            FrameItem::Text(t) => {
                let (ranges, has_other) = collect_text_spans(t, main, span_index);
                let (min_r, max_r) = ranges_minmax(&ranges);
                out_leaves.push(FlatLeaf {
                    pos: abs,
                    item: FrameItem::Text(t.clone()),
                    text_size: Some(t.size),
                    ranges_in_main: ranges,
                    has_attached_non_main: has_other,
                    min_range: min_r,
                    max_range: max_r,
                });
            }
            FrameItem::Shape(shape, span) => {
                let (ranges, has_other) = collect_shape_span(*span, main, span_index);
                let (min_r, max_r) = ranges_minmax(&ranges);
                out_leaves.push(FlatLeaf {
                    pos: abs,
                    item: FrameItem::Shape(shape.clone(), *span),
                    text_size: None,
                    ranges_in_main: ranges,
                    has_attached_non_main: has_other,
                    min_range: min_r,
                    max_range: max_r,
                });
            }
            _ => {}
        }
    }
}
