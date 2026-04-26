//! Top-down compilation strategy.
//!
//! Plan: compile the user's real document **once** with `typst::compile`,
//! then walk the resulting frame tree to extract per-fragment SVGs.
//! This inherits Typst's internal layout parallelism (the 2–3× speedup
//! the 0.12 blog post advertises) for free, because all fragments
//! share the same `compile()` call and the same comemo cache.
//!
//! Contrast: `BottomUpCompiler::compile_fragment_scoped` builds `N`
//! synthetic single-page documents (skeleton + fragment) and runs
//! `compile()` `N` times — `N` cache misses, no shared layout work.
//! See `doc/full-document-approach.md` and the post-mortem on the
//! `parallel-compile` branch (kept as a documented dead end).
//!
//! ## Submodules
//!
//! - [`flatten`] — frame-tree walk → linear `FlatLeaf` list with
//!   span→source-range resolution and Group baselines.
//! - [`extract`] — per-fragment slice through the flat list, baseline
//!   picker, font-size picker, SVG cropping/rendering.

mod extract;
mod flatten;
#[cfg(test)]
mod tests;

use std::ops::Range;

use typst::compile;
use typst::layout::{Frame, FrameItem, PagedDocument, Point};
use typst::syntax::{FileId, Source};
use typst::World;

use crate::world::TipWorld;
use tip_protocol::messages::{FragmentLocation, FragmentResult};

pub use extract::{extract_fragment_svg, FragmentRender};

use extract::extract_from_index;
use flatten::{build_span_index, flatten_leaves_inner, FlatLeaf, GroupRecord};

pub struct TopDownCompiler;

impl TopDownCompiler {
    /// Compile every fragment in `fragments` from a single full-document
    /// compile of `content`.  Returns `Err` on document-level compile
    /// failure (the synthetic path is the safety net — it produces
    /// per-fragment errors so individual broken fragments don't
    /// poison the whole render).
    pub fn compile_all(
        world: &mut TipWorld,
        content: &str,
        fragments: &[FragmentLocation],
    ) -> Result<Vec<FragmentResult>, String> {
        let doc = compile_real_document(world, content)?;
        // Pre-flatten all pages ONCE.  Per-fragment extraction then
        // does a linear pass over the cached `Vec<FlatLeaf>` instead
        // of re-walking the frame tree — the difference between O(N)
        // and O(N · content) for a batch of N fragments.
        let main = world.main();
        let main_src = world.source(main).ok();
        let mut page_index: Vec<(Vec<FlatLeaf>, Vec<GroupRecord>)> =
            Vec::with_capacity(doc.pages.len());
        if let Some(ms) = &main_src {
            // Build span→range index ONCE, reused across all pages.
            let span_index = build_span_index(ms);
            for page in &doc.pages {
                let mut leaves = Vec::new();
                let mut groups = Vec::new();
                flatten_leaves_inner(
                    &page.frame, Point::zero(), main, &span_index,
                    &mut leaves, &mut groups,
                );
                page_index.push((leaves, groups));
            }
        }
        let mut results = Vec::with_capacity(fragments.len());
        for f in fragments {
            let render = if main_src.is_some() {
                extract_from_index(&page_index, f.start, f.end)
            } else {
                None
            };
            let r = match render {
                Some(render) => FragmentResult {
                    start: f.start,
                    end: f.end,
                    svg: tip_protocol::svg_color::fills_to_current_color(
                        &render.svg,
                        tip_protocol::svg_color::STANDIN_HEX,
                    ),
                    height_pt: render.height_pt,
                    depth_pt: render.depth_pt,
                    width_pt: render.width_pt,
                    font_size_pt: Some(render.font_size_pt),
                    error: None,
                    error_detail: None,
                },
                None => FragmentResult {
                    start: f.start,
                    end: f.end,
                    svg: String::new(),
                    height_pt: 0.0,
                    depth_pt: 0.0,
                    width_pt: 0.0,
                    font_size_pt: Some(11.0),
                    error: None,
                    error_detail: None,
                },
            };
            results.push(r);
        }
        Ok(results)
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
