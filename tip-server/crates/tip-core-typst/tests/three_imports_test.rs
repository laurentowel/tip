use tip_core_typst::compiler::FragmentCompiler;
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

/// Find all math fragments by scanning for $ delimiters.
fn find_fragments(doc: &str) -> Vec<(usize, usize)> {
    let mut frags = Vec::new();
    let bytes = doc.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'$' {
            let start = i;
            i += 1;
            // Skip display math space
            let _display = i < bytes.len() && bytes[i] == b' ';
            // Find closing $
            let mut depth = 0u32;
            while i < bytes.len() {
                if bytes[i] == b'$' && depth == 0 {
                    break;
                }
                // Track nested content/code blocks to avoid false $ matches
                if bytes[i] == b'{' || bytes[i] == b'[' {
                    depth += 1;
                } else if (bytes[i] == b'}' || bytes[i] == b']') && depth > 0 {
                    depth -= 1;
                }
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
    frags
}

// ┌──────────────────────────┬──────────────────────────────────────────────────────┐
// │ What it tests            │ Expected                                             │
// ├──────────────────────────┼──────────────────────────────────────────────────────┤
// │ Relative import          │ ℂ, ℝ, ℤ, ℕ, ℚ, H (calligraphic) from mystyle.typ   │
// │ Local package @local/mmm │ SL, norm, iprod, colored math, restriction           │
// │ Remote @preview/fletcher │ Commutative diagram (SVG of diagram)                 │
// │ Mixed                    │ All three import sources in one equation              │
// └──────────────────────────┴──────────────────────────────────────────────────────┘

#[test]
fn three_imports_all_fragments() {
    let doc = std::fs::read_to_string(
        format!("{}/three_imports.typ", fixtures_dir()),
    )
    .unwrap();

    let mut world = TipWorld::builder().root(fixtures_dir()).build();

    let frags = find_fragments(&doc);
    eprintln!("found {} math fragments", frags.len());

    let mut ok = 0;
    let mut failed = 0;
    for (idx, (start, end)) in frags.iter().enumerate() {
        let content = &doc[*start..*end];
        match FragmentCompiler::compile_fragment_scoped(
            &mut world,
            &doc,
            *start,
            *end,
            "#000000",
            None,
            None,
        ) {
            Ok(output) => {
                write_svg(&format!("3imp_{idx}"), &output.svg);
                eprintln!(
                    "  [{idx}] OK  h={:.1}pt  {:?}",
                    output.height_pt,
                    if content.len() > 60 {
                        format!("{}...", &content[..57])
                    } else {
                        content.to_string()
                    }
                );
                ok += 1;
            }
            Err(e) => {
                eprintln!("  [{idx}] FAIL {:?}: {e}", &content[..content.len().min(60)]);
                failed += 1;
            }
        }
    }

    eprintln!("\n{ok}/{} fragments compiled ({failed} failed)", frags.len());
    assert!(frags.len() >= 10, "should find many fragments");
    assert!(
        ok as f64 / frags.len() as f64 > 0.7,
        "at least 70% should compile: {ok}/{}",
        frags.len()
    );
}
