use typst::compile;
use typst::layout::PagedDocument;
use typst::syntax::SyntaxKind;
use typst_svg::svg;

use crate::world::TipWorld;
use baseline::{
    collect_text_items, find_font_ascent, find_ink_extent, find_math_axis_em,
    find_outermost_group_baseline, pick_baseline_y,
};

mod baseline;

/// Detect display math. In Typst, display math has whitespace after opening `$`.
fn is_display_math(content: &str) -> bool {
    content.starts_with('$')
        && content.as_bytes().get(1).map_or(false, |b| b.is_ascii_whitespace())
}

/// Detect multi-line display math (has newlines between `$` delimiters).
/// Multi-line gets wide page (16cm), single-line display gets width: auto.
fn is_multiline_math(content: &str) -> bool {
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
    let svg_string = svg(page);
    let page_height = page.frame.height().to_pt();
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
        // INLINE MATH: crop SVG to ink bounds, compute baseline for ascent.
        // find_baseline_depth tries: Group baseline → text heuristic → font metrics.
        // Final fallback (should rarely hit): 20pt margin + estimated ascent.
        let baseline_y = find_baseline_depth(&page.frame, 0.0)
            .unwrap_or_else(|| {
                // Last resort: derive from page height and margins.
                // For height:auto with 20pt top margin and 11pt text,
                // baseline ≈ 20 + 11 * 0.8 = 28.8
                20.0 + 11.0 * 0.8
            });

        let crop_top = (ink.min_y - pad).max(0.0);
        let crop_bottom = (ink.max_y + pad).min(page_height);
        let cropped_height = crop_bottom - crop_top;
        let baseline_in_crop = baseline_y - crop_top;
        let depth_pt = (cropped_height - baseline_in_crop).max(0.0);

        let cropped_svg = crop_svg_viewbox(
            &svg_string, page_width, page_height, crop_top, cropped_height,
        );

        Ok(FragmentOutput {
            svg: cropped_svg,
            height_pt: cropped_height,
            depth_pt,
            width_pt: ink.width() + pad * 2.0,
        })
    } else {
        // BLOCK/DISPLAY MATH: crop SVG to ink bounds (avoids clipping from
        // Typst's height:auto not accounting for full glyph extents, typst#1028).
        // No baseline computation — display math uses :ascent center.
        let crop_top = (ink.min_y - pad).max(0.0);
        let crop_bottom = (ink.max_y + pad).min(page_height);
        let cropped_height = crop_bottom - crop_top;

        let cropped_svg = crop_svg_viewbox(
            &svg_string, page_width, page_height, crop_top, cropped_height,
        );

        Ok(FragmentOutput {
            svg: cropped_svg,
            height_pt: cropped_height,
            depth_pt: 0.0,
            width_pt: ink.width() + pad * 2.0,
        })
    }
}

/// Crop the SVG by rewriting its viewBox and height attributes.
fn crop_svg_viewbox(
    svg: &str,
    width: f64,
    _page_height: f64,
    crop_top: f64,
    new_height: f64,
) -> String {
    let mut result = svg.to_string();

    // Replace viewBox="0 0 W H" with "0 crop_top W new_height"
    if let Some(vb_start) = result.find("viewBox=\"") {
        let vb_val_start = vb_start + 9;
        if let Some(vb_end) = result[vb_val_start..].find('"') {
            let new_vb = format!("0 {} {} {}", crop_top, width, new_height);
            result.replace_range(vb_val_start..vb_val_start + vb_end, &new_vb);
        }
    }

    // Replace height="Xpt" with new height
    if let Some(h_start) = result.find("height=\"") {
        let h_val_start = h_start + 8;
        if let Some(h_end) = result[h_val_start..].find('"') {
            let new_h = format!("{}pt", new_height);
            result.replace_range(h_val_start..h_val_start + h_end, &new_h);
        }
    }

    result
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
fn find_baseline_depth(
    frame: &typst::layout::Frame,
    y_offset: f64,
) -> Option<f64> {
    if frame.has_baseline() {
        return Some(y_offset + frame.baseline().to_pt());
    }

    // Strategy 1: walk Groups for explicit baselines.
    if let Some(bl) = find_outermost_group_baseline(frame, y_offset) {
        return Some(bl);
    }

    // Strategy 2: largest text item heuristic.
    let page_mid = y_offset + frame.height().to_pt() / 2.0;
    let mut items = Vec::new();
    collect_text_items(frame, y_offset, &mut items);

    // Find the largest font size (at or above threshold).
    let max_size = items.iter().map(|&(s, _)| s).fold(0.0_f64, f64::max);

    if max_size > 0.0 {
        // Collect y-values of items at that largest size.
        let ys: Vec<f64> = items
            .iter()
            .filter(|&&(s, _)| (s - max_size).abs() < 0.1)
            .map(|&(_, y)| y)
            .collect();

        if max_size >= 9.0 {
            // Body-sized text in fragment: pick directly.
            return Some(pick_baseline_y(&ys, page_mid));
        }

        // Strategy 3: all text at reduced size (sub/super/fraction
        // glyphs).  The most common case is a bare fraction `$a/b$`
        // where Typst inlines numerator + denominator at script size
        // straddling the math axis.  The visual baseline for the
        // surrounding paragraph is at `math_axis_y + axis_em *
        // body_size_pt` — not at either row's individual baseline.
        if ys.len() >= 2 {
            // 2+ rows at the same reduced size → fraction-shaped.
            // Midpoint approximates the math axis (where the bar
            // sits); body baseline is one axis-height below.
            if let Some(axis_em) = find_math_axis_em(frame) {
                let mid_y = ys.iter().copied().sum::<f64>() / ys.len() as f64;
                // 11pt is the body size we set via the `#show
                // math.equation: set text(size: 11pt)' rule in
                // build_scoped_source.
                return Some(mid_y + axis_em * 11.0);
            }
        }

        // Single reduced item: fall back to the older ascent-ratio
        // formula.  This case is rare (a standalone subscript or
        // accent at script size with no companion glyph) and the
        // formula is approximate, but it's better than nothing.
        let y = pick_baseline_y(&ys, page_mid);
        if let Some(ascent) = find_font_ascent(frame) {
            let full_baseline = y - (ascent * max_size) + (ascent * 11.0);
            return Some(full_baseline);
        }
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

    let fragment = &document_source[frag_start..frag_end];

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
fn build_fragment_source(content: &str, color: &str, preamble: &str) -> String {
    let is_multiline = is_multiline_math(content);
    let is_inline = !is_display_math(content);

    let color_setup = format!("#show math.equation: set text(rgb(\"{color}\"))\n");

    if is_multiline {
        // Multi-line display: wide page
        format!(
            "{color_setup}\
             {preamble}\n\
             #set page(width: 16cm, height: auto, fill: none, margin: (x: 0cm, y: 0.2cm))\n\
             {content}\n"
        )
    } else if is_inline {
        // Inline: generous margins for baseline crop
        let inner = content.trim_matches('$').trim();
        format!(
            "{color_setup}\
             #set page(height: auto, width: auto, margin: (top: 20pt, bottom: 20pt, rest: 0pt), fill: none)\n\
             {preamble}\n\
             $ {inner} $\n"
        )
    } else {
        // Single-line display: auto width, normal margins
        format!(
            "{color_setup}\
             {preamble}\n\
             #set page(height: auto, width: auto, margin: 0.2cm, fill: none)\n\
             {content}\n"
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Standalone compilation tests ---

    #[test]
    fn build_inline_source() {
        let src = build_fragment_source("$a + b$", "#000000", "");
        assert!(src.contains("width: auto"));
        assert!(src.contains("$ a + b $"));
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
