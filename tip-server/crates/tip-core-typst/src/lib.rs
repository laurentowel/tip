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
/// Default: `BottomUp` (today's per-fragment skeleton path).  The
/// dispatch lives in `tip_server::typst_backend`; that's also where
/// `TIP_COMPILE_STRATEGY` is parsed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CompileStrategy {
    /// One synthetic doc per fragment.  Stable, current default.
    #[default]
    BottomUp,
    /// One real-document compile, frame-tree extraction per fragment.
    TopDown,
}
