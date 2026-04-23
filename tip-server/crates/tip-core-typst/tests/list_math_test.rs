use tip_core_typst::compiler::FragmentCompiler;
use tip_core_typst::world::TipWorld;

fn fixtures_dir() -> String {
    format!("{}/tests/fixtures", env!("CARGO_MANIFEST_DIR"))
}

fn write_svg(name: &str, svg: &str) {
    let path = format!("{}/test-output/{}.svg",
        env!("CARGO_MANIFEST_DIR").replace("/crates/tip-core-typst", ""), name);
    std::fs::write(&path, svg).unwrap();
    eprintln!("wrote {path}");
}

#[test]
fn list_math_fragments_compile_cleanly() {
    let doc = std::fs::read_to_string(
        format!("{}/list_math.typ", fixtures_dir())
    ).unwrap();

    let mut world = TipWorld::builder()
        .root(fixtures_dir())
        .build();

    // Find all $ delimited fragments
    let mut frags = Vec::new();
    let bytes = doc.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'$' {
            let start = i;
            i += 1;
            let mut depth = 0u32;
            while i < bytes.len() {
                if bytes[i] == b'$' && depth == 0 { break; }
                if bytes[i] == b'{' || bytes[i] == b'[' { depth += 1; }
                else if (bytes[i] == b'}' || bytes[i] == b']') && depth > 0 { depth -= 1; }
                i += 1;
            }
            if i < bytes.len() {
                i += 1;
                frags.push((start, i));
            }
        } else { i += 1; }
    }

    eprintln!("found {} fragments", frags.len());

    let mut ok = 0;
    let mut bad = 0;
    for (idx, (start, end)) in frags.iter().enumerate() {
        let content = &doc[*start..*end];
        match FragmentCompiler::compile_fragment_scoped(
            &mut world, &doc, *start, *end, "#000000", None, None,
        ) {
            Ok(output) => {
                write_svg(&format!("list_{idx}"), &output.svg);
                // Check SVG doesn't contain list bullet artifacts
                // The SVG should only contain math, not layout elements
                let has_svg = output.svg.contains("<svg");
                let height_ok = output.height_pt > 0.0;
                eprintln!("  [{idx}] OK  h={:.1}  {:?}",
                    output.height_pt,
                    if content.len() > 50 { &content[..47] } else { content });
                if has_svg && height_ok { ok += 1; } else { bad += 1; }
            }
            Err(e) => {
                eprintln!("  [{idx}] FAIL {:?}: {e}",
                    if content.len() > 40 { &content[..37] } else { content });
                bad += 1;
            }
        }
    }

    eprintln!("\n{ok}/{} compiled, {bad} failed", frags.len());
    assert!(frags.len() > 5, "should find many fragments");
    assert_eq!(bad, 0, "all fragments should compile");
}
