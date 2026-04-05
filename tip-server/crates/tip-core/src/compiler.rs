use typst::compile;
use typst::layout::PagedDocument;
use typst::syntax::{LinkedNode, SyntaxKind, Side};
use typst_svg::svg;

use crate::world::TipWorld;

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

/// Default rendering preamble.
///
/// Does NOT use bounded() — bounded distorts the frame coordinates
/// differently per expression, breaking baseline consistency.
/// Instead, relies on generous bottom margin to fit subscripts,
/// and the natural page layout which keeps the baseline at a
/// constant position from the page top.
const DEFAULT_RENDERING_PREAMBLE: &str = "";

/// Result of compiling a single math fragment.
#[derive(Debug, Clone)]
pub struct FragmentOutput {
    /// The rendered SVG string.
    pub svg: String,
    /// Total height of the SVG in points.
    pub height_pt: f64,
    /// Depth below the baseline in points (for ascent calculation).
    pub depth_pt: f64,
}

/// Compiles math fragments from a Typst document to SVG.
pub struct FragmentCompiler;

impl FragmentCompiler {
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
        let is_multiline = is_multiline_math(content);
        let is_inline = !is_display_math(content);

        let source = build_scoped_source(document_source, frag_start, frag_end, color, is_multiline, page_setup, preamble)?;
        compile_source(world, &source, is_inline)
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

    if is_inline {
        // INLINE MATH: crop SVG to ink bounds, compute baseline for ascent.
        let baseline_y = find_baseline_depth(&page.frame, 0.0)
            .unwrap_or(27.5); // 20pt margin + ~7.5pt font ascent

        let (ink_top, ink_bottom) = find_ink_extent(&page.frame, 0.0);
        let pad = 0.5;
        let crop_top = (ink_top - pad).max(0.0);
        let crop_bottom = (ink_bottom + pad).min(page_height);
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
        })
    } else {
        // BLOCK/DISPLAY MATH: use as-is, no cropping needed.
        // Typst handles display layout correctly with standard margins.
        Ok(FragmentOutput {
            svg: svg_string,
            height_pt: page_height,
            depth_pt: 0.0, // block math doesn't need baseline alignment
        })
    }
}

/// Find the vertical extent of all rendered content (ink bounds).
/// Returns (min_y, max_y) in page coordinates.
fn find_ink_extent(frame: &typst::layout::Frame, y_offset: f64) -> (f64, f64) {
    use typst::layout::FrameItem;

    let mut min_y = f64::MAX;
    let mut max_y = f64::MIN;

    for (pos, item) in frame.items() {
        let item_y = y_offset + pos.y.to_pt();
        match item {
            FrameItem::Text(text) => {
                // Text is positioned at baseline. Ascend above, descend below.
                let font_size = text.size.to_pt();
                // Approximate: ascent ~80% of font size, descent ~20%
                let ascent = font_size * 0.8;
                let descent = font_size * 0.25;
                min_y = min_y.min(item_y - ascent);
                max_y = max_y.max(item_y + descent);
            }
            FrameItem::Group(group) => {
                let (child_min, child_max) =
                    find_ink_extent(&group.frame, item_y);
                min_y = min_y.min(child_min);
                max_y = max_y.max(child_max);
            }
            FrameItem::Shape(_, _) => {
                // Shapes (fraction bars, etc.) — use position + small extent
                min_y = min_y.min(item_y - 0.5);
                max_y = max_y.max(item_y + 0.5);
            }
            _ => {}
        }
    }

    if min_y > max_y {
        (0.0, frame.height().to_pt())
    } else {
        (min_y, max_y)
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
/// Strategy: find the text item with the LARGEST font size. This is the primary
/// math content (not sub/superscripts). Its y-position is the math baseline.
/// This gives consistent baselines across expressions with and without
/// subscripts, since the primary text's position is the true baseline.
fn find_baseline_depth(
    frame: &typst::layout::Frame,
    y_offset: f64,
) -> Option<f64> {
    if frame.has_baseline() {
        return Some(y_offset + frame.baseline().to_pt());
    }

    let page_mid = y_offset + frame.height().to_pt() / 2.0;
    let mut best: Option<(f64, f64, f64)> = None;

    collect_text_baselines(frame, y_offset, page_mid, &mut best);

    // Only return if the found text is at primary size (>=9pt).
    // For fractions where all text is reduced size (~7.7pt), return None
    // so the caller uses the constant fallback baseline.
    best.and_then(|(size, _, y)| if size >= 9.0 { Some(y) } else { None })
}

/// Recursively collect text items and track the one most likely to be
/// on the math baseline. Strategy: prefer the largest font size; on ties,
/// prefer the y-position closest to the page's vertical midpoint
/// (which is near the math baseline for centered fractions etc.).
fn collect_text_baselines(
    frame: &typst::layout::Frame,
    y_offset: f64,
    page_mid: f64,
    best: &mut Option<(f64, f64, f64)>, // (font_size_pt, dist_to_mid, y_from_page_top)
) {
    use typst::layout::FrameItem;

    for (pos, item) in frame.items() {
        match item {
            FrameItem::Text(text) => {
                let size = text.size.to_pt();
                let y = y_offset + pos.y.to_pt();
                let dist = (y - page_mid).abs();
                let is_better = match best {
                    Some((best_size, best_dist, _)) => {
                        if size > *best_size {
                            true
                        } else if (size - *best_size).abs() < 0.1 {
                            // Same font size: prefer closer to midpoint
                            dist < *best_dist
                        } else {
                            false
                        }
                    }
                    None => true,
                };
                if is_better {
                    *best = Some((size, dist, y));
                }
            }
            FrameItem::Group(group) => {
                let child_y = y_offset + pos.y.to_pt();
                collect_text_baselines(&group.frame, child_y, page_mid, best);
            }
            _ => {}
        }
    }
}

/// Build a scope-aware source by extracting only scope-defining statements
/// from the document (discarding all other content), then appending the
/// target fragment.
fn build_scoped_source(
    document_source: &str,
    frag_start: usize,
    frag_end: usize,
    _color: &str,
    is_multiline: bool,
    page_setup_override: Option<&str>,
    preamble_override: Option<&str>,
) -> Result<String, String> {
    let root = typst::syntax::parse(document_source);
    let skeleton = extract_scope_skeleton(&root, document_source, frag_start);
    let content = &document_source[frag_start..frag_end];
    let is_inline = !is_display_math(content);

    let page_setup = match page_setup_override {
        Some(custom) => format!("{custom}\n"),
        None if is_multiline => {
            // Multi-line display: wide page
            "#set page(width: 16cm, height: auto, fill: none, margin: (x: 0cm, y: 0.2cm))\n".into()
        }
        None if is_inline => {
            // Inline: generous margins for baseline crop hack
            "#set page(height: auto, width: auto, margin: (top: 20pt, bottom: 20pt, rest: 0pt), fill: none)\n".into()
        }
        None => {
            // Single-line display: auto width, normal margins
            "#set page(height: auto, width: auto, margin: 0.2cm, fill: none)\n".into()
        }
    };

    let fragment = &document_source[frag_start..frag_end];
    let closing = compute_closing_delimiters(document_source, frag_end);

    // bounded() is always included to prevent clipping.
    // Client preamble (colors, etc.) is additional.
    let client_preamble = preamble_override.unwrap_or("");

    Ok(format!(
        "{page_setup}{DEFAULT_RENDERING_PREAMBLE}{client_preamble}\n{skeleton}{fragment}{closing}\n"
    ))
}

/// Extract a "scope skeleton" from the document — only the statements that
/// define scope (let, import, set, show) and the block structure around them,
/// up to the target fragment position. All other content is discarded.
fn extract_scope_skeleton(
    root: &typst::syntax::SyntaxNode,
    source: &str,
    frag_start: usize,
) -> String {
    let mut result = String::new();
    collect_scope_nodes(root, source, frag_start, 0, &mut result);
    result
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
            // DON'T emit bare # — it was only needed for scope-defining statements,
            // and those now include the # themselves via the offset-1 check above.
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
                collect_scope_nodes(child, source, frag_start, child_offset, result);
                child_offset += child.len();
            }
        }

        // Code blocks: emit { }, recurse
        SyntaxKind::CodeBlock => {
            result.push_str("{\n");
            let mut child_offset = offset;
            for child in node.children() {
                collect_scope_nodes(child, source, frag_start, child_offset, result);
                child_offset += child.len();
            }
            // Don't close if fragment is inside (closing handled by compute_closing_delimiters)
            if frag_start >= node_end {
                result.push_str("}\n");
            }
        }

        // Content blocks: emit [ ], recurse
        SyntaxKind::ContentBlock => {
            result.push_str("[\n");
            let mut child_offset = offset;
            for child in node.children() {
                collect_scope_nodes(child, source, frag_start, child_offset, result);
                child_offset += child.len();
            }
            if frag_start >= node_end {
                result.push_str("]\n");
            }
        }

        // For ANY other node that contains the fragment (FuncCall, Args, Hash, etc.):
        // DON'T emit the node's own syntax (no function names, no bullets).
        // Just recurse into the child that contains the fragment.
        // This strips layout containers (#list, #box, #definition, etc.)
        // while preserving structural blocks (ContentBlock, CodeBlock).
        _ => {
            let mut child_offset = offset;
            for child in node.children() {
                let child_end = child_offset + child.len();
                if child_offset < frag_start && child_end > frag_start {
                    // Child contains the fragment: recurse
                    collect_scope_nodes(child, source, frag_start, child_offset, result);
                }
                child_offset = child_end;
            }
        }
    }
}

/// Append closing delimiters for any blocks that contain the fragment.
fn compute_closing_delimiters(source: &str, frag_end: usize) -> String {
    let root = typst::syntax::parse(source);
    let linked = LinkedNode::new(&root);

    let leaf = match linked.leaf_at(frag_end.saturating_sub(1), Side::Before) {
        Some(l) => l,
        None => return String::new(),
    };

    let mut closers = Vec::new();
    let mut current = leaf;
    while let Some(parent) = current.parent() {
        let parent_end = parent.offset() + parent.get().len();
        if parent_end > frag_end {
            match parent.kind() {
                SyntaxKind::CodeBlock => closers.push("}"),
                SyntaxKind::ContentBlock => closers.push("]"),
                _ => {}
            }
        }
        current = parent.clone();
    }

    closers.join("")
}

/// Build a Typst source document for a standalone fragment (no scope context).
fn build_fragment_source(content: &str, color: &str, preamble: &str) -> String {
    let is_multiline = is_multiline_math(content);
    let is_inline = !is_display_math(content);

    let color_setup = format!("#show math.equation: set text(rgb(\"{color}\"))\n");

    if is_multiline {
        // Multi-line display: wide page
        format!(
            "{color_setup}\
             {DEFAULT_RENDERING_PREAMBLE}\
             {preamble}\n\
             #set page(width: 16cm, height: auto, fill: none, margin: (x: 0cm, y: 0.2cm))\n\
             {content}\n"
        )
    } else if is_inline {
        // Inline: generous margins for baseline crop
        let inner = content.trim_matches('$').trim();
        format!(
            "{color_setup}\
             {DEFAULT_RENDERING_PREAMBLE}\
             #set page(height: auto, width: auto, margin: (top: 20pt, bottom: 20pt, rest: 0pt), fill: none)\n\
             {preamble}\n\
             $ {inner} $\n"
        )
    } else {
        // Single-line display: auto width, normal margins
        format!(
            "{color_setup}\
             {DEFAULT_RENDERING_PREAMBLE}\
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
        let output = FragmentCompiler::compile_fragment(
            &mut world, "$a + b$", "#000000", "",
        ).unwrap();
        assert!(output.svg.contains("<svg"));
        assert!(output.height_pt > 0.0);
    }

    #[test]
    fn compile_block_math() {
        let mut world = TipWorld::new();
        let output = FragmentCompiler::compile_fragment(
            &mut world, "$ sum_(i=0)^n i^2 $", "#000000", "",
        ).unwrap();
        assert!(output.svg.contains("<svg"));
    }

    #[test]
    fn compile_with_preamble() {
        let mut world = TipWorld::new();
        let output = FragmentCompiler::compile_fragment(
            &mut world, "$cl$", "#000000", "#let cl = math.cal(\"L\")\n",
        ).unwrap();
        assert!(output.svg.contains("<svg"));
    }

    #[test]
    fn compile_invalid_returns_error() {
        let mut world = TipWorld::new();
        let result = FragmentCompiler::compile_fragment(
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
        let skel = extract_scope_skeleton(&root, doc, frag_start);
        assert!(skel.contains("let x = 1"), "skeleton: {skel}");
    }

    #[test]
    fn skeleton_extracts_set_rule() {
        let doc = "#set text(fill: blue)\nText $a$";
        let root = typst::syntax::parse(doc);
        let frag_start = doc.find("$a$").unwrap();
        let skel = extract_scope_skeleton(&root, doc, frag_start);
        assert!(skel.contains("set text(fill: blue)"), "skeleton: {skel}");
    }

    #[test]
    fn skeleton_extracts_show_rule() {
        let doc = "#show math.equation: set text(fill: red)\n$a$";
        let root = typst::syntax::parse(doc);
        let frag_start = doc.find("$a$").unwrap();
        let skel = extract_scope_skeleton(&root, doc, frag_start);
        assert!(skel.contains("show math.equation"), "skeleton: {skel}");
    }

    #[test]
    fn skeleton_skips_text_content() {
        let doc = "#let x = 1\nHello world some text here\n$x$";
        let root = typst::syntax::parse(doc);
        let frag_start = doc.find("$x$").unwrap();
        let skel = extract_scope_skeleton(&root, doc, frag_start);
        assert!(skel.contains("let x = 1"));
        assert!(!skel.contains("Hello world"), "should not contain text: {skel}");
    }

    #[test]
    fn skeleton_preserves_block_structure() {
        let doc = "#{\n  let x = 1\n  $x$\n}";
        let root = typst::syntax::parse(doc);
        let frag_start = doc.find("$x$").unwrap();
        let skel = extract_scope_skeleton(&root, doc, frag_start);
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
        let output = FragmentCompiler::compile_fragment_scoped(
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
        let output = FragmentCompiler::compile_fragment_scoped(
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
        let output = FragmentCompiler::compile_fragment_scoped(
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
        assert!(FragmentCompiler::compile_fragment_scoped(
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
        let output = FragmentCompiler::compile_fragment_scoped(
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
        let output = FragmentCompiler::compile_fragment_scoped(
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
        let output = FragmentCompiler::compile_fragment_scoped(
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
        let output = FragmentCompiler::compile_fragment_scoped(
            &mut world, doc, start, end, "#000000", None, None,
        ).expect("math in #enum should compile");
        assert!(output.svg.contains("<svg"));
    }
}
