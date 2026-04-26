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
use typst::layout::{Abs, Frame, FrameItem, PagedDocument, Point, Size};
use typst::syntax::{FileId, Source};
use typst::World;
use typst_svg::svg_frame;

use crate::world::TipWorld;
use tip_protocol::messages::{FragmentLocation, FragmentResult};

pub struct FullDocCompiler;

impl FullDocCompiler {
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
        let mut results = Vec::with_capacity(fragments.len());
        for f in fragments {
            let r = match extract_fragment_svg(world, &doc, f.start, f.end) {
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
                    // Empty SVG; client treats this as "skip this
                    // fragment" (no overlay placed).  Common for
                    // `hide()`-only fragments or imports.
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

/// Render output for a single fragment extracted from a full document.
/// Coordinates are in points.  `depth_pt` is the height of ink BELOW
/// the line's baseline — for inline math this is what Emacs needs for
/// `:ascent` calculation.
#[derive(Debug, Clone)]
pub struct FragmentRender {
    pub svg: String,
    pub width_pt: f64,
    pub height_pt: f64,
    pub depth_pt: f64,
    pub page: usize,
    /// True iff `depth_pt` came from a surrounding-text baseline
    /// reference (not a fallback derived from the fragment's own
    /// items).  `false` => depth is best-effort; the caller may want
    /// to use `:ascent center` for display math.
    pub baseline_external: bool,
    /// Largest `TextItem::size` among the fragment's items, in points.
    /// Synthetic compiler always renders at 11 pt regardless of the
    /// document's actual font size; full-doc captures the real size,
    /// which matters when the user has `#set text(size: 14pt)` or
    /// section-specific sizing.  Emacs's `tip--effective-scale` uses
    /// this to scale the displayed image so the preview matches the
    /// document's own typesetting.
    pub font_size_pt: f64,
}

/// Build a minimal `Frame` containing only items belonging to the
/// fragment range, translated so the frame's origin is the ink-bounds
/// top-left, and render it as SVG.
///
/// Returns `None` if the fragment range matched no items (empty math,
/// `hide()` with no descendant content, all items in imported
/// modules — none of which are renderable inline previews).
pub fn extract_fragment_svg(
    world: &dyn World,
    doc: &PagedDocument,
    start: usize,
    end: usize,
) -> Option<FragmentRender> {
    let main = world.main();
    let main_src = world.source(main).ok()?;

    // Pick the first page that has any matching item.  Multi-page
    // fragments are not a typical case for inline math; we'd need a
    // different strategy (e.g., merge frames) if it ever comes up.
    for (page_idx, page) in doc.pages.iter().enumerate() {
        let mut keep: Vec<(Point, FrameItem)> = Vec::new();
        let mut bounds = ItemBounds::empty();
        let mut max_text_size = Abs::zero();
        collect_for_fragment(
            &page.frame,
            Point::zero(),
            main,
            &main_src,
            start,
            end,
            &mut keep,
            &mut bounds,
            &mut max_text_size,
        );
        if keep.is_empty() || bounds.is_empty() {
            continue;
        }
        let pad = Abs::pt(0.5);
        let min_x = bounds.min_x - pad;
        let min_y = bounds.min_y - pad;
        let width = bounds.max_x - bounds.min_x + pad * 2.0;
        let height = bounds.max_y - bounds.min_y + pad * 2.0;

        // Baseline reference: prefer surrounding-text baseline on this
        // page (that's the user's actual line baseline).  Fall back to
        // the bottom-most fragment text baseline.  Falling further to
        // the bottom of ink covers Shape-only fragments.
        let frag_baselines: Vec<Abs> = keep
            .iter()
            .filter_map(|(p, item)| match item {
                FrameItem::Text(_) => Some(p.y),
                _ => None,
            })
            .collect();
        let (baseline_y, external) =
            match find_external_baseline(&page.frame, &frag_baselines, main, &main_src, start, end)
            {
                Some(b) => (b, true),
                None => (
                    frag_baselines.iter().copied().max().unwrap_or(bounds.max_y),
                    false,
                ),
            };
        let depth = (bounds.max_y - baseline_y).max(Abs::zero());

        // Rebuild a flat Frame at the cropped origin.  Clone is cheap
        // — FrameItem is `derive(Clone)` and Text/Shape are Arcs/Vecs.
        let mut out = Frame::soft(Size::new(width, height));
        for (pos, item) in keep {
            out.push(Point::new(pos.x - min_x, pos.y - min_y), item);
        }

        // Default to 11 pt when the fragment has no Text items at all
        // (e.g., Shape-only diagram); matches the synthetic path's
        // default and keeps `tip--effective-scale` at 1.0.
        let font_size = if max_text_size > Abs::zero() {
            max_text_size.to_pt()
        } else {
            11.0
        };

        return Some(FragmentRender {
            svg: svg_frame(&out),
            width_pt: width.to_pt(),
            height_pt: height.to_pt(),
            depth_pt: depth.to_pt(),
            page: page_idx,
            baseline_external: external,
            font_size_pt: font_size,
        });
    }

    None
}

/// Bounds in absolute page coordinates (points).
#[derive(Debug)]
struct ItemBounds {
    min_x: Abs,
    max_x: Abs,
    min_y: Abs,
    max_y: Abs,
    nonempty: bool,
}

impl ItemBounds {
    fn empty() -> Self {
        Self {
            min_x: Abs::pt(f64::MAX),
            max_x: Abs::pt(f64::MIN),
            min_y: Abs::pt(f64::MAX),
            max_y: Abs::pt(f64::MIN),
            nonempty: false,
        }
    }
    fn is_empty(&self) -> bool {
        !self.nonempty
    }
    fn extend(&mut self, x0: Abs, y0: Abs, x1: Abs, y1: Abs) {
        self.min_x = self.min_x.min(x0);
        self.max_x = self.max_x.max(x1);
        self.min_y = self.min_y.min(y0);
        self.max_y = self.max_y.max(y1);
        self.nonempty = true;
    }
}

fn span_in_range(
    span: typst::syntax::Span,
    main: FileId,
    src: &Source,
    start: usize,
    end: usize,
) -> bool {
    if span.id() != Some(main) {
        return false;
    }
    match src.range(span) {
        Some(r) => r.start < end && r.end > start,
        None => false,
    }
}

/// Find a surrounding-text baseline on `frame` (a page) for an
/// inline-math fragment whose own text-item baselines are
/// `frag_baselines`.  Walks all text items NOT inside the fragment's
/// source range; returns the one whose baseline-y is closest to any
/// `frag_baselines` entry, within ~one line-height.  Returns `None`
/// when nothing surrounding is on the same line (display math, or
/// the math is the only content).
fn find_external_baseline(
    frame: &Frame,
    frag_baselines: &[Abs],
    main: FileId,
    src: &Source,
    exclude_start: usize,
    exclude_end: usize,
) -> Option<Abs> {
    if frag_baselines.is_empty() {
        return None;
    }
    let mut external_ys: Vec<Abs> = Vec::new();
    walk_external(
        frame,
        Point::zero(),
        main,
        src,
        exclude_start,
        exclude_end,
        &mut external_ys,
    );
    let tol = Abs::pt(20.0);
    let mut best: Option<(Abs, Abs)> = None; // (distance, y)
    for ey in external_ys {
        for fy in frag_baselines {
            let d = (ey - *fy).abs();
            if d > tol {
                continue;
            }
            if best.map_or(true, |(bd, _)| d < bd) {
                best = Some((d, ey));
            }
        }
    }
    best.map(|(_, y)| y)
}

fn walk_external(
    frame: &Frame,
    offset: Point,
    main: FileId,
    src: &Source,
    exclude_start: usize,
    exclude_end: usize,
    out: &mut Vec<Abs>,
) {
    for (pos, item) in frame.items() {
        let abs = Point::new(offset.x + pos.x, offset.y + pos.y);
        match item {
            FrameItem::Group(g) => {
                walk_external(&g.frame, abs, main, src, exclude_start, exclude_end, out)
            }
            FrameItem::Text(t) => {
                let any_in = t
                    .glyphs
                    .iter()
                    .any(|gl| span_in_range(gl.span.0, main, src, exclude_start, exclude_end));
                if !any_in {
                    out.push(abs.y);
                }
            }
            _ => {}
        }
    }
}

fn collect_for_fragment(
    frame: &Frame,
    offset: Point,
    main: FileId,
    src: &Source,
    start: usize,
    end: usize,
    keep: &mut Vec<(Point, FrameItem)>,
    bounds: &mut ItemBounds,
    max_text_size: &mut Abs,
) {
    for (pos, item) in frame.items() {
        let abs = Point::new(offset.x + pos.x, offset.y + pos.y);
        match item {
            FrameItem::Group(g) => {
                collect_for_fragment(
                    &g.frame, abs, main, src, start, end, keep, bounds, max_text_size,
                );
            }
            FrameItem::Text(t) => {
                let any = t
                    .glyphs
                    .iter()
                    .any(|g| span_in_range(g.span.0, main, src, start, end));
                if any {
                    // `text.bbox()` returns glyph-coord y (y-up).  In
                    // frame coords (y-down) the FRAME-TOP is `bbox.max.y`
                    // (a negative number above the baseline) and the
                    // FRAME-BOTTOM is `bbox.min.y` (positive, descender).
                    // Same flip the synthetic compiler uses in
                    // `find_ink_extent`.
                    let bbox = t.bbox();
                    bounds.extend(
                        abs.x + bbox.min.x,
                        abs.y + bbox.max.y,
                        abs.x + bbox.max.x,
                        abs.y + bbox.min.y,
                    );
                    if t.size > *max_text_size {
                        *max_text_size = t.size;
                    }
                    keep.push((abs, FrameItem::Text(t.clone())));
                }
            }
            FrameItem::Shape(shape, span) => {
                if span_in_range(*span, main, src, start, end) {
                    // Shape geometry: use a coarse bbox from the
                    // shape's own size info.  `Geometry` exposes this
                    // via `bbox_size` on Line/Rect/Path; for simplicity
                    // we extend by a small region around the position.
                    // SVG-level cropping picks up the rest.
                    bounds.extend(abs.x, abs.y, abs.x, abs.y);
                    keep.push((abs, FrameItem::Shape(shape.clone(), *span)));
                }
            }
            _ => {}
        }
    }
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

    /// Regression for the `hide()`-base / superscript case:
    ///
    ///   #let phantom(x) = hide($#x$)
    ///   $phantom(a)^2$
    ///
    /// `hide()` removes the base glyph from the frame tree, but the
    /// `^2` superscript stays at its real laid-out y-position relative
    /// to the (invisible) base.  The synthetic-fragment compiler can't
    /// see that — its page contains only `^2`, so cropping makes `^2`
    /// look baseline-aligned on itself and the apparent ascent is
    /// wrong.  Full-doc must keep the y-position so step 3 / 4 can
    /// recover the right baseline from the surrounding page context.
    #[test]
    fn hidden_base_preserves_superscript_position() {
        let mut world = TipWorld::new();
        let src = "\
#let phantom(x) = hide($#x$)
$phantom(a)^2$ vs $a^2$
";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let spans = collect_leaf_spans(&world, &doc);

        let r_phantom = locate(src, "$phantom(a)^2$");
        let r_plain = locate(src, "$a^2$");

        let in_phantom = fragment_items(&spans, r_phantom.start, r_phantom.end);
        let in_plain = fragment_items(&spans, r_plain.start, r_plain.end);

        // Both fragments must yield at least one visible leaf — the
        // superscript "2" — even though the phantom version's base is
        // hidden.
        assert!(
            !in_phantom.is_empty(),
            "phantom-base superscript fragment yielded no visible items"
        );
        assert!(!in_plain.is_empty());

        // Sanity: the phantom version has FEWER visible glyphs than
        // the plain `a^2` — the base `a` is hidden in the first.
        assert!(
            in_phantom.len() < in_plain.len(),
            "expected phantom version (no visible base) to have fewer \
             items than plain a^2; got {} vs {}",
            in_phantom.len(),
            in_plain.len()
        );

        // The y-positions of the surviving glyphs ARE roughly the same
        // height in both fragments — the superscript sits at the same
        // vertical offset whether or not the base is visible.  We
        // measure the topmost y in each set; they should be within a
        // small epsilon (the `^2` glyph in both cases).
        let top_y = |items: &[&LeafSpan]| -> f64 {
            items.iter().map(|s| s.pos_pt.1).fold(f64::INFINITY, f64::min)
        };
        let y_phantom = top_y(&in_phantom);
        let y_plain = top_y(&in_plain);
        assert!(
            (y_phantom - y_plain).abs() < 1.0,
            "superscript y drifted: phantom={:.3}pt plain={:.3}pt — \
             full-doc baseline recovery in step 3/4 will need this",
            y_phantom,
            y_plain
        );
    }

    #[test]
    fn extract_renders_distinct_svgs_for_two_fragments() {
        let mut world = TipWorld::new();
        let src = "Some text $x + y$ between $a - b$ math.\n";
        let doc = compile_real_document(&mut world, src).expect("compile");

        let r1 = locate(src, "$x + y$");
        let r2 = locate(src, "$a - b$");
        let f1 = extract_fragment_svg(&world, &doc, r1.start, r1.end)
            .expect("fragment 1 should render");
        let f2 = extract_fragment_svg(&world, &doc, r2.start, r2.end)
            .expect("fragment 2 should render");

        assert!(f1.width_pt > 0.0 && f1.height_pt > 0.0);
        assert!(f2.width_pt > 0.0 && f2.height_pt > 0.0);
        assert!(f1.svg.contains("<svg"));
        assert!(f2.svg.contains("<svg"));
        assert_ne!(f1.svg, f2.svg, "two distinct fragments produced identical SVG");
    }

    /// Step-4 acceptance: with surrounding text on the same line,
    /// `$phantom(a)^2$` and `$a^2$` must report the **same baseline**
    /// (i.e. the same `height_pt - depth_pt`, since both crop to the
    /// surrounding-text baseline).  Without external baseline this
    /// would silently regress on hidden-base superscripts.
    #[test]
    fn external_baseline_matches_for_phantom_vs_plain() {
        let mut world = TipWorld::new();
        let src = "\
#let phantom(x) = hide($#x$)
text $phantom(a)^2$ and $a^2$ done
";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let r_phantom = locate(src, "$phantom(a)^2$");
        let r_plain = locate(src, "$a^2$");

        let f_phantom = extract_fragment_svg(&world, &doc, r_phantom.start, r_phantom.end)
            .expect("phantom render");
        let f_plain = extract_fragment_svg(&world, &doc, r_plain.start, r_plain.end)
            .expect("plain render");

        assert!(
            f_phantom.baseline_external && f_plain.baseline_external,
            "both fragments should pick up the surrounding-text baseline"
        );
        // The plain a^2 has a real `a` glyph touching the baseline, so
        // its depth is ~0 (no descender).  The phantom version's only
        // ink is `^2` entirely above the baseline, so depth is also 0.
        // What matters is they agree.
        assert!(
            (f_phantom.depth_pt - f_plain.depth_pt).abs() < 0.5,
            "depth diverged: phantom={:.3} plain={:.3}",
            f_phantom.depth_pt,
            f_plain.depth_pt
        );
    }

    /// Mixed-size: the same `$x + y$` body inside a 14 pt section
    /// must report `font_size_pt == 14`, while the same expression
    /// at the document default reports ~11 pt.  Emacs's effective
    /// scale uses this ratio so the preview matches the document's
    /// own typesetting.
    #[test]
    fn font_size_tracks_document_text_size() {
        let mut world = TipWorld::new();
        let src = "\
$x + y$ default size

#text(size: 14pt)[$x + y$ bigger]
";
        let doc = compile_real_document(&mut world, src).expect("compile");
        // `find` returns the FIRST match — locate the second `$x + y$`
        // by skipping past the first one explicitly.
        let first_start = src.find("$x + y$").unwrap();
        let second_start = src[first_start + 7..].find("$x + y$").unwrap()
            + first_start
            + 7;

        let f1 = extract_fragment_svg(&world, &doc, first_start, first_start + 7).unwrap();
        let f2 = extract_fragment_svg(&world, &doc, second_start, second_start + 7).unwrap();

        // Default text size in Typst is 11 pt (give or take).
        assert!(
            (f1.font_size_pt - 11.0).abs() < 0.5,
            "expected default ~11 pt, got {:.3}",
            f1.font_size_pt
        );
        assert!(
            (f2.font_size_pt - 14.0).abs() < 0.5,
            "expected 14 pt section, got {:.3}",
            f2.font_size_pt
        );
        // Sanity: the 14 pt fragment renders bigger than the 11 pt one.
        assert!(
            f2.height_pt > f1.height_pt * 1.15,
            "14pt fragment ({:.2}) should be visibly taller than 11pt ({:.2})",
            f2.height_pt,
            f1.height_pt
        );
    }

    /// Comparison: render the same fragment with synthetic and
    /// full-doc strategies on a default-size doc; metrics should
    /// agree within sensible tolerances.  Mixed-size docs are
    /// covered by the `font_size_tracks_*` test above — synthetic
    /// always reports 11 pt, full-doc reports the actual size, so
    /// equivalence on mixed-size is by design false.
    #[test]
    fn synthetic_and_full_doc_agree_on_default_size() {
        use crate::compiler::FragmentCompiler;

        let mut w_full = TipWorld::new();
        let mut w_syn = TipWorld::new();
        let src = "Body $x + y$ here.\n";
        let doc = compile_real_document(&mut w_full, src).expect("compile");
        let r = locate(src, "$x + y$");
        let full = extract_fragment_svg(&w_full, &doc, r.start, r.end).unwrap();
        let syn = FragmentCompiler::compile_fragment_scoped(
            &mut w_syn,
            src,
            r.start,
            r.end,
            tip_protocol::svg_color::STANDIN_HEX,
            None,
            None,
        )
        .expect("synthetic compile");

        // Width within 25% (different layout contexts produce slightly
        // different glyph advances; allow some slack but flag big drift).
        let wr = full.width_pt / syn.width_pt;
        assert!(
            wr > 0.75 && wr < 1.25,
            "width drift: full={:.2} synthetic={:.2} ratio={:.2}",
            full.width_pt,
            syn.width_pt,
            wr
        );
        // Height within 35% — synthetic adds 0.5pt padding and crops
        // differently around margins, but the ink should be similar.
        let hr = full.height_pt / syn.height_pt;
        assert!(
            hr > 0.65 && hr < 1.35,
            "height drift: full={:.2} synthetic={:.2} ratio={:.2}",
            full.height_pt,
            syn.height_pt,
            hr
        );
    }

    #[test]
    fn extract_handles_phantom_base_superscript() {
        // The phantom-base case from the partition regression test:
        // `phantom(a)^2` must still render — the `^2` glyph is real,
        // even with an invisible base.  Step 4 handles the baseline.
        let mut world = TipWorld::new();
        let src = "\
#let phantom(x) = hide($#x$)
$phantom(a)^2$
";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let r = locate(src, "$phantom(a)^2$");
        let f = extract_fragment_svg(&world, &doc, r.start, r.end)
            .expect("phantom-base fragment should render");
        assert!(f.width_pt > 0.0);
        assert!(f.height_pt > 0.0);
        assert!(f.svg.contains("<svg"));
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
