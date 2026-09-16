//! Paged document validation, without SVG extraction or synthetic fallback.

use tip_protocol::messages::{Diagnostic, ErrorSeverity, ValidateResult};
use typst::diag::{Severity, SourceDiagnostic};
use typst::syntax::Lines;
use typst::{World, WorldExt};
use typst_layout::PagedDocument;

use crate::world::TipWorld;

pub fn validate(world: &mut TipWorld, content: &str) -> ValidateResult {
    world.refresh_validation_sources(content);
    let result = typst::compile::<PagedDocument>(world);
    let ok = result.output.is_ok();
    // Typst exposes errors and warnings separately. Preserve each vector's
    // emission order, with errors first, and keep warnings even on success.
    let errors = result.output.err().unwrap_or_default();
    let diagnostics = errors
        .iter()
        .chain(result.warnings.iter())
        .map(|d| diagnostic(world, d))
        .collect();
    ValidateResult { ok, diagnostics }
}

fn diagnostic(world: &TipWorld, source: &SourceDiagnostic) -> Diagnostic {
    let mut result = Diagnostic {
        severity: match source.severity {
            Severity::Error => ErrorSeverity::Error,
            Severity::Warning => ErrorSeverity::Warning,
        },
        message: source.message.to_string(),
        path: None,
        line: None,
        column: None,
        byte_start: None,
        byte_end: None,
        hint: None,
    };
    let Some(id) = source.span.id() else {
        return result;
    };
    if id != world.main() {
        result.path = world.resolve_path(id).ok().map(|p| p.display().to_string());
    }
    let Some(range) = world.range(source.span) else {
        return result;
    };
    result.byte_start = u32::try_from(range.start).ok();
    result.byte_end = u32::try_from(range.end).ok();
    // `file` also covers diagnostic ranges in non-Typst files (JSON, CSV).
    if let Ok(bytes) = world.file(id) {
        if let Ok(text) = std::str::from_utf8(bytes.as_slice()) {
            let lines = Lines::new(text);
            if let Some((line, column)) = lines.byte_to_line_column(range.start) {
                result.line = u32::try_from(line + 1).ok();
                result.column = u32::try_from(column + 1).ok();
                result.hint = lines
                    .line_to_range(line)
                    .and_then(|r| text.get(r))
                    .map(|s| s.trim_end_matches(['\r', '\n']).to_owned());
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use typst::syntax::Span;

    #[test]
    fn detached_diagnostic_has_no_location() {
        let world = TipWorld::new();
        let d = diagnostic(&world, &SourceDiagnostic::error(Span::detached(), "oops"));
        assert_eq!(d.message, "oops");
        assert_eq!(d.severity, ErrorSeverity::Error);
        assert_eq!(
            (d.path, d.line, d.column, d.byte_start, d.byte_end, d.hint),
            (None, None, None, None, None, None)
        );
    }
}
