//! The LaTeX→SVG pipeline.
//!
//! # Pipeline
//!
//! 1. Build a single `batch.tex` containing the user's preamble plus
//!    `\usepackage[active,tightpage]{preview}`, with each fragment
//!    source wrapped in `\begin{preview}...\end{preview}`.
//! 2. Run `latex -interaction=nonstopmode -output-directory $TMP
//!    batch.tex`.  Expected exit code is 1 (preview.sty raises a fake
//!    error per snippet to force page breaks) — treat 0 and 1 as
//!    success, everything else as failure.
//! 3. Parse latex's stdout for:
//!    - `Preview: Tightpage L B R T` — four margin offsets, in scaled
//!      points (65536/pt).  Emitted once per compile.
//!    - `! Preview: Snippet N ended.(H+D×W)` — per-snippet height,
//!      depth, width in scaled points.
//! 4. Run `dvisvgm --page=1- --no-fonts --bbox=preview --exact
//!    --relative -o batch-%9p.svg batch.dvi`.  One SVG per fragment.
//! 5. Read each `batch-NNNNNNNNN.svg`, associate by page number with
//!    the corresponding fragment metrics, return `Vec<FragmentOutput>`.
//!
//! # Units
//!
//! LaTeX emits dimensions in scaled points: `sp = pt * 65536`.  We
//! convert to pt before returning.  `dvisvgm --bbox=preview` writes the
//! SVG's viewBox in pt already, so height/width agree with our parsed
//! values up to rounding.
//!
//! # v1 scope
//!
//! No mylatexformat precompile; no persistent cache; no streaming
//! output.  Batch compile, return whole result set, done.  Optimizations
//! are follow-ups (see doc/digestif-extraction.md § "Proposed build
//! order").

use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::Command;

/// Compiled output for a single fragment.
#[derive(Debug, Clone)]
pub struct FragmentOutput {
    pub svg: String,
    pub height_pt: f64,
    pub depth_pt: f64,
    pub width_pt: f64,
    /// Base font size used by LaTeX when rendering this batch, in pt.
    /// Parsed from preview.sty's `Preview: Fontsize Npt` line.  Constant
    /// across all fragments in a batch — it reflects the document class
    /// option (10pt / 11pt / 12pt).  None when the line was absent.
    pub font_size_pt: Option<f64>,
}

#[derive(Debug, Clone)]
pub enum LatexError {
    /// I/O failure (tempfile, read, spawn).
    Io(String),
    /// `latex` / `dvisvgm` not on PATH.
    ToolMissing(String),
    /// Compile failed (non-zero-non-one exit or matched "! LaTeX Error").
    CompileFailed {
        log_tail: String,
        per_fragment: Vec<Option<String>>,
    },
    /// Compile succeeded but a fragment's metrics / SVG couldn't be read.
    BadOutput(String),
}

impl LatexError {
    pub fn message(&self) -> String {
        match self {
            LatexError::Io(s) => format!("I/O error: {s}"),
            LatexError::ToolMissing(s) => format!("tool missing on PATH: {s}"),
            LatexError::CompileFailed { log_tail, .. } => {
                format!("latex compile failed:\n{log_tail}")
            }
            LatexError::BadOutput(s) => format!("bad output: {s}"),
        }
    }
}

pub struct LatexCompiler;

impl LatexCompiler {
    /// Compile all `fragments` with a shared `preamble`, returning one
    /// result per fragment.
    ///
    /// Each element of `fragments` is the *raw* source for one preview
    /// (e.g. `"$a+b$"` or `"\\begin{equation}x\\end{equation}"`).  The
    /// caller is responsible for extracting fragment strings from the
    /// source buffer; this function just wraps each in a `preview`
    /// environment.
    pub fn compile_batch(
        preamble: &str,
        fragments: &[&str],
        working_dir: Option<&Path>,
        display_math_width: Option<&str>,
    ) -> Result<Vec<Result<FragmentOutput, String>>, LatexError> {
        if fragments.is_empty() {
            return Ok(vec![]);
        }

        let tmp = tempfile::tempdir()
            .map_err(|e| LatexError::Io(format!("create tempdir: {e}")))?;
        let tex_path = tmp.path().join("batch.tex");
        write_batch_tex(&tex_path, preamble, fragments, display_math_width)
            .map_err(|e| LatexError::Io(format!("write batch.tex: {e}")))?;

        // Step 1: latex → DVI
        let cwd = working_dir.unwrap_or(tmp.path());
        let latex_output = Command::new("latex")
            .args([
                "-interaction=nonstopmode",
                "-file-line-error",
                "-output-directory",
            ])
            .arg(tmp.path())
            .arg(&tex_path)
            .current_dir(cwd)
            .output()
            .map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => LatexError::ToolMissing("latex".into()),
                _ => LatexError::Io(format!("spawn latex: {e}")),
            })?;

        let stdout = String::from_utf8_lossy(&latex_output.stdout).into_owned();
        // Treat exit codes 0 and 1 as success; preview.sty always raises
        // a fake error → exit 1 is the expected case.
        let exit_ok = matches!(latex_output.status.code(), Some(0) | Some(1));
        if !exit_ok {
            return Err(LatexError::CompileFailed {
                log_tail: tail(&stdout, 40),
                per_fragment: vec![None; fragments.len()],
            });
        }

        let dvi_path = tmp.path().join("batch.dvi");
        if !dvi_path.exists() {
            return Err(LatexError::CompileFailed {
                log_tail: tail(&stdout, 40),
                per_fragment: vec![None; fragments.len()],
            });
        }

        // Step 2: parse preview.sty markers from stdout
        let metrics = parse_preview_output(&stdout, fragments.len());
        let font_size_pt = parse_preview_fontsize(&stdout);

        // Step 3: dvisvgm → N svg files
        //
        // --bbox=preview uses preview.sty's tightpage annotations, which
        // respect \textwidth: display math like `\[...\]` produces a
        // full-textwidth SVG with the math centered by LaTeX itself
        // (important for the `display_math_width` feature).  Inline math
        // fragments stay tight because preview.sty only pads display
        // environments.
        //
        // We read dimensions directly from the SVG's viewBox afterwards,
        // so the preview.sty stdout values don't need to match (they
        // don't — sp vs bp).
        let dvisvgm_out = Command::new("dvisvgm")
            .args([
                "--page=1-",
                "--no-fonts",
                "--bbox=preview",
                "--exact",
                "--relative",
                "--output=batch-%9p.svg",
            ])
            .arg(&dvi_path)
            .current_dir(tmp.path())
            .output()
            .map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => LatexError::ToolMissing("dvisvgm".into()),
                _ => LatexError::Io(format!("spawn dvisvgm: {e}")),
            })?;

        if !dvisvgm_out.status.success() {
            let stderr = String::from_utf8_lossy(&dvisvgm_out.stderr);
            return Err(LatexError::BadOutput(format!(
                "dvisvgm failed: {stderr}"
            )));
        }

        // Step 4: collect per-fragment results.  Use SVG viewBox to get the
        // true (ink-cropped) dimensions; fall back to the preview.sty log
        // metric if the viewBox is missing/malformed.
        let mut results = Vec::with_capacity(fragments.len());
        for (i, metric) in metrics.into_iter().enumerate() {
            let svg_path = tmp.path().join(format!("batch-{:09}.svg", i + 1));
            match fs::read_to_string(&svg_path) {
                Ok(svg) => {
                    let dims = parse_svg_dimensions(&svg).or_else(|| {
                        metric.as_ref().map(|m| SvgDims {
                            height_pt: m.height_pt,
                            depth_pt: m.depth_pt,
                            width_pt: m.width_pt,
                        })
                    });
                    match dims {
                        Some(d) => results.push(Ok(FragmentOutput {
                            svg,
                            height_pt: d.height_pt,
                            depth_pt: d.depth_pt,
                            width_pt: d.width_pt,
                            font_size_pt,
                        })),
                        None => results.push(Err(format!(
                            "fragment {} has no dimensions (svg viewBox missing, no log entry)",
                            i + 1
                        ))),
                    }
                }
                Err(e) => results.push(Err(format!(
                    "svg {} not readable: {}",
                    svg_path.display(),
                    e
                ))),
            }
        }
        Ok(results)
    }
}

#[derive(Debug, Clone, Copy)]
struct SvgDims {
    height_pt: f64,
    depth_pt: f64,
    width_pt: f64,
}

/// Extract ink-bounded dimensions from an SVG's viewBox and width attrs.
///
/// dvisvgm emits `viewBox='MIN_X MIN_Y WIDTH HEIGHT'` in pt units when we
/// pass `--exact --relative`.  With `--bbox=min`, MIN_Y ≤ 0 corresponds
/// to the ink extent above the text baseline (baseline is y=0), and
/// (MIN_Y + HEIGHT) ≥ 0 gives the depth below baseline.
fn parse_svg_dimensions(svg: &str) -> Option<SvgDims> {
    let vb_start = svg.find("viewBox=")?;
    let quote_char = svg[vb_start + "viewBox=".len()..].chars().next()?;
    let after_quote = &svg[vb_start + "viewBox=".len() + 1..];
    let vb_end = after_quote.find(quote_char)?;
    let inner = &after_quote[..vb_end];
    let parts: Vec<f64> = inner.split_whitespace().filter_map(|s| s.parse().ok()).collect();
    if parts.len() != 4 {
        return None;
    }
    let min_y = parts[1];
    let width = parts[2];
    let height = parts[3];
    let max_y = min_y + height;
    // Clamp: if the whole viewBox sits above or below the baseline (y=0),
    // treat the side away from baseline as zero.
    let depth = if max_y > 0.0 { max_y } else { 0.0 };
    Some(SvgDims {
        height_pt: height,
        depth_pt: depth,
        width_pt: width,
    })
}

/// Write `batch.tex` at PATH.
fn write_batch_tex(
    path: &Path,
    preamble: &str,
    fragments: &[&str],
    display_math_width: Option<&str>,
) -> std::io::Result<()> {
    let mut f = fs::File::create(path)?;
    // If preamble lacks \documentclass, supply a minimal default.
    let has_documentclass = preamble.contains("\\documentclass");
    if !has_documentclass {
        writeln!(f, "\\documentclass{{article}}")?;
    }
    // User preamble, up to (but not including) \begin{document} if present.
    let preamble_body = strip_begin_document(preamble);
    writeln!(f, "{}", preamble_body)?;
    // xcolor — required for our \color[HTML]{...} injection in the handler.
    writeln!(
        f,
        "\\makeatletter\\@ifpackageloaded{{xcolor}}{{}}{{\\usepackage{{xcolor}}}}\\makeatother"
    )?;
    // Optional textwidth for display-math sizing.  When set,
    // `\begin{preview}\[...\]\end{preview}` produces a full-textwidth SVG
    // with the math centered by LaTeX itself — no SVG post-processing
    // needed.  Inline math is unaffected (it doesn't fill a line).
    if let Some(w) = display_math_width {
        if !w.trim().is_empty() {
            writeln!(f, "\\setlength{{\\textwidth}}{{{}}}", w)?;
            writeln!(f, "\\setlength{{\\linewidth}}{{{}}}", w)?;
        }
    }
    // Preview.sty options: active (enable snippets), tightpage (emit bbox
    // metadata for dvisvgm to crop to), auctex (emit per-snippet size
    // messages we can parse from stdout).
    writeln!(f, "\\usepackage[active,tightpage,auctex]{{preview}}")?;
    writeln!(f, "\\begin{{document}}")?;
    for frag in fragments {
        writeln!(f, "\\begin{{preview}}")?;
        writeln!(f, "{}", frag)?;
        writeln!(f, "\\end{{preview}}")?;
    }
    writeln!(f, "\\end{{document}}")?;
    Ok(())
}

fn strip_begin_document(preamble: &str) -> &str {
    match preamble.find("\\begin{document}") {
        Some(i) => &preamble[..i],
        None => preamble,
    }
}

#[derive(Debug, Clone)]
struct FragmentMetric {
    /// TOTAL height of the SVG bounding box (above-baseline + below-baseline),
    /// in pt, after tightpage adjustment.  This matches tip-core-typst's
    /// convention so the client's tip--make-image-spec computes ascent
    /// as (height - depth) / height correctly.
    height_pt: f64,
    /// Depth below baseline, in pt, after tightpage adjustment.
    depth_pt: f64,
    /// Total width, in pt.
    width_pt: f64,
}

/// Parse preview.sty's stdout for per-snippet dimensions + tightpage margins.
///
/// Returns a vector of `Option<FragmentMetric>` of length `n_fragments`
/// (None where a snippet didn't produce an "ended" line, e.g. it failed
/// to compile).
fn parse_preview_output(stdout: &str, n_fragments: usize) -> Vec<Option<FragmentMetric>> {
    // Scaled points per pt.
    const SP_PER_PT: f64 = 65536.0;

    // Tightpage offsets: emitted once, four numbers after "Preview: Tightpage".
    // Tolerate a file:line: prefix (added by file-line-error).
    let tightpage = stdout
        .lines()
        .find_map(|line| {
            let marker = "Preview: Tightpage ";
            let at = line.find(marker)?;
            let rest = &line[at + marker.len()..];
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if parts.len() != 4 {
                return None;
            }
            let vals: Vec<f64> = parts.iter().filter_map(|s| s.parse().ok()).collect();
            if vals.len() == 4 {
                Some((vals[0], vals[1], vals[2], vals[3]))
            } else {
                None
            }
        })
        .unwrap_or((0.0, 0.0, 0.0, 0.0));
    let (left_sp, bottom_sp, right_sp, top_sp) = tightpage;

    // Per-snippet: "! Preview: Snippet N ended.(HEIGHT+DEPTHxWIDTH)"
    let mut metrics = vec![None; n_fragments];
    for line in stdout.lines() {
        if let Some((n, h, d, w)) = parse_snippet_ended(line) {
            if n == 0 || n > n_fragments {
                continue;
            }
            // org-latex-preview conventions (see doc/latex-preview-survey.md):
            //   above_baseline = H + T   (H is height above; T is tightpage top)
            //   below_baseline = D - B   (D is depth; B is tightpage bottom; B < 0)
            //   total_height   = above + below
            //   width          = W + R - L
            let above = h + top_sp;
            let below = d - bottom_sp;
            metrics[n - 1] = Some(FragmentMetric {
                height_pt: (above + below) / SP_PER_PT,
                depth_pt: below / SP_PER_PT,
                width_pt: (w + right_sp - left_sp) / SP_PER_PT,
            });
        }
    }
    metrics
}

/// Parse a line carrying "Preview: Snippet N ended.(H+DxW)", in any of
/// the three forms latex / preview.sty may emit:
///
///   `! Preview: Snippet 3 ended.(H+DxW)`        (halt-on-error + auctex)
///   `./batch.tex:7: Preview: Snippet 3 ended.(H+DxW).`  (file-line-error + auctex)
///   `Preview: Snippet 3 ended.(H+DxW)`          (bare — some setups)
///
/// H, D, W are integer scaled-points; D may be negative.  Trailing `.`
/// after `)` is tolerated.
fn parse_snippet_ended(line: &str) -> Option<(usize, f64, f64, f64)> {
    // Locate the core marker.
    let anchor = "Preview: Snippet ";
    let start = line.find(anchor)?;
    let tail = &line[start + anchor.len()..];
    let (n_str, rest) = tail.split_once(' ')?;
    let n: usize = n_str.parse().ok()?;
    // rest starts with "ended.(H+DxW)" maybe with a trailing ".".
    if !rest.starts_with("ended.") {
        return None;
    }
    let open = rest.find('(')?;
    let close = rest[open + 1..].find(')')?;
    let inner = &rest[open + 1..open + 1 + close];
    let plus = inner.find('+')?;
    let after_plus = &inner[plus + 1..];
    let x = after_plus.find('x')?;
    let h: f64 = inner[..plus].parse().ok()?;
    let d: f64 = after_plus[..x].parse().ok()?;
    let w: f64 = after_plus[x + 1..].parse().ok()?;
    Some((n, h, d, w))
}

/// Parse `Preview: Fontsize 10pt` (or 11pt / 12pt) from preview.sty's stdout.
/// Tolerates a file:line: prefix from file-line-error.
fn parse_preview_fontsize(stdout: &str) -> Option<f64> {
    stdout.lines().find_map(|line| {
        let marker = "Preview: Fontsize ";
        let at = line.find(marker)?;
        let rest = &line[at + marker.len()..];
        // `rest` starts with the number then "pt".
        let pt_at = rest.find("pt")?;
        rest[..pt_at].trim().parse::<f64>().ok()
    })
}

fn tail(s: &str, n_lines: usize) -> String {
    let lines: Vec<&str> = s.lines().collect();
    let start = lines.len().saturating_sub(n_lines);
    lines[start..].join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_snippet_ended_bang_form() {
        let line = "! Preview: Snippet 3 ended.(392832+181502x1256832)";
        assert_eq!(
            parse_snippet_ended(line),
            Some((3, 392832.0, 181502.0, 1256832.0))
        );
    }

    #[test]
    fn parses_snippet_ended_file_line_form() {
        let line = "./batch.tex:7: Preview: Snippet 2 ended.(913863+0x22609920).";
        assert_eq!(
            parse_snippet_ended(line),
            Some((2, 913863.0, 0.0, 22609920.0))
        );
    }

    #[test]
    fn parses_snippet_ended_negative_depth() {
        let line = "! Preview: Snippet 1 ended.(100000+-5000x200000)";
        assert_eq!(
            parse_snippet_ended(line),
            Some((1, 100000.0, -5000.0, 200000.0))
        );
    }

    #[test]
    fn parses_preview_output_with_tightpage() {
        let stdout = "\
Preview: Fontsize 10pt
Preview: Tightpage -32891 -32891 32891 32891
! Preview: Snippet 1 ended.(655360+131072x1310720)
! Preview: Snippet 2 ended.(131072+0x262144)
";
        let metrics = parse_preview_output(stdout, 2);
        assert!(metrics[0].is_some());
        assert!(metrics[1].is_some());
        let m = metrics[0].as_ref().unwrap();
        // above = (655360 + 32891) / 65536 ≈ 10.50 pt
        // below = (131072 - (-32891)) / 65536 ≈ 2.50 pt
        // height = above + below ≈ 13.00 pt
        assert!((m.height_pt - 13.00).abs() < 0.01, "got {}", m.height_pt);
        // depth  ≈ 2.50 pt
        assert!((m.depth_pt - 2.50).abs() < 0.01, "got {}", m.depth_pt);
        // width  = (1310720 + 32891 - (-32891)) / 65536 ≈ 21.00 pt
        assert!((m.width_pt - 21.00).abs() < 0.01, "got {}", m.width_pt);
    }

    #[test]
    fn parse_fontsize_basic() {
        assert_eq!(parse_preview_fontsize("Preview: Fontsize 10pt\nother\n"), Some(10.0));
        assert_eq!(parse_preview_fontsize("./file.tex:1: Preview: Fontsize 11pt"), Some(11.0));
        assert_eq!(parse_preview_fontsize("no fontsize here"), None);
    }

    #[test]
    fn parse_svg_dimensions_basic() {
        let svg = "<svg viewBox='.4 -6.9 38.9 7.74' width='38.9pt' height='7.74pt'>";
        let d = parse_svg_dimensions(svg).unwrap();
        assert!((d.width_pt - 38.9).abs() < 0.01);
        assert!((d.height_pt - 7.74).abs() < 0.01);
        // max_y = -6.9 + 7.74 = 0.84 → depth
        assert!((d.depth_pt - 0.84).abs() < 0.01, "got {}", d.depth_pt);
    }

    #[test]
    fn parse_svg_dimensions_no_depth() {
        // viewBox entirely above baseline (e.g. superscript only).
        let svg = "<svg viewBox='0 -5 10 3'>";
        let d = parse_svg_dimensions(svg).unwrap();
        assert!((d.height_pt - 3.0).abs() < 0.01);
        assert_eq!(d.depth_pt, 0.0);
    }

    #[test]
    fn strips_begin_document() {
        let p = "\\documentclass{article}\n\\usepackage{x}\n\\begin{document}\nbody";
        assert_eq!(
            strip_begin_document(p),
            "\\documentclass{article}\n\\usepackage{x}\n"
        );
    }

    /// Integration test: requires `latex` and `dvisvgm` on PATH.  Skipped otherwise.
    #[test]
    fn compiles_simple_fragment_end_to_end() {
        if which("latex").is_none() || which("dvisvgm").is_none() {
            eprintln!("SKIP: latex and/or dvisvgm not on PATH");
            return;
        }
        let preamble = "\\documentclass{article}\n\\usepackage{amsmath}\n";
        let fragments = ["$a + b$", "$$ x^2 + y^2 $$"];
        let results = LatexCompiler::compile_batch(preamble, &fragments, None, None)
            .expect("compile");
        assert_eq!(results.len(), 2);
        for r in &results {
            let out = r.as_ref().expect("fragment ok");
            assert!(out.svg.contains("<svg"), "svg missing <svg tag");
            assert!(out.height_pt > 0.0, "height_pt = {}", out.height_pt);
            assert!(out.width_pt > 0.0, "width_pt = {}", out.width_pt);
        }
    }

    fn which(cmd: &str) -> Option<std::path::PathBuf> {
        std::env::var_os("PATH").and_then(|paths| {
            std::env::split_paths(&paths).find_map(|dir| {
                let p = dir.join(cmd);
                if p.is_file() { Some(p) } else { None }
            })
        })
    }
}
