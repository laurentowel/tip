pub mod baseline;
pub mod bottom_up;
pub mod document;
pub mod top_down;
pub mod world;

/// Which compilation strategy `TypstBackend::handle_compile_fragments`
/// uses.  See `top_down` module docs for the rationale.
///
/// `bottom-up`: one synthetic doc per fragment, built from scratch.
/// `top-down`: compile the real document once, descend the frame tree
/// to extract per-fragment SVGs.
///
/// Default: `BottomUp` (today's per-fragment skeleton path).  Override
/// at server start via `TIP_COMPILE_STRATEGY=top-down`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CompileStrategy {
    /// One synthetic doc per fragment.  Stable, current default.
    #[default]
    BottomUp,
    /// One real-document compile, frame-tree extraction per fragment.
    TopDown,
}

impl CompileStrategy {
    /// Read `TIP_COMPILE_STRATEGY` at process start.  Unrecognized
    /// values silently fall back to `BottomUp` so a typo can't brick
    /// the server.  The legacy `full-doc` aliases are kept for one
    /// release for backward compat.
    pub fn from_env() -> Self {
        match std::env::var("TIP_COMPILE_STRATEGY").as_deref() {
            Ok("top-down") | Ok("topdown") | Ok("top_down") => Self::TopDown,
            Ok("full-doc") | Ok("fulldoc") | Ok("full_doc") => Self::TopDown,
            _ => Self::BottomUp,
        }
    }
}
