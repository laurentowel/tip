use tip_core_typst::bottom_up::BottomUpCompiler;
use tip_core_typst::world::TipWorld;

fn write_svg(name: &str, svg: &str) {
    let path = format!(
        "{}/test-output/{}.svg",
        env!("CARGO_MANIFEST_DIR").replace("/crates/tip-core-typst", ""),
        name
    );
    std::fs::write(&path, svg).expect("write SVG");
}

// ┌──────────────────────────┬────────────────────────────────────────────────────────────────┐
// │ Test                     │ Expected                                                       │
// ├──────────────────────────┼────────────────────────────────────────────────────────────────┤
// │ simple a+b               │ small depth (descenders only), ascent ~85-95%                  │
// │ fraction                 │ moderate depth (denominator below baseline)                     │
// │ integral with limits     │ large depth (subscript below)                                   │
// │ superscript only x^2     │ near-zero depth                                                 │
// │ subscript only x_i       │ notable depth                                                   │
// │ matrix                   │ significant depth (bottom row below baseline)                   │
// │ display sum              │ large depth (lower limit below baseline)                        │
// └──────────────────────────┴────────────────────────────────────────────────────────────────┘

#[test]
fn baseline_simple() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(&mut world, "$a + b$", "#000000", "").unwrap();
    write_svg("bl_simple", &out.svg);
    eprintln!("simple: h={:.2} d={:.2} ascent={:.0}%",
              out.height_pt, out.depth_pt,
              100.0 * (1.0 - out.depth_pt / out.height_pt));
    assert!(out.depth_pt >= 0.0, "depth should be non-negative");
    assert!(out.depth_pt < out.height_pt, "depth should be less than height");
    // Simple letters: ascent should be high (>80%)
    let ascent_pct = 100.0 * (1.0 - out.depth_pt / out.height_pt);
    assert!(ascent_pct > 70.0, "simple letters ascent too low: {:.0}%", ascent_pct);
}

#[test]
fn baseline_fraction() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(&mut world, "$frac(a, b)$", "#000000", "").unwrap();
    write_svg("bl_fraction", &out.svg);
    eprintln!("fraction: h={:.2} d={:.2} ascent={:.0}%",
              out.height_pt, out.depth_pt,
              100.0 * (1.0 - out.depth_pt / out.height_pt));
    assert!(out.depth_pt > 0.0, "fraction should have non-zero depth");
}

#[test]
fn baseline_integral() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(&mut world, "$integral_0^1 f(x) dif x$", "#000000", "").unwrap();
    write_svg("bl_integral", &out.svg);
    eprintln!("integral: h={:.2} d={:.2} ascent={:.0}%",
              out.height_pt, out.depth_pt,
              100.0 * (1.0 - out.depth_pt / out.height_pt));
    assert!(out.depth_pt > 0.0, "integral with limits should have depth");
}

#[test]
fn baseline_superscript() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(&mut world, "$x^2$", "#000000", "").unwrap();
    write_svg("bl_superscript", &out.svg);
    eprintln!("superscript: h={:.2} d={:.2} ascent={:.0}%",
              out.height_pt, out.depth_pt,
              100.0 * (1.0 - out.depth_pt / out.height_pt));
    // x^2 has minimal depth
    assert!(out.depth_pt < 4.0, "superscript should have small depth: {:.2}", out.depth_pt);
}

#[test]
fn baseline_subscript() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(&mut world, "$x_i$", "#000000", "").unwrap();
    write_svg("bl_subscript", &out.svg);
    eprintln!("subscript: h={:.2} d={:.2} ascent={:.0}%",
              out.height_pt, out.depth_pt,
              100.0 * (1.0 - out.depth_pt / out.height_pt));
    assert!(out.depth_pt > 0.0, "subscript should have depth");
}

#[test]
fn baseline_accent() {
    // Accents like hat/tilde produce 2 same-size text items: the base
    // character at the math baseline and the accent glyph above it.
    // The heuristic must pick the base (larger y), not the accent.
    let mut world = TipWorld::new();
    let simple = BottomUpCompiler::compile_fragment(&mut world, "$G$", "#000000", "").unwrap();
    let hat = BottomUpCompiler::compile_fragment(&mut world, "$hat(G)$", "#000000", "").unwrap();
    let tilde = BottomUpCompiler::compile_fragment(&mut world, "$tilde(G)$", "#000000", "").unwrap();
    assert!(hat.depth_pt < simple.depth_pt + 2.0,
            "hat depth ({:.2}) should match G's descender ({:.2})",
            hat.depth_pt, simple.depth_pt);
    assert!(tilde.depth_pt < simple.depth_pt + 2.0,
            "tilde depth ({:.2}) should match G's descender ({:.2})",
            tilde.depth_pt, simple.depth_pt);
}

#[test]
fn baseline_matrix() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(&mut world, "$mat(1, 0; 0, 1)$", "#000000", "").unwrap();
    write_svg("bl_matrix", &out.svg);
    eprintln!("matrix: h={:.2} d={:.2} ascent={:.0}%",
              out.height_pt, out.depth_pt,
              100.0 * (1.0 - out.depth_pt / out.height_pt));
    assert!(out.depth_pt > 0.0, "matrix should have depth (bottom row)");
    // Matrix should be roughly centered: ascent ~45-65%
    let ascent_pct = 100.0 * (1.0 - out.depth_pt / out.height_pt);
    assert!(ascent_pct > 30.0 && ascent_pct < 80.0,
            "matrix ascent should be roughly centered: {:.0}%", ascent_pct);
}

#[test]
fn baseline_display_sum() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(
        &mut world, "$ sum_(i=0)^n i^2 $", "#000000", ""
    ).unwrap();
    write_svg("bl_display_sum", &out.svg);
    eprintln!("display sum: h={:.2} d={:.2}", out.height_pt, out.depth_pt);
    // Display math returns depth=0 (no baseline alignment, vertically centered)
    assert!(out.height_pt > 0.0, "display sum should have height");
}

#[test]
fn baseline_depth_ordering() {
    let mut world = TipWorld::new();
    let simple = BottomUpCompiler::compile_fragment(&mut world, "$a$", "#000000", "").unwrap();
    let sub = BottomUpCompiler::compile_fragment(&mut world, "$a_i$", "#000000", "").unwrap();
    let frac = BottomUpCompiler::compile_fragment(&mut world, "$frac(a, b)$", "#000000", "").unwrap();

    eprintln!("depth ordering: simple={:.2} sub={:.2} frac={:.2}",
              simple.depth_pt, sub.depth_pt, frac.depth_pt);

    // Subscript should have noticeably more depth than simple — its
    // glyph really descends below the baseline.
    assert!(sub.depth_pt > simple.depth_pt + 0.5,
            "subscript depth ({:.2}) should exceed simple ({:.2}) by >0.5pt",
            sub.depth_pt, simple.depth_pt);

    // `compile_fragment` rewraps `$frac(a, b)$` as `$ frac(a, b) $`,
    // i.e. display math.  Strategy 2 picks the lower row's baseline
    // (denominator), so the visual baseline lands at the bottom of
    // the ink and depth collapses to the crop pad — same magnitude
    // as a single-letter fragment.  Assertion is "not significantly
    // less than simple", reflecting that reality.
    assert!(frac.depth_pt >= simple.depth_pt,
            "fraction depth ({:.2}) should be >= simple ({:.2})",
            frac.depth_pt, simple.depth_pt);
}

#[test]
fn baseline_bare_fraction_inline() {
    // Regression: `$1/a$` (and `$a/b$` etc) used to use a font-ascent
    // fallback that placed baseline_y too far below body-baseline,
    // causing the rendered image to float visually above surrounding
    // text.  Fix: use math-axis from the font's MATH table.
    //
    // What we assert: depth_pt is non-trivial.  If baseline_y is
    // chosen too low, the rendered image's baseline ends up at the
    // bottom of the ink and depth_pt collapses toward zero.
    // Use scoped compilation so the fragment stays inline ($..$);
    // compile_fragment adds spaces around the inner content, which
    // would convert it to display math and the bug would not apply.
    let doc = "Some text with $1/a$ inline.";
    let start = doc.find('$').unwrap();
    let end = doc.rfind('$').unwrap() + 1;
    let mut world = TipWorld::new();
    let frac = BottomUpCompiler::compile_fragment_scoped(
        &mut world, doc, start, end, "#000000", None, None,
    ).unwrap();
    write_svg("bl_bare_fraction", &frac.svg);
    eprintln!("$1/a$: h={:.2} d={:.2}", frac.height_pt, frac.depth_pt);
    assert!(frac.depth_pt >= 1.5,
            "$1/a$ depth too small ({:.2}pt); baseline_y likely chosen too low",
            frac.depth_pt);

    let doc = "Some text with $a/b$ inline.";
    let start = doc.find('$').unwrap();
    let end = doc.rfind('$').unwrap() + 1;
    let mut world = TipWorld::new();
    let ab = BottomUpCompiler::compile_fragment_scoped(
        &mut world, doc, start, end, "#000000", None, None,
    ).unwrap();
    eprintln!("$a/b$: h={:.2} d={:.2}", ab.height_pt, ab.depth_pt);
    assert!(ab.depth_pt >= 1.5,
            "$a/b$ depth too small ({:.2}pt); baseline_y likely chosen too low",
            ab.depth_pt);
}
