//! Verify that `#text(0.7em)[...]` inside a fragment scales the
//! wrapped math relative to the body anchor.  Before the fix at
//! `bottom_up/mod.rs:317` (replacing `set text(size: 11pt)` with
//! `set text(size: 1em)` plus a body anchor), the absolute show rule
//! would re-pin every nested math.equation to 11pt regardless of any
//! surrounding `text(...)` wrapper — defeating users who write
//! `edge(..., [#text(0.7em)[$...$]])` in fletcher diagrams.

use tip_core_typst::bottom_up::BottomUpCompiler;
use tip_core_typst::world::TipWorld;

#[test]
fn text_em_wrapper_around_inner_math_scales_down() {
    let mut world = TipWorld::new();
    let unwrapped =
        BottomUpCompiler::compile_fragment(&mut world, "$x y$", "#000000", "").unwrap();
    let wrapped = BottomUpCompiler::compile_fragment(
        &mut world,
        "$x #text(0.7em)[$y$]$",
        "#000000",
        "",
    )
    .unwrap();

    // Both fragments contain an `x' and a `y'.  When the `y' is wrapped in
    // `#text(0.7em)[...]`, the rendered width must be smaller — the inner
    // math inherits the 0.7em ambient size instead of the 11pt body anchor.
    assert!(
        wrapped.width_pt < unwrapped.width_pt,
        "expected `#text(0.7em)' wrapper to shrink math: wrapped={:.2}pt unwrapped={:.2}pt",
        wrapped.width_pt,
        unwrapped.width_pt
    );

    // Sanity: the difference should be material (>= 5% smaller).  If the
    // show rule absolute override creeps back in, both widths converge.
    let shrink = (unwrapped.width_pt - wrapped.width_pt) / unwrapped.width_pt;
    assert!(
        shrink >= 0.05,
        "expected >=5% shrink, got {:.1}% (wrapped={:.2} unwrapped={:.2})",
        shrink * 100.0,
        wrapped.width_pt,
        unwrapped.width_pt
    );
}

#[test]
fn top_level_math_still_at_body_anchor() {
    // With the body anchor (#set text(size: 11pt)), a bare `$a + b$' must
    // still render at the historical 11pt size — same width as before the
    // show-rule change.  A regression here would mean documents with a
    // doc-level `#set text(size: 14pt)' would now render math at 14pt.
    let mut world = TipWorld::new();
    let out =
        BottomUpCompiler::compile_fragment(&mut world, "$a + b$", "#000000", "").unwrap();
    // 11pt body, three glyphs + spaces.  An empirical sanity floor: width
    // must be in a plausible 11pt-body range (not crashed to 0, not
    // ballooned past 50pt).
    assert!(
        out.width_pt > 5.0 && out.width_pt < 50.0,
        "implausible width for $a + b$ at 11pt body: {:.2}pt",
        out.width_pt
    );
}
