//! KaTeX backend for `tip-server`, powered by RaTeX.
//!
//! Stateless: each `compile_fragments` request self-contains everything
//! the backend needs.  No sync/document-store round-trip is required —
//! we accept the fragment text directly from the client's extracted
//! ranges.  A small `DocumentStore` is kept anyway so the stock
//! sync-then-compile flow works identically to the other backends.

use std::path::{Path, PathBuf};

use tip_protocol::messages::*;
use tip_protocol::DocumentStore;

pub struct KatexBackend {
    docs: DocumentStore,
}

impl KatexBackend {
    pub fn new() -> Self {
        Self {
            docs: DocumentStore::default(),
        }
    }

    pub fn handle_sync(&mut self, params: SyncParams) -> ResponseResult {
        self.docs.sync(params.uri, params.content);
        ResponseResult::Sync { ok: true }
    }

    pub fn handle_compile_fragments(&mut self, params: CompileFragmentsParams) -> ResponseResult {
        let content = match self.docs.get(&params.uri) {
            Some(c) => c.to_string(),
            None => {
                return ResponseResult::Error {
                    error: format!("document not synced: {}", params.uri),
                }
            }
        };
        let mut results = Vec::with_capacity(params.fragments.len());
        for loc in &params.fragments {
            let src = match content.get(loc.start..loc.end) {
                Some(s) => s,
                None => {
                    results.push(fragment_error(loc, "byte range out of bounds".into()));
                    continue;
                }
            };
            let stripped = strip_math_delimiters(src);
            let display = is_display_delims(src);
            match tip_core_katex::compile(stripped, display) {
                Ok(f) => results.push(FragmentResult {
                    start: loc.start,
                    end: loc.end,
                    svg: recolor_svg(&f.svg, &params.color),
                    height_pt: f.height_pt,
                    depth_pt: f.depth_pt,
                    width_pt: f.width_pt,
                    font_size_pt: Some(f.font_size_pt),
                    error: None,
                    error_detail: None,
                }),
                Err(e) => results.push(fragment_error(loc, e)),
            }
        }
        tip_protocol::svg_color::apply_display_border(
            &mut results,
            &content,
            params.display_math_border_opacity,
            is_multiline_display_katex,
        );
        ResponseResult::Fragments { fragments: results }
    }

    /// `debug_skeleton` is not meaningful for KaTeX (no scope, no
    /// preamble) — return an empty source.
    pub fn handle_debug_skeleton(&self, _params: DebugSkeletonParams) -> ResponseResult {
        ResponseResult::DebugSkeleton {
            source: String::new(),
        }
    }

    /// KaTeX has no import graph — each fragment is standalone.
    pub fn handle_list_project_files(&self, params: ListProjectFilesParams) -> ResponseResult {
        let path = PathBuf::from(&params.uri);
        let root = path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| path.clone());
        crate::handler::single_file_project(root, params.uri)
    }
}

fn fragment_error(loc: &FragmentLocation, msg: String) -> FragmentResult {
    FragmentResult {
        start: loc.start,
        end: loc.end,
        svg: String::new(),
        height_pt: 0.0,
        depth_pt: 0.0,
        width_pt: 0.0,
        font_size_pt: None,
        error: Some(msg.clone()),
        error_detail: Some(FragmentError {
            severity: ErrorSeverity::Error,
            message: msg,
            detail: None,
            line_in_fragment: None,
            hint: None,
        }),
    }
}

/// Inspect the raw fragment text to decide whether to treat this as
/// display math.  Matches the markdown client's classifier: `$$…$$'
/// and `\\[…\\]' are block, everything else inline.
fn is_display_delims(s: &str) -> bool {
    let t = s.trim_start();
    t.starts_with("$$") || t.starts_with("\\[")
}

/// Multi-line display variant of `is_display_delims': true only when
/// the fragment is display-delimited AND contains a newline between
/// the delimiters.  Used by the shared border post-processor.
fn is_multiline_display_katex(s: &str) -> bool {
    is_display_delims(s) && s.contains('\n')
}

/// `ratex-parser::parse` strips outer `$`/`$$` if present, but our
/// callers sometimes pass ranges that already include delimiters and
/// sometimes don't (`$a+b$` vs `a+b`).  Normalize here so error
/// messages refer to the inner math.
fn strip_math_delimiters(s: &str) -> &str {
    let t = s.trim();
    for (open, close) in [("$$", "$$"), ("$", "$"), ("\\(", "\\)"), ("\\[", "\\]")] {
        if t.starts_with(open) && t.ends_with(close) && t.len() >= open.len() + close.len() {
            return &t[open.len()..t.len() - close.len()];
        }
    }
    t
}

/// RaTeX hard-codes its default fill as `rgba(0,0,0,1)` — it doesn't
/// accept a stand-in color through its public API.  So instead of the
/// sentinel-hex technique Typst/LaTeX can use, we rewrite that exact
/// encoding to `currentColor'.  Author colors (RaTeX emits those as
/// `rgba(R,G,B,1)` with nonzero R/G/B) stay intact.
fn recolor_svg(svg: &str, _color: &str) -> String {
    tip_protocol::svg_color::replace_default_black(svg)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_dollar() {
        assert_eq!(strip_math_delimiters("$a+b$"), "a+b");
        assert_eq!(strip_math_delimiters("$$x^2$$"), "x^2");
        assert_eq!(strip_math_delimiters("\\(y\\)"), "y");
        assert_eq!(strip_math_delimiters("no-delims"), "no-delims");
    }

    #[test]
    fn recolor_replaces_default_fill_with_currentColor() {
        let svg = "<svg><path fill='#000000'/></svg>";
        let out = recolor_svg(svg, "#ff0000");
        assert!(out.contains("currentColor"));
        assert!(!out.contains("#000000"));
    }

    #[test]
    fn recolor_author_color_left_alone() {
        // Non-black = author-specified via `\color{red}`.  Stays as-is.
        let svg = "<svg><path fill='#ff0000'/></svg>";
        let out = recolor_svg(svg, "#00ff00");
        assert!(out.contains("#ff0000"));
        assert!(!out.contains("currentColor"));
    }

    #[test]
    fn recolor_handles_rgba_black() {
        // RaTeX's actual output uses rgba notation.
        let svg = "<svg><path fill=\"rgba(0,0,0,1)\"/></svg>";
        let out = recolor_svg(svg, "#ffffff");
        assert!(out.contains("currentColor"));
        assert!(!out.contains("rgba(0,0,0,1)"));
    }

    #[test]
    fn compile_smoke() {
        let mut b = KatexBackend::new();
        b.handle_sync(SyncParams {
            backend: BackendId::Katex,
            project_root: None,
            latex_engine: None,
            uri: "/test.md".into(),
            content: "text $a+b$ more".into(),
        });
        let resp = b.handle_compile_fragments(CompileFragmentsParams {
            backend: BackendId::Katex,
            uri: "/test.md".into(),
            fragments: vec![FragmentLocation { start: 5, end: 10 }],
            color: "#000000".into(),
            page_setup: None,
            preamble: None,
            display_math_width: None,
            strategy: None,
            display_math_border_opacity: None,
        });
        match resp {
            ResponseResult::Fragments { fragments } => {
                assert_eq!(fragments.len(), 1);
                assert!(fragments[0].error.is_none(), "unexpected error: {:?}", fragments[0].error);
                assert!(fragments[0].svg.contains("<svg"));
            }
            other => panic!("unexpected: {:?}", other),
        }
    }
}
