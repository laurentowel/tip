//! Exhaustive tests for `tip_protocol::svg_color::add_viewbox_border`.
//!
//! The function is a general SVG transformer: take an SVG, expand its
//! viewBox + width + height by an edge inset, and inject a `<rect
//! stroke="currentColor">' that traces the new viewBox.  Tests
//! exercise viewBox variants, attribute orderings, fallback behavior,
//! and idempotency.

use tip_protocol::svg_color::add_viewbox_border;

fn make_svg(opening_attrs: &str) -> String {
    format!("<svg {opening_attrs}><circle cx=\"5\" cy=\"5\" r=\"3\"/></svg>")
}

/// Pull `attr="VAL"` from the FIRST `<svg ...>` tag.  Returns `VAL`.
fn attr<'a>(svg: &'a str, attr: &str) -> Option<&'a str> {
    let tag_end = svg.find('>')?;
    let tag = &svg[..tag_end];
    let needle = format!("{attr}=\"");
    let start = tag.find(&needle)? + needle.len();
    let end = tag[start..].find('"')? + start;
    Some(&tag[start..end])
}

// ---- shape: width/height/viewBox grow correctly ----

#[test]
fn dimensions_grow_by_2_edge() {
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.5, 0.5);
    let inner_pad = 2.0;
    let edge = inner_pad + 0.25; // pad + sw/2
    let expected_w = 10.0 + 2.0 * edge;
    let expected_h = 20.0 + 2.0 * edge;
    let w: f64 = attr(&out, "width")
        .unwrap()
        .trim_end_matches("pt")
        .parse()
        .unwrap();
    let h: f64 = attr(&out, "height")
        .unwrap()
        .trim_end_matches("pt")
        .parse()
        .unwrap();
    assert!((w - expected_w).abs() < 0.01, "width: got {w}, want {expected_w}");
    assert!((h - expected_h).abs() < 0.01, "height: got {h}, want {expected_h}");
}

#[test]
fn viewbox_origin_shifts_negative_by_edge() {
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.5, 0.5);
    let vb: Vec<f64> = attr(&out, "viewBox")
        .unwrap()
        .split_ascii_whitespace()
        .map(|s| s.parse().unwrap())
        .collect();
    let edge = 2.0 + 0.25;
    assert!((vb[0] - (-edge)).abs() < 0.01, "vb x: {:?}", vb);
    assert!((vb[1] - (-edge)).abs() < 0.01, "vb y: {:?}", vb);
    assert!((vb[2] - (10.0 + 2.0 * edge)).abs() < 0.01, "vb w: {:?}", vb);
    assert!((vb[3] - (20.0 + 2.0 * edge)).abs() < 0.01, "vb h: {:?}", vb);
}

#[test]
fn nonzero_viewbox_origin_preserved_with_offset() {
    // Inner viewBox starts at (50, 100) — Typst sometimes does this.
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="50 100 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.5, 0.5);
    let vb: Vec<f64> = attr(&out, "viewBox")
        .unwrap()
        .split_ascii_whitespace()
        .map(|s| s.parse().unwrap())
        .collect();
    let edge = 2.0 + 0.25;
    assert!((vb[0] - (50.0 - edge)).abs() < 0.01, "vb: {:?}", vb);
    assert!((vb[1] - (100.0 - edge)).abs() < 0.01, "vb: {:?}", vb);
    assert!((vb[2] - (10.0 + 2.0 * edge)).abs() < 0.01);
    assert!((vb[3] - (20.0 + 2.0 * edge)).abs() < 0.01);
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
fn rect_sits_inside_new_viewbox_by_half_stroke() {
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.5, 1.0);
    // sw=1.0; edge = inner_pad(2) + sw/2(0.5) = 2.5
    // viewBox: -2.5 -2.5 15 25
    // rect: x=-2.5+0.5=-2.0, y=-2.0, w=15-1=14, h=25-1=24
    let rect = find_rect(&out);
    assert_eq!(attr_in_tag(rect, "x"), Some("-2.000"));
    assert_eq!(attr_in_tag(rect, "y"), Some("-2.000"));
    assert_eq!(attr_in_tag(rect, "width"), Some("14.000"));
    assert_eq!(attr_in_tag(rect, "height"), Some("24.000"));
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
fn attribute_order_does_not_matter() {
    // width AFTER viewBox: should still work.
    let svg = make_svg(r#"viewBox="0 0 10 20" width="10pt" height="20pt""#);
    let out = add_viewbox_border(&svg, 10.0, 20.0, 0.3, 0.5);
    let w: f64 = attr(&out, "width").unwrap().trim_end_matches("pt").parse().unwrap();
    assert!((w - (10.0 + 4.5)).abs() < 0.01);
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
fn falls_back_to_fallback_dims_when_width_missing() {
    // No width/height attrs.  We pass fallback 100/50.
    let svg = make_svg(r#"viewBox="0 0 100 50""#);
    let out = add_viewbox_border(&svg, 100.0, 50.0, 0.3, 0.5);
    let edge = 2.0 + 0.25;
    let w: f64 = attr(&out, "width").unwrap().trim_end_matches("pt").parse().unwrap();
    let h: f64 = attr(&out, "height").unwrap().trim_end_matches("pt").parse().unwrap();
    assert!((w - (100.0 + 2.0 * edge)).abs() < 0.01);
    assert!((h - (50.0 + 2.0 * edge)).abs() < 0.01);
}

#[test]
fn falls_back_to_fallback_dims_when_viewbox_missing() {
    let svg = make_svg(r#"width="100pt" height="50pt""#);
    let out = add_viewbox_border(&svg, 100.0, 50.0, 0.3, 0.5);
    // viewBox should now exist with the fallback dimensions.
    let vb: Vec<f64> = attr(&out, "viewBox")
        .unwrap()
        .split_ascii_whitespace()
        .map(|s| s.parse().unwrap())
        .collect();
    let edge = 2.0 + 0.25;
    assert!((vb[0] + edge).abs() < 0.01);
    assert!((vb[1] + edge).abs() < 0.01);
}

#[test]
fn zero_dims_returns_input_unchanged() {
    let svg = make_svg(r#"width="0pt" height="0pt" viewBox="0 0 0 0""#);
    let out = add_viewbox_border(&svg, 0.0, 0.0, 0.3, 0.5);
    assert_eq!(out, svg);
}

// ---- idempotency / stacking ----

#[test]
fn applying_twice_stacks_a_second_border() {
    // Each call adds another rect + grows by 2*edge.  Not strictly
    // useful in production but documents the behavior.
    let svg = make_svg(r#"width="10pt" height="20pt" viewBox="0 0 10 20""#);
    let once = add_viewbox_border(&svg, 10.0, 20.0, 0.3, 0.5);
    let twice = add_viewbox_border(&once, 10.0, 20.0, 0.3, 0.5);
    let rect_count = twice.matches("<rect ").count();
    assert_eq!(rect_count, 2, "expected 2 nested borders, got {rect_count}");

    let edge = 2.0 + 0.25;
    let w: f64 = attr(&twice, "width").unwrap().trim_end_matches("pt").parse().unwrap();
    assert!((w - (10.0 + 4.0 * edge)).abs() < 0.01, "width should grow twice");
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
