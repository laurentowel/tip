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

// ┌──────────────────────────┬──────────────────────────────────────────────────────┬──────────────────────────────┐
// │ SVG filename             │ What it tests                                        │ Expected rendering           │
// ├──────────────────────────┼──────────────────────────────────────────────────────┼──────────────────────────────┤
// │ style_inline_sum         │ $sum_(i=0)^n i$ — inline: limits to the side         │ Σ with i=0 and n as sub/sup  │
// │ style_display_sum        │ $ sum_(i=0)^n i $ — display: limits above/below      │ Σ with i=0 below, n above    │
// │ style_inline_frac        │ $frac(a,b)$ — inline: compact fraction               │ small a/b                    │
// │ style_display_frac       │ $ frac(a,b) $ — display: full-size fraction          │ large a/b with bar           │
// │ style_inline_integral    │ $integral_0^1 f(x) dif x$ — inline                  │ ∫ with 0,1 to the side       │
// │ style_display_integral   │ $ integral_0^1 f(x) dif x $ — display               │ ∫ with 0 below, 1 above      │
// │ style_inline_product     │ $product_(k=1)^n k$ — inline                         │ Π with k=1,n to the side     │
// │ style_display_product    │ $ product_(k=1)^n k $ — display                      │ Π with k=1 below, n above    │
// └──────────────────────────┴──────────────────────────────────────────────────────┴──────────────────────────────┘

#[test]
fn style_inline_sum() {
    let mut world = TipWorld::new();
    let doc = "Text $sum_(i=0)^n i$ more text";
    let needle = "$sum_(i=0)^n i$";
    let start = doc.find(needle).unwrap();
    let out = FragmentCompiler::compile_fragment_scoped(
        &mut world, doc, start, start + needle.len(), "#000000", None, None,
    ).unwrap();
    write_svg("style_inline_sum", &out.svg);
    eprintln!("inline sum: {:.2}pt", out.height_pt);
}

#[test]
fn style_display_sum() {
    let mut world = TipWorld::new();
    let doc = "Text\n$ sum_(i=0)^n i $\nmore text";
    let needle = "$ sum_(i=0)^n i $";
    let start = doc.find(needle).unwrap();
    let out = FragmentCompiler::compile_fragment_scoped(
        &mut world, doc, start, start + needle.len(), "#000000", None, None,
    ).unwrap();
    write_svg("style_display_sum", &out.svg);
    eprintln!("display sum: {:.2}pt", out.height_pt);
}

#[test]
fn style_inline_frac() {
    let mut world = TipWorld::new();
    let doc = "Text $frac(a,b)$ more";
    let needle = "$frac(a,b)$";
    let start = doc.find(needle).unwrap();
    let out = FragmentCompiler::compile_fragment_scoped(
        &mut world, doc, start, start + needle.len(), "#000000", None, None,
    ).unwrap();
    write_svg("style_inline_frac", &out.svg);
    eprintln!("inline frac: {:.2}pt", out.height_pt);
}

#[test]
fn style_display_frac() {
    let mut world = TipWorld::new();
    let doc = "Text\n$ frac(a,b) $\nmore";
    let needle = "$ frac(a,b) $";
    let start = doc.find(needle).unwrap();
    let out = FragmentCompiler::compile_fragment_scoped(
        &mut world, doc, start, start + needle.len(), "#000000", None, None,
    ).unwrap();
    write_svg("style_display_frac", &out.svg);
    eprintln!("display frac: {:.2}pt", out.height_pt);
}

#[test]
fn style_inline_integral() {
    let mut world = TipWorld::new();
    let doc = "Text $integral_0^1 f(x) dif x$ more";
    let needle = "$integral_0^1 f(x) dif x$";
    let start = doc.find(needle).unwrap();
    let out = FragmentCompiler::compile_fragment_scoped(
        &mut world, doc, start, start + needle.len(), "#000000", None, None,
    ).unwrap();
    write_svg("style_inline_integral", &out.svg);
    eprintln!("inline integral: {:.2}pt", out.height_pt);
}

#[test]
fn style_display_integral() {
    let mut world = TipWorld::new();
    let doc = "Text\n$ integral_0^1 f(x) dif x $\nmore";
    let needle = "$ integral_0^1 f(x) dif x $";
    let start = doc.find(needle).unwrap();
    let out = FragmentCompiler::compile_fragment_scoped(
        &mut world, doc, start, start + needle.len(), "#000000", None, None,
    ).unwrap();
    write_svg("style_display_integral", &out.svg);
    eprintln!("display integral: {:.2}pt", out.height_pt);
}

#[test]
fn style_inline_product() {
    let mut world = TipWorld::new();
    let doc = "Text $product_(k=1)^n k$ more";
    let needle = "$product_(k=1)^n k$";
    let start = doc.find(needle).unwrap();
    let out = FragmentCompiler::compile_fragment_scoped(
        &mut world, doc, start, start + needle.len(), "#000000", None, None,
    ).unwrap();
    write_svg("style_inline_product", &out.svg);
    eprintln!("inline product: {:.2}pt", out.height_pt);
}

#[test]
fn style_display_product() {
    let mut world = TipWorld::new();
    let doc = "Text\n$ product_(k=1)^n k $\nmore";
    let needle = "$ product_(k=1)^n k $";
    let start = doc.find(needle).unwrap();
    let out = FragmentCompiler::compile_fragment_scoped(
        &mut world, doc, start, start + needle.len(), "#000000", None, None,
    ).unwrap();
    write_svg("style_display_product", &out.svg);
    eprintln!("display product: {:.2}pt", out.height_pt);
}
