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

use tip_protocol::messages::*;

use crate::diagnostics;
use crate::katex_backend::KatexBackend;
use crate::latex_backend::LatexBackend;
use crate::typst_backend::TypstBackend;

pub struct Handler {
    typst: TypstBackend,
    latex: LatexBackend,
    katex: KatexBackend,
    shutdown: bool,
}

impl Handler {
    pub fn new() -> Self {
        Self {
            typst: TypstBackend::new(),
            latex: LatexBackend::new(),
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
            Request::Init(params) => {
                // Font dirs only apply to typst.  LaTeX uses the system
                // TeX tree; KaTeX embeds its fonts at compile time.
                self.typst.handle_init(params)
            }
            Request::Sync(params) => match params.backend {
                BackendId::Typst => self.typst.handle_sync(params),
                BackendId::Latex => self.latex.handle_sync(params),
                BackendId::Katex => self.katex.handle_sync(params),
            },
            Request::CompileFragments(params) => match params.backend {
                BackendId::Typst => self.typst.handle_compile_fragments(params),
                BackendId::Latex => self.latex.handle_compile_fragments(params),
                BackendId::Katex => self.katex.handle_compile_fragments(params),
            },
            Request::CompileLive(params) => match params.backend {
                BackendId::Typst => self.typst.handle_compile_live(params),
                BackendId::Latex => self.latex.handle_compile_live(params),
                BackendId::Katex => self.katex.handle_compile_live(params),
            },
            Request::DebugSkeleton(params) => match params.backend {
                BackendId::Typst => self.typst.handle_debug_skeleton(params),
                BackendId::Latex => self.latex.handle_debug_skeleton(params),
                BackendId::Katex => self.katex.handle_debug_skeleton(params),
            },
            Request::HealthCheck => ResponseResult::Health {
                report: diagnostics::collect_report(&self.typst),
            },
            Request::ListProjectFiles(params) => match params.backend {
                BackendId::Typst => self.typst.handle_list_project_files(params),
                BackendId::Latex => self.latex.handle_list_project_files(params),
                BackendId::Katex => self.katex.handle_list_project_files(params),
            },
            Request::Shutdown => {
                self.shutdown = true;
                ResponseResult::Shutdown { ok: true }
            }
        };
        ResponseMessage { id, result }
    }
}
