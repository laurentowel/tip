use tip_core_typst::compiler::FragmentCompiler;
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

fn font_dir() -> String {
    format!(
        "{}/ref/Pennstander-ref/fonts/otf",
        env!("CARGO_MANIFEST_DIR").replace("/tip-server/crates/tip-core-typst", ""),
    )
}

fn compile_with_weight(weight_name: &str, math_weight: &str, text_weight: &str) {
    let dir = font_dir();
    let mut world = TipWorld::with_font_dirs(&[dir.as_str()]);

    let preamble = format!(
        "#show math.equation: set text(font: \"Pennstander Math\", weight: \"{}\")\n\
         #set text(font: \"Pennstander\", weight: \"{}\")\n",
        math_weight, text_weight
    );

    let content = "$integral_0^infinity e^(-x^2) dif x = frac(sqrt(pi), 2)$";

    let out = FragmentCompiler::compile_fragment(
        &mut world,
        content,
        "#000000",
        &preamble,
    )
    .unwrap();

    let filename = format!("penn_{}", weight_name);
    write_svg(&filename, &out.svg);
    eprintln!("{}: height={:.2}pt", weight_name, out.height_pt);
}

#[test]
fn visual_penn_thin() {
    compile_with_weight("thin", "thin", "thin");
}

#[test]
fn visual_penn_extralight() {
    compile_with_weight("extralight", "extralight", "extralight");
}

#[test]
fn visual_penn_light() {
    compile_with_weight("light", "light", "light");
}

#[test]
fn visual_penn_regular() {
    compile_with_weight("regular", "regular", "regular");
}

#[test]
fn visual_penn_medium() {
    compile_with_weight("medium", "medium", "medium");
}

#[test]
fn visual_penn_semibold() {
    compile_with_weight("semibold", "semibold", "semibold");
}

#[test]
fn visual_penn_bold() {
    compile_with_weight("bold", "bold", "bold");
}

#[test]
fn visual_penn_extrabold() {
    compile_with_weight("extrabold", "extrabold", "extrabold");
}

#[test]
fn visual_penn_black() {
    compile_with_weight("black", "black", "black");
}
