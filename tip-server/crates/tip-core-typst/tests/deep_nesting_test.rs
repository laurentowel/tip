use tip_core_typst::bottom_up::BottomUpCompiler;
use tip_core_typst::world::TipWorld;

fn fixtures_dir() -> String {
    format!("{}/tests/fixtures", env!("CARGO_MANIFEST_DIR"))
}

fn find_fragments(doc: &str) -> Vec<(usize, usize)> {
    let mut frags = Vec::new();
    let bytes = doc.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'$' {
            let start = i;
            i += 1;
            let mut depth = 0u32;
            while i < bytes.len() {
                if bytes[i] == b'$' && depth == 0 {
                    break;
                }
                if bytes[i] == b'{' || bytes[i] == b'[' {
                    depth += 1;
                } else if (bytes[i] == b'}' || bytes[i] == b']') && depth > 0 {
                    depth -= 1;
                }
                i += 1;
            }
            if i < bytes.len() {
                i += 1;
                frags.push((start, i));
            }
        } else {
            i += 1;
        }
    }
    frags
}

#[test]
fn deep_nesting_all_fragments_compile() {
    let doc = std::fs::read_to_string(format!("{}/deep_nesting.typ", fixtures_dir())).unwrap();

    let mut world = TipWorld::builder().root(fixtures_dir()).build();

    let frags = find_fragments(&doc);
    eprintln!("found {} fragments in deep_nesting.typ", frags.len());

    let mut ok = 0;
    let mut failed = 0;
    let mut failures = Vec::new();

    for (idx, (start, end)) in frags.iter().enumerate() {
        let content = &doc[*start..*end];
        let short = if content.len() > 45 {
            format!("{}...", &content[..42])
        } else {
            content.to_string()
        };

        match BottomUpCompiler::compile_fragment_scoped(
            &mut world, &doc, *start, *end, "#000000", None, None, None,
        ) {
            Ok(output) => {
                assert!(output.svg.contains("<svg"), "[{idx}] missing <svg>");
                assert!(output.height_pt > 0.0, "[{idx}] zero height");
                eprintln!("  [{idx:2}] OK  h={:5.1}  {short:?}", output.height_pt);
                ok += 1;
            }
            Err(e) => {
                let short_err = if e.len() > 60 {
                    format!("{}...", &e[..57])
                } else {
                    e.clone()
                };
                eprintln!("  [{idx:2}] FAIL {short:?}: {short_err}");
                failures.push((idx, short, e));
                failed += 1;
            }
        }
    }

    eprintln!("\n{ok}/{} compiled, {failed} failed", frags.len());
    if !failures.is_empty() {
        eprintln!("\nFailures:");
        for (idx, content, err) in &failures {
            eprintln!("  [{idx}] {content:?}: {err}");
        }
    }

    assert!(
        frags.len() >= 40,
        "should find many fragments, got {}",
        frags.len()
    );
    assert_eq!(
        failed,
        0,
        "{failed}/{} fragments failed to compile",
        frags.len()
    );
}
