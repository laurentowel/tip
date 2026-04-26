//! Full-document compilation strategy (stub).
//!
//! Plan: compile the user's real document **once** with `typst::compile`,
//! then walk the resulting frame tree to extract per-fragment SVGs.
//! This inherits Typst's internal layout parallelism (the 2–3× speedup
//! the 0.12 blog post advertises) for free, because all fragments
//! share the same `compile()` call and the same comemo cache.
//!
//! Contrast: today's `FragmentCompiler::compile_fragment_scoped` builds
//! `N` synthetic single-page documents (skeleton + fragment) and runs
//! `compile()` `N` times — `N` cache misses, no shared layout work.
//! See `doc/full-document-approach.md` and the post-mortem on the
//! `parallel-compile` branch (kept as a documented dead end).
//!
//! This file is currently a stub.  Step 1 of the rollout: enum +
//! config + plumbing, default remains `Synthetic`.  Steps 2–5 are
//! tracked in the project plan.
//!
//! Step 2 will land:
//!   - byte-range → frame-item position mapping
//!   - per-fragment SVG cropping from the page frame
//!   - baseline measurement at frame-item granularity
//!   - error fallback policy (compile-error → fall back to Synthetic)

use crate::world::TipWorld;
use tip_protocol::messages::{FragmentLocation, FragmentResult};

pub struct FullDocCompiler;

impl FullDocCompiler {
    /// Compile every fragment in `fragments` from a single full-document
    /// compile of `content`.  Currently unimplemented — callers must
    /// fall back to the synthetic strategy.
    pub fn compile_all(
        _world: &mut TipWorld,
        _content: &str,
        fragments: &[FragmentLocation],
    ) -> Result<Vec<FragmentResult>, String> {
        let _ = fragments;
        Err("full-document compilation strategy not yet implemented".into())
    }
}
