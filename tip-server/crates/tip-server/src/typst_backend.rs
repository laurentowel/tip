use std::path::{Path, PathBuf};

use tip_core_typst::bottom_up::BottomUpCompiler;
use tip_core_typst::document::DocumentStore;
use tip_core_typst::top_down::TopDownCompiler;
use tip_core_typst::world::TipWorld;
use tip_core_typst::CompileStrategy;
use tip_protocol::messages::*;

/// Read `TIP_COMPILE_STRATEGY` at process start.  Unrecognized values
/// silently fall back to `BottomUp` so a typo can't brick the server.
/// The legacy `full-doc` aliases are kept for one release for backward
/// compat.
fn strategy_from_env() -> CompileStrategy {
    match std::env::var("TIP_COMPILE_STRATEGY").as_deref() {
        Ok("top-down") | Ok("topdown") | Ok("top_down") => CompileStrategy::TopDown,
        Ok("full-doc") | Ok("fulldoc") | Ok("full_doc") => CompileStrategy::TopDown,
        _ => CompileStrategy::BottomUp,
    }
}

pub struct TypstBackend {
    documents: DocumentStore,
    world: TipWorld,
    strategy: CompileStrategy,
}

impl TypstBackend {
    pub fn new() -> Self {
        Self {
            documents: DocumentStore::new(),
            world: TipWorld::new(),
            strategy: strategy_from_env(),
        }
    }

    pub fn handle_init(&mut self, params: InitParams) -> ResponseResult {
        let dirs: Vec<&str> = params.font_dirs.iter().map(|s| s.as_str()).collect();
        self.world = TipWorld::with_font_dirs(&dirs);
        ResponseResult::Init { ok: true }
    }

    pub fn handle_sync(&mut self, params: SyncParams) -> ResponseResult {
        // Root resolution: explicit `project_root' from the client wins;
        // otherwise walk up from the file looking for a marker.
        let root = params
            .project_root
            .as_deref()
            .map(PathBuf::from)
            .or_else(|| {
                Path::new(&params.uri)
                    .parent()
                    .map(|p| Self::find_project_root(p).unwrap_or_else(|| p.to_path_buf()))
            });
        if let Some(root) = root {
            self.world.set_root(root);
            self.world.set_main_path(&params.uri);
        }
        self.documents.sync(params.uri, params.content);
        ResponseResult::Sync { ok: true }
    }

    /// Walk up from `dir` looking for a project root marker.
    /// Checks: typst.toml, Kodama.toml, .git (in priority order).
    fn find_project_root(dir: &Path) -> Option<PathBuf> {
        let markers = ["typst.toml", "Kodama.toml", ".git"];
        let mut current = dir;
        loop {
            for marker in &markers {
                if current.join(marker).exists() {
                    return Some(current.to_path_buf());
                }
            }
            match current.parent() {
                Some(parent) if parent != current => current = parent,
                _ => return None,
            }
        }
    }

    pub fn handle_compile_fragments(&mut self, params: CompileFragmentsParams) -> ResponseResult {
        let content = match self.documents.get(&params.uri) {
            Some(c) => c.to_string(),
            None => {
                return ResponseResult::Error {
                    error: format!("document not synced: {}", params.uri),
                }
            }
        };

        // Strategy dispatch: try `FullDoc` when configured; on
        // document-level compile failure (any error in the user's
        // source — not necessarily in a math fragment), fall through
        // to the synthetic per-fragment path.  Synthetic isolates
        // each fragment in its own synthetic page, so a single bad
        // fragment doesn't poison the rest.  The user briefly loses
        // full-doc niceties (paragraph-context font size, external
        // baseline) until the document parses again.
        if matches!(self.strategy, CompileStrategy::TopDown) {
            if let Ok(results) =
                TopDownCompiler::compile_all(&mut self.world, &content, &params.fragments)
            {
                return ResponseResult::Fragments { fragments: results };
            }
        }

        let mut results = Vec::new();
        for frag_loc in &params.fragments {
            if frag_loc.end > content.len() || frag_loc.start > frag_loc.end {
                results.push(FragmentResult {
                    start: frag_loc.start,
                    end: frag_loc.end,
                    svg: String::new(),
                    height_pt: 0.0,
                    depth_pt: 0.0,
                    width_pt: 0.0,
                            font_size_pt: Some(11.0),
                    error: Some("invalid fragment range".into()),
                            error_detail: None,
                });
                continue;
            }

            match BottomUpCompiler::compile_fragment_scoped(
                &mut self.world,
                &content,
                frag_loc.start,
                frag_loc.end,
                // Always render with the STANDIN_HEX sentinel, not the
                // client's color.  The post-render pass below rewrites
                // that sentinel to SVG's `currentColor', so Emacs picks
                // the actual foreground from the face at display time.
                // Author-specified `#text(fill: red)` etc. passes
                // through untouched.
                tip_protocol::svg_color::STANDIN_HEX,
                params.page_setup.as_deref(),
                params.preamble.as_deref(),
            ) {
                Ok(output) => {
                    results.push(FragmentResult {
                        start: frag_loc.start,
                        end: frag_loc.end,
                        svg: tip_protocol::svg_color::fills_to_current_color(
                            &output.svg,
                            tip_protocol::svg_color::STANDIN_HEX,
                        ),
                        height_pt: output.height_pt,
                        depth_pt: output.depth_pt,
                        width_pt: output.width_pt,
                            font_size_pt: Some(11.0),
                        error: None,
                            error_detail: None,
                    });
                }
                Err(err) => {
                    results.push(FragmentResult {
                        start: frag_loc.start,
                        end: frag_loc.end,
                        svg: String::new(),
                        height_pt: 0.0,
                        depth_pt: 0.0,
                        width_pt: 0.0,
                            font_size_pt: Some(11.0),
                        error: Some(err),
                            error_detail: None,
                    });
                }
            }
        }

        ResponseResult::Fragments { fragments: results }
    }

    pub fn handle_compile_live(&mut self, params: CompileLiveParams) -> ResponseResult {
        let content = match self.documents.get(&params.uri) {
            Some(c) => c.to_string(),
            None => {
                return ResponseResult::Error {
                    error: format!("document not synced: {}", params.uri),
                }
            }
        };

        // ALWAYS synth for live preview, regardless of strategy.
        // The benchmarks (bench_edit_append_new, bench_edit_middle in
        // full_doc.rs) showed that on a 5000-line doc full-doc has
        // p99 keystroke latency of ~5.7 SECONDS due to comemo cache
        // misses on mid-edit syntax errors.  Synth's per-fragment
        // compile is stable at ~30 ms even at 5k lines.  Visual
        // consistency between live and batch matters less than not
        // freezing the editor.

        match BottomUpCompiler::compile_fragment_scoped(
            &mut self.world,
            &content,
            params.start,
            params.end,
            tip_protocol::svg_color::STANDIN_HEX,
            params.page_setup.as_deref(),
            params.preamble.as_deref(),
        ) {
            Ok(output) => ResponseResult::Live {
                fragment: FragmentResult {
                    start: params.start,
                    end: params.end,
                    svg: tip_protocol::svg_color::fills_to_current_color(
                        &output.svg,
                        tip_protocol::svg_color::STANDIN_HEX,
                    ),
                    height_pt: output.height_pt,
                    depth_pt: output.depth_pt,
                    width_pt: output.width_pt,
                            font_size_pt: Some(11.0),
                    error: None,
                            error_detail: None,
                },
            },
            Err(err) => ResponseResult::Error { error: err },
        }
    }

    /// Typst has no dependency graph yet — return the URI alone.
    /// Clients pack just this file; if the user needs more, they re-run
    /// from a root file that imports everything.  Root dir is picked by
    /// the same marker walk `handle_sync' uses, or the URI's parent as
    /// fallback.
    pub fn handle_list_project_files(&self, params: ListProjectFilesParams) -> ResponseResult {
        let path = PathBuf::from(&params.uri);
        let root = path
            .parent()
            .and_then(Self::find_project_root)
            .or_else(|| path.parent().map(Path::to_path_buf))
            .unwrap_or_else(|| path.clone());
        ResponseResult::ProjectFiles {
            root: root.display().to_string(),
            files: vec![params.uri],
        }
    }

    pub fn handle_debug_skeleton(&self, params: DebugSkeletonParams) -> ResponseResult {
        let content = match self.documents.get(&params.uri) {
            Some(c) => c.to_string(),
            None => return ResponseResult::Error {
                error: format!("document not synced: {}", params.uri),
            },
        };
        match BottomUpCompiler::debug_scoped_source(&content, params.start, params.end) {
            Ok(source) => ResponseResult::DebugSkeleton { source },
            Err(err) => ResponseResult::Error { error: err },
        }
    }

    /// Fonts discovered by the underlying `TipWorld`.  Used by the
    /// `health_check` handler.
    pub fn fonts_found(&self) -> usize {
        self.world.font_count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sync_params(uri: &str, content: &str) -> SyncParams {
        SyncParams {
            backend: BackendId::Typst,
            project_root: None,
            uri: uri.into(),
            content: content.into(),
        }
    }

    fn fragments_params(uri: &str, fragments: Vec<FragmentLocation>) -> CompileFragmentsParams {
        CompileFragmentsParams {
            backend: BackendId::Typst,
            uri: uri.into(),
            fragments,
            color: "#000000".into(),
            page_setup: None,
            preamble: None,
            display_math_width: None,
        }
    }

    #[test]
    fn init_returns_ok() {
        let mut b = TypstBackend::new();
        let resp = b.handle_init(InitParams { font_dirs: vec![] });
        assert_eq!(resp, ResponseResult::Init { ok: true });
    }

    #[test]
    fn sync_then_compile_returns_svg() {
        let mut b = TypstBackend::new();
        b.handle_sync(sync_params("/test.typ", "$a + b$"));
        let resp = b.handle_compile_fragments(fragments_params(
            "/test.typ",
            vec![FragmentLocation { start: 0, end: 7 }],
        ));
        match resp {
            ResponseResult::Fragments { fragments } => {
                assert_eq!(fragments.len(), 1);
                assert!(fragments[0].svg.contains("<svg"));
                assert!(fragments[0].height_pt > 0.0);
            }
            other => panic!("expected fragments, got {:?}", other),
        }
    }

    #[test]
    fn compile_without_sync_errors() {
        let mut b = TypstBackend::new();
        let resp = b.handle_compile_fragments(fragments_params("/missing.typ", vec![]));
        match resp {
            ResponseResult::Error { error } => assert!(error.contains("not synced")),
            other => panic!("expected error, got {:?}", other),
        }
    }

    #[test]
    fn compile_live_returns_svg() {
        let mut b = TypstBackend::new();
        b.handle_sync(sync_params("/test.typ", "$x^2$"));
        let resp = b.handle_compile_live(CompileLiveParams {
            backend: BackendId::Typst,
            uri: "/test.typ".into(),
            start: 0,
            end: 5,
            color: "#000000".into(),
            page_setup: None,
            preamble: None,
        });
        match resp {
            ResponseResult::Live { fragment } => {
                assert!(fragment.svg.contains("<svg"));
                assert!(fragment.height_pt > 0.0);
            }
            other => panic!("expected live, got {:?}", other),
        }
    }
}
