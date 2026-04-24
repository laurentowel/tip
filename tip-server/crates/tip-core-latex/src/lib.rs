//! LaTeX backend core: orchestrates `latex` + `dvisvgm` to render math
//! fragments from a buffer into SVGs with baseline/ink metrics.
//!
//! The compiler is stateless between batches — `compile_batch` takes a
//! preamble and a list of fragment source strings, returns one
//! [`FragmentOutput`] per input in order.  See module docs in
//! [`compiler`] for the pipeline details.

pub mod compiler;
pub mod document;
pub mod project;

pub use compiler::{FragmentOutput, LatexCompiler, LatexError};
pub use document::DocumentStore;
pub use project::{ProjectError, Script, TexProject};
