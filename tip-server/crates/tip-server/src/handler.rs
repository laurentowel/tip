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

/// Dispatch a method call to the backend named in `params.backend`.
/// Each arm is gated by the corresponding feature flag; missing
/// backends fall through to `not_compiled_in`.
macro_rules! dispatch {
    ($self:expr, $params:expr, $method:ident) => {{
        let params = $params;
        #[allow(unreachable_patterns)]
        match params.backend {
            #[cfg(feature = "typst")]
            BackendId::Typst => $self.typst.$method(params),
            #[cfg(feature = "latex")]
            BackendId::Latex => $self.latex.$method(params),
            #[cfg(feature = "katex")]
            BackendId::Katex => $self.katex.$method(params),
            other => not_compiled_in(other),
        }
    }};
}

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
            Request::Sync(params) => dispatch!(self, params, handle_sync),
            Request::CompileFragments(params) => {
                dispatch!(self, params, handle_compile_fragments)
            }
            Request::DebugSkeleton(params) => dispatch!(self, params, handle_debug_skeleton),
            Request::HealthCheck => ResponseResult::Health {
                report: diagnostics::collect_report(self.typst_health_input()),
            },
            Request::ListProjectFiles(params) => {
                dispatch!(self, params, handle_list_project_files)
            }
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

fn not_compiled_in(b: BackendId) -> ResponseResult {
    ResponseResult::Error {
        error: format!("backend {:?} not compiled in this build", b),
    }
}

/// Build a `ProjectFiles` response for a backend with no dependency
/// graph: the project consists of the URI alone, rooted at `root`.
/// Used by Typst (after a marker walk) and KaTeX (parent dir).
pub(crate) fn single_file_project(root: std::path::PathBuf, uri: String) -> ResponseResult {
    ResponseResult::ProjectFiles {
        root: root.display().to_string(),
        files: vec![uri],
    }
}
