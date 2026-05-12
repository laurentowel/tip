use typst::compile;
use typst::layout::{Abs, Frame, PagedDocument, Point, Size};
use typst::syntax::SyntaxKind;
use typst_svg::svg_frame;

use crate::world::TipWorld;
use baseline::{collect_text_items, find_ink_extent, find_outermost_group_baseline};

mod baseline;

/// Detect display math. In Typst, display math has whitespace after opening `$`.
pub fn is_display_math(content: &str) -> bool {
    content.starts_with('$')
        && content.as_bytes().get(1).map_or(false, |b| b.is_ascii_whitespace())
}

/// Detect multi-line display math (has newlines between `$` delimiters).
/// Multi-line gets wide page (16cm), single-line display gets width: auto.
pub fn is_multiline_math(content: &str) -> bool {
    is_display_math(content) && content[1..content.len() - 1].contains('\n')
}

/// Result of compiling a single math fragment.
#[derive(Debug, Clone)]
pub struct FragmentOutput {
    /// The rendered SVG string.
    pub svg: String,
    /// Total height of the SVG in points.
    pub height_pt: f64,
    /// Depth below the baseline in points (for ascent calculation).
    pub depth_pt: f64,
    /// Ink width in points (actual content, no margins).
    pub width_pt: f64,
}

/// Compiles math fragments from a Typst document to SVG.
pub struct BottomUpCompiler;

impl BottomUpCompiler {
    /// Compile a single math fragment with explicit preamble (simple API).
    pub fn compile_fragment(
        world: &mut TipWorld,
        content: &str,
        color: &str,
        preamble: &str,
    ) -> Result<FragmentOutput, String> {
        let is_inline = !is_display_math(content);
        let source = build_fragment_source(content, color, preamble);
        compile_source(world, &source, is_inline)
    }

    /// Compile a math fragment with full scope awareness.
    ///
    /// Extracts scope-defining statements (#let, #import, #set, #show,
    /// block structure) from the document, discards non-scope content,
    /// and compiles just the target fragment with its full scope context.
    ///
    /// `page_setup` is an optional Typst page setup string from the client.
    /// If None, a default is used based on whether the fragment is inline or block.
    pub fn compile_fragment_scoped(
        world: &mut TipWorld,
        document_source: &str,
        frag_start: usize,
        frag_end: usize,
        color: &str,
        page_setup: Option<&str>,
        preamble: Option<&str>,
    ) -> Result<FragmentOutput, String> {
        if frag_end > document_source.len() || frag_start >= frag_end {
            return Err("invalid fragment range".into());
        }

        let content = &document_source[frag_start..frag_end];
        let is_math = content.starts_with('$');
        let is_multiline = is_math && is_multiline_math(content);
        let is_inline = is_math && !is_display_math(content);

        let source = build_scoped_source(document_source, frag_start, frag_end, color, is_multiline, page_setup, preamble)?;
        compile_source(world, &source, is_inline)
    }

    /// Return the generated source for a fragment without compiling it.
    /// Useful for debugging scope resolution.
    pub fn debug_scoped_source(
        document_source: &str,
        frag_start: usize,
        frag_end: usize,
    ) -> Result<String, String> {
        if frag_end > document_source.len() || frag_start >= frag_end {
            return Err("invalid fragment range".into());
        }
        let content = &document_source[frag_start..frag_end];
        let is_math = content.starts_with('$');
        let is_multiline = is_math && is_multiline_math(content);
        build_scoped_source(document_source, frag_start, frag_end, "#000000", is_multiline, None, None)
    }
}

/// Compile a prepared source string and return the fragment output.
/// `is_inline` controls whether baseline measurement + SVG cropping is applied.
fn compile_source(world: &mut TipWorld, source: &str, is_inline: bool) -> Result<FragmentOutput, String> {
    world.set_main_source(source);

    let warned = compile::<PagedDocument>(world);
    let document = warned
        .output
        .map_err(|errors: ecow::EcoVec<typst::diag::SourceDiagnostic>| {
            errors
                .into_iter()
                .map(|e| e.message.to_string())
                .collect::<Vec<_>>()
                .join("; ")
        })?;

    let pages = &document.pages;
    if pages.is_empty() {
        return Err("compilation produced no pages".into());
    }

    let page = &pages[0];
    let page_width = page.frame.width().to_pt();

    let ink = find_ink_extent(&page.frame, 0.0, 0.0);
    let pad = 0.5;

    // No visible content — return empty result so client skips it
    if ink.is_empty() {
        return Ok(FragmentOutput {
            svg: String::new(),
            height_pt: 0.0,
            depth_pt: 0.0,
            width_pt: 0.0,
        });
    }

    if is_inline {
        // INLINE MATH: crop the page Frame vertically to the ink+baseline
        // region, then render the cropped Frame to SVG.  Same approach
        // top_down uses (extract.rs:221).  Cleaner than rewriting an
        // already-rendered SVG's `viewBox' string and gives us one
        // mental model for cropping across both strategies.
        let baseline_y = find_baseline_depth(&page.frame, 0.0)
            .unwrap_or_else(|| {
                // Last resort: page is auto-sized to content + margins,
                // so the body baseline lives at `page_height -
                // bottom_margin'.  Hit when the only text item is a
                // sub/super-script glyph (e.g. `$#sym.zws^2$') and
                // there's no Group baseline either — the page
                // reserves a body-line height even if the body
                // glyph is invisible (ZWS).
                page.frame.height().to_pt() - 20.0
            });

        // Always include the baseline in the crop region.  Without this,
        // a fragment whose ink lives entirely above the baseline (e.g.
        // `$#sym.zws^2$' — invisible base, visible superscript) would
        // crop to just the superscript, leaving the baseline below the
        // cropped image and breaking ascent computation.  Same for
        // entirely-below-baseline ink.
        let crop_top = (ink.min_y.min(baseline_y) - pad).max(0.0);
        let crop_bottom = (ink.max_y.max(baseline_y) + pad).min(page.frame.height().to_pt());
        let cropped_height = crop_bottom - crop_top;
        let baseline_in_crop = baseline_y - crop_top;
        let depth_pt = (cropped_height - baseline_in_crop).max(0.0);

        let cropped = crop_frame_y(&page.frame, crop_top, cropped_height, page_width);
        let svg_string = svg_frame(&cropped);

        Ok(FragmentOutput {
            svg: svg_string,
            height_pt: cropped_height,
            depth_pt,
            width_pt: ink.width() + pad * 2.0,
        })
    } else {
        // BLOCK/DISPLAY MATH: crop Frame to ink bounds (avoids clipping from
        // Typst's height:auto not accounting for full glyph extents, typst#1028).
        // No baseline computation — display math uses :ascent center.
        let crop_top = (ink.min_y - pad).max(0.0);
        let crop_bottom = (ink.max_y + pad).min(page.frame.height().to_pt());
        let cropped_height = crop_bottom - crop_top;

        let cropped = crop_frame_y(&page.frame, crop_top, cropped_height, page_width);
        let svg_string = svg_frame(&cropped);

        Ok(FragmentOutput {
            svg: svg_string,
            height_pt: cropped_height,
            depth_pt: 0.0,
            width_pt: ink.width() + pad * 2.0,
        })
    }
}

/// Build a flat copy of `src' shifted up by `crop_top' and clipped to
/// `cropped_height'.  Width is preserved (bottom-up only crops
/// vertically; horizontal extent comes from `width: auto' page
/// settings already tight on the math).  The output Frame, when
/// rendered via `typst_svg::svg', produces an SVG whose viewBox
/// already matches the cropped region — no string rewriting needed.
///
/// Same idiom top_down uses (extract.rs:221) — we share the mental
/// model for cropping across both strategies.
fn crop_frame_y(src: &Frame, crop_top: f64, cropped_height: f64, width: f64) -> Frame {
    let mut out = Frame::soft(Size::new(Abs::pt(width), Abs::pt(cropped_height)));
    let dy = Abs::pt(crop_top);
    for (pos, item) in src.items() {
        out.push(Point::new(pos.x, pos.y - dy), item.clone());
    }
    out
}

/// Find the math baseline y-position (from page top) by examining the frame tree.
///
/// Strategy (in priority order):
/// 1. Check if any Group frame has an explicit baseline (set by Typst's math layout
///    for sums, integrals, matrices, brackets, cases, etc.) — exact, no heuristic.
/// 2. Find the text item with the LARGEST font size (primary math content, not
///    sub/superscripts). Its y-position is the math baseline.
/// 3. For bare fractions (all text at reduced size), compute from font metrics:
///    margin_top + font_ascent (derived from the font's ascender value).
/// Find the math baseline y (page-frame coords, y-down) for the
/// rendered fragment.
///
/// Three paths, each exact:
///
/// 1. The page frame itself has a baseline (rare for math, but handled
///    if Typst ever sets it).
/// 2. A descendant Group has `has_baseline()=true' — Typst's math
///    layout produces these for sized delimiters, fractions, big
///    operators, matrices, AND for any inline math augmented with the
///    `#hide[#sym.zws]' phantom we append in `build_scoped_source'.
///    `find_outermost_group_baseline' returns the OUTERMOST one,
///    which carries the body baseline (vs inner sub/sup Groups that
///    carry math-axis baselines).
/// 3. Single body-glyph fallback.  Typst flattens trivial math
///    (`\$phi\$', `\$x\$') to a single text item that bypasses Group
///    wrapping even with the phantom.  The single text item's
///    y-position IS the baseline by definition for a single glyph
///    AT BODY SIZE.
/// 4. Page-derived fallback.  When the only text items are
///    REDUCED-size (sub/super-only fragments like `\$#sym.zws^2\$' —
///    a superscript with an invisible base), the glyph y is the
///    superscript's own baseline, NOT the body baseline.  Trusting it
///    would mis-anchor the image.  Fall back to
///    `page_height - 20pt' (the body baseline of the auto-sized
///    page given our 20pt bottom margin).
///
/// The pre-phantom heuristic that picked baselines from arrays of
/// y-positions (and its reduced-size / math-axis fallbacks) lived
/// here through commit `legacy-baseline-heuristics'.  It mispicked
/// for stacked accents (`hat(tilde(phi))') because the closest-to-
/// page-midpoint y was an accent, not the base.  See
/// `tests/phantom_force_baseline.rs' for the empirical demonstration.
fn find_baseline_depth(
    frame: &typst::layout::Frame,
    y_offset: f64,
) -> Option<f64> {
    if frame.has_baseline() {
        return Some(y_offset + frame.baseline().to_pt());
    }
    if let Some(bl) = find_outermost_group_baseline(frame, y_offset) {
        return Some(bl);
    }
    // Single body-glyph fallback ($phi$, $a$, etc.): one text item at
    // body size → its y IS the baseline.  Reject reduced-size
    // singletons (e.g. a lone superscript whose y is the SUPERSCRIPT
    // baseline, not the body baseline).  Multi-text fragments without
    // a Group baseline shouldn't occur in production (the phantom
    // guarantees a Group for inline math), but if one does we'd
    // rather return None and
    // let the caller fall back than guess.
    let mut items = Vec::new();
    collect_text_items(frame, y_offset, &mut items);
    // 11pt is the body size we set via `#show math.equation: set
    // text(size: 11pt)' in build_scoped_source; reduced-size items
    // are sub/super script glyphs at ~7-8pt.
    const BODY_SIZE_THRESHOLD_PT: f64 = 9.0;
    if items.len() == 1 && items[0].0 >= BODY_SIZE_THRESHOLD_PT {
        return Some(items[0].1);
    }
    None
}

/// Build a scope-aware source by extracting only scope-defining statements
/// from the document (discarding all other content), then appending the
/// target fragment.
fn build_scoped_source(
    document_source: &str,
    frag_start: usize,
    frag_end: usize,
    color: &str,
    is_multiline: bool,
    page_setup_override: Option<&str>,
    preamble_override: Option<&str>,
) -> Result<String, String> {
    let root = typst::syntax::parse(document_source);
    let (skeleton, closing) = extract_scope_skeleton(&root, document_source, frag_start);
    let content = &document_source[frag_start..frag_end];
    let is_inline = !is_display_math(content);

    let page_setup = match page_setup_override {
        Some(custom) => format!("{custom}\n"),
        None => {
            // HTML-targeting documents forbid setting text size
            let targets_html = skeleton.contains("html.elem")
                || skeleton.contains("html.frame")
                || skeleton.contains("html.figure");
            let size_rule = if targets_html {
                ""
            } else {
                "#show math.equation: set text(size: 11pt)\n"
            };
            let page = if is_multiline {
                "#set page(width: 16cm, height: auto, fill: none, margin: (top: 20pt, bottom: 20pt, rest: 0pt), header: none, footer: none)\n"
            } else if is_inline {
                "#set page(height: auto, width: auto, margin: (top: 20pt, bottom: 20pt, rest: 0pt), fill: none, header: none, footer: none)\n"
            } else {
                "#set page(height: auto, width: auto, margin: (top: 20pt, bottom: 20pt, rest: 0pt), fill: none, header: none, footer: none)\n"
            };
            format!("{size_rule}{page}")
        }
    };

    // Inline math: append a `#hide[#sym.zws]' phantom inside the
    // closing `$' to force Typst to wrap the math in a Group with the
    // body baseline.  Without it, simple inline math (a + b, sub/sup,
    // accents, accent stacks) gets inlined into the page frame as
    // bare text items and we have to guess the baseline from y
    // positions — a heuristic that mispicks among stacked accents
    // (`hat(tilde(phi))', `tilde(hat(phi))') because the closest-to-
    // page-midpoint y is an accent, not the base glyph.  See
    // `tests/phantom_force_baseline.rs' for the empirical
    // justification (and the `legacy-baseline-heuristics' git tag for
    // the heuristic this replaced).
    //
    // ZWS (zero-width space) carries zero ink AND zero width, so it
    // doesn't inflate the SVG or interfere with our ink-extent crop.
    // `#hide[..]' makes the contents layout-only (invisible).
    let fragment_owned;
    let fragment: &str = if is_inline
        && content.starts_with('$')
        && content.ends_with('$')
        && content.len() >= 2
    {
        fragment_owned = format!("{} #hide[#sym.zws]$", &content[..content.len() - 1]);
        &fragment_owned
    } else {
        &document_source[frag_start..frag_end]
    };

    // The color override goes LAST among the setup chunks so it wins
    // over any client-supplied `set text(rgb(...))' in preamble_override
    // and document-level rules in skeleton.  Server passes the
    // sentinel STANDIN_HEX here; the post-render pass rewrites it to
    // SVG `currentColor' (see typst_backend.rs).
    let color_override = format!("#show math.equation: set text(rgb(\"{color}\"))\n");

    // page_setup and client_preamble go AFTER skeleton so they override
    // document-level rules (page layout, text size, colors).
    // Join non-empty sections with single newlines to avoid blank lines
    // (Typst renders \n\n as paragraph breaks, causing spurious empty space).
    let sections: Vec<&str> = [
        skeleton.trim(),
        preamble_override.unwrap_or("").trim(),
        page_setup.trim(),
        color_override.trim(),
        fragment,
        closing.as_str(),
    ].into_iter().filter(|s| !s.is_empty()).collect();
    let source = sections.join("\n") + "\n";
    Ok(source)
}

/// Extract a "scope skeleton" from the document — only the statements that
/// define scope (let, import, set, show) and the block structure around them,
/// up to the target fragment position. All other content is discarded.
///
/// Returns (skeleton, closers) where closers are the delimiters needed to
/// close blocks that the skeleton opened but the fragment sits inside.
fn extract_scope_skeleton(
    root: &typst::syntax::SyntaxNode,
    source: &str,
    frag_start: usize,
) -> (String, String) {
    let mut result = String::new();
    let mut closers: Vec<&str> = Vec::new();
    collect_scope_nodes(root, source, frag_start, 0, &mut result, &mut closers);
    (result, closers.into_iter().rev().collect::<Vec<_>>().join(""))
}

/// Recursively collect scope-defining nodes and structural ancestors
/// of the fragment from the syntax tree.
///
/// Three cases for each node:
/// 1. Node is entirely before frag_start → include if scope-defining, skip otherwise
/// 2. Node contains frag_start → recurse into children (preserving structure)
/// 3. Node starts at or after frag_start → skip
fn collect_scope_nodes(
    node: &typst::syntax::SyntaxNode,
    source: &str,
    frag_start: usize,
    offset: usize,
    result: &mut String,
    closers: &mut Vec<&str>,
) {
    let node_end = offset + node.len();

    // Case 3: skip nodes at or after fragment
    if offset >= frag_start {
        return;
    }

    // Case 1: node is entirely before fragment
    if node_end <= frag_start {
        match node.kind() {
            // Scope-defining: include full source WITH the preceding #
            SyntaxKind::LetBinding
            | SyntaxKind::SetRule
            | SyntaxKind::ShowRule
            | SyntaxKind::ModuleImport
            | SyntaxKind::ModuleInclude => {
                let raw = &source[offset..node_end];
                // Filter out two doc-level rules that would either
                // poison or wrap our synthetic single-fragment compile:
                //
                //   `#set page(...)' — we emit our own page geometry
                //   for baseline accounting; doc's would conflict.
                //
                //   `#show: rest => …' (body-transform with no
                //   selector) — wraps everything that follows in a
                //   container, including our page_setup → "page
                //   configuration is not allowed inside of containers".
                //   Doc-level `#show:` typically does multi-column
                //   layout / page-frame wrapping, not anything we
                //   want for a fragment preview.
                let is_set_page = matches!(node.kind(), SyntaxKind::SetRule)
                    && raw.trim_start().starts_with("set page");
                let is_body_show = matches!(node.kind(), SyntaxKind::ShowRule)
                    && raw.trim_start().starts_with("show:");
                if is_set_page || is_body_show {
                    return;
                }
                // Include the # prefix if present (it's the preceding Hash sibling)
                let start = if offset > 0 && source.as_bytes().get(offset - 1) == Some(&b'#') {
                    offset - 1
                } else {
                    offset
                };
                result.push_str(&source[start..node_end]);
                result.push('\n');
            }
            _ => {}
        }
        return;
    }

    // Case 2: node CONTAINS frag_start — must recurse to preserve structure
    match node.kind() {
        // Transparent containers: just recurse
        SyntaxKind::Markup
        | SyntaxKind::Code => {
            let mut child_offset = offset;
            for child in node.children() {
                collect_scope_nodes(child, source, frag_start, child_offset, result, closers);
                child_offset += child.len();
            }
        }

        // Code blocks: emit {, track closer
        SyntaxKind::CodeBlock => {
            result.push_str("{\n");
            closers.push("}");
            let mut child_offset = offset;
            for child in node.children() {
                collect_scope_nodes(child, source, frag_start, child_offset, result, closers);
                child_offset += child.len();
            }
        }

        // Content blocks: only emit [ if they contain scope-defining children
        SyntaxKind::ContentBlock => {
            let has_scope_children = node.children().any(|child| {
                matches!(child.kind(),
                    SyntaxKind::LetBinding | SyntaxKind::SetRule |
                    SyntaxKind::ShowRule | SyntaxKind::ModuleImport |
                    SyntaxKind::ModuleInclude)
            });
            if has_scope_children {
                result.push_str("[\n");
                closers.push("]");
            }
            let mut child_offset = offset;
            for child in node.children() {
                collect_scope_nodes(child, source, frag_start, child_offset, result, closers);
                child_offset += child.len();
            }
        }

        // Any other container (FuncCall, Args, etc.): strip it, recurse transparently
        _ => {
            let mut child_offset = offset;
            for child in node.children() {
                let child_end = child_offset + child.len();
                if child_offset < frag_start && child_end > frag_start {
                    collect_scope_nodes(child, source, frag_start, child_offset, result, closers);
                }
                child_offset = child_end;
            }
        }
    }
}

/// Append closing delimiters for any blocks that contain the fragment.

/// Build a Typst source document for a standalone fragment (no scope context).
///
/// Thin wrapper over `build_scoped_source`: treat the fragment content
/// as the entire document, with no scope-defining ancestors to extract.
/// The shared builder handles inline/display/multiline classification,
/// page setup, color override, and phantom injection identically to the
/// production path — no need to duplicate that logic here.
fn build_fragment_source(content: &str, color: &str, preamble: &str) -> String {
    let preamble = if preamble.is_empty() { None } else { Some(preamble) };
    build_scoped_source(
        content,
        0,
        content.len(),
        color,
        is_multiline_math(content),
        None,
        preamble,
    )
    .expect("build_scoped_source: 0..len() is always a valid range")
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Standalone compilation tests ---

    #[test]
    fn build_inline_source() {
        let src = build_fragment_source("$a + b$", "#000000", "");
        assert!(src.contains("width: auto"));
        assert!(
            src.contains("$a + b #hide[#sym.zws]$"),
            "expected phantom-augmented inline math (no padding around delimiters), got:\n{src}"
        );
    }

    #[test]
    fn build_single_line_display_source() {
        let src = build_fragment_source("$ a + b $", "#000000", "");
        assert!(src.contains("width: auto"), "single-line display should use auto width");
        assert!(!src.contains("16cm"), "single-line display should not use 16cm");
    }

    #[test]
    fn build_multiline_display_source() {
        let src = build_fragment_source("$\n  a + b\n$", "#000000", "");
        assert!(src.contains("width: 16cm"), "multiline display should use 16cm");
    }

    #[test]
    fn compile_simple_inline() {
        let mut world = TipWorld::new();
        let output = BottomUpCompiler::compile_fragment(
            &mut world, "$a + b$", "#000000", "",
        ).unwrap();
        assert!(output.svg.contains("<svg"));
        assert!(output.height_pt > 0.0);
    }

    #[test]
    fn compile_block_math() {
        let mut world = TipWorld::new();
        let output = BottomUpCompiler::compile_fragment(
            &mut world, "$ sum_(i=0)^n i^2 $", "#000000", "",
        ).unwrap();
        assert!(output.svg.contains("<svg"));
    }

    #[test]
    fn compile_with_preamble() {
        let mut world = TipWorld::new();
        let output = BottomUpCompiler::compile_fragment(
            &mut world, "$cl$", "#000000", "#let cl = math.cal(\"L\")\n",
        ).unwrap();
        assert!(output.svg.contains("<svg"));
    }

    #[test]
    fn compile_invalid_returns_error() {
        let mut world = TipWorld::new();
        let result = BottomUpCompiler::compile_fragment(
            &mut world, "$#nonexistent_function()$", "#000000", "",
        );
        assert!(result.is_err());
    }

    // --- Scope skeleton extraction tests ---

    #[test]
    fn skeleton_extracts_let() {
        let doc = "#let x = 1\nSome text $x$";
        let root = typst::syntax::parse(doc);
        let frag_start = doc.find("$x$").unwrap();
        let (skel, _closers) = extract_scope_skeleton(&root, doc, frag_start);
        assert!(skel.contains("let x = 1"), "skeleton: {skel}");
    }

    #[test]
    fn skeleton_extracts_set_rule() {
        let doc = "#set text(fill: blue)\nText $a$";
        let root = typst::syntax::parse(doc);
        let frag_start = doc.find("$a$").unwrap();
        let (skel, _closers) = extract_scope_skeleton(&root, doc, frag_start);
        assert!(skel.contains("set text(fill: blue)"), "skeleton: {skel}");
    }

    #[test]
    fn skeleton_extracts_show_rule() {
        let doc = "#show math.equation: set text(fill: red)\n$a$";
        let root = typst::syntax::parse(doc);
        let frag_start = doc.find("$a$").unwrap();
        let (skel, _closers) = extract_scope_skeleton(&root, doc, frag_start);
        assert!(skel.contains("show math.equation"), "skeleton: {skel}");
    }

    #[test]
    fn skeleton_skips_text_content() {
        let doc = "#let x = 1\nHello world some text here\n$x$";
        let root = typst::syntax::parse(doc);
        let frag_start = doc.find("$x$").unwrap();
        let (skel, _closers) = extract_scope_skeleton(&root, doc, frag_start);
        assert!(skel.contains("let x = 1"));
        assert!(!skel.contains("Hello world"), "should not contain text: {skel}");
    }

    #[test]
    fn skeleton_preserves_block_structure() {
        let doc = "#{\n  let x = 1\n  $x$\n}";
        let root = typst::syntax::parse(doc);
        let frag_start = doc.find("$x$").unwrap();
        let (skel, _closers) = extract_scope_skeleton(&root, doc, frag_start);
        assert!(skel.contains("let x = 1"), "skeleton: {skel}");
        assert!(skel.contains("{"), "should have block opener: {skel}");
    }

    // --- Scoped compilation tests ---

    #[test]
    fn scoped_compile_top_level_let() {
        let mut world = TipWorld::new();
        let doc = "#let foo = \"bar\"\nSome text $foo$";
        let frag_start = doc.find("$foo$").unwrap();
        let frag_end = frag_start + "$foo$".len();
        let output = BottomUpCompiler::compile_fragment_scoped(
            &mut world, doc, frag_start, frag_end, "#000000", None, None,
        ).unwrap();
        assert!(output.svg.contains("<svg"));
    }

    #[test]
    fn scoped_compile_block_scoped_let() {
        let mut world = TipWorld::new();
        let doc = "#{\n  let x = 42\n  $x$\n}";
        let frag_start = doc.find("$x$").unwrap();
        let frag_end = frag_start + "$x$".len();
        let output = BottomUpCompiler::compile_fragment_scoped(
            &mut world, doc, frag_start, frag_end, "#000000", None, None,
        ).unwrap();
        assert!(output.svg.contains("<svg"));
    }

    #[test]
    fn scoped_compile_with_show_rule() {
        let mut world = TipWorld::new();
        let doc = "#show math.equation: set text(fill: red)\n$a + b$";
        let frag_start = doc.find("$a + b$").unwrap();
        let frag_end = frag_start + "$a + b$".len();
        let output = BottomUpCompiler::compile_fragment_scoped(
            &mut world, doc, frag_start, frag_end, "#000000", None, None,
        ).unwrap();
        assert!(output.svg.contains("<svg"));
    }

    #[test]
    fn scoped_compile_no_extra_content() {
        let _world = TipWorld::new();
        let doc = "#let x = 1\nLots of text here that should NOT appear\n$x$";
        let frag_start = doc.find("$x$").unwrap();
        let frag_end = frag_start + "$x$".len();
        let source = build_scoped_source(doc, frag_start, frag_end, "#000000", false, None, None).unwrap();
        assert!(!source.contains("Lots of text"), "generated source should not contain text content: {source}");
    }

    #[test]
    fn scoped_compile_invalid_range() {
        let mut world = TipWorld::new();
        assert!(BottomUpCompiler::compile_fragment_scoped(
            &mut world, "$a$", 0, 999, "#000000", None, None,
        ).is_err());
    }

    // --- Math inside function calls ---

    #[test]
    fn scoped_compile_math_in_list() {
        let mut world = TipWorld::new();
        let doc = "#list[$a + b$][$x^2$]";
        let needle = "$a + b$";
        let start = doc.find(needle).unwrap();
        let end = start + needle.len();
        let output = BottomUpCompiler::compile_fragment_scoped(
            &mut world, doc, start, end, "#000000", None, None,
        ).expect("math in #list should compile");
        assert!(output.svg.contains("<svg"));
    }

    #[test]
    fn scoped_compile_math_in_nested_funcall() {
        let mut world = TipWorld::new();
        let doc = "#box[#text(red)[$alpha + beta$]]";
        let needle = "$alpha + beta$";
        let start = doc.find(needle).unwrap();
        let end = start + needle.len();
        let output = BottomUpCompiler::compile_fragment_scoped(
            &mut world, doc, start, end, "#000000", None, None,
        ).expect("math in nested funcall should compile");
        assert!(output.svg.contains("<svg"));
    }

    #[test]
    fn scoped_compile_math_in_multiarg_list() {
        let mut world = TipWorld::new();
        let doc = "#list[\n  $lambda(mu, pi) = norm(pi(mu))_(\"op\")$ and\n][\n  $cal(L)(mu,pi) = -log lambda(mu,pi)$\n]";
        let needle = "$cal(L)(mu,pi) = -log lambda(mu,pi)$";
        let start = doc.find(needle).unwrap();
        let end = start + needle.len();
        let output = BottomUpCompiler::compile_fragment_scoped(
            &mut world, doc, start, end, "#000000", None, None,
        ).expect("math in multi-arg list should compile");
        assert!(output.svg.contains("<svg"));
    }

    #[test]
    fn scoped_compile_math_in_enum() {
        let mut world = TipWorld::new();
        let doc = "#enum[first $a$][second $b$]";
        let needle = "$b$";
        let start = doc.find(needle).unwrap();
        let end = start + needle.len();
        let output = BottomUpCompiler::compile_fragment_scoped(
            &mut world, doc, start, end, "#000000", None, None,
        ).expect("math in #enum should compile");
        assert!(output.svg.contains("<svg"));
    }
}
