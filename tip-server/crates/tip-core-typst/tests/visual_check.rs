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
fn visual_inline_simple() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(&mut world, "$a + b = c$", "#000000", "").unwrap();
    write_svg("inline_simple", &out.svg);
    eprintln!(
        "height: {:.2}pt, depth: {:.2}pt",
        out.height_pt, out.depth_pt
    );
}

#[test]
fn visual_inline_fraction() {
    let mut world = TipWorld::new();
    let out =
        BottomUpCompiler::compile_fragment(&mut world, "$frac(a, b)$", "#000000", "").unwrap();
    write_svg("inline_fraction", &out.svg);
    eprintln!(
        "height: {:.2}pt, depth: {:.2}pt",
        out.height_pt, out.depth_pt
    );
}

#[test]
fn visual_block_sum() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(
        &mut world,
        "$ sum_(i=0)^n i^2 = frac(n(n+1)(2n+1), 6) $",
        "#000000",
        "",
    )
    .unwrap();
    write_svg("block_sum", &out.svg);
    eprintln!(
        "height: {:.2}pt, depth: {:.2}pt",
        out.height_pt, out.depth_pt
    );
}

#[test]
fn visual_colored() {
    let mut world = TipWorld::new();
    let out = BottomUpCompiler::compile_fragment(
        &mut world,
        "$integral_0^infinity e^(-x^2) dif x = frac(sqrt(pi), 2)$",
        "#ff3333",
        "",
    )
    .unwrap();
    write_svg("colored_integral", &out.svg);
    eprintln!(
        "height: {:.2}pt, depth: {:.2}pt",
        out.height_pt, out.depth_pt
    );
}

#[test]
fn visual_with_preamble() {
    let mut world = TipWorld::new();
    let preamble = "#let cl = math.cal(\"L\")\n#let RR = math.bb(\"R\")\n";
    let out =
        BottomUpCompiler::compile_fragment(&mut world, "$cl(RR^n)$", "#000000", preamble).unwrap();
    write_svg("with_preamble", &out.svg);
    eprintln!(
        "height: {:.2}pt, depth: {:.2}pt",
        out.height_pt, out.depth_pt
    );
}
