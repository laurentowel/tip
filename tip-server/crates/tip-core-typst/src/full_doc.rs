//! Full-document compilation strategy.
//!
//! Plan: compile the user's real document **once** with `typst::compile`,
//! then walk the resulting frame tree to extract per-fragment SVGs.
//! This inherits Typst's internal layout parallelism (the 2–3× speedup
//! the 0.12 blog post advertises) for free, because all fragments
//! share the same `compile()` call and the same comemo cache.
//!
//! Contrast: today's `FragmentCompiler::compile_fragment_scoped` builds
//! `N` synthetic single-page documents (skeleton + fragment) and runs
//! `compile()` `N` times — `N` cache misses, no shared layout work.
//! See `doc/full-document-approach.md` and the post-mortem on the
//! `parallel-compile` branch (kept as a documented dead end).
//!
//! ## Rollout
//!
//! Step 1 (landed): strategy enum + dispatch plumbing.
//! Step 2 (this file): compile real doc; walk frames; map each leaf
//!   item (Text glyph, Shape) back to a byte range in the main source.
//!   `fragment_items` filters by [start, end).  No SVG yet.
//! Step 3 (planned): per-fragment SVG cropping from the page frame.
//! Step 4 (planned): baseline measurement at frame-item granularity.
//! Step 5 (planned): error-fallback policy + comparison test against
//!   the synthetic strategy on the existing visual-test corpus.

use std::ops::Range;

use typst::compile;
use typst::layout::{Frame, FrameItem, PagedDocument};
use typst::syntax::{FileId, Source};
use typst::World;

use crate::world::TipWorld;
use tip_protocol::messages::{FragmentLocation, FragmentResult};

pub struct FullDocCompiler;

impl FullDocCompiler {
    /// Compile every fragment in `fragments` from a single full-document
    /// compile of `content`.  Currently unimplemented (step 3+) — callers
    /// fall back to the synthetic strategy on `Err`.
    pub fn compile_all(
        _world: &mut TipWorld,
        _content: &str,
        fragments: &[FragmentLocation],
    ) -> Result<Vec<FragmentResult>, String> {
        let _ = fragments;
        Err("full-document compilation strategy not yet implemented".into())
    }
}

/// One leaf frame item paired with the source byte range of the
/// syntactic fragment that produced it.  Position is in **page**
/// coordinates (points), already accumulated from any enclosing
/// `FrameItem::Group` offsets.
///
/// `source_range` is `None` when the item's span doesn't resolve to
/// the main source (e.g., the item came from an imported module — it
/// can't belong to any user-supplied fragment range).
#[derive(Debug, Clone)]
pub struct LeafSpan {
    pub source_range: Option<Range<usize>>,
    pub page: usize,
    pub pos_pt: (f64, f64),
}

/// Compile the user's source as-is and return the laid-out document.
/// On error returns the joined diagnostic messages.
pub fn compile_real_document(
    world: &mut TipWorld,
    content: &str,
) -> Result<PagedDocument, String> {
    world.set_main_source(content);
    compile::<PagedDocument>(world).output.map_err(|errors| {
        errors
            .into_iter()
            .map(|e| e.message.to_string())
            .collect::<Vec<_>>()
            .join("; ")
    })
}

/// Walk every page's frame tree and collect a `LeafSpan` for each
/// leaf item (Text glyph, Shape).  Group offsets are accumulated so
/// every position is in absolute page-frame coordinates.
pub fn collect_leaf_spans(world: &dyn World, doc: &PagedDocument) -> Vec<LeafSpan> {
    let main = world.main();
    let main_src = world.source(main).ok();
    let mut out = Vec::new();
    for (page_idx, page) in doc.pages.iter().enumerate() {
        walk(&page.frame, page_idx, 0.0, 0.0, main, main_src.as_ref(), &mut out);
    }
    out
}

fn walk(
    frame: &Frame,
    page: usize,
    x_off: f64,
    y_off: f64,
    main: FileId,
    main_src: Option<&Source>,
    out: &mut Vec<LeafSpan>,
) {
    for (pos, item) in frame.items() {
        let ix = x_off + pos.x.to_pt();
        let iy = y_off + pos.y.to_pt();
        match item {
            FrameItem::Group(g) => walk(&g.frame, page, ix, iy, main, main_src, out),
            FrameItem::Text(t) => {
                for glyph in &t.glyphs {
                    let span = glyph.span.0;
                    let range = if span.id() == Some(main) {
                        main_src.and_then(|s| s.range(span))
                    } else {
                        None
                    };
                    out.push(LeafSpan { source_range: range, page, pos_pt: (ix, iy) });
                }
            }
            FrameItem::Shape(_, span) => {
                let range = if span.id() == Some(main) {
                    main_src.and_then(|s| s.range(*span))
                } else {
                    None
                };
                out.push(LeafSpan { source_range: range, page, pos_pt: (ix, iy) });
            }
            _ => {}
        }
    }
}

/// Items whose source range overlaps `[start, end)`.  Items with
/// `source_range = None` are excluded — they can't belong to a
/// user-fragment range by definition.
pub fn fragment_items<'a>(
    spans: &'a [LeafSpan],
    start: usize,
    end: usize,
) -> Vec<&'a LeafSpan> {
    spans
        .iter()
        .filter(|s| match &s.source_range {
            Some(r) => r.start < end && r.end > start,
            None => false,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn locate(content: &str, needle: &str) -> Range<usize> {
        let start = content.find(needle).expect("needle not in source");
        start..start + needle.len()
    }

    #[test]
    fn full_doc_compiles_simple_source() {
        let mut world = TipWorld::new();
        let src = "$x + y$\n";
        let doc = compile_real_document(&mut world, src).expect("compile");
        assert!(!doc.pages.is_empty());
    }

    #[test]
    fn leaf_spans_partition_two_inline_fragments() {
        let mut world = TipWorld::new();
        let src = "Some text $x + y$ between $a - b$ math.\n";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let spans = collect_leaf_spans(&world, &doc);

        // Sanity: we collected items, and at least some have resolved
        // source ranges in the main file.
        assert!(!spans.is_empty(), "expected leaf items");
        let with_range = spans.iter().filter(|s| s.source_range.is_some()).count();
        assert!(with_range > 0, "expected some items with main-source ranges");

        let r1 = locate(src, "$x + y$");
        let r2 = locate(src, "$a - b$");

        let in1 = fragment_items(&spans, r1.start, r1.end);
        let in2 = fragment_items(&spans, r2.start, r2.end);

        assert!(!in1.is_empty(), "fragment 1 ($x + y$) should attract items");
        assert!(!in2.is_empty(), "fragment 2 ($a - b$) should attract items");

        // Disjoint: an item in fragment 1's range can't simultaneously
        // be in fragment 2's range — the source ranges don't overlap.
        for a in &in1 {
            for b in &in2 {
                assert!(
                    !std::ptr::eq(*a, *b),
                    "leaf item appeared in both fragments — overlap bug"
                );
            }
        }
    }

    #[test]
    fn leaf_spans_skip_unrelated_text() {
        let mut world = TipWorld::new();
        let src = "Body. $x$ done.\n";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let spans = collect_leaf_spans(&world, &doc);
        let r = locate(src, "$x$");
        let inside = fragment_items(&spans, r.start, r.end);
        // The body text "Body." and " done." should not be counted as
        // belonging to the math fragment.
        for s in &inside {
            let sr = s.source_range.as_ref().unwrap();
            assert!(
                sr.start >= r.start && sr.end <= r.end,
                "item at {:?} leaked outside fragment range {:?}",
                sr,
                r
            );
        }
    }
}
