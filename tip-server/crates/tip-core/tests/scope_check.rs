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
    let frag_start = doc.find(needle).expect("fragment not found in doc");
    let frag_end = frag_start + needle.len();
    let out = FragmentCompiler::compile_fragment_scoped(
        world, doc, frag_start, frag_end, "#000000", None, None,
    )
    .expect(&format!("{name} should compile"));
    write_svg(name, &out.svg);
    eprintln!("{name}: height={:.2}pt", out.height_pt);
}

// ┌─────────────────────────┬──────────────────────────────────────────────────────┬───────────────────────┐
// │ SVG filename            │ What it tests                                        │ Expected rendering    │
// ├─────────────────────────┼──────────────────────────────────────────────────────┼───────────────────────┤
// │ scope_top_level_let     │ #let at top-level defines math.cal, used in math     │ L(α) (calligraphic L) │
// │ scope_block_let         │ let inside #{ } defines symbol, used in math         │ β + β                 │
// │ scope_nested_blocks     │ lets at 3 nesting levels, all visible in math        │ α + β + γ             │
// │ scope_show_rule_font    │ #show math.equation sets Pennstander font            │ a+b=c in Pennstander  │
// │ scope_set_rule_color    │ #set text(fill: blue) from doc, not overridden       │ a+b in blue           │
// │ scope_multi_frag1       │ first of 3 frags sharing let defs (no extra text)    │ F (calligraphic)      │
// │ scope_multi_frag2       │ second of 3 frags (no extra text)                    │ G (calligraphic)      │
// │ scope_multi_frag3       │ third frag uses both defs (no extra text)            │ F∘G (calligraphic)    │
// └─────────────────────────┴──────────────────────────────────────────────────────┴───────────────────────┘

#[test]
fn visual_scope_top_level_let() {
    let mut world = TipWorld::new();
    // math.cal("L") is a multi-char math operator, resolves in math by name
    let doc = "#let al = sym.alpha\n#let cl = math.cal(\"L\")\nSome text $cl(al)$ more";
    compile_scoped(&mut world, doc, "$cl(al)$", "scope_top_level_let");
}

#[test]
fn visual_scope_block_let() {
    let mut world = TipWorld::new();
    // Multi-char name 'bb' resolves from scope in math
    let doc = "#{\n  let bb = sym.beta\n  $bb + bb$\n}";
    compile_scoped(&mut world, doc, "$bb + bb$", "scope_block_let");
}

#[test]
fn visual_scope_nested_blocks() {
    let mut world = TipWorld::new();
    // Three nesting levels with multi-char names
    let doc = "#let aa = sym.alpha\n#{\n  let bb = sym.beta\n  {\n    let cc = sym.gamma\n    $aa + bb + cc$\n  }\n}";
    compile_scoped(&mut world, doc, "$aa + bb + cc$", "scope_nested_blocks");
}

#[test]
fn visual_scope_show_rule() {
    let font_dir = format!(
        "{}/ref/Pennstander-ref/fonts/otf",
        env!("CARGO_MANIFEST_DIR").replace("/tip-server/crates/tip-core", ""),
    );
    let mut world = TipWorld::with_font_dirs(&[font_dir.as_str()]);
    let doc = "#show math.equation: set text(font: \"Pennstander Math\")\n$a + b = c$";
    compile_scoped(&mut world, doc, "$a + b = c$", "scope_show_rule_font");
}

#[test]
fn visual_scope_set_rule() {
    let mut world = TipWorld::new();
    // Document sets blue text — scoped compilation should preserve this
    let doc = "#set text(fill: blue)\n$a + b$";
    compile_scoped(&mut world, doc, "$a + b$", "scope_set_rule_color");
}

#[test]
fn visual_scope_multiple_fragments() {
    let mut world = TipWorld::new();
    // Should render ONLY the fragment, no surrounding text
    let doc = "#let ff = math.cal(\"F\")\n#let gg = math.cal(\"G\")\nFirst $ff$ then $gg$ then $ff compose gg$";

    compile_scoped(&mut world, doc, "$ff$", "scope_multi_frag1");
    compile_scoped(&mut world, doc, "$gg$", "scope_multi_frag2");
    compile_scoped(&mut world, doc, "$ff compose gg$", "scope_multi_frag3");
}
