pub mod compiler;
pub mod document;
pub mod full_doc;
pub mod world;

/// Which compilation strategy `TypstBackend::handle_compile_fragments`
/// uses.  See `full_doc` module docs for the rationale.
///
/// Default: `Synthetic` (today's per-fragment skeleton path).  Override
/// at server start via `TIP_COMPILE_STRATEGY=full-doc`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CompileStrategy {
    /// One synthetic doc per fragment.  Stable, current default.
    #[default]
    Synthetic,
    /// One real-document compile, frame-tree extraction per fragment.
    /// Currently a stub — falls back to `Synthetic` on every call.
    FullDoc,
}

impl CompileStrategy {
    /// Read `TIP_COMPILE_STRATEGY` at process start.  Unrecognized
    /// values silently fall back to `Synthetic` so a typo can't brick
    /// the server.
    pub fn from_env() -> Self {
        match std::env::var("TIP_COMPILE_STRATEGY").as_deref() {
            Ok("full-doc") | Ok("fulldoc") | Ok("full_doc") => Self::FullDoc,
            _ => Self::Synthetic,
        }
    }
}
