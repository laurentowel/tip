use tip_core::compiler::FragmentCompiler;
use tip_core::world::TipWorld;

fn write_svg(name: &str, svg: &str) {
    let path = format!(
        "{}/test-output/{}.svg",
        env!("CARGO_MANIFEST_DIR").replace("/crates/tip-core", ""),
        name
    );
    std::fs::write(&path, svg).expect("write SVG");
    eprintln!("wrote {path}");
}

fn compile_scoped(world: &mut TipWorld, doc: &str, needle: &str, name: &str) {
    let frag_start = doc.find(needle).expect(&format!("needle {needle:?} not found"));
    let frag_end = frag_start + needle.len();
    let out = FragmentCompiler::compile_fragment_scoped(
        world, doc, frag_start, frag_end, "#000000", None, None,
    )
    .expect(&format!("{name} should compile"));
    write_svg(name, &out.svg);
    eprintln!("{name}: height={:.2}pt", out.height_pt);
}

// ┌──────────────────────────┬──────────────────────────────────────────────────────────────┬───────────────────────┐
// │ SVG filename             │ What it tests                                                │ Expected rendering    │
// ├──────────────────────────┼──────────────────────────────────────────────────────────────┼───────────────────────┤
// │ nest_math_text_math      │ $a + #text[$b$]$ — math containing text containing math     │ a + b (b in text)     │
// │ nest_deep_mode_switch    │ 3 levels of mode switching                                   │ a+b+c (mixed modes)   │
// │ nest_let_in_content      │ let defined inside #[ ], fragment inside same content block  │ ω + ω                 │
// │ nest_let_across_modes    │ let at top, used deep inside mode switches                   │ ℝ (blackboard bold)   │
// │ nest_show_inside_block   │ show rule inside code block, applies to nested math          │ red a+b               │
// │ nest_func_returning_math │ function returns math content, used in equation              │ x² + y²               │
// │ nest_math_in_box         │ #box wrapping math, with styling                             │ boxed blue a+b        │
// │ nest_context_in_math     │ #context inside math accessing state                        │ counter value = 1     │
// └──────────────────────────┴──────────────────────────────────────────────────────────────┴───────────────────────┘

#[test]
fn nest_math_text_math() {
    let mut world = TipWorld::new();
    // Math → #text → [content] → math: the inner $b$ is in text style
    let doc = "Equation $a + #text[$b$]$";
    compile_scoped(&mut world, doc, "$a + #text[$b$]$", "nest_math_text_math");
}

#[test]
fn nest_deep_mode_switch() {
    let mut world = TipWorld::new();
    // math → code → content → math → code → content → math
    let doc = "Deep $a + #[#let x = $b$; #x] + c$";
    compile_scoped(&mut world, doc, "$a + #[#let x = $b$; #x] + c$", "nest_deep_mode_switch");
}

#[test]
fn nest_let_in_content() {
    let mut world = TipWorld::new();
    // Let defined inside a content block, fragment in same block
    let doc = "#[\n  #let ww = sym.omega\n  Result: $ww + ww$\n]";
    compile_scoped(&mut world, doc, "$ww + ww$", "nest_let_in_content");
}

#[test]
fn nest_let_across_modes() {
    let mut world = TipWorld::new();
    // Top-level let, used deep inside nested mode switches
    let doc = "#let RR = math.bb(\"R\")\nSome text #[\n  More text $RR$\n]";
    compile_scoped(&mut world, doc, "$RR$", "nest_let_across_modes");
}

#[test]
fn nest_show_inside_block() {
    let mut world = TipWorld::new();
    // Show rule defined inside a code block, applies to math in that block
    let doc = "#{\n  show math.equation: set text(fill: red)\n  $a + b$\n}";
    compile_scoped(&mut world, doc, "$a + b$", "nest_show_inside_block");
}

#[test]
fn nest_func_returning_math() {
    let mut world = TipWorld::new();
    // Function that builds math, called in an equation
    let doc = "\
#let sumsq(x, y) = $#x^2 + #y^2$
Result $sumsq(x, y)$";
    compile_scoped(&mut world, doc, "$sumsq(x, y)$", "nest_func_returning_math");
}

#[test]
fn nest_math_in_box() {
    let mut world = TipWorld::new();
    // Box with styling wrapping math inside a show rule
    let doc = "\
#show math.equation: it => {
  box(stroke: 1pt + blue, inset: 4pt, radius: 2pt, fill: blue.lighten(90%), it)
}
Styled $a + b$";
    compile_scoped(&mut world, doc, "$a + b$", "nest_math_in_box");
}

#[test]
fn nest_set_inside_content_block() {
    let mut world = TipWorld::new();
    // Set rule inside content block affects only that block's math
    let doc = "\
Outer $a$
#[
  #set text(fill: red)
  Inner $a + b$
]";
    compile_scoped(&mut world, doc, "$a + b$", "nest_set_inside_content_block");
}
