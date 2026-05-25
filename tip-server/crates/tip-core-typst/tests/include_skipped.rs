use tip_core_typst::bottom_up::BottomUpCompiler;

#[test]
fn include_is_omitted_from_skeleton() {
    let doc = "#include \"other.typ\"\n#let x = 1\n$x + 1$\n";
    let frag_start = doc.find("$x").unwrap();
    let frag_end = doc.rfind('$').unwrap() + 1;
    let src = BottomUpCompiler::debug_scoped_source(doc, frag_start, frag_end).unwrap();
    assert!(!src.contains("include"), "skeleton must drop #include:\n{src}");
    assert!(src.contains("#let x"), "skeleton must keep #let:\n{src}");
}
