//! Regression test: when a math fragment lives inside a heading and
//! the document also calls `#outline()`, top-down was extracting
//! BOTH the original heading-rendered glyph AND the outline-entry
//! glyph (plus dot leaders / page numbers) into one SVG.  Pick-best-
//! cluster (largest max text size) keeps just the heading occurrence.

use tip_core_typst::top_down::TopDownCompiler;
use tip_core_typst::world::TipWorld;
use tip_protocol::messages::FragmentLocation;

#[test]
fn outline_does_not_bleed_into_heading_math() {
    let doc = "\
#outline()

= Section about $G$

Body text.
";
    let frag_start = doc.find("$G$").unwrap();
    let frag_end = frag_start + "$G$".len();
    let mut world = TipWorld::new();
    let frags = vec![FragmentLocation {
        start: frag_start,
        end: frag_end,
    }];
    let r = TopDownCompiler::compile_all(&mut world, doc, &frags, None)
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    eprintln!(
        "heading $G$ with #outline(): h={:.2} d={:.2} w={:.2} fs={:?}",
        r.height_pt, r.depth_pt, r.width_pt, r.font_size_pt
    );

    // A bare `$G$` rendered at the heading's font size is at most
    // ~15pt wide.  If we accidentally pulled in the outline entry, the
    // image would also contain "Section about", dot leaders, and a
    // page number — easily 100+ pt.  Keep the threshold strict.
    assert!(
        r.width_pt < 20.0,
        "width {:.2} suggests outline-entry artifacts leaked into heading-math SVG",
        r.width_pt
    );

    // The heading's $G$ is at the heading font size (~15.4pt for a
    // level-1 heading at 11pt body); the outline entry's G would be
    // at body size (11pt).  Picking by largest text size selects the
    // heading version.
    let fs = r.font_size_pt.unwrap_or(0.0);
    assert!(
        fs > 13.0,
        "font_size_pt {fs:.2} suggests we picked the body-size outline cluster instead of the heading"
    );
}
