//! KaTeX backend for `tip-server`, powered by RaTeX.
//!
//! Stateless: each `compile_fragments` request self-contains everything
//! the backend needs.  No sync/document-store round-trip is required —
//! we accept the fragment text directly from the client's extracted
//! ranges.  A small `DocumentStore` is kept anyway so the stock
//! sync-then-compile flow works identically to the other backends.

use std::path::{Path, PathBuf};

use tip_protocol::messages::*;

pub struct KatexBackend {
    docs: DocStore,
}

#[derive(Default)]
struct DocStore {
    current: std::collections::HashMap<String, String>,
}

impl DocStore {
    fn sync(&mut self, uri: String, content: String) {
        self.current.insert(uri, content);
    }
    fn get(&self, uri: &str) -> Option<&str> {
        self.current.get(uri).map(String::as_str)
    }
}

impl KatexBackend {
    pub fn new() -> Self {
        Self {
            docs: DocStore::default(),
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
        ResponseResult::Fragments { fragments: results }
    }

    pub fn handle_compile_live(&mut self, params: CompileLiveParams) -> ResponseResult {
        let fp = CompileFragmentsParams {
            backend: BackendId::Katex,
            uri: params.uri,
            fragments: vec![FragmentLocation {
                start: params.start,
                end: params.end,
            }],
            color: params.color,
            page_setup: params.page_setup,
            preamble: params.preamble,
            display_math_width: None,
        };
        match self.handle_compile_fragments(fp) {
            ResponseResult::Fragments { mut fragments } if !fragments.is_empty() => {
                ResponseResult::Live {
                    fragment: fragments.remove(0),
                }
            }
            other => other,
        }
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
        ResponseResult::ProjectFiles {
            root: root.display().to_string(),
            files: vec![params.uri],
        }
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

/// Rewrite default-foreground fills to SVG's `currentColor` keyword.
///
/// This is the technique org-latex-preview uses (see its
/// `--svg-make-fg-currentColor'): render the SVG with a specific
/// "standin" color for the default foreground, then rewrite that
/// color to `currentColor' so Emacs picks up the buffer face's
/// `:foreground' at display time.  Theme changes become FREE — the
/// image re-uses whatever color the face carries right now, no
/// recompile, no SVG string-replace on the client.
///
/// RaTeX's default fill is `rgba(0,0,0,1)`.  Replacing ONLY that
/// means author-specified colors (e.g. the red in `\color{red}{x}`)
/// stay as authored — RaTeX emits those as `rgba(255,0,0,1)` etc.
///
/// The `_color` parameter is accepted for signature compatibility
/// with earlier callers but intentionally unused: the whole point of
/// currentColor is to let the CLIENT's face pick the color, not the
/// server.
fn recolor_svg(svg: &str, _color: &str) -> String {
    svg.replace("fill=\"rgba(0,0,0,1)\"", "fill=\"currentColor\"")
        .replace("fill='rgba(0,0,0,1)'", "fill='currentColor'")
        .replace("fill=\"#000000\"", "fill=\"currentColor\"")
        .replace("fill='#000000'", "fill='currentColor'")
        .replace("fill=\"black\"", "fill=\"currentColor\"")
        .replace("fill='black'", "fill='currentColor'")
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
