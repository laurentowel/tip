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

/// RaTeX's standalone SVG uses `fill` on individual glyph paths with
/// `rgba(R,G,B,A)` notation.  Normalize to the requested foreground in
/// hex (`#RRGGBB`) so (1) light/dark themes flip correctly on initial
/// render, and (2) our client-side theme-change handler (which does
/// string-replace on the stored `tip-fg` hex) can later swap the color
/// without a server round-trip.  Non-black glyph colors are left alone
/// (author-intentional, e.g. `\color{red}`).
fn recolor_svg(svg: &str, color: &str) -> String {
    let hex = normalize_color(color);
    // Every black-ish fill in RaTeX's output becomes the requested fg.
    svg.replace("fill=\"rgba(0,0,0,1)\"", &format!("fill=\"{hex}\""))
        .replace("fill='rgba(0,0,0,1)'", &format!("fill='{hex}'"))
        .replace("fill=\"#000000\"", &format!("fill=\"{hex}\""))
        .replace("fill='#000000'", &format!("fill='{hex}'"))
        .replace("fill=\"black\"", &format!("fill=\"{hex}\""))
        .replace("fill='black'", &format!("fill='{hex}'"))
}

/// Normalize a color token (named or hex) to lower-case `#rrggbb` so
/// the SVG's post-render string-replacement theme switcher has a
/// stable anchor to find.
fn normalize_color(c: &str) -> String {
    if let Some(hex) = c.strip_prefix('#') {
        if hex.len() == 6 && hex.chars().all(|ch| ch.is_ascii_hexdigit()) {
            return format!("#{}", hex.to_lowercase());
        }
    }
    match c.to_ascii_lowercase().as_str() {
        "black" => "#000000".into(),
        "white" => "#ffffff".into(),
        _ => c.to_string(),
    }
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
    fn recolor_replaces_black_only() {
        let svg = "<svg><path fill='#000000'/></svg>";
        assert!(recolor_svg(svg, "#ff0000").contains("#ff0000"));
        // Non-black left alone (author-intentional color).
        let svg = "<svg><path fill='#ff0000'/></svg>";
        assert!(recolor_svg(svg, "#00ff00").contains("#ff0000"));
    }

    #[test]
    fn recolor_handles_rgba_black() {
        // RaTeX actually emits rgba(0,0,0,1) not #000000.
        let svg = "<svg><path fill=\"rgba(0,0,0,1)\"/></svg>";
        let out = recolor_svg(svg, "#ffffff");
        assert!(out.contains("#ffffff"));
        assert!(!out.contains("rgba(0,0,0,1)"));
    }

    #[test]
    fn recolor_normalizes_to_client_anchor_even_for_black() {
        // Even when fg is black we should rewrite rgba(0,0,0,1) → #000000
        // so the client's theme-change string-replace has a stable anchor.
        let svg = "<svg><path fill=\"rgba(0,0,0,1)\"/></svg>";
        let out = recolor_svg(svg, "#000000");
        assert!(out.contains("#000000"));
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
