//! Per-fragment extraction from a flattened frame tree.  Picks the
//! baseline, the font size, builds a cropped Frame, renders SVG.
//! See `super` for the strategy overview.

use typst::layout::{Abs, Frame, FrameItem, Point, Size};

use super::flatten::{FlatLeaf, GroupRecord, LeafCategory};
use crate::geometry::text_item_frame_bbox;
use crate::svg::svg_frame;

#[cfg(test)]
use {
    super::flatten::flatten_leaves,
    typst::syntax::{FileId, Source},
    typst::World,
    typst_layout::PagedDocument,
};

/// Render output for a single fragment extracted from a full document.
/// Coordinates are in points.  `depth_pt` is the height of ink BELOW
/// the line's baseline — for inline math this is what Emacs needs for
/// `:ascent` calculation.
#[derive(Debug, Clone)]
#[allow(dead_code)] // `page` and `baseline_external` are read only by tests
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
///
/// Test-only.  The production hot path is `extract_from_index`, which
/// reuses a pre-flattened page index across many fragments instead of
/// re-walking per call.
#[cfg(test)]
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
    for (page_idx, page) in doc.pages().iter().enumerate() {
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
        // heuristic-elimination pass [H1] in `devdoc/full-document-approach.md`.
        let mut keep: Vec<(Point, FrameItem)> = Vec::new();
        let mut bounds = ItemBounds::empty();
        let mut max_text_size = Abs::zero();
        let mut detached_buffer: Vec<usize> = Vec::new();
        let mut in_fragment = false;
        for (i, leaf) in leaves.iter().enumerate() {
            match leaf.category_for(start, end) {
                LeafCategory::InRange => {
                    // Flush only those buffered Detached leaves that are
                    // spatially close to this InRange — real leading
                    // math symbols (operators, auto-spacing, accents)
                    // sit within an em or so of the math glyph; list
                    // markers ("1.", "2.") sit at the line's left
                    // margin, far from the math fragment on the same
                    // line.  Without this filter, the marker glyphs
                    // bleed into the extracted SVG.  Same-line dy slack
                    // accommodates stacked accents above the base.
                    let attach_threshold = leaf.text_size.unwrap_or(Abs::pt(11.0));
                    let in_x = leaf.pos.x;
                    let in_y = leaf.pos.y;
                    for j in detached_buffer.drain(..) {
                        let buf = &leaves[j];
                        let dx = (buf.pos.x - in_x).abs();
                        let dy = (buf.pos.y - in_y).abs();
                        if dx <= attach_threshold && dy <= attach_threshold {
                            push_leaf(buf, &mut keep, &mut bounds, &mut max_text_size);
                        }
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
        // `flatten_leaves` pushes in post-order (children before
        // parents), so the LAST has-in-range group is the outermost
        // — the math-equation Group whose baseline aligns with the
        // surrounding paragraph.  For a nested sub/sup tower, inner
        // Groups' baselines are shifted down/up; only the outer
        // baseline matches the line baseline.
        let group_has_in_range = |g: &GroupRecord| {
            leaves[g.leaf_range.clone()]
                .iter()
                .any(|l| matches!(l.category_for(start, end), LeafCategory::InRange))
        };
        let outermost_group_baseline = group_records
            .iter()
            .rev()
            .find(|g| group_has_in_range(g))
            .map(|g| g.baseline_y);
        let group_baselines: Vec<Abs> = group_records
            .iter()
            .filter(|g| group_has_in_range(g))
            .map(|g| g.baseline_y)
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
        //   1. **Group baseline** from the OUTERMOST fragment-bearing
        //      Group with `has_baseline()=true`.  Typst sets this on
        //      math equations and the outer Group's baseline is the
        //      canonical line baseline (inner Groups' baselines are
        //      math-internally shifted for sub/super/frac layout).
        //   2. **External** = surrounding-text line baseline.  Kicks
        //      in for inlined math (no Group wrapper).  When fragment
        //      glyphs are sub/super-shifted, external is below them —
        //      the `>` comparison naturally falls through to "use
        //      external".  When fragment glyphs sit at the line,
        //      external == frag_max anyway, so order doesn't matter.
        //   3. **frag_max** = lowest TextItem baseline in the fragment.
        //      Used when there's no Group AND no external candidate
        //      (display math alone, or no surrounding prose on the line).
        //   4. **bounds.max_y** as a last resort (Shape-only fragments).
        //
        // Previously had a `SHIFT_THRESHOLD = 2pt` guard to distinguish
        // "fragment is at line baseline" from "fragment is sup-shifted",
        // but that's now redundant: outer Group baseline handles all
        // wrapped math; for inlined math, external (when present) is
        // always at least as authoritative as frag_max.
        let frag_max = frag_baselines.iter().copied().max();
        let group_baseline = outermost_group_baseline;
        let external_y = find_external_baseline(
            &page.frame,
            &frag_baselines,
            max_text_size,
            main,
            &main_src,
            start,
            end,
        );
        let (baseline_y, external) = match (group_baseline, external_y, frag_max) {
            (Some(gb), _, _) => (gb, false),
            (None, Some(ex), _) => (ex, true),
            (None, None, Some(fm)) => (fm, false),
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

#[cfg(test)]
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
    match src.find(span).map(|node| node.range()) {
        Some(r) => r.start < end && r.end > start,
        None => false,
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
            let (lx, ly, hx, hy) = text_item_frame_bbox(t, leaf.pos);
            bounds.extend(lx, ly, hx, hy);
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

/// Indexed variant: pick external baseline by iterating pre-flattened
/// leaves rather than re-walking the page frame.  O(L) per fragment
/// instead of O(content) per fragment.
fn find_external_baseline_from_leaves(
    leaves: &[FlatLeaf],
    frag_baselines: &[Abs],
    max_text_size: Abs,
    start: usize,
    end: usize,
) -> Option<Abs> {
    if frag_baselines.is_empty() {
        return None;
    }
    // Phase 1: tight tol scaled to fragment's own text size.  Catches
    // body-sized fragments in body-sized prose where surrounding text
    // sits at the fragment's baseline.
    if let Some(b) =
        pick_external_baseline(leaves, frag_baselines, line_tol(max_text_size), start, end)
    {
        return Some(b);
    }
    // Phase 2: fragment is sub/super-only — its glyphs sit a script-
    // baseline-shift above the line baseline, outside Phase 1's tol.
    // Re-scan with tol scaled to the LARGEST external text size on the
    // page.  Triggered only when Phase 1 failed, so adversarial mixed-
    // small-size docs (every fragment finds its own body text in
    // Phase 1) don't bleed neighbor lines.
    let max_external_size = leaves
        .iter()
        .filter_map(|l| match &l.item {
            FrameItem::Text(t) if !matches!(l.category_for(start, end), LeafCategory::InRange) => {
                Some(t.size)
            }
            _ => None,
        })
        .fold(Abs::zero(), Abs::max);
    if max_external_size <= max_text_size {
        return None;
    }
    pick_external_baseline(
        leaves,
        frag_baselines,
        line_tol(max_external_size),
        start,
        end,
    )
}

fn pick_external_baseline(
    leaves: &[FlatLeaf],
    frag_baselines: &[Abs],
    tol: Abs,
    start: usize,
    end: usize,
) -> Option<Abs> {
    let mut best: Option<Abs> = None;
    for l in leaves {
        if !matches!(l.item, FrameItem::Text(_)) {
            continue;
        }
        if matches!(l.category_for(start, end), LeafCategory::InRange) {
            continue;
        }
        let ey = l.pos.y;
        let in_tol = frag_baselines.iter().any(|fy| (ey - *fy).abs() <= tol);
        if in_tol && best.map_or(true, |b| ey > b) {
            best = Some(ey);
        }
    }
    best
}

fn find_external_line_size_from_leaves(
    leaves: &[FlatLeaf],
    line_anchors: &[Abs],
    max_text_size: Abs,
    start: usize,
    end: usize,
) -> Option<Abs> {
    if line_anchors.is_empty() {
        return None;
    }
    // Same two-pass shape as `find_external_baseline_from_leaves':
    // tight fragment-scaled tol catches body-sized fragments in body-
    // sized prose; if that finds nothing, retry with tol scaled to the
    // page's largest external text size.  Without phase 2, sub/super-
    // only fragments (e.g. `$#sym.zws^2$') would leave font_size_pt at
    // ~7.7pt (the script size), causing tip-scale='auto' to inflate
    // the displayed image by 11/7.7 ≈ 1.4×.
    if let Some(s) =
        pick_external_line_size(leaves, line_anchors, line_tol(max_text_size), start, end)
    {
        return Some(s);
    }
    let max_external_size = leaves
        .iter()
        .filter_map(|l| {
            if matches!(l.category_for(start, end), LeafCategory::InRange) {
                None
            } else {
                l.text_size
            }
        })
        .fold(Abs::zero(), Abs::max);
    if max_external_size <= max_text_size {
        return None;
    }
    pick_external_line_size(
        leaves,
        line_anchors,
        line_tol(max_external_size),
        start,
        end,
    )
}

fn pick_external_line_size(
    leaves: &[FlatLeaf],
    line_anchors: &[Abs],
    tol: Abs,
    start: usize,
    end: usize,
) -> Option<Abs> {
    let mut best: Option<Abs> = None;
    for l in leaves {
        let size = match l.text_size {
            Some(s) => s,
            None => continue,
        };
        if matches!(l.category_for(start, end), LeafCategory::InRange) {
            continue;
        }
        let ey = l.pos.y;
        let in_tol = line_anchors.iter().any(|a| (ey - *a).abs() <= tol);
        if in_tol && best.map_or(true, |b| size > b) {
            best = Some(size);
        }
    }
    best
}

/// Per-page extraction using a pre-flattened index.  No frame-tree
/// walking inside this function.
///
/// `canvas_width`, when set, expands the output Frame's width to the
/// given value with the math content centered inside it.  Used for
/// multi-line display math to match the wide-canvas treatment
/// `bottom_up::compile_source` gives via Typst's 16cm page layout —
/// without it, top-down's tight ink-only crop would render display
/// math flush-left while bottom-up renders it centered.
/// One run of contiguous in-range leaves on a single page, bundled
/// with its display bounds and max text size.  A page can produce
/// multiple clusters when the user's source range maps to multiple
/// rendered occurrences (e.g. a math glyph that appears both in a
/// heading and in `#outline()' entries that reference that heading).
struct Cluster {
    keep: Vec<(Point, FrameItem)>,
    bounds: ItemBounds,
    max_text_size: Abs,
}

impl Default for Cluster {
    fn default() -> Self {
        Cluster {
            keep: Vec::new(),
            bounds: ItemBounds::empty(),
            max_text_size: Abs::zero(),
        }
    }
}

/// Walk one page's leaves and return every cluster.  Same attachment
/// logic as the original single-cluster pass: InRange opens a run;
/// OutAttached closes it; Detached attaches when in-run, buffered
/// otherwise (with a spatial proximity check on flush so list markers
/// at the line's left margin don't merge into a math run on the same
/// line).
fn collect_clusters(leaves: &[FlatLeaf], start: usize, end: usize) -> Vec<Cluster> {
    let mut clusters: Vec<Cluster> = Vec::new();
    let mut current = Cluster::default();
    let mut in_run = false;
    let mut detached_buffer: Vec<usize> = Vec::new();

    let finalize = |cluster: &mut Cluster, clusters: &mut Vec<Cluster>| {
        if !cluster.keep.is_empty() {
            clusters.push(std::mem::take(cluster));
        }
    };

    for (i, leaf) in leaves.iter().enumerate() {
        match leaf.category_for(start, end) {
            LeafCategory::InRange => {
                let attach_threshold = leaf.text_size.unwrap_or(Abs::pt(11.0));
                let in_x = leaf.pos.x;
                let in_y = leaf.pos.y;
                for j in detached_buffer.drain(..) {
                    let buf = &leaves[j];
                    let dx = (buf.pos.x - in_x).abs();
                    let dy = (buf.pos.y - in_y).abs();
                    if dx <= attach_threshold && dy <= attach_threshold {
                        push_leaf(
                            buf,
                            &mut current.keep,
                            &mut current.bounds,
                            &mut current.max_text_size,
                        );
                    }
                }
                push_leaf(
                    leaf,
                    &mut current.keep,
                    &mut current.bounds,
                    &mut current.max_text_size,
                );
                in_run = true;
            }
            LeafCategory::Detached => {
                if in_run {
                    push_leaf(
                        leaf,
                        &mut current.keep,
                        &mut current.bounds,
                        &mut current.max_text_size,
                    );
                } else {
                    detached_buffer.push(i);
                }
            }
            LeafCategory::OutAttached => {
                if in_run {
                    finalize(&mut current, &mut clusters);
                    in_run = false;
                }
                detached_buffer.clear();
            }
        }
    }
    if in_run {
        finalize(&mut current, &mut clusters);
    }
    clusters
}

pub fn extract_from_index(
    pages: &[(Vec<FlatLeaf>, Vec<GroupRecord>)],
    start: usize,
    end: usize,
    canvas_width: Option<Abs>,
) -> Option<FragmentRender> {
    // Collect every cluster (run of InRange + close-by Detached) across
    // all pages, then pick the one whose max text size is largest.
    // This handles `#outline()` and similar duplicators where the same
    // source range maps to multiple frame leaves: the original heading
    // glyph is rendered at heading size (bigger), the outline-rendered
    // glyph at body size (smaller).  Without picking, we'd extract
    // BOTH into one SVG and the preview would contain stray outline-
    // entry artifacts.  Picking by largest text size also wins for the
    // common case (single cluster) since the comparison is degenerate.
    let mut all_clusters: Vec<(usize, Cluster)> = Vec::new();
    for (page_idx, (leaves, _group_records)) in pages.iter().enumerate() {
        for cluster in collect_clusters(leaves, start, end) {
            all_clusters.push((page_idx, cluster));
        }
    }
    let (page_idx, picked) = all_clusters.into_iter().max_by(|a, b| {
        a.1.max_text_size
            .partial_cmp(&b.1.max_text_size)
            .unwrap_or(std::cmp::Ordering::Equal)
    })?;
    if picked.keep.is_empty() || picked.bounds.is_empty() {
        return None;
    }
    // Bind to the page's leaves/group_records.  Subsequent code reads
    // these for baseline picking and font-size resolution; everything
    // continues to operate on a single page.
    let (leaves, group_records) = &pages[page_idx];
    let keep = picked.keep;
    let bounds = picked.bounds;
    let max_text_size = picked.max_text_size;

    let group_has_in_range = |g: &GroupRecord| {
        leaves[g.leaf_range.clone()]
            .iter()
            .any(|l| matches!(l.category_for(start, end), LeafCategory::InRange))
    };
    let outermost_group_baseline = group_records
        .iter()
        .rev()
        .find(|g| group_has_in_range(g))
        .map(|g| g.baseline_y);
    let group_baselines: Vec<Abs> = group_records
        .iter()
        .filter(|g| group_has_in_range(g))
        .map(|g| g.baseline_y)
        .collect();
    let frag_baselines: Vec<Abs> = keep
        .iter()
        .filter_map(|(p, item)| match item {
            FrameItem::Text(_) => Some(p.y),
            _ => None,
        })
        .collect();
    let frag_max = frag_baselines.iter().copied().max();
    let group_baseline = outermost_group_baseline;
    let external_y =
        find_external_baseline_from_leaves(leaves, &frag_baselines, max_text_size, start, end);
    let (baseline_y, external) = match (group_baseline, external_y, frag_max) {
        (Some(gb), _, _) => (gb, false),
        (None, Some(ex), _) => (ex, true),
        (None, None, Some(fm)) => (fm, false),
        (None, None, None) => (bounds.max_y, false),
    };

    let pad = Abs::pt(0.5);
    let crop_max_y = bounds.max_y.max(baseline_y);
    let crop_min_y = bounds.min_y.min(baseline_y);
    let min_x = bounds.min_x - pad;
    let min_y = crop_min_y - pad;
    let ink_width = bounds.max_x - bounds.min_x + pad * 2.0;
    let height = crop_max_y - crop_min_y + pad * 2.0;
    let depth = ((crop_max_y - baseline_y) + pad).max(Abs::zero());

    // Canvas widening for display math: Frame becomes `canvas_width'
    // wide with the inner content centered.  When unset, output is
    // tight (just ink + pad) — same as before.
    let (final_width, x_offset) = match canvas_width {
        Some(cw) if cw > ink_width => (cw, (cw - ink_width) / 2.0),
        _ => (ink_width, Abs::zero()),
    };

    let mut out = Frame::soft(Size::new(final_width, height));
    for (pos, item) in keep {
        out.push(Point::new(pos.x - min_x + x_offset, pos.y - min_y), item);
    }

    let line_anchors: Vec<Abs> = group_baselines
        .iter()
        .copied()
        .chain(frag_baselines.iter().copied())
        .collect();
    let external_size =
        find_external_line_size_from_leaves(leaves, &line_anchors, max_text_size, start, end);
    let candidate_sizes = [Some(max_text_size), external_size];
    let derived = candidate_sizes
        .iter()
        .filter_map(|x| *x)
        .filter(|s| *s > Abs::zero())
        .max();
    let font_size = derived.map(|a| a.to_pt()).unwrap_or(11.0);

    Some(FragmentRender {
        svg: svg_frame(&out),
        width_pt: final_width.to_pt(),
        height_pt: height.to_pt(),
        depth_pt: depth.to_pt(),
        page: page_idx,
        baseline_external: external,
        font_size_pt: font_size,
    })
}

/// Find a surrounding-text baseline on `frame` (a page) for an
/// inline-math fragment whose own text-item baselines are
/// `frag_baselines`.  Walks all text items NOT inside the fragment's
/// source range; returns the one whose baseline-y is closest to any
/// `frag_baselines` entry, within ~half an em of `max_text_size`.
/// Returns `None` when nothing surrounding is on the same line
/// (display math, or the math is the only content).
#[cfg(test)]
pub fn find_external_baseline(
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

#[cfg(test)]
pub fn walk_external(
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
#[cfg(test)]
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

#[cfg(test)]
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
            FrameItem::Group(g) => {
                walk_external_size(&g.frame, abs, main, src, exclude_start, exclude_end, out)
            }
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
