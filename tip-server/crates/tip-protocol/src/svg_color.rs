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
/// Inject a `<rect>` border that traces the SVG's viewBox.  Used by
/// the Typst backend for multi-line display math so the resulting
/// image carries a subtle frame around the equation.  The stroke
/// uses `currentColor` and the caller-supplied opacity, so the
/// border picks up the Emacs face color at display time (theme
/// changes are free) and "transparentized" without baking a
/// fragile color into the SVG.
///
/// `width_pt' / `height_pt' must match the SVG's viewBox (origin
/// 0,0).  The rect is inset by half the stroke width so the border
/// sits inside the viewBox rather than being half-clipped at the
/// edge.  `stroke_width_pt' defaults to 0.5pt — bumped to 1pt+ if
/// the caller wants something more visible.
pub fn add_viewbox_border(
    svg: &str,
    width_pt: f64,
    height_pt: f64,
    stroke_opacity: f64,
    stroke_width_pt: f64,
) -> String {
    if stroke_opacity <= 0.0 || width_pt <= 0.0 || height_pt <= 0.0 {
        return svg.to_string();
    }
    let half = stroke_width_pt / 2.0;
    let w = (width_pt - stroke_width_pt).max(0.0);
    let h = (height_pt - stroke_width_pt).max(0.0);
    let rect = format!(
        "<rect x=\"{:.3}\" y=\"{:.3}\" width=\"{:.3}\" height=\"{:.3}\" \
         stroke=\"currentColor\" stroke-opacity=\"{:.3}\" stroke-width=\"{:.3}\" \
         fill=\"none\"/>",
        half, half, w, h, stroke_opacity, stroke_width_pt
    );
    if let Some(pos) = svg.rfind("</svg>") {
        let mut s = String::with_capacity(svg.len() + rect.len());
        s.push_str(&svg[..pos]);
        s.push_str(&rect);
        s.push_str(&svg[pos..]);
        s
    } else {
        svg.to_string()
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
