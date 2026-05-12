//! SVG color-substitution helpers shared across backends.
//!
//! The `currentColor` technique (adapted from org-latex-preview's
//! `--svg-make-fg-currentColor'): render the fragment with a chosen
//! "stand-in" color that represents the default foreground, then
//! rewrite every occurrence of that stand-in to the SVG keyword
//! `currentColor'.  Emacs picks the actual color at display time from
//! the face's `:foreground' attribute — so theme changes become free
//! and math fragments automatically inherit the color of the
//! surrounding face.
//!
//! Stand-in convention:
//!   - backends that accept a user-supplied fg (Typst, LaTeX) should
//!     pass `STANDIN_HEX` to the renderer so the emitted SVG puts
//!     exactly that color on every default-fg path;
//!   - backends that render with a fixed default (KaTeX/RaTeX emits
//!     `rgba(0,0,0,1)` for its default) use `replace_default_black`.
//!
//! Author-specified colors (e.g. `\color{red}`) are NOT rewritten —
//! the string replace is anchored on the specific stand-in/default
//! value.

/// Stand-in hex color for "default foreground".  Unlikely to appear
/// organically in any math expression; matches org-latex-preview's
/// choice for the same reason.
pub const STANDIN_HEX: &str = "#000001";

/// Rewrite every SVG attribute encoding of HEX to `currentColor'.
/// HEX must be a `#RRGGBB' string (case-insensitive).  Handles the
/// three common SVG encodings seen in our backends:
///   - `fill="#RRGGBB"` / `fill='#RRGGBB'`
///   - `fill="rgb(r,g,b)"` / `fill='rgb(r,g,b)'`
///   - `fill="rgba(r,g,b,1)"` / `fill='rgba(r,g,b,1)'`
/// Same for `stroke=`.  HEX is also matched for SVG `stop-color` and
/// inline `style="fill:#RRGGBB"`.
pub fn fills_to_current_color(svg: &str, hex: &str) -> String {
    let (r, g, b) = match parse_hex(hex) {
        Some(rgb) => rgb,
        None => return svg.to_string(),
    };
    let lower = format!("#{:02x}{:02x}{:02x}", r, g, b);
    let upper = format!("#{:02X}{:02X}{:02X}", r, g, b);
    let rgb = format!("rgb({},{},{})", r, g, b);
    let rgba = format!("rgba({},{},{},1)", r, g, b);
    let mut out = svg.to_string();
    for pat in [lower.as_str(), upper.as_str(), rgb.as_str(), rgba.as_str()] {
        // All attribute quote variants share the same replacement
        // target: `currentColor' as a bare value.
        for (attr, open, close) in [
            ("fill=", "\"", "\""),
            ("fill=", "'", "'"),
            ("stroke=", "\"", "\""),
            ("stroke=", "'", "'"),
            ("stop-color=", "\"", "\""),
            ("stop-color=", "'", "'"),
        ] {
            let from = format!("{attr}{open}{pat}{close}");
            let to = format!("{attr}{open}currentColor{close}");
            if out.contains(&from) {
                out = out.replace(&from, &to);
            }
        }
        // Inline style: fill:#xxxxxx;
        let from = format!("fill:{pat}");
        if out.contains(&from) {
            out = out.replace(&from, "fill:currentColor");
        }
        let from = format!("stroke:{pat}");
        if out.contains(&from) {
            out = out.replace(&from, "stroke:currentColor");
        }
    }
    out
}

/// Convenience: rewrite the renderer-default black (in the specific
/// forms RaTeX emits) to `currentColor'.  RaTeX hard-codes its fill
/// as `rgba(0,0,0,1)` and doesn't offer a stand-in knob — so this
/// variant targets that specific encoding plus the common textual
/// aliases.
/// Wrap an existing SVG in a slightly larger outer SVG that draws a
/// subtle border around it.  Used by display-math post-processing so
/// the resulting image carries a frame around the equation.  The
/// stroke uses `currentColor` so the border picks up the Emacs face
/// color at display time (theme changes are free); opacity is
/// caller-supplied.
///
/// The outer SVG's dimensions come from parsing the INNER SVG's own
/// `width="Xpt"` / `height="Xpt"` attributes — NOT from
/// `FragmentResult.width_pt`, which is ink-width and may be narrower
/// than the actual viewBox (bottom-up renders display math on a
/// page-width-wide canvas with the ink centered).  The inner SVG is
/// embedded verbatim inside a `<g transform="translate(edge, edge)">`,
/// preserving its own viewBox + coordinate system.  Wrapping (rather
/// than injecting into the inner SVG's viewBox) sidesteps any
/// internal transforms Typst or dvisvgm might apply.
///
/// `width_pt' / `height_pt' are fallbacks used when the inner SVG
/// has no parseable `width`/`height` attribute (defensive — Typst
/// always writes them).
pub fn add_viewbox_border(
    svg: &str,
    width_pt: f64,
    height_pt: f64,
    stroke_opacity: f64,
    stroke_width_pt: f64,
) -> String {
    if stroke_opacity <= 0.0 {
        return svg.to_string();
    }
    let iw = parse_svg_dim(svg, "width").unwrap_or(width_pt);
    let ih = parse_svg_dim(svg, "height").unwrap_or(height_pt);
    if iw <= 0.0 || ih <= 0.0 {
        return svg.to_string();
    }
    let (vx, vy, vw, vh) = parse_viewbox(svg).unwrap_or((0.0, 0.0, iw, ih));
    if vw <= 0.0 || vh <= 0.0 {
        return svg.to_string();
    }

    // The rect sits inside the existing viewBox, inset by half the
    // stroke width so the visible line stays within bounds.  No
    // resizing — the SVG's width/height/viewBox stay exactly as the
    // caller produced them, so Emacs renders the image at the same
    // pixel size as before.  The border eats a tiny strip of the
    // viewBox; for canvas-wide display math this strip is well clear
    // of the centered ink, and for tight crops it brushes the ink
    // edges (the intended "subtle border on the math").
    let half = stroke_width_pt / 2.0;
    let rect_x = vx + half;
    let rect_y = vy + half;
    let rect_w = (vw - stroke_width_pt).max(0.0);
    let rect_h = (vh - stroke_width_pt).max(0.0);
    let rect = format!(
        "<rect x=\"{:.3}\" y=\"{:.3}\" width=\"{:.3}\" height=\"{:.3}\" \
         stroke=\"currentColor\" stroke-opacity=\"{:.3}\" \
         stroke-width=\"{:.3}\" fill=\"none\"/>",
        rect_x, rect_y, rect_w, rect_h, stroke_opacity, stroke_width_pt
    );

    let mut out = svg.to_string();
    if let Some(tag_end) = find_tag_close(&out) {
        out.insert_str(tag_end + 1, &rect);
    }
    out
}

/// Widen an SVG's canvas to `target_width_pt`, centering the original
/// content horizontally inside the new viewport.  Used by backends
/// that don't natively support a target-width knob (KaTeX) so display
/// math still gets the wide-canvas-with-centered-math treatment that
/// Typst and LaTeX produce.
///
/// Mechanics: the viewBox's x-origin shifts negatively by
/// `(target_width - current_width) / 2`, its width grows by the
/// matching amount, and the `width' attribute is replaced.  Content
/// positions in the SVG body are untouched — they were at their
/// original coords inside the original viewBox, which now sits in
/// the middle of a wider viewport.  No-op when the target is `<=`
/// the current width, or when width / viewBox can't be parsed.
pub fn widen_canvas(svg: &str, target_width_pt: f64) -> String {
    let iw = match parse_svg_dim(svg, "width") {
        Some(v) if v > 0.0 => v,
        _ => return svg.to_string(),
    };
    if target_width_pt <= iw {
        return svg.to_string();
    }
    let (vx, vy, vw, vh) = match parse_viewbox(svg) {
        Some(v) => v,
        None => return svg.to_string(),
    };
    let shift = (target_width_pt - iw) / 2.0;
    let new_vx = vx - shift;
    let new_vw = vw + 2.0 * shift;
    let new_viewbox = format!("{:.3} {:.3} {:.3} {:.3}", new_vx, vy, new_vw, vh);
    let new_width = format!("{:.3}pt", target_width_pt);
    let out = rewrite_quoted_attr(svg, "viewBox", &new_viewbox);
    rewrite_quoted_attr(&out, "width", &new_width)
}

/// Replace the value of `attr` within the first `<svg>` opening tag,
/// preserving the original quote style (`"` or `'`).  No-op if the
/// attribute is missing.
fn rewrite_quoted_attr(svg: &str, attr: &str, new_val: &str) -> String {
    let tag_end = match find_tag_close(svg) {
        Some(p) => p,
        None => return svg.to_string(),
    };
    let tag = &svg[..tag_end];
    for quote in ['"', '\''] {
        let needle = format!("{attr}={quote}");
        if let Some(start) = tag.find(&needle) {
            let val_start = start + needle.len();
            if let Some(rel_end) = tag[val_start..].find(quote) {
                let val_end = val_start + rel_end;
                let mut out = String::with_capacity(svg.len() + new_val.len());
                out.push_str(&svg[..val_start]);
                out.push_str(new_val);
                out.push_str(&svg[val_end..]);
                return out;
            }
        }
    }
    svg.to_string()
}

/// Parse `attr="VAL"` or `attr='VAL'` from the outer `<svg>` tag.
/// Both quote styles are valid SVG; Typst emits double, dvisvgm
/// (LaTeX backend) emits single.  Returns the value WITHOUT quotes.
fn parse_attr_value<'a>(svg: &'a str, attr: &str) -> Option<&'a str> {
    let trimmed = svg.trim_start_matches(|c: char| c.is_whitespace());
    let tag_end = trimmed.find('>')?;
    let tag = &trimmed[..tag_end];
    for quote in ['"', '\''] {
        let needle = format!("{attr}={quote}");
        if let Some(start) = tag.find(&needle) {
            let val_start = start + needle.len();
            let val_end = tag[val_start..].find(quote)? + val_start;
            return Some(&tag[val_start..val_end]);
        }
    }
    None
}

/// Parse a numeric attribute (in points) from the outer `<svg>` tag.
fn parse_svg_dim(svg: &str, attr: &str) -> Option<f64> {
    let val = parse_attr_value(svg, attr)?;
    val.trim_end_matches(|c: char| c.is_alphabetic())
        .trim()
        .parse()
        .ok()
}

/// Parse `viewBox` from the outer `<svg>` tag (double or single quotes).
fn parse_viewbox(svg: &str) -> Option<(f64, f64, f64, f64)> {
    let val = parse_attr_value(svg, "viewBox")?;
    let parts: Vec<&str> = val.split_ascii_whitespace().collect();
    if parts.len() != 4 {
        return None;
    }
    Some((
        parts[0].parse().ok()?,
        parts[1].parse().ok()?,
        parts[2].parse().ok()?,
        parts[3].parse().ok()?,
    ))
}

/// Find the byte offset of the `>` closing the first `<svg ...>` tag.
fn find_tag_close(svg: &str) -> Option<usize> {
    let bytes = svg.as_bytes();
    let start = svg.find("<svg")?;
    let mut i = start + 4;
    let mut in_quotes: Option<u8> = None;
    while i < bytes.len() {
        let b = bytes[i];
        match in_quotes {
            Some(q) if q == b => in_quotes = None,
            None if b == b'"' || b == b'\'' => in_quotes = Some(b),
            None if b == b'>' => return Some(i),
            _ => {}
        }
        i += 1;
    }
    None
}

/// Widen the canvas of every multi-line-display `FragmentResult' to
/// `target_width_pt' via `widen_canvas'.  Updates the result's
/// `width_pt' to match so downstream consumers (border post-process,
/// client-side image scaling) see the new dimensions.
pub fn apply_display_widen<F>(
    results: &mut [crate::messages::FragmentResult],
    document_content: &str,
    target_width_pt: Option<f64>,
    is_multiline_display: F,
) where
    F: Fn(&str) -> bool,
{
    let target = match target_width_pt {
        Some(w) if w > 0.0 => w,
        _ => return,
    };
    for r in results.iter_mut() {
        if r.svg.is_empty() || r.error.is_some() {
            continue;
        }
        let Some(text) = document_content.get(r.start..r.end) else {
            continue;
        };
        if !is_multiline_display(text) {
            continue;
        }
        r.svg = widen_canvas(&r.svg, target);
        if r.width_pt < target {
            r.width_pt = target;
        }
    }
}

/// Apply a border to every `FragmentResult' whose source content is
/// classified as multi-line display math by `is_multiline_display'.
/// Each backend supplies its own classifier (Typst recognizes `$ ... $'
/// with internal newlines; LaTeX recognizes `\\[...\\]' and
/// `\\begin{equation}/align/...}'; KaTeX recognizes `$$...$$'),
/// keeping per-backend display-math semantics out of this transport-
/// agnostic helper.
///
/// `width_pt' / `height_pt' on the result must match the SVG's
/// viewBox; the rect uses those dimensions verbatim.  Border is
/// skipped when `opacity' is `None' or `<= 0', when the result has no
/// SVG (compile error / empty), or when the classifier says false.
pub fn apply_display_border<F>(
    results: &mut [crate::messages::FragmentResult],
    document_content: &str,
    opacity: Option<f64>,
    is_multiline_display: F,
) where
    F: Fn(&str) -> bool,
{
    let op = match opacity {
        Some(o) if o > 0.0 => o,
        _ => return,
    };
    for r in results.iter_mut() {
        if r.svg.is_empty() || r.error.is_some() {
            continue;
        }
        let Some(text) = document_content.get(r.start..r.end) else {
            continue;
        };
        if !is_multiline_display(text) {
            continue;
        }
        r.svg = add_viewbox_border(&r.svg, r.width_pt, r.height_pt, op, 0.5);
    }
}

pub fn replace_default_black(svg: &str) -> String {
    svg.replace("fill=\"rgba(0,0,0,1)\"", "fill=\"currentColor\"")
        .replace("fill='rgba(0,0,0,1)'", "fill='currentColor'")
        .replace("fill=\"#000000\"", "fill=\"currentColor\"")
        .replace("fill='#000000'", "fill='currentColor'")
        .replace("fill=\"black\"", "fill=\"currentColor\"")
        .replace("fill='black'", "fill='currentColor'")
}

fn parse_hex(hex: &str) -> Option<(u8, u8, u8)> {
    let hex = hex.strip_prefix('#')?;
    if hex.len() != 6 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
    let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
    let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
    Some((r, g, b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standin_to_current_color_double_quote_hex() {
        let svg = "<svg><path fill=\"#000001\"/></svg>";
        assert_eq!(
            fills_to_current_color(svg, STANDIN_HEX),
            "<svg><path fill=\"currentColor\"/></svg>"
        );
    }

    #[test]
    fn standin_to_current_color_rgba() {
        let svg = "<svg><path fill=\"rgba(0,0,1,1)\"/></svg>";
        assert_eq!(
            fills_to_current_color(svg, STANDIN_HEX),
            "<svg><path fill=\"currentColor\"/></svg>"
        );
    }

    #[test]
    fn standin_leaves_other_colors_alone() {
        let svg = "<svg><path fill=\"#ff0000\"/><path fill=\"#000001\"/></svg>";
        let out = fills_to_current_color(svg, STANDIN_HEX);
        assert!(out.contains("#ff0000"));
        assert!(out.contains("currentColor"));
        assert!(!out.contains("#000001"));
    }

    #[test]
    fn standin_matches_inline_style() {
        let svg = "<path style=\"fill:#000001;stroke:none\"/>";
        let out = fills_to_current_color(svg, STANDIN_HEX);
        assert!(out.contains("fill:currentColor"));
    }

    #[test]
    fn replace_default_black_rewrites_rgba() {
        let svg = "<path fill=\"rgba(0,0,0,1)\"/>";
        assert_eq!(
            replace_default_black(svg),
            "<path fill=\"currentColor\"/>"
        );
    }

    #[test]
    fn replace_default_black_leaves_author_color() {
        let svg = "<path fill=\"rgba(255,0,0,1)\"/>";
        assert_eq!(replace_default_black(svg), svg);
    }

    #[test]
    fn parse_hex_roundtrip() {
        assert_eq!(parse_hex("#000001"), Some((0, 0, 1)));
        assert_eq!(parse_hex("#FFFFFF"), Some((255, 255, 255)));
        assert_eq!(parse_hex("#abcdef"), Some((0xab, 0xcd, 0xef)));
        assert_eq!(parse_hex("not-hex"), None);
        assert_eq!(parse_hex("#fff"), None);
    }
}
