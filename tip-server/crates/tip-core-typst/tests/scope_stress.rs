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
    let frag_start = doc
        .find(needle)
        .expect(&format!("needle {needle:?} not found"));
    let frag_end = frag_start + needle.len();
    let out = BottomUpCompiler::compile_fragment_scoped(
        world, doc, frag_start, frag_end, "#000000", None, None, None,
    )
    .expect(&format!("{name} should compile"));
    write_svg(name, &out.svg);
    eprintln!("{name}: height={:.2}pt", out.height_pt);
}

// ┌──────────────────────────┬─────────────────────────────────────────────────────────┬─────────────────────┐
// │ SVG filename             │ What it tests                                           │ Expected rendering  │
// ├──────────────────────────┼─────────────────────────────────────────────────────────┼─────────────────────┤
// │ stress_shadow            │ inner let shadows outer let of same name                │ β  (not α)          │
// │ stress_closure           │ let defines a closure, called in math                   │ x²+1                │
// │ stress_chained_let       │ let depends on previous let                             │ double-struck R³    │
// │ stress_show_set_combo    │ show rule + set rule both in scope                      │ red italic a+b      │
// │ stress_deep_nest         │ 5 levels of nested code blocks                          │ 5 (the number)      │
// │ stress_set_overrides     │ two set rules, later one wins                           │ 16pt sized a+b      │
// │ stress_content_block     │ let inside content block scope [...], fragment inside    │ ω                   │
// │ stress_for_scope         │ fragment after a for loop (loop var NOT in scope)        │ just "x"            │
// │ stress_multi_import_let  │ many lets before fragment, all in scope                 │ A·B·C·D·E           │
// │ stress_equation_numbering│ show rule modifies equation numbering/display            │ a=b (with custom)   │
// └──────────────────────────┴─────────────────────────────────────────────────────────┴─────────────────────┘

#[test]
fn stress_shadow() {
    let mut world = TipWorld::new();
    // Inner let shadows outer — fragment should see β, not α
    let doc = "\
#let xx = sym.alpha
#{
  let xx = sym.beta
  $xx$
}";
    compile_scoped(&mut world, doc, "$xx$", "stress_shadow");
}

#[test]
fn stress_closure() {
    let mut world = TipWorld::new();
    // Closure defined via let, called with argument in math
    let doc = "\
#let sq(x) = $x^2 + 1$
Result: $sq(x)$";
    compile_scoped(&mut world, doc, "$sq(x)$", "stress_closure");
}

#[test]
fn stress_chained_let() {
    let mut world = TipWorld::new();
    // Second let depends on first
    let doc = "\
#let RR = math.bb(\"R\")
#let dim = 3
Space $RR^dim$";
    compile_scoped(&mut world, doc, "$RR^dim$", "stress_chained_let");
}

#[test]
fn stress_show_set_combo() {
    let mut world = TipWorld::new();
    // Both show and set rules affect the fragment
    let doc = "\
#show math.equation: set text(fill: red)
#set text(style: \"italic\")
Formula $a + b$";
    compile_scoped(&mut world, doc, "$a + b$", "stress_show_set_combo");
}

#[test]
fn stress_deep_nest() {
    let mut world = TipWorld::new();
    // 5 levels of nesting, each adds 1
    let doc = "\
#let a = 1
#{
  let b = 1
  {
    let c = 1
    {
      let d = 1
      {
        let e = 1
        $a + b + c + d + e$
      }
    }
  }
}";
    compile_scoped(&mut world, doc, "$a + b + c + d + e$", "stress_deep_nest");
}

#[test]
fn stress_set_overrides() {
    let mut world = TipWorld::new();
    // Second set rule overrides first — should be 16pt
    let doc = "\
#set text(size: 8pt)
#set text(size: 16pt)
Big $a + b$";
    compile_scoped(&mut world, doc, "$a + b$", "stress_set_overrides");
}

#[test]
fn stress_content_block() {
    let mut world = TipWorld::new();
    // Let inside a content block [...], fragment inside it
    let doc = "\
#let outer = sym.alpha
#[
  #let inner = sym.omega
  Math: $inner$
]";
    compile_scoped(&mut world, doc, "$inner$", "stress_content_block");
}

#[test]
fn stress_for_scope() {
    let mut world = TipWorld::new();
    // Loop variable `i` is NOT in scope after the loop — just renders italic x
    let doc = "\
#for i in range(3) {
  // loop body
}
After loop $x$";
    compile_scoped(&mut world, doc, "$x$", "stress_for_scope");
}

#[test]
fn stress_multi_import_let() {
    let mut world = TipWorld::new();
    // Many lets, all should be in scope
    let doc = "\
#let AA = math.bold(\"A\")
#let BB = math.bold(\"B\")
#let CC = math.bold(\"C\")
#let DD = math.bold(\"D\")
#let EE = math.bold(\"E\")
Product $AA dot BB dot CC dot DD dot EE$";
    compile_scoped(
        &mut world,
        doc,
        "$AA dot BB dot CC dot DD dot EE$",
        "stress_multi_import_let",
    );
}

#[test]
fn stress_equation_numbering() {
    let mut world = TipWorld::new();
    // Show rule that wraps equations in a box with color
    let doc = "\
#show math.equation: it => {
  box(stroke: 0.5pt + blue, inset: 3pt, it)
}
Boxed $a = b$";
    compile_scoped(&mut world, doc, "$a = b$", "stress_equation_numbering");
}
