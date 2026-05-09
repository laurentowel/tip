//! Regression tests: invisible-base superscript fragments (the
//! `$#sym.zws^2$' / `$#(sym.zws)^2$' shape) must crop to include the
//! body baseline of the surrounding line, not just the superscript
//! glyph's own ink.  See `bottom_up/mod.rs::find_baseline_depth' and
//! `top_down/extract.rs::find_external_baseline_from_leaves' for the
//! body-baseline anchoring logic.

use tip_core_typst::top_down::TopDownCompiler;
use tip_core_typst::world::TipWorld;
use tip_protocol::messages::FragmentLocation;

#[test]
fn top_down_zws_super_with_surrounding_prose() {
    // The fragment lives in a paragraph with surrounding text — the
    // surrounding prose's body baseline should anchor the crop.
    let doc = "Some prose text here $#sym.zws^2$ and more text after.";
    let frag_start = doc.find("$#sym.zws^2$").unwrap();
    let frag_end = frag_start + "$#sym.zws^2$".len();
    let mut world = TipWorld::new();
    let frags = vec![FragmentLocation {
        start: frag_start,
        end: frag_end,
    }];
    let results = TopDownCompiler::compile_all(&mut world, doc, &frags, None).unwrap();
    let r = &results[0];
    assert!(
        r.height_pt > 8.0,
        "top-down: image should extend from glyph top to body baseline, got h={:.2}",
        r.height_pt
    );
    let ascent_pct = 100.0 * (1.0 - r.depth_pt / r.height_pt);
    assert!(
        ascent_pct >= 90.0,
        "ascent should be ≥ 90% (image mostly above baseline); got {:.0}%",
        ascent_pct
    );
    // font_size_pt must reflect the SURROUNDING line's body size,
    // not the fragment's superscript glyph size.  Otherwise
    // `tip-scale='auto'` on the client side would inflate the image
    // by `body_size_pt / superscript_size_pt' ≈ 1.4× to compensate
    // for what it thinks is small text.  Default Typst body is 11pt
    // (the typst-ts paragraph default).
    let fs = r.font_size_pt.unwrap_or(0.0);
    assert!(
        (fs - 11.0).abs() < 1.0,
        "font_size_pt should be the body size (~11pt), not the superscript size; got {fs:.2}"
    );
}
