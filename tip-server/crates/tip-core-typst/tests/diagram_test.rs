use tip_core_typst::bottom_up::BottomUpCompiler;
use tip_core_typst::world::TipWorld;

fn write_svg(name: &str, svg: &str) {
    let path = format!("{}/test-output/{}.svg",
        env!("CARGO_MANIFEST_DIR").replace("/crates/tip-core-typst", ""), name);
    std::fs::write(&path, svg).unwrap();
    eprintln!("wrote {path}");
}

fn fixtures_dir() -> String {
    format!("{}/tests/fixtures", env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn cetz_canvas_compiles() {
    let mut world = TipWorld::builder().root(fixtures_dir()).build();
    let doc = std::fs::read_to_string(format!("{}/diagrams.typ", fixtures_dir())).unwrap();

    // Find the first cetz.canvas call: #cetz.canvas({...})
    let needle = "#cetz.canvas({";
    let start = doc.find(needle).unwrap();
    // Find the matching closing })
    let mut depth = 0;
    let mut end = start;
    let bytes = doc.as_bytes();
    let mut found_open = false;
    for i in start..bytes.len() {
        if bytes[i] == b'{' { depth += 1; found_open = true; }
        if bytes[i] == b'}' { depth -= 1; }
        if found_open && depth == 0 {
            // Skip past the closing )
            end = i + 1;
            if end < bytes.len() && bytes[end] == b')' { end += 1; }
            break;
        }
    }

    let content = &doc[start..end];
    eprintln!("cetz fragment ({} bytes): {:?}...", content.len(),
              &content[..content.len().min(60)]);

    // Use display page setup (no baseline crop)
    let page_setup = "#set page(height: auto, width: auto, margin: 0.5cm, fill: none)\n";
    let result = BottomUpCompiler::compile_fragment_scoped(
        &mut world, &doc, start, end, "#000000",
        Some(page_setup), None, None,
    );
    match &result {
        Ok(out) => {
            write_svg("diagram_cetz", &out.svg);
            eprintln!("cetz: OK h={:.1}pt", out.height_pt);
            assert!(out.svg.contains("<svg"));
            assert!(out.height_pt > 0.0);
        }
        Err(e) => {
            eprintln!("cetz: FAIL {e}");
            panic!("cetz diagram should compile");
        }
    }
}

#[test]
fn fletcher_diagram_compiles() {
    let mut world = TipWorld::builder().root(fixtures_dir()).build();
    let doc = std::fs::read_to_string(format!("{}/diagrams.typ", fixtures_dir())).unwrap();

    // Find the first #diagram( call
    let needle = "#diagram(\n  node((0, 0), $A$)";
    let start = doc.find(needle).unwrap();
    // Find matching closing )
    let bytes = doc.as_bytes();
    let mut depth = 0;
    let mut end = start;
    for i in start..bytes.len() {
        if bytes[i] == b'(' { depth += 1; }
        if bytes[i] == b')' {
            depth -= 1;
            if depth == 0 {
                end = i + 1;
                break;
            }
        }
    }

    let content = &doc[start..end];
    eprintln!("fletcher fragment ({} bytes): {:?}...", content.len(),
              &content[..content.len().min(60)]);

    let page_setup = "#set page(height: auto, width: auto, margin: 0.5cm, fill: none)\n";
    let result = BottomUpCompiler::compile_fragment_scoped(
        &mut world, &doc, start, end, "#000000",
        Some(page_setup), None, None,
    );
    match &result {
        Ok(out) => {
            write_svg("diagram_fletcher", &out.svg);
            eprintln!("fletcher: OK h={:.1}pt", out.height_pt);
            assert!(out.svg.contains("<svg"));
            assert!(out.height_pt > 0.0);
        }
        Err(e) => {
            eprintln!("fletcher: FAIL {e}");
            panic!("fletcher diagram should compile");
        }
    }
}

#[test]
fn fletcher_commutative_square_compiles() {
    let mut world = TipWorld::builder().root(fixtures_dir()).build();
    let doc = std::fs::read_to_string(format!("{}/diagrams.typ", fixtures_dir())).unwrap();

    // Find the commutative square
    let needle = "#diagram(\n  node((0, 0), $X$)";
    let start = doc.find(needle).unwrap();
    let bytes = doc.as_bytes();
    let mut depth = 0;
    let mut end = start;
    for i in start..bytes.len() {
        if bytes[i] == b'(' { depth += 1; }
        if bytes[i] == b')' {
            depth -= 1;
            if depth == 0 { end = i + 1; break; }
        }
    }

    let page_setup = "#set page(height: auto, width: auto, margin: 0.5cm, fill: none)\n";
    let result = BottomUpCompiler::compile_fragment_scoped(
        &mut world, &doc, start, end, "#000000",
        Some(page_setup), None, None,
    );
    match &result {
        Ok(out) => {
            write_svg("diagram_square", &out.svg);
            eprintln!("square: OK h={:.1}pt w in SVG", out.height_pt);
        }
        Err(e) => panic!("commutative square failed: {e}"),
    }
}
