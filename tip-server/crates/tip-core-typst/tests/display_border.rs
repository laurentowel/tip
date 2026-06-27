//! Regression test: the `display_math_border_opacity` protocol field
//! injects an SVG `<rect stroke="currentColor">' around multi-line
//! display math (and nothing else).  Border rendering happens
//! post-compile via `tip_protocol::svg_color::apply_display_border',
//! which is shared across Typst/LaTeX/KaTeX backends and uses each
//! backend's own multi-line-display classifier.

use tip_core_typst::bottom_up::{is_multiline_math, BottomUpCompiler};
use tip_core_typst::world::TipWorld;
use tip_protocol::messages::FragmentResult;
use tip_protocol::svg_color::apply_display_border;

fn one_fragment(doc: &str, start: usize, end: usize) -> FragmentResult {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment_scoped(
        &mut world, doc, start, end, "#000000", None, None, None,
    )
    .unwrap();
    FragmentResult {
        start,
        end,
        svg: out.svg,
        height_pt: out.height_pt,
        depth_pt: out.depth_pt,
        width_pt: out.width_pt,
        font_size_pt: Some(11.0),
        error: None,
        error_detail: None,
    }
}

#[test]
fn multiline_display_gets_border() {
    let doc = "$\n  a + b \\\n  = c\n$\n";
    let mut results = vec![one_fragment(doc, 0, doc.len() - 1)];
    apply_display_border(&mut results, doc, Some(0.3), is_multiline_math);
    let svg = &results[0].svg;
    assert!(
        svg.contains("stroke=\"currentColor\""),
        "expected border rect; got:\n{svg}"
    );
    assert!(
        svg.contains("stroke-opacity=\"0.300\""),
        "expected stroke-opacity 0.3; got:\n{svg}"
    );
}

#[test]
fn inline_and_single_line_display_get_no_border() {
    // Inline math: `$a + b$' (no whitespace adjacent to delimiters).
    let inline = "$a + b$";
    let mut r1 = vec![one_fragment(inline, 0, inline.len())];
    apply_display_border(&mut r1, inline, Some(0.3), is_multiline_math);
    assert!(
        !r1[0].svg.contains("stroke=\"currentColor\""),
        "inline math must not get a border"
    );

    // Single-line display: `$ a + b $' (no newline).
    let single = "$ a + b $";
    let mut r2 = vec![one_fragment(single, 0, single.len())];
    apply_display_border(&mut r2, single, Some(0.3), is_multiline_math);
    assert!(
        !r2[0].svg.contains("stroke=\"currentColor\""),
        "single-line display must not get a border"
    );
}

#[test]
fn opacity_none_or_zero_skips_border() {
    let doc = "$\n  a + b\n$\n";
    let baseline = one_fragment(doc, 0, doc.len() - 1).svg;

    let mut none_results = vec![one_fragment(doc, 0, doc.len() - 1)];
    apply_display_border(&mut none_results, doc, None, is_multiline_math);
    assert_eq!(none_results[0].svg, baseline);

    let mut zero_results = vec![one_fragment(doc, 0, doc.len() - 1)];
    apply_display_border(&mut zero_results, doc, Some(0.0), is_multiline_math);
    assert_eq!(zero_results[0].svg, baseline);
}
