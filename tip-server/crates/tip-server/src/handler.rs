//! Unified dispatcher for the `tip-server` binary.
//!
//! Routes each request to the backend indicated by the message's
//! `backend` field (set by the client from `tip-active-backend`, which
//! is derived from the buffer's `major-mode` — NOT from the URI, since
//! files may have nonstandard extensions or no associated file at all).
//!
//! Per-request routing (rather than per-session) means a single server
//! process can serve both a Typst and a LaTeX buffer in the same Emacs
//! session without restart.
//!
//! Backends are Cargo-feature gated.  A request for a backend not
//! compiled in returns `error: "backend not compiled in"`.  See
//! `Cargo.toml`'s `[features]` block for the slim-build recipes.

use tip_protocol::messages::*;

use crate::diagnostics;
#[cfg(feature = "katex")]
use crate::katex_backend::KatexBackend;
#[cfg(feature = "latex")]
use crate::latex_backend::LatexBackend;
#[cfg(feature = "typst")]
use crate::typst_backend::TypstBackend;

pub struct Handler {
    #[cfg(feature = "typst")]
    typst: TypstBackend,
    #[cfg(feature = "latex")]
    latex: LatexBackend,
    #[cfg(feature = "katex")]
    katex: KatexBackend,
    shutdown: bool,
}

impl Handler {
    pub fn new() -> Self {
        Self {
            #[cfg(feature = "typst")]
            typst: TypstBackend::new(),
            #[cfg(feature = "latex")]
            latex: LatexBackend::new(),
            #[cfg(feature = "katex")]
            katex: KatexBackend::new(),
            shutdown: false,
        }
    }

    pub fn should_shutdown(&self) -> bool {
        self.shutdown
    }

    pub fn handle(&mut self, msg: RequestMessage) -> ResponseMessage {
        let id = msg.id;
        let result = match msg.request {
            Request::Init(_params) => {
                // `init` carries font_dirs (Typst-only) + the version
                // handshake.  Without typst we still need to honor the
                // handshake — emit a minimal Init response.
                #[cfg(feature = "typst")]
                {
                    self.typst.handle_init(_params)
                }
                #[cfg(not(feature = "typst"))]
                {
                    let mismatch = match _params.client_version.as_deref() {
                        Some(v) if v != tip_protocol::messages::PROTOCOL_VERSION => format!(
                            "client speaks {} but server speaks {}",
                            v,
                            tip_protocol::messages::PROTOCOL_VERSION
                        ),
                        _ => String::new(),
                    };
                    ResponseResult::Init {
                        ok: true,
                        server_version: tip_protocol::messages::PROTOCOL_VERSION.to_string(),
                        version_mismatch: mismatch,
                    }
                }
            }
            Request::Sync(params) => self.dispatch_sync(params),
            Request::CompileFragments(params) => self.dispatch_compile_fragments(params),
            Request::CompileLive(params) => self.dispatch_compile_live(params),
            Request::DebugSkeleton(params) => self.dispatch_debug_skeleton(params),
            Request::HealthCheck => ResponseResult::Health {
                report: diagnostics::collect_report(self.typst_health_input()),
            },
            Request::ListProjectFiles(params) => self.dispatch_list_project_files(params),
            Request::Shutdown => {
                self.shutdown = true;
                ResponseResult::Shutdown { ok: true }
            }
        };
        ResponseMessage { id, result }
    }

    /// Reference to the typst backend for the diagnostics probe, or
    /// `None` when typst isn't compiled in.  Centralized so the
    /// `health_check` arm above doesn't need its own cfg.
    #[cfg(feature = "typst")]
    fn typst_health_input(&self) -> Option<&TypstBackend> {
        Some(&self.typst)
    }
    #[cfg(not(feature = "typst"))]
    fn typst_health_input(&self) -> Option<&()> {
        None
    }
}

// Per-method dispatchers.  Each is a small `match` over `BackendId`
// where the arm exists only if the corresponding feature is enabled;
// the catch-all returns `not compiled in`.

fn not_compiled_in(b: BackendId) -> ResponseResult {
    ResponseResult::Error {
        error: format!("backend {:?} not compiled in this build", b),
    }
}

impl Handler {
    fn dispatch_sync(&mut self, params: SyncParams) -> ResponseResult {
        #[allow(unreachable_patterns)]
        match params.backend {
            #[cfg(feature = "typst")]
            BackendId::Typst => self.typst.handle_sync(params),
            #[cfg(feature = "latex")]
            BackendId::Latex => self.latex.handle_sync(params),
            #[cfg(feature = "katex")]
            BackendId::Katex => self.katex.handle_sync(params),
            other => not_compiled_in(other),
        }
    }

    fn dispatch_compile_fragments(
        &mut self,
        params: CompileFragmentsParams,
    ) -> ResponseResult {
        #[allow(unreachable_patterns)]
        match params.backend {
            #[cfg(feature = "typst")]
            BackendId::Typst => self.typst.handle_compile_fragments(params),
            #[cfg(feature = "latex")]
            BackendId::Latex => self.latex.handle_compile_fragments(params),
            #[cfg(feature = "katex")]
            BackendId::Katex => self.katex.handle_compile_fragments(params),
            other => not_compiled_in(other),
        }
    }

    fn dispatch_compile_live(&mut self, params: CompileLiveParams) -> ResponseResult {
        #[allow(unreachable_patterns)]
        match params.backend {
            #[cfg(feature = "typst")]
            BackendId::Typst => self.typst.handle_compile_live(params),
            #[cfg(feature = "latex")]
            BackendId::Latex => self.latex.handle_compile_live(params),
            #[cfg(feature = "katex")]
            BackendId::Katex => self.katex.handle_compile_live(params),
            other => not_compiled_in(other),
        }
    }

    fn dispatch_debug_skeleton(&mut self, params: DebugSkeletonParams) -> ResponseResult {
        #[allow(unreachable_patterns)]
        match params.backend {
            #[cfg(feature = "typst")]
            BackendId::Typst => self.typst.handle_debug_skeleton(params),
            #[cfg(feature = "latex")]
            BackendId::Latex => self.latex.handle_debug_skeleton(params),
            #[cfg(feature = "katex")]
            BackendId::Katex => self.katex.handle_debug_skeleton(params),
            other => not_compiled_in(other),
        }
    }

    fn dispatch_list_project_files(
        &mut self,
        params: ListProjectFilesParams,
    ) -> ResponseResult {
        #[allow(unreachable_patterns)]
        match params.backend {
            #[cfg(feature = "typst")]
            BackendId::Typst => self.typst.handle_list_project_files(params),
            #[cfg(feature = "latex")]
            BackendId::Latex => self.latex.handle_list_project_files(params),
            #[cfg(feature = "katex")]
            BackendId::Katex => self.katex.handle_list_project_files(params),
            other => not_compiled_in(other),
        }
    }
}
