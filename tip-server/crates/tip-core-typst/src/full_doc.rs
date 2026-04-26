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
        // Step 1: flatten the page's frame tree into a linear leaf
        // list in iteration order.  Groups become transparent for
        // leaf-level decisions; their baselines (if set) are
        // captured separately.
        let mut leaves: Vec<FlatLeaf> = Vec::new();
        let mut group_records: Vec<GroupRecord> = Vec::new();
        flatten_leaves(
            &page.frame,
            Point::zero(),
            main,
            &main_src,
            start,
            end,
            &mut leaves,
            &mut group_records,
        );

        // Step 2: linear "run" pass.  In iteration order, leaves
        // categorize as InRange (attached span overlaps fragment),
        // Detached (`span.id() == None` — typst-synthesized math
        // symbol, accent, auto-space, etc.), or OutAttached (attached
        // span belonging to a different file or a different fragment).
        //
        // OutAttached leaves act as barriers — they end the current
        // fragment-run and clear any pending detached items.  Detached
        // leaves either join an active fragment (back-fill if they
        // preceded the first InRange in the run) or wait for one.
        //
        // No spatial tolerance, no magic distance.  This is the
        // heuristic-elimination pass [H1] in `doc/full-document-approach.md`.
        let mut keep: Vec<(Point, FrameItem)> = Vec::new();
        let mut bounds = ItemBounds::empty();
        let mut max_text_size = Abs::zero();
        let mut detached_buffer: Vec<usize> = Vec::new();
        let mut in_fragment = false;
        for (i, leaf) in leaves.iter().enumerate() {
            match leaf.category {
                LeafCategory::InRange => {
                    for j in detached_buffer.drain(..) {
                        push_leaf(&leaves[j], &mut keep, &mut bounds, &mut max_text_size);
                    }
                    push_leaf(leaf, &mut keep, &mut bounds, &mut max_text_size);
                    in_fragment = true;
                }
                LeafCategory::Detached => {
                    if in_fragment {
                        push_leaf(leaf, &mut keep, &mut bounds, &mut max_text_size);
                    } else {
                        detached_buffer.push(i);
                    }
                }
                LeafCategory::OutAttached => {
                    in_fragment = false;
                    detached_buffer.clear();
                }
            }
        }

        if keep.is_empty() || bounds.is_empty() {
            continue;
        }

        // Group baselines that belong to fragment-bearing groups.
        let group_baselines: Vec<Abs> = group_records
            .iter()
            .filter(|r| r.has_in_range)
            .map(|r| r.baseline_y)
            .collect();

        let frag_baselines: Vec<Abs> = keep
            .iter()
            .filter_map(|(p, item)| match item {
                FrameItem::Text(_) => Some(p.y),
                _ => None,
            })
            .collect();
        // Baseline picker (priority order):
        //
        //   1. **Group baseline** from a fragment-bearing Group with
        //      `has_baseline()=true`.  Typst sets this on math
        //      equations and is what the synthetic compiler uses via
        //      `find_group_baseline`.  Sits ~0.5 pt above raw
        //      TextItem `pos.y` due to math-axis alignment.
        //   2. **frag_max** = lowest TextItem baseline in the
        //      fragment.  Used when the fragment has no explicit
        //      Group baseline.
        //   3. **external** = surrounding-text line baseline within
        //      tol.  Used when the fragment is sub/super-shifted
        //      (`^2` after `phantom(a)` etc.) — its own baselines
        //      sit far above the line, so we have to reach out for
        //      the real line baseline.
        //   4. **bounds.max_y** as a last resort (Shape-only
        //      fragments).
        let frag_max = frag_baselines.iter().copied().max();
        let group_baseline = group_baselines.iter().copied().max();
        let external_y =
            find_external_baseline(&page.frame, &frag_baselines, max_text_size, main, &main_src, start, end);
        const SHIFT_THRESHOLD: f64 = 2.0;
        let (baseline_y, external) = match (group_baseline, frag_max, external_y) {
            (Some(gb), _, _) => (gb, false),
            (None, Some(fm), Some(ex)) if (ex - fm).to_pt() > SHIFT_THRESHOLD => (ex, true),
            (None, Some(fm), _) => (fm, false),
            (None, None, Some(ex)) => (ex, true),
            (None, None, None) => (bounds.max_y, false),
        };

        // Crop bounds: tight to ink in x; in y, EXTEND to include the
        // baseline so callers placing the image at `:ascent (depth/H)`
        // get the right visual position.  Without this, a fragment
        // whose ink is entirely above the baseline (e.g. a bare
        // `^2`, or `phantom(a)^2`) crops to just the superscript and
        // looks baseline-aligned on itself — losing the "high up"
        // appearance the user expects.  Extending the bottom of the
        // crop down to baseline_y reserves blank space below the ink
        // so the resulting image's bottom edge IS the baseline.
        let pad = Abs::pt(0.5);
        let crop_max_y = bounds.max_y.max(baseline_y);
        let crop_min_y = bounds.min_y.min(baseline_y);
        let min_x = bounds.min_x - pad;
        let min_y = crop_min_y - pad;
        let width = bounds.max_x - bounds.min_x + pad * 2.0;
        let height = crop_max_y - crop_min_y + pad * 2.0;
        // Depth = ink-below-baseline + bottom pad.  The pad is empty
        // crop space we added below `crop_max_y`; from the displayer's
        // perspective the image extends `pad` below the baseline too,
        // so it has to be included or the image floats up by 0.5 pt.
        // Matches the synthetic compiler's `cropped_height -
        // baseline_in_crop` arithmetic.
        let depth = ((crop_max_y - baseline_y) + pad).max(Abs::zero());

        // Rebuild a flat Frame at the cropped origin.  Clone is cheap
        // — FrameItem is `derive(Clone)` and Text/Shape are Arcs/Vecs.
        let mut out = Frame::soft(Size::new(width, height));
        for (pos, item) in keep {
            out.push(Point::new(pos.x - min_x, pos.y - min_y), item);
        }

        // `font_size_pt` represents the paragraph context size, used
        // by `tip--effective-scale` to keep the displayed image at
        // about Emacs's text size.  Take the LARGEST of:
        //   - the fragment's own max TextItem size, AND
        //   - the surrounding line's max external TextItem size.
        //
        // Fragment-only max fails for sub/super-only fragments
        // (e.g. `phantom(a)^2` — single `^2` glyph at ~7 pt) where
        // `tip-scale='auto'` would then scale the preview up
        // ~1.6×.  Including external line size gives the true
        // paragraph point size in those cases.
        let line_anchors: Vec<Abs> = group_baselines
            .iter()
            .copied()
            .chain(frag_baselines.iter().copied())
            .collect();
        let external_size = find_external_line_size(
            &page.frame,
            &line_anchors,
            max_text_size,
            main,
            &main_src,
            start,
            end,
        );
        let candidate_sizes = [Some(max_text_size), external_size];
        let derived = candidate_sizes
            .iter()
            .filter_map(|x| *x)
            .filter(|s| *s > Abs::zero())
            .max();
        let font_size = derived.map(|a| a.to_pt()).unwrap_or(11.0);

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

/// One leaf (Text or Shape) flattened from the frame tree, with its
/// fragment-membership category pre-computed.  Group offsets are
/// already accumulated into `pos`.
struct FlatLeaf {
    pos: Point,
    item: FrameItem,
    category: LeafCategory,
    text_size: Option<Abs>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LeafCategory {
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
struct GroupRecord {
    baseline_y: Abs,
    has_in_range: bool,
}

fn classify_text(t: &typst::text::TextItem, main: FileId, src: &Source, start: usize, end: usize) -> LeafCategory {
    let mut has_in_range = false;
    let mut has_out_attached = false;
    for g in &t.glyphs {
        let span = g.span.0;
        match span.id() {
            None => {} // detached
            Some(id) if id == main => match src.range(span) {
                Some(r) if r.start < end && r.end > start => has_in_range = true,
                Some(_) => has_out_attached = true,
                None => {} // attached-but-unresolvable; treat like detached
            },
            Some(_) => has_out_attached = true, // attached to another file
        }
    }
    if has_in_range {
        LeafCategory::InRange
    } else if has_out_attached {
        LeafCategory::OutAttached
    } else {
        LeafCategory::Detached
    }
}

fn classify_span(span: typst::syntax::Span, main: FileId, src: &Source, start: usize, end: usize) -> LeafCategory {
    match span.id() {
        None => LeafCategory::Detached,
        Some(id) if id == main => match src.range(span) {
            Some(r) if r.start < end && r.end > start => LeafCategory::InRange,
            Some(_) => LeafCategory::OutAttached,
            None => LeafCategory::Detached,
        },
        Some(_) => LeafCategory::OutAttached,
    }
}

/// Walk the frame tree depth-first, accumulating Group offsets.  Each
/// leaf becomes a `FlatLeaf`; each Group with `has_baseline()` becomes
/// a `GroupRecord` flagged with whether any of its descendants are
/// in-range.  Groups themselves don't appear as leaves — they're
/// transparent for the run-based pass.
fn flatten_leaves(
    frame: &Frame,
    offset: Point,
    main: FileId,
    src: &Source,
    start: usize,
    end: usize,
    out_leaves: &mut Vec<FlatLeaf>,
    out_groups: &mut Vec<GroupRecord>,
) {
    for (pos, item) in frame.items() {
        let abs = Point::new(offset.x + pos.x, offset.y + pos.y);
        match item {
            FrameItem::Group(g) => {
                let before = out_leaves.len();
                flatten_leaves(&g.frame, abs, main, src, start, end, out_leaves, out_groups);
                if g.frame.has_baseline() {
                    let has_in_range = out_leaves[before..]
                        .iter()
                        .any(|l| matches!(l.category, LeafCategory::InRange));
                    out_groups.push(GroupRecord {
                        baseline_y: abs.y + g.frame.baseline(),
                        has_in_range,
                    });
                }
            }
            FrameItem::Text(t) => {
                out_leaves.push(FlatLeaf {
                    pos: abs,
                    item: FrameItem::Text(t.clone()),
                    category: classify_text(t, main, src, start, end),
                    text_size: Some(t.size),
                });
            }
            FrameItem::Shape(shape, span) => {
                out_leaves.push(FlatLeaf {
                    pos: abs,
                    item: FrameItem::Shape(shape.clone(), *span),
                    category: classify_span(*span, main, src, start, end),
                    text_size: None,
                });
            }
            _ => {}
        }
    }
}

/// Append a leaf to the kept items, extending bounds and the
/// running max_text_size.  The bbox y-flip mirrors what the synthetic
/// compiler does in `find_ink_extent` (TextItem::bbox returns
/// glyph-coord y, so frame-top is `bbox.max.y` and frame-bottom is
/// `bbox.min.y`).
fn push_leaf(
    leaf: &FlatLeaf,
    keep: &mut Vec<(Point, FrameItem)>,
    bounds: &mut ItemBounds,
    max_text_size: &mut Abs,
) {
    match &leaf.item {
        FrameItem::Text(t) => {
            let bbox = t.bbox();
            bounds.extend(
                leaf.pos.x + bbox.min.x,
                leaf.pos.y + bbox.max.y,
                leaf.pos.x + bbox.max.x,
                leaf.pos.y + bbox.min.y,
            );
            if let Some(s) = leaf.text_size {
                if s > *max_text_size {
                    *max_text_size = s;
                }
            }
        }
        FrameItem::Shape(_, _) => {
            // Shape geometry: contribute a 1-pt bbox at position.
            // Proper Geometry walking is on the readiness checklist.
            bounds.extend(leaf.pos.x, leaf.pos.y, leaf.pos.x, leaf.pos.y);
        }
        _ => {}
    }
    keep.push((leaf.pos, leaf.item.clone()));
}

/// Tolerance for "same line as fragment", scaled with the fragment's
/// own text size.  Default leading in typst is ~1.2 em, so anything
/// within 0.5 em is on the same line; anything beyond is a different
/// paragraph (or a different line in a tight paragraph).
///
/// Replaces a fixed 6 pt tol that worked at 11 pt body but bled into
/// adjacent paragraphs at 1–3 pt body.  Lower bound 0.5 pt keeps the
/// math sane for sub-pt extremes.
fn line_tol(max_text_size: Abs) -> Abs {
    let scaled = max_text_size * 0.5;
    if scaled.to_pt() < 0.5 {
        Abs::pt(0.5)
    } else {
        scaled
    }
}

/// Find a surrounding-text baseline on `frame` (a page) for an
/// inline-math fragment whose own text-item baselines are
/// `frag_baselines`.  Walks all text items NOT inside the fragment's
/// source range; returns the one whose baseline-y is closest to any
/// `frag_baselines` entry, within ~half an em of `max_text_size`.
/// Returns `None` when nothing surrounding is on the same line
/// (display math, or the math is the only content).
fn find_external_baseline(
    frame: &Frame,
    frag_baselines: &[Abs],
    max_text_size: Abs,
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
    // Pick the LARGEST external pos.y within tol of any fragment
    // baseline.  Rationale: in y-down frame coords, line-baselines
    // sit BELOW super-script baselines (super shifts text UP).  If a
    // fragment has only a `^2` glyph (e.g. `phantom(a)^2`), nearby
    // candidates include other fragments' superscripts (~same y) AND
    // the prose text on the same line (~5 pt larger y).  The line
    // baseline is what we want — and it's always the maximum.
    let tol = line_tol(max_text_size);
    let mut best: Option<Abs> = None;
    for ey in external_ys {
        let in_tol = frag_baselines.iter().any(|fy| (ey - *fy).abs() <= tol);
        if in_tol && best.map_or(true, |b| ey > b) {
            best = Some(ey);
        }
    }
    best
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

/// Largest external `TextItem::size` on the same line as the fragment.
/// Used to set `font_size_pt` to the paragraph context size, not the
/// math glyph size — important when the fragment's only visible
/// content is sub/super-shifted (e.g. `phantom(a)^2`), whose `^2` is
/// rendered at ~7 pt.  Without this, `tip-scale='auto'` would scale
/// the preview up by ~1.6× because Emacs computes
/// `emacs_font_pt / rendered_pt`.
///
/// `max_text_size` is the fragment's own largest text size, used to
/// scale the same-line tolerance (`line_tol`).  At small body sizes
/// a fixed tol bleeds across paragraph boundaries.
fn find_external_line_size(
    frame: &Frame,
    line_anchors: &[Abs],
    max_text_size: Abs,
    main: FileId,
    src: &Source,
    exclude_start: usize,
    exclude_end: usize,
) -> Option<Abs> {
    if line_anchors.is_empty() {
        return None;
    }
    let mut candidates: Vec<(Abs, Abs)> = Vec::new(); // (y, size)
    walk_external_size(
        frame,
        Point::zero(),
        main,
        src,
        exclude_start,
        exclude_end,
        &mut candidates,
    );
    let tol = line_tol(max_text_size);
    candidates
        .into_iter()
        .filter(|(y, _)| line_anchors.iter().any(|a| (*y - *a).abs() <= tol))
        .map(|(_, s)| s)
        .max()
}

fn walk_external_size(
    frame: &Frame,
    offset: Point,
    main: FileId,
    src: &Source,
    exclude_start: usize,
    exclude_end: usize,
    out: &mut Vec<(Abs, Abs)>,
) {
    for (pos, item) in frame.items() {
        let abs = Point::new(offset.x + pos.x, offset.y + pos.y);
        match item {
            FrameItem::Group(g) => walk_external_size(
                &g.frame,
                abs,
                main,
                src,
                exclude_start,
                exclude_end,
                out,
            ),
            FrameItem::Text(t) => {
                let any_in = t
                    .glyphs
                    .iter()
                    .any(|gl| span_in_range(gl.span.0, main, src, exclude_start, exclude_end));
                if !any_in {
                    out.push((abs.y, t.size));
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

    /// `font_size_pt` for `$phantom(a)^2$` must reflect the paragraph
    /// context (~11 pt), not the `^2` glyph's own ~7 pt.  Otherwise
    /// `tip-scale='auto'` (Emacs default) divides by 7 and scales the
    /// preview ~1.6× — making the superscript huge.
    #[test]
    fn font_size_for_sup_only_fragment_uses_paragraph_context() {
        let mut world = TipWorld::new();
        let src = "\
#let phantom(x) = hide($#x$)
text $phantom(a)^2$ and $a^2$ done
";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let r_phantom = locate(src, "$phantom(a)^2$");
        let r_plain = locate(src, "$a^2$");
        let f_phantom =
            extract_fragment_svg(&world, &doc, r_phantom.start, r_phantom.end).unwrap();
        let f_plain = extract_fragment_svg(&world, &doc, r_plain.start, r_plain.end).unwrap();
        // Both fragments live in an 11 pt paragraph; phantom should
        // adopt the same paragraph size as plain even though its
        // only visible glyph is sup-scaled.
        assert!(
            (f_phantom.font_size_pt - f_plain.font_size_pt).abs() < 0.5,
            "phantom font_size {:.3} should match plain {:.3} (paragraph context)",
            f_phantom.font_size_pt,
            f_plain.font_size_pt
        );
        assert!(
            f_phantom.font_size_pt > 9.0,
            "phantom font_size {:.3} suspiciously low — likely picked up the \
             sup-scaled `^2` glyph instead of paragraph text",
            f_phantom.font_size_pt
        );
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

        // What matters is matching depth + height — whether the picker
        // got there via Group baseline, frag-text baseline, or external
        // is implementation detail.
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
        // Crucial: phantom's frame height must extend DOWN to the
        // baseline even though its ink doesn't.  Otherwise the
        // resulting image looks baseline-aligned on the `^2` itself.
        // Heights should agree within a glyph-descender's worth.
        assert!(
            (f_phantom.height_pt - f_plain.height_pt).abs() < 2.0,
            "phantom height should match plain (both extend to baseline): \
             phantom={:.3} plain={:.3}",
            f_phantom.height_pt,
            f_plain.height_pt
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
    /// Live-bug probe: print height/depth/baseline for `$a+b=c$` in
    /// both strategies.  Eyeballed against GUI rendering — synthetic
    /// looks correct; full-doc reportedly puts math too high.
    #[test]
    #[ignore = "diagnostic only, run with --ignored"]
    fn diag_depth_for_inline() {
        use crate::compiler::FragmentCompiler;
        let mut w_full = TipWorld::new();
        let mut w_syn = TipWorld::new();
        let src = "Default 11pt: $a + b = c$ and rest.\n";
        let doc = compile_real_document(&mut w_full, src).expect("compile");
        let r = locate(src, "$a + b = c$");
        let f = extract_fragment_svg(&w_full, &doc, r.start, r.end).unwrap();
        let s = FragmentCompiler::compile_fragment_scoped(
            &mut w_syn,
            src,
            r.start,
            r.end,
            tip_protocol::svg_color::STANDIN_HEX,
            None,
            None,
        )
        .unwrap();
        let spans = collect_leaf_spans(&w_full, &doc);
        for s in &spans {
            if let Some(ref r2) = s.source_range {
                if r2.start >= r.start && r2.end <= r.end {
                    eprintln!("  frag glyph range={:?} pos.y={:.3}", r2, s.pos_pt.1);
                }
            }
        }
        eprintln!(
            "full:  h={:.3} d={:.3} w={:.3} fs={:.3} ext={}",
            f.height_pt, f.depth_pt, f.width_pt, f.font_size_pt, f.baseline_external
        );
        eprintln!(
            "synth: h={:.3} d={:.3} w={:.3}",
            s.height_pt, s.depth_pt, s.width_pt
        );
        eprintln!(
            "ascent_full={:.1}%  ascent_synth={:.1}%",
            (f.height_pt - f.depth_pt) / f.height_pt * 100.0,
            (s.height_pt - s.depth_pt) / s.height_pt * 100.0,
        );
    }

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

    /// Regression: `dif`, `pi`, and other typst math symbols are
    /// referenced by user-written identifiers but resolved via the
    /// math scope (or imported modules).  If their resulting glyphs
    /// carry spans that point to the std-lib definition rather than
    /// the user source, the fragment-range filter drops them and
    /// the rendered SVG is missing `dif x` / `pi` etc.  Verify the
    /// glyphs survive the filter.
    #[test]
    fn extract_keeps_math_symbol_glyphs() {
        // Render `$dif x$` (full doc) and `$x$` alone.  If `dif`'s
        // detached-span TextItem isn't recovered by the neighborhood
        // pass, the rendered widths are equal — bug.  With recovery,
        // `dif x` is wider than `x` by roughly the width of a `d`
        // glyph plus its math spacing.
        let mut world = TipWorld::new();
        let src = "$dif x$ then $x$ alone\n";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let r_dif = locate(src, "$dif x$");
        let r_x = locate(src, "$x$");
        let f_dif = extract_fragment_svg(&world, &doc, r_dif.start, r_dif.end)
            .expect("dif x render");
        let f_x = extract_fragment_svg(&world, &doc, r_x.start, r_x.end).expect("x render");
        assert!(
            f_dif.width_pt > f_x.width_pt + 4.0,
            "expected `dif x` ({:.2}pt) noticeably wider than `x` ({:.2}pt) — \
             detached `dif` glyph likely dropped",
            f_dif.width_pt,
            f_x.width_pt
        );
    }

    /// Back-to-back math fragments separated only by `dif`-style
    /// detached glyphs MUST NOT cross-contaminate.  The run-based
    /// algorithm should treat the prose word "and" between them as
    /// an OutAttached barrier, partitioning detached items by which
    /// fragment they belong to.
    /// Stress: very small body size (1 pt).  At this scale the
    /// default 13 pt line spacing collapses to ~1.2 pt, well inside
    /// the 6 pt baseline tol [H2].  If `find_external_baseline` picks
    /// up the next line's baseline, depth + height go absurd.
    ///
    /// We're not asserting that 1 pt looks GOOD — just that the
    /// metrics stay sane: positive height, font_size near 1, and
    /// no cross-line baseline contamination.
    #[test]
    fn extreme_small_text_size_1pt() {
        let mut world = TipWorld::new();
        let src = "\
#set text(size: 1pt)
line one with $a + b$ math.
line two with $c - d$ math.
";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let r1 = locate(src, "$a + b$");
        let r2 = locate(src, "$c - d$");
        let f1 = extract_fragment_svg(&world, &doc, r1.start, r1.end).unwrap();
        let f2 = extract_fragment_svg(&world, &doc, r2.start, r2.end).unwrap();

        eprintln!(
            "f1 (1pt): h={:.3} d={:.3} w={:.3} fs={:.3} ext={}",
            f1.height_pt, f1.depth_pt, f1.width_pt, f1.font_size_pt, f1.baseline_external
        );
        eprintln!(
            "f2 (1pt): h={:.3} d={:.3} w={:.3} fs={:.3} ext={}",
            f2.height_pt, f2.depth_pt, f2.width_pt, f2.font_size_pt, f2.baseline_external
        );

        // Sanity: font size matches paragraph context.
        assert!(
            f1.font_size_pt < 2.0,
            "f1 font_size {:.3} should be ~1pt",
            f1.font_size_pt
        );
        assert!(
            f2.font_size_pt < 2.0,
            "f2 font_size {:.3} should be ~1pt",
            f2.font_size_pt
        );
        // Cross-line contamination check: at 1 pt, line spacing ~1.2 pt,
        // tol=6pt could pick the OTHER line's baseline.  If it does, the
        // height blows up to ~one line spacing.  An honest 1 pt math
        // height should be < 2 pt.
        assert!(
            f1.height_pt < 2.0,
            "f1 height {:.3} much larger than 1pt — likely cross-line baseline",
            f1.height_pt
        );
        assert!(
            f2.height_pt < 2.0,
            "f2 height {:.3} much larger than 1pt — likely cross-line baseline",
            f2.height_pt
        );
    }

    /// Stress: phantom-base superscript at 1 pt — super-shift is
    /// ~0.4 pt, below the 2 pt SHIFT_THRESHOLD [H3].  The picker
    /// won't escape to external; depth/height come from frag own.
    /// At this scale, both behaviors should produce similar results
    /// since the shift is so small.  Verify it doesn't crash and
    /// produces positive numbers.
    #[test]
    fn extreme_small_phantom_superscript_1pt() {
        let mut world = TipWorld::new();
        let src = "\
#set text(size: 1pt)
#let phantom(x) = hide($#x$)
text $phantom(a)^2$ and $a^2$ done
";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let r_phantom = locate(src, "$phantom(a)^2$");
        let r_plain = locate(src, "$a^2$");
        let f_phantom =
            extract_fragment_svg(&world, &doc, r_phantom.start, r_phantom.end).unwrap();
        let f_plain = extract_fragment_svg(&world, &doc, r_plain.start, r_plain.end).unwrap();

        eprintln!(
            "1pt phantom: h={:.3} d={:.3} w={:.3} fs={:.3}",
            f_phantom.height_pt, f_phantom.depth_pt, f_phantom.width_pt, f_phantom.font_size_pt
        );
        eprintln!(
            "1pt plain:   h={:.3} d={:.3} w={:.3} fs={:.3}",
            f_plain.height_pt, f_plain.depth_pt, f_plain.width_pt, f_plain.font_size_pt
        );

        assert!(f_phantom.height_pt > 0.0);
        assert!(f_plain.height_pt > 0.0);
        // Both should report ~1 pt paragraph context.
        assert!(f_phantom.font_size_pt < 2.0);
        assert!(f_plain.font_size_pt < 2.0);
    }

    /// Stress: very tight `#set par(leading: 0pt)` — adjacent lines
    /// can be < 1 pt apart.  Even at 11 pt body, our 6 pt tol could
    /// span lines.  Verify metrics stay sane.
    /// Stress: pseudo-random mix of 1pt..10pt in the same buffer.
    /// Each math fragment must report `font_size_pt` matching ITS
    /// section, not bleed from neighbors.  Heights scale with the
    /// section size.  Catches: external-baseline picker grabbing a
    /// neighbor of a different size, font-size lookup returning an
    /// unrelated section's value.
    #[test]
    fn extreme_mixed_sizes_1_to_10pt() {
        let mut world = TipWorld::new();
        let src = "\
#text(size: 1pt)[$a + b$ at one]

#text(size: 3pt)[$a + b$ at three]

#text(size: 7pt)[$a + b$ at seven]

#text(size: 10pt)[$a + b$ at ten]

#text(size: 2pt)[$a + b$ at two]

#text(size: 9pt)[$a + b$ at nine]
";
        let doc = compile_real_document(&mut world, src).expect("compile");
        // Locate each fragment by section.
        let cases = [
            ("at one", 1.0),
            ("at three", 3.0),
            ("at seven", 7.0),
            ("at ten", 10.0),
            ("at two", 2.0),
            ("at nine", 9.0),
        ];
        let mut results = Vec::new();
        for (anchor, expected_size) in cases {
            // Find the `$a + b$` whose follow-up text is `anchor`.
            let after_idx = src.find(anchor).unwrap();
            // Walk back to the nearest `$a + b$` before `anchor`.
            let math_start = src[..after_idx].rfind("$a + b$").unwrap();
            let f = extract_fragment_svg(
                &world,
                &doc,
                math_start,
                math_start + "$a + b$".len(),
            )
            .unwrap();
            eprintln!(
                "{anchor:>10} (~{expected_size}pt): h={:.3} d={:.3} w={:.3} fs={:.3}",
                f.height_pt, f.depth_pt, f.width_pt, f.font_size_pt
            );
            results.push((expected_size, f));
        }

        // Each fragment's reported font_size_pt must be within 0.5pt
        // of the section size — proves no leak from neighbors.
        for (expected, f) in &results {
            assert!(
                (f.font_size_pt - expected).abs() < 0.5,
                "fragment at {expected}pt got font_size {:.3} — neighbor bleed?",
                f.font_size_pt
            );
        }

        // Heights must scale roughly with size — but not linearly,
        // because the pad+depth contribute a near-constant ~0.5 pt
        // floor.  At 10 pt vs 1 pt, the ratio is ~5× rather than 10×.
        let h_1pt = results[0].1.height_pt;
        let h_10pt = results[3].1.height_pt;
        assert!(
            h_10pt > h_1pt * 3.0,
            "10pt height {:.3} should be visibly larger than 1pt {:.3}",
            h_10pt,
            h_1pt
        );

        // No fragment should have an absurd height (cross-paragraph
        // baseline pickup).  Cap: 3× the section size.
        for (expected, f) in &results {
            assert!(
                f.height_pt < expected * 3.0,
                "fragment at {expected}pt has height {:.3} — sane upper bound is ~{}",
                f.height_pt,
                expected * 3.0
            );
        }
    }

    #[test]
    fn extreme_zero_leading() {
        let mut world = TipWorld::new();
        let src = "\
#set par(leading: 0pt)
line one with $a + b$ math.
line two with $c - d$ math.
";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let r1 = locate(src, "$a + b$");
        let r2 = locate(src, "$c - d$");
        let f1 = extract_fragment_svg(&world, &doc, r1.start, r1.end).unwrap();
        let f2 = extract_fragment_svg(&world, &doc, r2.start, r2.end).unwrap();

        eprintln!(
            "0-leading f1: h={:.3} d={:.3} ext={}",
            f1.height_pt, f1.depth_pt, f1.baseline_external
        );
        eprintln!(
            "0-leading f2: h={:.3} d={:.3} ext={}",
            f2.height_pt, f2.depth_pt, f2.baseline_external
        );

        // Reasonable inline-math height for 11 pt body is ~10 pt.
        // If we're picking the WRONG line's baseline, height balloons
        // way beyond that.
        assert!(
            f1.height_pt < 20.0,
            "f1 height {:.3} suggests cross-line contamination",
            f1.height_pt
        );
        assert!(
            f2.height_pt < 20.0,
            "f2 height {:.3} suggests cross-line contamination",
            f2.height_pt
        );
    }

    #[test]
    fn run_pass_partitions_detached_between_fragments() {
        let mut world = TipWorld::new();
        let src = "$dif x$ and $dif y$\n";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let r1 = locate(src, "$dif x$");
        let r2 = locate(src, "$dif y$");
        let f1 = extract_fragment_svg(&world, &doc, r1.start, r1.end).unwrap();
        let f2 = extract_fragment_svg(&world, &doc, r2.start, r2.end).unwrap();
        // Each fragment should be wider than just `x` or `y` — so its
        // own `dif` glyph is included.  Their widths should be similar
        // (same glyphs, same context).
        assert!(
            f1.width_pt > 8.0,
            "fragment 1 missing dif: w={:.2}",
            f1.width_pt
        );
        assert!(
            f2.width_pt > 8.0,
            "fragment 2 missing dif: w={:.2}",
            f2.width_pt
        );
        assert!(
            (f1.width_pt - f2.width_pt).abs() < 4.0,
            "fragment widths drifted, suggesting cross-contamination: \
             f1={:.2} f2={:.2}",
            f1.width_pt,
            f2.width_pt
        );
    }

    #[test]
    fn extract_keeps_sqrt_radicand() {
        // Companion: `$sqrt(pi)$` must include the `pi` (π) glyph.
        // Without the neighborhood pass it renders as just `√`.
        let mut world = TipWorld::new();
        let src = "Body $sqrt(pi)$ and $sqrt(x)$ done\n";
        let doc = compile_real_document(&mut world, src).expect("compile");
        let r_pi = locate(src, "$sqrt(pi)$");
        let r_x = locate(src, "$sqrt(x)$");
        let f_pi = extract_fragment_svg(&world, &doc, r_pi.start, r_pi.end).unwrap();
        let f_x = extract_fragment_svg(&world, &doc, r_x.start, r_x.end).unwrap();
        // sqrt(pi) and sqrt(x) should both render with a radicand —
        // their widths shouldn't differ by more than a few pt.  If
        // pi's glyph is dropped, sqrt(pi)'s ink is just the radical
        // which is much narrower.
        assert!(
            (f_pi.width_pt - f_x.width_pt).abs() < 5.0,
            "sqrt(pi) ({:.2}) and sqrt(x) ({:.2}) widths diverged — \
             pi glyph probably missing",
            f_pi.width_pt,
            f_x.width_pt
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
