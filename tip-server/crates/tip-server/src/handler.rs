use std::path::Path;

use tip_core::compiler::FragmentCompiler;
use tip_core::document::DocumentStore;
use tip_core::world::TipWorld;
use tip_protocol::messages::*;

pub struct Handler {
    documents: DocumentStore,
    world: TipWorld,
    shutdown: bool,
}

impl Handler {
    pub fn new() -> Self {
        Self {
            documents: DocumentStore::new(),
            world: TipWorld::new(),
            shutdown: false,
        }
    }

    pub fn should_shutdown(&self) -> bool {
        self.shutdown
    }

    pub fn handle(&mut self, msg: RequestMessage) -> ResponseMessage {
        let id = msg.id;
        let result = match msg.request {
            Request::Sync(params) => self.handle_sync(params),
            Request::CompileFragments(params) => self.handle_compile_fragments(params),
            Request::CompileLive(params) => self.handle_compile_live(params),
            Request::Shutdown => self.handle_shutdown(),
        };
        ResponseMessage { id, result }
    }

    fn handle_sync(&mut self, params: SyncParams) -> ResponseResult {
        // Set project root from the file's parent directory
        if let Some(parent) = Path::new(&params.uri).parent() {
            self.world.set_root(parent.to_path_buf());
        }
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

        let mut results = Vec::new();
        for frag_loc in &params.fragments {
            if frag_loc.end > content.len() || frag_loc.start > frag_loc.end {
                results.push(FragmentResult {
                    start: frag_loc.start,
                    end: frag_loc.end,
                    svg: String::new(),
                    height_pt: 0.0,
                    depth_pt: 0.0,
                    error: Some("invalid fragment range".into()),
                });
                continue;
            }

            match FragmentCompiler::compile_fragment_scoped(
                &mut self.world,
                &content,
                frag_loc.start,
                frag_loc.end,
                &params.color,
                params.page_setup.as_deref(),
                params.preamble.as_deref(),
            ) {
                Ok(output) => {
                    results.push(FragmentResult {
                        start: frag_loc.start,
                        end: frag_loc.end,
                        svg: output.svg,
                        height_pt: output.height_pt,
                        depth_pt: output.depth_pt,
                        error: None,
                    });
                }
                Err(err) => {
                    results.push(FragmentResult {
                        start: frag_loc.start,
                        end: frag_loc.end,
                        svg: String::new(),
                        height_pt: 0.0,
                        depth_pt: 0.0,
                        error: Some(err),
                    });
                }
            }
        }

        ResponseResult::Fragments { fragments: results }
    }

    fn handle_compile_live(&mut self, params: CompileLiveParams) -> ResponseResult {
        let content = match self.documents.get(&params.uri) {
            Some(c) => c.to_string(),
            None => {
                return ResponseResult::Error {
                    error: format!("document not synced: {}", params.uri),
                }
            }
        };

        match FragmentCompiler::compile_fragment_scoped(
            &mut self.world,
            &content,
            params.start,
            params.end,
            &params.color,
            params.page_setup.as_deref(),
            params.preamble.as_deref(),
        ) {
            Ok(output) => ResponseResult::Live {
                fragment: FragmentResult {
                    start: params.start,
                    end: params.end,
                    svg: output.svg,
                    height_pt: output.height_pt,
                    depth_pt: output.depth_pt,
                    error: None,
                },
            },
            Err(err) => ResponseResult::Error { error: err },
        }
    }

    fn handle_shutdown(&mut self) -> ResponseResult {
        self.shutdown = true;
        ResponseResult::Shutdown { ok: true }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_handler() -> Handler {
        Handler::new()
    }

    #[test]
    fn sync_then_compile_returns_svg() {
        let mut h = make_handler();

        h.handle(RequestMessage {
            id: 1,
            request: Request::Sync(SyncParams {
                uri: "/test.typ".into(),
                content: "$a + b$".into(),
            }),
        });

        let resp = h.handle(RequestMessage {
            id: 2,
            request: Request::CompileFragments(CompileFragmentsParams {
                uri: "/test.typ".into(),
                fragments: vec![FragmentLocation { start: 0, end: 7 }],
                color: "#000000".into(),
                page_setup: None,
                preamble: None,
            }),
        });
        assert_eq!(resp.id, 2);
        match &resp.result {
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
        let mut h = make_handler();
        let resp = h.handle(RequestMessage {
            id: 1,
            request: Request::CompileFragments(CompileFragmentsParams {
                uri: "/missing.typ".into(),
                fragments: vec![],
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

    #[test]
    fn compile_live_returns_svg() {
        let mut h = make_handler();

        h.handle(RequestMessage {
            id: 1,
            request: Request::Sync(SyncParams {
                uri: "/test.typ".into(),
                content: "$x^2$".into(),
            }),
        });

        let resp = h.handle(RequestMessage {
            id: 2,
            request: Request::CompileLive(CompileLiveParams {
                uri: "/test.typ".into(),
                start: 0,
                end: 5,
                color: "#000000".into(),
                page_setup: None,
                preamble: None,
            }),
        });
        match &resp.result {
            ResponseResult::Live { fragment } => {
                assert!(fragment.svg.contains("<svg"));
                assert!(fragment.height_pt > 0.0);
            }
            other => panic!("expected live result, got {:?}", other),
        }
    }

    #[test]
    fn shutdown_sets_flag() {
        let mut h = make_handler();
        assert!(!h.should_shutdown());
        let resp = h.handle(RequestMessage {
            id: 1,
            request: Request::Shutdown,
        });
        assert_eq!(resp.result, ResponseResult::Shutdown { ok: true });
        assert!(h.should_shutdown());
    }
}
