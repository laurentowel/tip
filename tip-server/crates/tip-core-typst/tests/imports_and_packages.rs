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

fn fixtures_dir() -> String {
    format!(
        "{}/tests/fixtures",
        env!("CARGO_MANIFEST_DIR"),
    )
}

fn compile_scoped_with_root(
    root: &str,
    font_dirs: &[&str],
    doc: &str,
    needle: &str,
    name: &str,
) {
    let mut world = TipWorld::builder()
        .root(root)
        .build();
    for dir in font_dirs {
        // Rebuild with font dirs if needed — for simplicity just use new
        let _ = dir;
    }
    // Set root for import resolution
    let frag_start = doc.find(needle).expect(&format!("needle {needle:?} not found"));
    let frag_end = frag_start + needle.len();
    let out = BottomUpCompiler::compile_fragment_scoped(
        &mut world, doc, frag_start, frag_end, "#000000", None, None,
    )
    .expect(&format!("{name} should compile"));
    write_svg(name, &out.svg);
    eprintln!("{name}: height={:.2}pt", out.height_pt);
}

// ┌───────────────────────────┬───────────────────────────────────────────────────────┬──────────────────────┐
// │ SVG filename              │ What it tests                                         │ Expected rendering   │
// ├───────────────────────────┼───────────────────────────────────────────────────────┼──────────────────────┤
// │ import_wildcard           │ #import "utils.typ": * — all symbols available         │ ℝ³                   │
// │ import_named              │ #import "utils.typ": RR, CC — selective import         │ ℝ × ℂ                │
// │ import_renamed            │ #import "utils.typ": RR as Reals — renamed import      │ Reals (ℝ)            │
// │ import_function           │ #import "utils.typ": norm — import a function          │ ‖x‖                  │
// │ import_multi_file         │ imports from two files, both in scope                  │ ℝ ⊗ ℤ                │
// │ import_nested_scope       │ import inside a code block, fragment inside block      │ ℂ                    │
// │ import_with_let           │ import + local let, both in scope                      │ ℝⁿ                   │
// └───────────────────────────┴───────────────────────────────────────────────────────┴──────────────────────┘

#[test]
fn import_wildcard() {
    let root = fixtures_dir();
    let doc = "#import \"utils.typ\": *\nSpace $RR^3$";
    compile_scoped_with_root(&root, &[], doc, "$RR^3$", "import_wildcard");
}

#[test]
fn import_named() {
    let root = fixtures_dir();
    let doc = "#import \"utils.typ\": RR, CC\nField $RR times CC$";
    compile_scoped_with_root(&root, &[], doc, "$RR times CC$", "import_named");
}

#[test]
fn import_renamed() {
    let root = fixtures_dir();
    let doc = "#import \"utils.typ\": RR as Reals\nThe $Reals$";
    compile_scoped_with_root(&root, &[], doc, "$Reals$", "import_renamed");
}

#[test]
fn import_function() {
    let root = fixtures_dir();
    let doc = "#import \"utils.typ\": norm\nValue $norm(x)$";
    compile_scoped_with_root(&root, &[], doc, "$norm(x)$", "import_function");
}

#[test]
fn import_multi_file() {
    let root = fixtures_dir();
    let doc = "#import \"utils.typ\": RR, ZZ\n#import \"operators.typ\": tensor\nResult $RR tensor ZZ$";
    compile_scoped_with_root(&root, &[], doc, "$RR tensor ZZ$", "import_multi_file");
}

#[test]
fn import_nested_scope() {
    let root = fixtures_dir();
    let doc = "#{\n  import \"utils.typ\": CC\n  $CC$\n}";
    compile_scoped_with_root(&root, &[], doc, "$CC$", "import_nested_scope");
}

#[test]
fn import_with_let() {
    let root = fixtures_dir();
    let doc = "#import \"utils.typ\": RR\n#let nn = \"n\"\nDimension $RR^nn$";
    compile_scoped_with_root(&root, &[], doc, "$RR^nn$", "import_with_let");
}
