//! Regression test: numbered-list markers ("1.", "2.") must NOT bleed
//! into a math fragment's extracted SVG.  User-reported case (May 2026):
//!   1. $G$ ... statement
//!   2. $G$ ... statement
//! In top-down mode, the SVG for `$G$` was including the "1" or "2"
//! glyph from the list marker.

use tip_core_typst::top_down::TopDownCompiler;
use tip_core_typst::world::TipWorld;
use tip_protocol::messages::FragmentLocation;

#[test]
fn enum_marker_does_not_bleed_into_math() {
    let doc = "\
For groups acting on M, TFAE:

1. $G$ can push any measure to a point.
2. $G$ can convolve any measure to a point.
";
    // Find the two `$G$` fragments by byte offset.
    let mut starts = Vec::new();
    let mut idx = 0;
    while let Some(pos) = doc[idx..].find("$G$") {
        let s = idx + pos;
        starts.push(s);
        idx = s + "$G$".len();
    }
    assert_eq!(starts.len(), 2, "should find two `$G$` fragments");

    let frags: Vec<FragmentLocation> = starts
        .iter()
        .map(|&s| FragmentLocation {
            start: s,
            end: s + "$G$".len(),
        })
        .collect();

    let mut world = TipWorld::new();
    let results = TopDownCompiler::compile_all(&mut world, doc, &frags, None).unwrap();
    assert_eq!(results.len(), 2);

    for (i, r) in results.iter().enumerate() {
        let label = format!("frag {} starting at {}", i, starts[i]);
        eprintln!(
            "{label}: h={:.2} d={:.2} w={:.2} svg_len={}",
            r.height_pt,
            r.depth_pt,
            r.width_pt,
            r.svg.len()
        );
        // A bare `$G$` is a single italic glyph.  It should be no
        // wider than ~10pt (the glyph + padding).  If width is much
        // bigger, the marker glyph leaked into the crop.
        assert!(
            r.width_pt < 12.0,
            "{label}: width {:.2} suggests the list marker leaked in",
            r.width_pt
        );
        // Defensive: the SVG should not contain a literal `>1<` or
        // `>2<` digit glyph.  Typst SVG output uses `<text>` elements
        // for glyphs; the digit literal shows up between `>` and `<`.
        assert!(
            !r.svg.contains(">1<"),
            "{label}: SVG contains literal '1' marker"
        );
        assert!(
            !r.svg.contains(">2<"),
            "{label}: SVG contains literal '2' marker"
        );
    }
}
