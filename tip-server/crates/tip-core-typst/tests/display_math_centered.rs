//! Top-down must produce a wide canvas with the math centered for
//! multi-line display fragments — matching bottom-up's 16cm wide page
//! treatment.  Without this the SVG was a tight ink-only crop, and the
//! display equation appeared flush-left in Emacs while the same
//! equation rendered centered under the bottom-up strategy.

use tip_core_typst::top_down::TopDownCompiler;
use tip_core_typst::world::TipWorld;
use tip_protocol::messages::FragmentLocation;

#[test]
fn top_down_multiline_display_uses_canvas_width() {
    let doc = "Some lead-in prose.\n\n$\nx = a + b \\\n  = c + d\n$\n\nMore text.\n";
    let frag_start = doc.find('$').unwrap();
    let frag_end = doc[frag_start + 1..].find('$').unwrap() + frag_start + 2;
    let mut world = TipWorld::new();
    let frags = vec![FragmentLocation {
        start: frag_start,
        end: frag_end,
    }];

    // Default canvas (None → 16cm fallback).
    let r_default = TopDownCompiler::compile_all(&mut world, doc, &frags, None)
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    eprintln!("default canvas: w={:.2}pt", r_default.width_pt);
    // 16 cm = 453.5 pt — width should reach near that.
    assert!(
        r_default.width_pt > 400.0,
        "default 16cm canvas should make w > 400pt; got {:.2}",
        r_default.width_pt
    );

    // Explicit width override via the protocol field.
    let r_28em = TopDownCompiler::compile_all(&mut world, doc, &frags, Some("28em"))
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    // 28em at 11pt body = 308pt.
    eprintln!("28em canvas: w={:.2}pt", r_28em.width_pt);
    assert!(
        (r_28em.width_pt - 308.0).abs() < 5.0,
        "28em should give w ≈ 308pt; got {:.2}",
        r_28em.width_pt
    );

    let r_400pt = TopDownCompiler::compile_all(&mut world, doc, &frags, Some("400pt"))
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    eprintln!("400pt canvas: w={:.2}pt", r_400pt.width_pt);
    assert!(
        (r_400pt.width_pt - 400.0).abs() < 5.0,
        "400pt should give w ≈ 400pt; got {:.2}",
        r_400pt.width_pt
    );
}

#[test]
fn top_down_inline_keeps_tight_crop() {
    // Inline fragments should NOT use the canvas widening.
    let doc = "Some prose with $x + y$ inline.";
    let frag_start = doc.find("$x + y$").unwrap();
    let frag_end = frag_start + "$x + y$".len();
    let mut world = TipWorld::new();
    let frags = vec![FragmentLocation {
        start: frag_start,
        end: frag_end,
    }];
    // Even with a 16cm canvas hint, inline math should crop tight.
    let r = TopDownCompiler::compile_all(&mut world, doc, &frags, Some("16cm"))
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    eprintln!("inline w={:.2}pt", r.width_pt);
    assert!(
        r.width_pt < 50.0,
        "inline `$x + y$' should stay tight; got w={:.2}",
        r.width_pt
    );
}
