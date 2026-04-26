use tip_core_typst::bottom_up::BottomUpCompiler;
use tip_core_typst::world::TipWorld;

fn write_svg(name: &str, svg: &str) {
    let path = format!(
        "{}/test-output/{}.svg",
        env!("CARGO_MANIFEST_DIR").replace("/crates/tip-core-typst", ""),
        name
    );
    std::fs::write(&path, svg).expect("write SVG");
    eprintln!("wrote {path}");
}

#[test]
fn visual_default_math_font() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(
        &mut world,
        "$a + b = c$",
        "#000000",
        "",
    )
    .unwrap();
    write_svg("math_default", &out.svg);
    eprintln!("height: {:.2}pt", out.height_pt);
}

#[test]
fn visual_pennstander_math() {
    let font_dir = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../ref/Pennstander-ref/fonts/otf"
    );
    let mut world = TipWorld::with_font_dirs(&[font_dir]);

    let preamble = concat!(
        "#show math.equation: set text(font: \"Pennstander Math\")\n",
        "#set text(font: \"Pennstander\")\n",
    );

    let out = BottomUpCompiler::compile_fragment(
        &mut world,
        "$a + b = c$",
        "#000000",
        preamble,
    )
    .unwrap();
    write_svg("math_pennstander_inline", &out.svg);
    eprintln!("height: {:.2}pt", out.height_pt);
}

#[test]
fn visual_pennstander_block() {
    let font_dir = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../ref/Pennstander-ref/fonts/otf"
    );
    let mut world = TipWorld::with_font_dirs(&[font_dir]);

    let preamble = concat!(
        "#show math.equation: set text(font: \"Pennstander Math\")\n",
        "#set text(font: \"Pennstander\")\n",
    );

    let out = BottomUpCompiler::compile_fragment(
        &mut world,
        "$ sum_(i=0)^n i^2 = frac(n(n+1)(2n+1), 6) $",
        "#000000",
        preamble,
    )
    .unwrap();
    write_svg("math_pennstander_block", &out.svg);
    eprintln!("height: {:.2}pt", out.height_pt);
}

#[test]
fn visual_pennstander_integral() {
    let font_dir = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../ref/Pennstander-ref/fonts/otf"
    );
    let mut world = TipWorld::with_font_dirs(&[font_dir]);

    let preamble = concat!(
        "#show math.equation: set text(font: \"Pennstander Math\")\n",
        "#set text(font: \"Pennstander\")\n",
    );

    let out = BottomUpCompiler::compile_fragment(
        &mut world,
        "$integral_0^infinity e^(-x^2) dif x = frac(sqrt(pi), 2)$",
        "#2244aa",
        preamble,
    )
    .unwrap();
    write_svg("math_pennstander_integral", &out.svg);
    eprintln!("height: {:.2}pt", out.height_pt);
}
