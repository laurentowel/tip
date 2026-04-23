use typst::compile;
use typst::layout::{PagedDocument, Frame, FrameItem};
use tip_core_typst::world::TipWorld;

fn dump_all(frame: &Frame, depth: usize, y_off: f64) {
    let indent = " ".repeat(depth * 2);
    for (pos, item) in frame.items() {
        let y = y_off + pos.y.to_pt();
        match item {
            FrameItem::Text(t) => eprintln!("{indent}Text y={:.2} sz={:.1} {:?}", y, t.size.to_pt(), t.text.as_str()),
            FrameItem::Shape(_, _) => eprintln!("{indent}Shape y={:.2}", y),
            FrameItem::Group(g) => {
                eprintln!("{indent}Group y={:.2}:", y);
                dump_all(&g.frame, depth+1, y);
            }
            _ => eprintln!("{indent}Other y={:.2}", y),
        }
    }
}

#[test]
fn dump_multiple() {
    let mut world = TipWorld::new();
    for (label, math) in [
        ("a+b", "$a + b$"),
        ("a_b", "$a_b$"),
        ("a^a", "$a^a$"),
        ("frac", "$frac(a,b)$"),
        ("x_ij", "$x_(i_j)$"),
    ] {
        let src = format!(
            "#set page(height: auto, width: auto, margin: (top: 20pt, bottom: 20pt, rest: 0pt), fill: none)\n{math}\n"
        );
        world.set_main_source(&src);
        let doc = compile::<PagedDocument>(&world).output.unwrap();
        let page = &doc.pages[0];
        eprintln!("\n=== {label} === page_h={:.2}", page.frame.height().to_pt());
        dump_all(&page.frame, 0, 0.0);
    }
}
