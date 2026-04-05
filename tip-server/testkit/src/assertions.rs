/// Assert that a string is valid SVG (basic check: starts with <svg, ends with </svg>).
pub fn assert_valid_svg(data: &str) {
    let trimmed = data.trim();
    assert!(
        trimmed.starts_with("<svg"),
        "SVG should start with <svg, got: {}...",
        &trimmed[..trimmed.len().min(80)]
    );
    assert!(
        trimmed.ends_with("</svg>"),
        "SVG should end with </svg>"
    );
}

/// Assert SVG height is within tolerance of expected value.
pub fn assert_svg_height(data: &str, expected_pt: f64, tolerance: f64) {
    let height = extract_svg_height_pt(data)
        .expect("could not extract height from SVG");
    assert!(
        (height - expected_pt).abs() <= tolerance,
        "SVG height {:.2}pt not within {:.2} of expected {:.2}pt",
        height,
        tolerance,
        expected_pt
    );
}

/// Assert depth (below baseline) is within tolerance.
pub fn assert_svg_depth(depth_pt: f64, expected_pt: f64, tolerance: f64) {
    assert!(
        (depth_pt - expected_pt).abs() <= tolerance,
        "depth {:.2}pt not within {:.2} of expected {:.2}pt",
        depth_pt,
        tolerance,
        expected_pt
    );
}

/// Assert baseline measurements are sane.
pub fn assert_baseline_sane(height_pt: f64, depth_pt: f64) {
    assert!(height_pt > 0.0, "height must be positive, got {}", height_pt);
    assert!(depth_pt >= 0.0, "depth must be non-negative, got {}", depth_pt);
    assert!(
        depth_pt < height_pt,
        "depth ({}) must be less than height ({})",
        depth_pt,
        height_pt
    );
    let ascent = 100.0 * (1.0 - depth_pt / height_pt);
    assert!(
        (0.0..=100.0).contains(&ascent),
        "ascent {}% out of range",
        ascent
    );
}

/// Extract height in pt from SVG `height="Xpt"` attribute.
fn extract_svg_height_pt(data: &str) -> Option<f64> {
    // Look for height="12.5pt" pattern
    let height_start = data.find("height=\"")?;
    let after = &data[height_start + 8..];
    let end = after.find('"')?;
    let value_str = &after[..end];
    let numeric = value_str.trim_end_matches("pt");
    numeric.parse::<f64>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_height_from_svg() {
        let svg = r#"<svg width="50pt" height="12.5pt" viewBox="0 0 50 12.5"></svg>"#;
        assert_eq!(extract_svg_height_pt(svg), Some(12.5));
    }

    #[test]
    fn baseline_sane_valid() {
        assert_baseline_sane(12.5, 2.3);
    }

    #[test]
    #[should_panic(expected = "depth")]
    fn baseline_sane_depth_exceeds_height() {
        assert_baseline_sane(5.0, 10.0);
    }
}
