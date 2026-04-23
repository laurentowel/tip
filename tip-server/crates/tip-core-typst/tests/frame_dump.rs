use tip_core_typst::compiler::FragmentCompiler;
use tip_core_typst::world::TipWorld;

#[test]
fn dump_frame_structures() {
    let mut world = TipWorld::new();
    for (label, content) in [
        ("a+b", "$a + b$"),
        ("a^a", "$a^a$"),
        ("a_b", "$a_b$"),
        ("frac", "$frac(a,b)$"),
    ] {
        let out = FragmentCompiler::compile_fragment(
            &mut world, content, "#000000", "",
        ).unwrap();
        eprintln!("{label:5}: h={:.2}pt d={:.2}pt ascent={:.0}%",
                  out.height_pt, out.depth_pt,
                  if out.height_pt > 0.0 { 100.0 * (1.0 - out.depth_pt / out.height_pt) } else { 0.0 });
    }

    // Now test: what does ascent=center mean numerically?
    // center = 50 for Emacs
    // Our values: a+b=89%, a^a=?, a_b=64%, frac=24%
    // If center (50%) aligns baselines, then maybe the baseline
    // is at 50% of the image height for simple text?
    eprintln!();
    eprintln!("If center (50%) aligns baselines correctly,");
    eprintln!("it means the math baseline is at the vertical center");
    eprintln!("of the bounded glyph box for simple expressions.");
    eprintln!("Our text-item y-position approach may be finding");
    eprintln!("the wrong reference point.");
}
