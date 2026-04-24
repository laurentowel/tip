//! KaTeX-compatible math rendering via the `ratex` crate family.
//!
//! Minimal surface: one function that takes a math source string and
//! returns an SVG plus width/height/depth in points.  Stateless per
//! fragment — no preamble, no scope, no imports.  Users get macro
//! reuse the same way Kodama users do: write `\newcommand` inside the
//! math fragment itself.
//!
//! Why no bundled LayoutOptions knob: everything the client might want
//! (color, style) is already expressible either in the source or via
//! the rendered SVG's `fill` attribute after the fact.  Keeping the
//! surface one function keeps the server handler trivial.

use ratex_layout::{layout, to_display_list, LayoutOptions};
use ratex_parser::parse;
use ratex_svg::{render_to_svg, SvgOptions};

/// Default base font size in points, matching our Typst and LaTeX
/// backends for a consistent inline-math look.
const DEFAULT_FONT_SIZE_PT: f64 = 11.0;

/// KaTeX's CSS convention: `.katex { font-size: 1.21em; }`.  Without
/// this factor, math rendered from RaTeX's em-based layout appears
/// noticeably smaller than surrounding text (KaTeX_Main's em-square is
/// larger than its visible glyph extent).  Applied both to the SVG
/// user-units scale and to the height/depth/width we report, so the
/// client's auto-scale keeps the factor in the final image height.
const KATEX_SIZE_FACTOR: f64 = 1.21;

/// Extra size bump for display-mode fragments.  Matches common
/// browser behavior where `\displaystyle' math visually reads as
/// larger than inline — though in true KaTeX the per-glyph em size is
/// identical, users still expect block math to feel more prominent.
const DISPLAY_MODE_BOOST: f64 = 1.25;

/// A compiled math fragment: SVG plus TeX-style width/height/depth in points.
/// Convention matches the Typst and LaTeX backends: `height_pt` is the
/// TOTAL image height (ascent + descent), and `depth_pt` is the descent
/// below the baseline.  Clients compute the ascent ratio as
/// `(height_pt - depth_pt) / height_pt`.
#[derive(Debug, Clone)]
pub struct KatexFragment {
    pub svg: String,
    pub width_pt: f64,
    pub height_pt: f64,
    pub depth_pt: f64,
    pub font_size_pt: f64,
}

/// Compile a math fragment.  `source` should NOT include outer `$`
/// delimiters — those are stripped by `ratex-parser` if present, but
/// callers should strip them client-side to keep errors honest.
///
/// `display` controls the extra DISPLAY_MODE_BOOST scale factor;
/// MathStyle::Display is used regardless of this flag (both Display
/// and Text share size_multiplier 1.0 in KaTeX — only layout differs).
pub fn compile(source: &str, display: bool) -> Result<KatexFragment, String> {
    let nodes = parse(source).map_err(|e| format!("parse error: {:?}", e))?;
    let opts = LayoutOptions::default();
    let lbox = layout(&nodes, &opts);
    let dl = to_display_list(&lbox);

    let boost = if display { DISPLAY_MODE_BOOST } else { 1.0 };
    let em_to_pt = DEFAULT_FONT_SIZE_PT * KATEX_SIZE_FACTOR * boost;
    let svg_opts = SvgOptions {
        font_size: em_to_pt,
        padding: 0.5,
        embed_glyphs: true,
        ..SvgOptions::default()
    };
    let svg = render_to_svg(&dl, &svg_opts);

    // KaTeX's LayoutBox uses `height = ascent` and `depth = descent`
    // with baseline at y=0.  The client-side ascent formula is
    // `(height_pt - depth_pt) / height_pt` and expects `height_pt` to
    // be the TOTAL image height (ascent+descent) — matching preview.sty
    // and our Typst cropped_height.  Sum them here.
    let total_em = dl.height + dl.depth;

    Ok(KatexFragment {
        svg,
        width_pt: dl.width * em_to_pt,
        height_pt: total_em * em_to_pt,
        depth_pt: dl.depth * em_to_pt,
        // Report the TARGET text size, not the KaTeX-scaled em size:
        // the client's auto-scale computes `emacs_pt / rendered_pt`,
        // and we want 1.0 there so the scaling we baked into the *_pt
        // fields above survives to the final image height.
        font_size_pt: DEFAULT_FONT_SIZE_PT,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compile_simple() {
        let out = compile("a + b", false).expect("compile");
        assert!(out.svg.contains("<svg"));
        assert!(out.width_pt > 0.0);
        assert!(out.height_pt > 0.0);
    }

    #[test]
    fn compile_fraction_has_depth() {
        let out = compile("\\frac{a}{b}", false).expect("compile");
        assert!(out.depth_pt > 0.0, "fraction should have descent");
    }

    #[test]
    fn compile_height_is_total_not_ascent_only() {
        // Fraction has nonzero depth, so total height must exceed
        // ascent (which is what dl.height alone would report).
        let out = compile("\\frac{a}{b}", false).expect("compile");
        assert!(out.height_pt > out.depth_pt,
                "height should be ascent+descent, not descent alone");
    }

    #[test]
    fn compile_display_boost_produces_larger_output() {
        let inline = compile("x^2", false).expect("inline");
        let display = compile("x^2", true).expect("display");
        assert!(display.height_pt > inline.height_pt,
                "display mode should bump size (inline {}, display {})",
                inline.height_pt, display.height_pt);
    }

    #[test]
    fn compile_parse_error() {
        let err = compile("\\frac{a", false);
        assert!(err.is_err(), "expected parse error for unmatched brace");
    }

    #[test]
    fn compile_with_inline_newcommand() {
        // Kodama-style in-fragment macro.
        let out = compile("\\newcommand{\\RR}{\\mathbb{R}} x \\in \\RR", false)
            .expect("compile");
        assert!(out.svg.contains("<svg"));
    }
}
