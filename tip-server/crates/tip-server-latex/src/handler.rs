//! Protocol handler for tip-server-latex.
//!
//! Receives the same JSON-RPC messages as tip-server-typst (see
//! tip-protocol). Implements `sync`, `compile_fragments`, and
//! `shutdown`. `init`, `compile_live`, and `debug_skeleton` are accepted
//! with minimal/no-op implementations — they can grow as needed.

use std::path::Path;

use tip_core_latex::{DocumentStore, LatexCompiler};
use tip_protocol::messages::*;

pub struct Handler {
    documents: DocumentStore,
    shutdown: bool,
}

impl Handler {
    pub fn new() -> Self {
        Self {
            documents: DocumentStore::new(),
            shutdown: false,
        }
    }

    pub fn should_shutdown(&self) -> bool {
        self.shutdown
    }

    pub fn handle(&mut self, msg: RequestMessage) -> ResponseMessage {
        let id = msg.id;
        let result = match msg.request {
            Request::Init(_) => ResponseResult::Init { ok: true },
            Request::Sync(params) => self.handle_sync(params),
            Request::CompileFragments(params) => self.handle_compile_fragments(params),
            Request::CompileLive(params) => self.handle_compile_live(params),
            Request::DebugSkeleton(_) => ResponseResult::Error {
                error: "debug_skeleton not implemented for LaTeX backend".into(),
            },
            Request::Shutdown => {
                self.shutdown = true;
                ResponseResult::Shutdown { ok: true }
            }
        };
        ResponseMessage { id, result }
    }

    fn handle_sync(&mut self, params: SyncParams) -> ResponseResult {
        self.documents.sync(params.uri, params.content);
        ResponseResult::Sync { ok: true }
    }

    fn handle_compile_fragments(&mut self, params: CompileFragmentsParams) -> ResponseResult {
        let content = match self.documents.get(&params.uri) {
            Some(c) => c.to_string(),
            None => {
                return ResponseResult::Error {
                    error: format!("document not synced: {}", params.uri),
                }
            }
        };

        // Extract each fragment's raw source.
        let fragment_srcs: Vec<&str> = params
            .fragments
            .iter()
            .filter_map(|loc| content.get(loc.start..loc.end))
            .collect();
        if fragment_srcs.len() != params.fragments.len() {
            return ResponseResult::Error {
                error: "fragment byte range out of bounds".into(),
            };
        }

        // Preamble comes from the client; default if empty.
        let preamble = params.preamble.as_deref().unwrap_or_default();
        let preamble = if preamble.trim().is_empty() {
            "\\documentclass{article}\n\\usepackage{amsmath,amssymb}\n"
        } else {
            preamble
        };

        // Inject color into the preamble via \color{...} in the body? Simplest:
        // prepend a \color directive to each fragment.  Keep it inline so
        // fragments that are \begin{equation} still work.
        let color_cmd = color_command(&params.color);
        let wrapped: Vec<String> = fragment_srcs
            .iter()
            .map(|s| format!("{}{}", color_cmd, s))
            .collect();
        let wrapped_refs: Vec<&str> = wrapped.iter().map(String::as_str).collect();

        // Working dir = directory of the uri, so relative \includegraphics etc.
        // resolve the same way they would during a real compile.
        let cwd = Path::new(&params.uri).parent().map(Path::to_path_buf);

        match LatexCompiler::compile_batch(preamble, &wrapped_refs, cwd.as_deref()) {
            Ok(batch) => {
                let mut results = Vec::with_capacity(batch.len());
                for (loc, out) in params.fragments.iter().zip(batch.into_iter()) {
                    match out {
                        Ok(frag) => results.push(FragmentResult {
                            start: loc.start,
                            end: loc.end,
                            svg: frag.svg,
                            height_pt: frag.height_pt,
                            depth_pt: frag.depth_pt,
                            width_pt: frag.width_pt,
                            error: None,
                        }),
                        Err(e) => results.push(FragmentResult {
                            start: loc.start,
                            end: loc.end,
                            svg: String::new(),
                            height_pt: 0.0,
                            depth_pt: 0.0,
                            width_pt: 0.0,
                            error: Some(e),
                        }),
                    }
                }
                ResponseResult::Fragments { fragments: results }
            }
            Err(err) => ResponseResult::Error {
                error: err.message(),
            },
        }
    }

    fn handle_compile_live(&mut self, params: CompileLiveParams) -> ResponseResult {
        // Map live → batch-of-one.
        let fragments_params = CompileFragmentsParams {
            uri: params.uri,
            fragments: vec![FragmentLocation {
                start: params.start,
                end: params.end,
            }],
            color: params.color,
            page_setup: params.page_setup,
            preamble: params.preamble,
        };
        match self.handle_compile_fragments(fragments_params) {
            ResponseResult::Fragments { mut fragments } if !fragments.is_empty() => {
                ResponseResult::Live {
                    fragment: fragments.remove(0),
                }
            }
            other => other,
        }
    }
}

/// Convert `#RRGGBB` or a named color to a LaTeX `\color[HTML]{RRGGBB}`.
fn color_command(color: &str) -> String {
    if let Some(hex) = color.strip_prefix('#') {
        if hex.len() == 6 && hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return format!("\\color[HTML]{{{}}}", hex.to_ascii_uppercase());
        }
    }
    // Fallback: pass through as a named color.
    format!("\\color{{{}}}", color)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn color_from_hex() {
        assert_eq!(color_command("#abcdef"), "\\color[HTML]{ABCDEF}");
    }

    #[test]
    fn color_from_name() {
        assert_eq!(color_command("red"), "\\color{red}");
    }

    #[test]
    fn shutdown_sets_flag() {
        let mut h = Handler::new();
        let resp = h.handle(RequestMessage {
            id: 1,
            request: Request::Shutdown,
        });
        assert_eq!(resp.result, ResponseResult::Shutdown { ok: true });
        assert!(h.should_shutdown());
    }

    #[test]
    fn compile_without_sync_errors() {
        let mut h = Handler::new();
        let resp = h.handle(RequestMessage {
            id: 1,
            request: Request::CompileFragments(CompileFragmentsParams {
                uri: "/missing.tex".into(),
                fragments: vec![FragmentLocation { start: 0, end: 0 }],
                color: "#000000".into(),
                page_setup: None,
                preamble: None,
            }),
        });
        match resp.result {
            ResponseResult::Error { error } => {
                assert!(error.contains("not synced"));
            }
            other => panic!("expected error, got {:?}", other),
        }
    }
}
