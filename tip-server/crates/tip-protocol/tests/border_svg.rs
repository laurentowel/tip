//! Exhaustive tests for `tip_protocol::svg_color::add_viewbox_border`.
//!
//! The function is a general SVG transformer: insert a
//! `<rect stroke="currentColor">' that traces the inside of the
//! existing viewBox, half-stroke-inset so the visible line stays
//! within bounds.  The SVG's outer dimensions and the inner content
//! are otherwise untouched — Emacs renders the image at the same
//! pixel size as before (no scaling artifacts from a grown
//! viewBox).  Tests exercise viewBox variants, attribute orderings,
//! fallback behavior, and content preservation.

use tip_protocol::svg_color::add_viewbox_border;

fn make_svg(opening_attrs: &str) -> String {
    format!("<svg {opening_attrs}><circle cx=\"5\" cy=\"5\" r=\"3\"/></svg>")
}

/// Pull `attr="VAL"` or `attr='VAL'` from the FIRST `<svg ...>` tag.
fn attr<'a>(svg: &'a str, attr: &str) -> Option<&'a str> {
    let tag_end = svg.find('>')?;
    let tag = &svg[..tag_end];
    for q in ['"', '\''] {
        let needle = format!("{attr}={q}");
        if let Some(s) = tag.find(&needle) {
            let val_start = s + needle.len();
            let val_end = tag[val_start..].find(q)? + val_start;
            return Some(&tag[val_start..val_end]);
        }
    }
    None
}

// ---- dimensions preserved: SVG is rewritten in place ----

#[test]
fn dimensions_unchanged() {
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.5, 0.5);
    assert_eq!(attr(&out, "width"), Some("10pt"));
    assert_eq!(attr(&out, "height"), Some("20pt"));
    assert_eq!(attr(&out, "viewBox"), Some("0 0 10 20"));
}

#[test]
fn nonzero_viewbox_origin_preserved() {
    // Inner viewBox doesn't start at (0,0) — must stay unchanged.
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="50 100 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.5, 0.5);
    assert_eq!(attr(&out, "viewBox"), Some("50 100 10 20"));
    assert_eq!(attr(&out, "width"), Some("10pt"));
}

// ---- the rect itself ----

#[test]
fn rect_uses_current_color_and_opacity() {
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.42, 0.5);
    assert!(out.contains("stroke=\"currentColor\""));
    assert!(out.contains("stroke-opacity=\"0.420\""));
    assert!(out.contains("fill=\"none\""));
}

#[test]
fn rect_sits_inside_viewbox_by_half_stroke() {
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.5, 1.0);
    // sw=1.0; rect inset by sw/2=0.5 on each side.
    // viewBox stays "0 0 10 20".
    // rect: x=0.5, y=0.5, w=10-1=9, h=20-1=19
    let rect = find_rect(&out);
    assert_eq!(attr_in_tag(rect, "x"), Some("0.500"));
    assert_eq!(attr_in_tag(rect, "y"), Some("0.500"));
    assert_eq!(attr_in_tag(rect, "width"), Some("9.000"));
    assert_eq!(attr_in_tag(rect, "height"), Some("19.000"));
}

#[test]
fn rect_offsets_from_nonzero_viewbox_origin() {
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="50 100 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.5, 1.0);
    let rect = find_rect(&out);
    assert_eq!(attr_in_tag(rect, "x"), Some("50.500"));
    assert_eq!(attr_in_tag(rect, "y"), Some("100.500"));
    assert_eq!(attr_in_tag(rect, "width"), Some("9.000"));
    assert_eq!(attr_in_tag(rect, "height"), Some("19.000"));
}

fn find_rect(svg: &str) -> &str {
    let start = svg.find("<rect ").expect("rect present");
    let end = svg[start..].find("/>").unwrap() + start + 2;
    &svg[start..end]
}

fn attr_in_tag<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    let needle = format!("{name}=\"");
    let s = tag.find(&needle)? + needle.len();
    let e = tag[s..].find('"')? + s;
    Some(&tag[s..e])
}

// ---- content preservation ----

#[test]
fn original_body_is_preserved_byte_for_byte() {
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.3, 0.5);
    // The <circle> from the original must still be there, intact.
    assert!(out.contains(r#"<circle cx="5" cy="5" r="3"/>"#));
    assert!(out.ends_with("</svg>"));
}

#[test]
fn other_svg_attrs_preserved() {
    // class, xmlns:xlink, etc. must survive unchanged.
    let svg = make_svg(
        r#"class="typst-doc" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10pt" height="20pt" viewBox="0 0 10 20""#,
    );
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.3, 0.5);
    assert!(out.contains("class=\"typst-doc\""));
    assert!(out.contains("xmlns=\"http://www.w3.org/2000/svg\""));
    assert!(out.contains("xmlns:xlink=\"http://www.w3.org/1999/xlink\""));
}

#[test]
fn single_quoted_attributes_are_recognized() {
    // dvisvgm (LaTeX backend) emits SVGs with SINGLE-quoted attributes:
    //   <svg width='10pt' height='20pt' viewBox='0 0 10 20' ...>
    // Both quote styles are valid per the SVG spec.  Must parse both
    // so the border lands at the right place.
    let svg = "<svg width='10pt' height='20pt' viewBox='0 0 10 20'><circle r='3'/></svg>";
    let out = add_viewbox_border(svg, 10.0, 20.0, 0.5, 1.0);
    // Rect was inserted (border applied).
    assert!(out.contains("<rect "), "rect missing from output:\n{out}");
    // Rect uses the parsed viewBox, not the fallback.
    let rect = find_rect(&out);
    assert_eq!(attr_in_tag(rect, "x"), Some("0.500"));
    assert_eq!(attr_in_tag(rect, "width"), Some("9.000"));
}

#[test]
fn single_quoted_nonzero_viewbox_origin() {
    // dvisvgm typically emits a non-zero viewBox origin (the
    // preview.sty tight-page box starts at e.g. `0 -8 ...`).
    let svg = "<svg width='10pt' height='20pt' viewBox='5 -8 10 20'><circle r='3'/></svg>";
    let out = add_viewbox_border(svg, 10.0, 20.0, 0.5, 1.0);
    let rect = find_rect(&out);
    assert_eq!(attr_in_tag(rect, "x"), Some("5.500"));
    assert_eq!(attr_in_tag(rect, "y"), Some("-7.500"));
    assert_eq!(attr_in_tag(rect, "width"), Some("9.000"));
    assert_eq!(attr_in_tag(rect, "height"), Some("19.000"));
}

#[test]
fn attribute_order_does_not_matter() {
    // width AFTER viewBox in source — both must still parse.
    let svg = make_svg(r#"viewBox="0 0 10 20" width="10pt" height="20pt""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.3, 0.5);
    assert!(out.contains("<rect "), "rect should be inserted");
    assert_eq!(attr(&out, "width"), Some("10pt"));
}

// ---- fallbacks + degenerate inputs ----

#[test]
fn opacity_zero_returns_input_unchanged() {
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.0, 0.5);
    assert_eq!(out, svg);
}

#[test]
fn negative_opacity_returns_input_unchanged() {
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, -0.1, 0.5);
    assert_eq!(out, svg);
}

#[test]
fn missing_viewbox_uses_fallback_dims_for_rect() {
    // No viewBox.  We pass fallback width=100, height=50 — those
    // define the rect's coordinate space.
    let svg = make_svg(r#"width="100pt" height="50pt""#);
    let out = add_viewbox_border(&svg, 100.0, 50.0, 0.3, 0.5);
    let rect = find_rect(&out);
    assert_eq!(attr_in_tag(rect, "x"), Some("0.250"));
    assert_eq!(attr_in_tag(rect, "y"), Some("0.250"));
    assert_eq!(attr_in_tag(rect, "width"), Some("99.500"));
    assert_eq!(attr_in_tag(rect, "height"), Some("49.500"));
    // SVG outer attrs untouched.
    assert_eq!(attr(&out, "width"), Some("100pt"));
}

#[test]
fn zero_dims_returns_input_unchanged() {
    let svg = make_svg(r#"width="0pt" height="0pt" viewBox="0 0 0 0""#);
    let out = add_viewbox_border(&svg, 0.0, 0.0, 0.3, 0.5);
    assert_eq!(out, svg);
}

// ---- idempotency / stacking ----

#[test]
fn applying_twice_inserts_a_second_rect_dimensions_unchanged() {
    // Function is additive in `<rect>' count but does NOT resize.
    // Two calls = two overlapping borders, same outer dimensions.
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let once = add_viewbox_border(&svg, 10.0, 20.0, 0.3, 0.5);
    let twice = add_viewbox_border(&once, 10.0, 20.0, 0.3, 0.5);
    let rect_count = twice.matches("<rect ").count();
    assert_eq!(rect_count, 2, "expected 2 overlapping borders, got {rect_count}");
    assert_eq!(attr(&twice, "width"), Some("10pt"));
    assert_eq!(attr(&twice, "viewBox"), Some("0 0 10 20"));
}

// ---- ill-formed input ----

#[test]
fn non_svg_input_is_returned_verbatim() {
    let s = "not an svg";
    let out = add_viewbox_border(s, 10.0, 20.0, 0.3, 0.5);
    // Without a <svg tag, width parse returns None, fallback 10/20 used,
    // then rewrite_attr does nothing because no <svg> tag — string
    // unchanged.
    assert_eq!(out, s);
}
