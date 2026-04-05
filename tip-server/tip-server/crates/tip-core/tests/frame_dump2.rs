use typst::compile;
use typst::layout::{PagedDocument, Frame, FrameItem};
use tip_core::world::TipWorld;

fn dump(frame: &Frame, depth: usize, y_offset: f64) {
    let indent = " ".repeat(depth * 2);
    eprintln!("{indent}Frame h={:.2} bl={:.2} has_bl={} y_off={:.2}",
              frame.height().to_pt(),
              frame.baseline().to_pt(),
              frame.has_baseline(),
              y_offset);
    for (pos, item) in frame.items() {
        match item {
            FrameItem::Text(t) => {
                eprintln!("{indent}  Text y={:.3} size={:.1}pt text={:?}",
                          pos.y.to_pt(), t.size.to_pt(), t.text.as_str());
            }
            FrameItem::Group(g) => {
                eprintln!("{indent}  Group at y={:.3}:",
                          pos.y.to_pt());
                dump(&g.frame, depth + 1, y_offset + pos.y.to_pt());
            }
            _ => {}
        }
    }
}

fn compile_and_dump(world: &mut TipWorld, label: &str, source: &str) {
    world.set_main_source(source);
    let warned = compile::<PagedDocument>(world);
    let doc = warned.output.unwrap();
    let page = &doc.pages[0];
    eprintln!("\n=== {label} === page_h={:.2}", page.frame.height().to_pt());
    dump(&page.frame, 0, 0.0);
}

#[test]
fn dump_frames_with_and_without_bounded() {
    let mut world = TipWorld::new();

    // WITHOUT bounded
    eprintln!("\n########## WITHOUT bounded ##########");
    for (label, math) in [
        ("a+b", "$a + b$"),
        ("a_b", "$a_b$"),
        ("frac", "$frac(a,b)$"),
    ] {
        let src = format!(
            "#set page(height: auto, width: auto, margin: 0pt, fill: none)\n{math}\n"
        );
        compile_and_dump(&mut world, &format!("NO-BND {label}"), &src);
    }

    // WITH bounded
    eprintln!("\n########## WITH bounded ##########");
    for (label, math) in [
        ("a+b", "$a + b$"),
        ("a_b", "$a_b$"),
        ("frac", "$frac(a,b)$"),
    ] {
        let src = format!(
            "#let bounded(eq) = text(top-edge: \"bounds\", bottom-edge: \"bounds\", eq)\n\
             #show math.equation: bounded\n\
             #set page(height: auto, width: auto, margin: 0pt, fill: none)\n{math}\n"
        );
        compile_and_dump(&mut world, &format!("BND {label}"), &src);
    }
}
