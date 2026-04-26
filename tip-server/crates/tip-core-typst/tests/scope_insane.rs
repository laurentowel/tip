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

fn compile_scoped(world: &mut TipWorld, doc: &str, needle: &str, name: &str) {
    let frag_start = doc.find(needle).expect(&format!("needle {needle:?} not found"));
    let frag_end = frag_start + needle.len();
    let out = BottomUpCompiler::compile_fragment_scoped(
        world, doc, frag_start, frag_end, "#000000", None, None,
    )
    .expect(&format!("{name} should compile"));
    write_svg(name, &out.svg);
    eprintln!("{name}: height={:.2}pt", out.height_pt);
}

// ┌──────────────────────────┬──────────────────────────────────────────────────────────┬──────────────────────────────┐
// │ SVG filename             │ What it tests                                            │ Expected rendering           │
// ├──────────────────────────┼──────────────────────────────────────────────────────────┼──────────────────────────────┤
// │ insane_recursive_op      │ let defines operator via other lets recursively          │ (((α⊕β)⊕γ)⊕δ)               │
// │ insane_show_rewrite      │ show rule underlines + colors all inline equations       │ red underlined a+b           │
// │ insane_matrix_let        │ let builds a matrix constructor, used in math            │ 2×2 identity matrix          │
// │ insane_shadow_chain      │ 4 shadows of same name, innermost wins                  │ δ                            │
// │ insane_set_cascade       │ set text size, then show scales it 2x, then set color   │ large blue equation          │
// │ insane_conditional_let   │ let assigned via if/else                                 │ ∞                            │
// │ insane_greek_soup        │ 10 greek lets composed in one equation                   │ αβγδεζηθικ                   │
// │ insane_operator_override │ show rule replaces + with ⊕ in all equations             │ a⊕b                         │
// └──────────────────────────┴──────────────────────────────────────────────────────────┴──────────────────────────────┘

#[test]
fn insane_recursive_op() {
    let mut world = TipWorld::new();
    let doc = "\
#let oplus = sym.plus.o
#let aa = sym.alpha
#let bb = sym.beta
#let cc = sym.gamma
#let dd = sym.delta
#let fold(..args) = {
  let items = args.pos()
  let result = items.first()
  for item in items.slice(1) {
    result = $( #result oplus #item )$
  }
  result
}
Result: $#fold(aa, bb, cc, dd)$";
    compile_scoped(&mut world, doc, "$#fold(aa, bb, cc, dd)$", "insane_recursive_op");
}

#[test]
fn insane_show_rewrite() {
    let mut world = TipWorld::new();
    // Show rule that underlines all inline equations and makes them red
    let doc = "\
#show math.equation.where(block: false): it => {
  text(fill: red, underline(it))
}
Check $a + b$";
    compile_scoped(&mut world, doc, "$a + b$", "insane_show_rewrite");
}

#[test]
fn insane_matrix_let() {
    let mut world = TipWorld::new();
    let doc = "\
#let eye = math.mat(
  (1, 0),
  (0, 1),
)
The matrix $eye$";
    compile_scoped(&mut world, doc, "$eye$", "insane_matrix_let");
}

#[test]
fn insane_shadow_chain() {
    let mut world = TipWorld::new();
    // 4 nested shadows of `zz`, only innermost (δ) should be visible
    let doc = "\
#let zz = sym.alpha
#{
  let zz = sym.beta
  {
    let zz = sym.gamma
    {
      let zz = sym.delta
      $zz$
    }
  }
}";
    compile_scoped(&mut world, doc, "$zz$", "insane_shadow_chain");
}

#[test]
fn insane_set_cascade() {
    let mut world = TipWorld::new();
    // Large blue math: set size, show rule doubles it, set color
    let doc = "\
#set text(size: 10pt)
#show math.equation: set text(size: 20pt)
#set text(fill: blue)
Go $a + b$";
    compile_scoped(&mut world, doc, "$a + b$", "insane_set_cascade");
}

#[test]
fn insane_conditional_let() {
    let mut world = TipWorld::new();
    let doc = "\
#let finite = false
#let val = if finite { sym.emptyset } else { sym.infinity }
Result $val$";
    compile_scoped(&mut world, doc, "$val$", "insane_conditional_let");
}

#[test]
fn insane_greek_soup() {
    let mut world = TipWorld::new();
    let doc = "\
#let aa = sym.alpha
#let bb = sym.beta
#let cc = sym.gamma
#let dd = sym.delta
#let ee = sym.epsilon
#let zz = sym.zeta
#let hh = sym.eta
#let tt = sym.theta
#let ii = sym.iota
#let kk = sym.kappa
Soup $aa bb cc dd ee zz hh tt ii kk$";
    compile_scoped(&mut world, doc, "$aa bb cc dd ee zz hh tt ii kk$", "insane_greek_soup");
}

#[test]
fn insane_operator_override() {
    let mut world = TipWorld::new();
    // Show rule replaces all + in math with ⊕
    let doc = "\
#show math.equation: it => {
  show sym.plus: sym.plus.circle
  it
}
Formula $a + b$";
    compile_scoped(&mut world, doc, "$a + b$", "insane_operator_override");
}
