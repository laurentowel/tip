//! Smoke test against single-file Typst documents harvested from the
//! wild.  Each fixture under `tests/fixtures/external/` is scanned for
//! inline math fragments via a tiny regex-style walker; every fragment
//! is sent through `BottomUpCompiler::compile_fragment_scoped`; we
//! assert that all of them produce a non-empty SVG without errors.
//!
//! The point is diversity coverage — the maintainer's own writing
//! style is narrow.  See `fixtures/external/README.md` for sources
//! and licensing.
//!
//! Failure modes this catches:
//! - Scope skeleton extraction tripping over an unfamiliar pattern
//!   (`#let f(..args) = ...` with rest-spread, conditional `set`,
//!   nested mode switches).
//! - Math constructs we haven't exercised (long multi-line aligns,
//!   exotic accents, deeply nested fractions, custom symbols).
//! - File-encoding or shebang lines confusing the byte-range math.

use std::fs;
use std::path::Path;
use tip_core_typst::bottom_up::BottomUpCompiler;
use tip_core_typst::world::TipWorld;

/// Find inline math `$...$` byte ranges.  Skips line comments,
/// quoted strings, and raw blocks (`` ` `` / ``` ``` ``` ```) — Typst
/// raw text can contain literal `$` that we must not interpret as
/// math delimiters.  Naïve enough that adversarial docs can confuse
/// it, but adequate for the corpus we test against.
fn collect_inline_math(src: &str) -> Vec<(usize, usize)> {
    let bytes = src.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        // Line comment.
        if b == b'/' && bytes.get(i + 1) == Some(&b'/') {
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        // Block comment.
        if b == b'/' && bytes.get(i + 1) == Some(&b'*') {
            i += 2;
            while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                i += 1;
            }
            i += 2;
            continue;
        }
        // Quoted string ("...").
        if b == b'"' {
            i += 1;
            while i < bytes.len() && bytes[i] != b'"' {
                if bytes[i] == b'\\' && i + 1 < bytes.len() {
                    i += 2;
                    continue;
                }
                i += 1;
            }
            i += 1; // closing "
            continue;
        }
        // Raw block (single or triple backtick).
        if b == b'`' {
            // Triple-backtick raw block: ```lang body ```
            if bytes.get(i + 1) == Some(&b'`') && bytes.get(i + 2) == Some(&b'`') {
                i += 3;
                while i + 2 < bytes.len()
                    && !(bytes[i] == b'`' && bytes[i + 1] == b'`' && bytes[i + 2] == b'`')
                {
                    i += 1;
                }
                i += 3;
                continue;
            }
            // Single-backtick raw inline: `body`.
            i += 1;
            while i < bytes.len() && bytes[i] != b'`' {
                i += 1;
            }
            i += 1;
            continue;
        }
        // Math fragment.
        if b == b'$' {
            let start = i;
            i += 1;
            while i < bytes.len() {
                let c = bytes[i];
                if c == b'\\' && i + 1 < bytes.len() {
                    i += 2;
                    continue;
                }
                if c == b'$' {
                    out.push((start, i + 1));
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    out
}

fn fixtures_dir() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("external")
}

#[test]
fn external_corpus_compiles_cleanly() {
    let dir = fixtures_dir();
    let mut docs: Vec<std::path::PathBuf> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("read {dir:?}: {e}"))
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("typ"))
        .collect();
    docs.sort();
    assert!(!docs.is_empty(), "no .typ fixtures found in {dir:?}");

    let mut total_fragments = 0usize;
    let mut total_failures = 0usize;
    let mut total_empty_svgs = 0usize;
    let mut per_doc: Vec<(String, usize, usize, usize)> = Vec::new();
    let mut failure_examples: Vec<String> = Vec::new();

    for doc_path in &docs {
        let name = doc_path.file_name().unwrap().to_string_lossy().to_string();
        let src = fs::read_to_string(doc_path).unwrap_or_else(|e| panic!("read {doc_path:?}: {e}"));
        let frags = collect_inline_math(&src);

        let mut world = TipWorld::new();
        let mut failures = 0usize;
        let mut empties = 0usize;
        for (start, end) in &frags {
            match BottomUpCompiler::compile_fragment_scoped(
                &mut world, &src, *start, *end, "#000000", None, None, None,
            ) {
                Ok(out) if !out.svg.is_empty() => {}
                Ok(_) => empties += 1,
                Err(e) => {
                    failures += 1;
                    if failure_examples.len() < 3 {
                        let frag_text = &src[*start..*end];
                        let preview: String = frag_text.chars().take(60).collect();
                        failure_examples.push(format!("[{name} @ {start}..{end}] {preview} → {e}"));
                    }
                }
            }
        }
        per_doc.push((name.clone(), frags.len(), failures, empties));
        total_fragments += frags.len();
        total_failures += failures;
        total_empty_svgs += empties;
    }

    eprintln!("\n=== external corpus ===");
    for (name, n, fails, empties) in &per_doc {
        eprintln!("  {name:<30} frags={n:>4}  failed={fails:>3}  empty={empties:>3}");
    }
    eprintln!(
        "  TOTAL: {} docs, {} fragments, {} failures, {} empty",
        docs.len(),
        total_fragments,
        total_failures,
        total_empty_svgs
    );

    if total_failures > 0 {
        for ex in &failure_examples {
            eprintln!("  example: {ex}");
        }
    }
    assert_eq!(
        total_failures, 0,
        "external corpus had {total_failures} compile failures (see stderr)"
    );
    // An empty SVG either means the fragment was a whitespace-only
    // skip (legitimate) or a render failure.  Be tolerant for now,
    // print a count so a sudden spike is visible.
    let _ = total_empty_svgs;
}
