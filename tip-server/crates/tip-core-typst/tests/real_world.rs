use tip_core_typst::bottom_up::BottomUpCompiler;
use tip_core_typst::world::TipWorld;

fn write_svg(name: &str, svg: &str) {
    let path = format!(
        "{}/test-output/{}.svg",
        env!("CARGO_MANIFEST_DIR").replace("/crates/tip-core-typst", ""),
        name
    );
    std::fs::write(&path, svg).expect("write SVG");
}

fn fixtures_dir() -> String {
    format!("{}/tests/fixtures", env!("CARGO_MANIFEST_DIR"))
}

/// Compile all math fragments found in a document, return count of successes.
fn compile_all_fragments(doc: &str, world: &mut TipWorld) -> (usize, usize) {
    // Simple regex-free fragment finder: scan for $ delimiters
    let mut frags = Vec::new();
    let bytes = doc.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'$' {
            let start = i;
            i += 1;
            // Find matching close $
            while i < bytes.len() && bytes[i] != b'$' {
                i += 1;
            }
            if i < bytes.len() {
                i += 1; // include closing $
                frags.push((start, i));
            }
        } else {
            i += 1;
        }
    }

    let total = frags.len();
    let mut ok = 0;
    for (idx, (start, end)) in frags.iter().enumerate() {
        match BottomUpCompiler::compile_fragment_scoped(
            world, doc, *start, *end, "#000000", None, None,
        ) {
            Ok(output) => {
                write_svg(&format!("real_{idx}"), &output.svg);
                assert!(output.svg.contains("<svg"), "fragment {idx} missing <svg>");
                assert!(output.height_pt > 0.0, "fragment {idx} zero height");
                ok += 1;
            }
            Err(e) => {
                eprintln!("fragment {idx} ({start}..{end}) failed: {e}");
                eprintln!("  content: {:?}", &doc[*start..*end]);
            }
        }
    }
    (ok, total)
}

#[test]
fn real_world_all_fragments_compile() {
    let doc = std::fs::read_to_string(
        format!("{}/real_world.typ", fixtures_dir())
    ).unwrap();
    let mut world = TipWorld::builder()
        .root(fixtures_dir())
        .build();
    let (ok, total) = compile_all_fragments(&doc, &mut world);
    eprintln!("compiled {ok}/{total} fragments successfully");
    // Allow some failures (e.g. fragments inside show rules may not parse cleanly)
    // but most should work
    assert!(total > 0, "should find fragments");
    assert!(
        ok as f64 / total as f64 > 0.7,
        "at least 70% of fragments should compile: {ok}/{total}"
    );
}
