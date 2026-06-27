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
//! See `devdoc/full-document-approach.md` and the post-mortem on the
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

use typst::compile;
use typst::layout::Point;
use typst::World;
use typst_layout::PagedDocument;

use crate::world::TipWorld;
use tip_protocol::messages::{FragmentLocation, FragmentResult};

use extract::extract_from_index;
use flatten::{build_span_index, flatten_leaves_inner, FlatLeaf, GroupRecord};

#[cfg(test)]
use {
    std::ops::Range,
    typst::layout::{Frame, FrameItem},
    typst::syntax::{FileId, Source},
};

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
        display_math_width: Option<&str>,
    ) -> Result<Vec<FragmentResult>, String> {
        let doc = compile_real_document(world, content)?;
        // Pre-flatten all pages ONCE.  Per-fragment extraction then
        // does a linear pass over the cached `Vec<FlatLeaf>` instead
        // of re-walking the frame tree — the difference between O(N)
        // and O(N · content) for a batch of N fragments.
        let main = world.main();
        let main_src = world.source(main).ok();
        let mut page_index: Vec<(Vec<FlatLeaf>, Vec<GroupRecord>)> =
            Vec::with_capacity(doc.pages().len());
        if let Some(ms) = &main_src {
            // Build span→range index ONCE, reused across all pages.
            let span_index = build_span_index(ms);
            for page in doc.pages() {
                let mut leaves = Vec::new();
                let mut groups = Vec::new();
                flatten_leaves_inner(
                    &page.frame,
                    Point::zero(),
                    main,
                    &span_index,
                    &mut leaves,
                    &mut groups,
                );
                page_index.push((leaves, groups));
            }
        }
        // Display-math canvas: comes from the protocol's
        // `display_math_width' field (Emacs's `tip-display-math-width'
        // resolved per-backend, sent as a Typst-style length string
        // like "28em" / "400pt" / "16cm").  Centering happens inside
        // `extract_from_index': inner content shifts right to sit in
        // the middle of the wider frame.  Inline / single-line display
        // fragments keep their tight crop (None).  Default 16cm
        // matches the prior bottom-up multi-line treatment when the
        // client doesn't set a value.
        let display_math_canvas_width = display_math_width
            .and_then(parse_typst_length)
            .unwrap_or_else(|| typst::layout::Abs::cm(16.0));
        let mut results = Vec::with_capacity(fragments.len());
        for f in fragments {
            let frag_content = content.get(f.start..f.end).unwrap_or("");
            let canvas_width = if super::bottom_up::is_multiline_math(frag_content) {
                Some(display_math_canvas_width)
            } else {
                None
            };
            let render = if main_src.is_some() {
                extract_from_index(&page_index, f.start, f.end, canvas_width)
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

/// Parse a Typst-style length string ("28em", "400pt", "16cm", "180mm",
/// "2in") into an `Abs`.  Returns `None` on parse failure.  Used to
/// translate the protocol's `display_math_width' field (sent by Emacs
/// as the resolved `tip-display-math-width' value) into a frame width.
///
/// `em' is resolved against the Typst body size (11pt) — the same body
/// size `build_scoped_source' bakes into its `set text(size: 11pt)'
/// rule, so this stays in sync with the rendered glyph size.
fn parse_typst_length(s: &str) -> Option<typst::layout::Abs> {
    use typst::layout::Abs;
    let s = s.trim();
    let split = s.find(|c: char| c.is_alphabetic())?;
    let (num, unit) = s.split_at(split);
    let n: f64 = num.trim().parse().ok()?;
    match unit.trim() {
        "pt" => Some(Abs::pt(n)),
        "em" => Some(Abs::pt(n * 11.0)),
        "cm" => Some(Abs::cm(n)),
        "mm" => Some(Abs::mm(n)),
        "in" => Some(Abs::inches(n)),
        _ => None,
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
///
/// Test-only: production extraction uses `flatten::FlatLeaf` instead.
#[cfg(test)]
#[derive(Debug, Clone)]
pub(crate) struct LeafSpan {
    pub source_range: Option<Range<usize>>,
    #[allow(dead_code)]
    pub page: usize,
    pub pos_pt: (f64, f64),
}

/// Compile the user's source as-is and return the laid-out document.
/// On error returns the joined diagnostic messages.
pub(crate) fn compile_real_document(
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
#[cfg(test)]
pub(crate) fn collect_leaf_spans(world: &dyn World, doc: &PagedDocument) -> Vec<LeafSpan> {
    let main = world.main();
    let main_src = world.source(main).ok();
    let mut out = Vec::new();
    for (page_idx, page) in doc.pages().iter().enumerate() {
        walk(
            &page.frame,
            page_idx,
            0.0,
            0.0,
            main,
            main_src.as_ref(),
            &mut out,
        );
    }
    out
}

#[cfg(test)]
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
                        main_src.and_then(|s| s.find(span).map(|node| node.range()))
                    } else {
                        None
                    };
                    out.push(LeafSpan {
                        source_range: range,
                        page,
                        pos_pt: (ix, iy),
                    });
                }
            }
            FrameItem::Shape(_, span) => {
                let range = if span.id() == Some(main) {
                    main_src.and_then(|s| s.find(*span).map(|node| node.range()))
                } else {
                    None
                };
                out.push(LeafSpan {
                    source_range: range,
                    page,
                    pos_pt: (ix, iy),
                });
            }
            _ => {}
        }
    }
}

/// Items whose source range overlaps `[start, end)`.  Items with
/// `source_range = None` are excluded — they can't belong to a
/// user-fragment range by definition.
#[cfg(test)]
pub(crate) fn fragment_items<'a>(
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
