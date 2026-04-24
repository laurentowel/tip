//! Dependency probing for `health_check` responses.
//!
//! Designed to be reusable for a future `bug_report` handler: the
//! [`HealthReport`] it produces already carries server version,
//! OS/arch, per-backend probe results, and warnings — exactly what
//! we'd want a user to paste into a GitHub issue.  A `bug_report`
//! command would just add user-supplied context (description,
//! reproduction steps) to the same structure.

use std::process::Command;

use tip_protocol::messages::{BinaryProbe, HealthReport, LatexHealth, TypstHealth};

use crate::typst_backend::TypstBackend;

/// Collect a full diagnostic report.  Cheap enough (a few short
/// subprocess calls) to run synchronously in the request handler.
pub fn collect_report(typst: &TypstBackend) -> HealthReport {
    let mut warnings = Vec::new();
    let latex = probe_latex_deps(&mut warnings);
    let typst_health = Some(TypstHealth {
        ok: true,
        typst_version: typst_crate_version(),
        fonts_found: typst.fonts_found(),
    });
    HealthReport {
        server_version: env!("CARGO_PKG_VERSION").to_string(),
        target_triple: target_triple().to_string(),
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        typst: typst_health,
        latex: Some(latex),
        warnings,
    }
}

fn probe_latex_deps(warnings: &mut Vec<String>) -> LatexHealth {
    let latex = probe_binary("latex", &["--version"], None);
    let dvisvgm = probe_binary("dvisvgm", &["--version"], None);
    let preview_sty = probe_kpsewhich("preview.sty");

    if !latex.found {
        warnings.push("`latex` not found in PATH — LaTeX fragments will fail".into());
    }
    if !dvisvgm.found {
        warnings.push("`dvisvgm` not found in PATH — LaTeX fragments will fail".into());
    }
    if !preview_sty.found {
        warnings.push(
            "`preview.sty` not found (kpsewhich); install texlive-latex-extra or similar".into(),
        );
    }

    let ok = latex.found && dvisvgm.found && preview_sty.found;
    LatexHealth { ok, latex, dvisvgm, preview_sty }
}

/// Run `cmd args...`, parse the first line of stdout as the version.
/// `min_version`: if `Some`, compare; `None` means no floor.
fn probe_binary(cmd: &str, args: &[&str], min_version: Option<&str>) -> BinaryProbe {
    let path = which::which(cmd).ok().map(|p| p.display().to_string());
    let found = path.is_some();
    let version = if found {
        Command::new(cmd)
            .args(args)
            .output()
            .ok()
            .and_then(|o| {
                let s = String::from_utf8_lossy(&o.stdout).to_string();
                s.lines().next().map(|l| l.trim().to_string())
            })
    } else {
        None
    };
    let meets = match (min_version, version.as_deref()) {
        (None, _) => true,
        (Some(_), None) => false,
        (Some(min), Some(v)) => version_at_least(v, min),
    };
    BinaryProbe {
        found,
        path,
        version,
        meets_min_version: meets,
    }
}

/// `kpsewhich` is part of any TeX Live / MacTeX install; use it to
/// resolve a package file.  Returns a BinaryProbe where `path` is the
/// resolved .sty location and `version` is parsed from the file header
/// when we can find it.
fn probe_kpsewhich(pkg: &str) -> BinaryProbe {
    let out = Command::new("kpsewhich").arg(pkg).output();
    match out {
        Ok(o) if o.status.success() => {
            let path = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if path.is_empty() {
                return BinaryProbe {
                    found: false,
                    path: None,
                    version: None,
                    meets_min_version: true,
                };
            }
            // Try to extract a version from the first 20 lines of the file.
            let version = std::fs::read_to_string(&path)
                .ok()
                .and_then(|s| parse_sty_version(&s));
            BinaryProbe {
                found: true,
                path: Some(path),
                version,
                meets_min_version: true,
            }
        }
        _ => BinaryProbe {
            found: false,
            path: None,
            version: None,
            meets_min_version: true,
        },
    }
}

/// Best-effort scrape of a `\ProvidesPackage{foo}[YYYY/MM/DD vX.Y desc]` line.
/// Returns just the date + version token (e.g. "2017/04/15 v13.2"), dropping
/// the trailing prose.
fn parse_sty_version(source: &str) -> Option<String> {
    for line in source.lines().take(40) {
        if let Some(start) = line.find('[') {
            if let Some(end) = line[start..].find(']') {
                let bracket = line[start + 1..start + end].trim();
                // Keep at most the first two whitespace-separated tokens:
                // "YYYY/MM/DD vX.Y" — drop the package description after.
                let mut it = bracket.split_whitespace();
                return match (it.next(), it.next()) {
                    (Some(a), Some(b)) => Some(format!("{a} {b}")),
                    (Some(a), None) => Some(a.to_string()),
                    _ => None,
                };
            }
        }
    }
    None
}

/// Compare dotted version strings.  Pulls the first run of digits-dot-digits
/// from each and does numeric component-wise comparison.  Tolerant of
/// prefixes like "dvisvgm 2.14.2".
fn version_at_least(found: &str, min: &str) -> bool {
    fn parse(s: &str) -> Vec<u32> {
        // Find the first digit, then read a dotted numeric run.
        let bytes = s.as_bytes();
        let start = bytes.iter().position(|b| b.is_ascii_digit());
        let Some(mut i) = start else { return vec![] };
        let mut parts = Vec::new();
        let mut cur = 0u32;
        loop {
            match bytes.get(i) {
                Some(b) if b.is_ascii_digit() => {
                    cur = cur * 10 + (b - b'0') as u32;
                    i += 1;
                }
                Some(b'.') => {
                    parts.push(cur);
                    cur = 0;
                    i += 1;
                }
                _ => {
                    parts.push(cur);
                    break;
                }
            }
        }
        parts
    }
    let f = parse(found);
    let m = parse(min);
    // Component-wise compare; pad shorter side with zeros.
    for i in 0..f.len().max(m.len()) {
        let a = f.get(i).copied().unwrap_or(0);
        let b = m.get(i).copied().unwrap_or(0);
        if a > b {
            return true;
        }
        if a < b {
            return false;
        }
    }
    true
}

fn typst_crate_version() -> String {
    // Hardcoded because typst doesn't expose CARGO_PKG_VERSION via its public API
    // and we don't want to parse Cargo.lock at runtime.  Keep in sync with the
    // [dependencies] pin in tip-core-typst/Cargo.toml.
    "0.14.2".to_string()
}

fn target_triple() -> &'static str {
    // Set via build.rs or via env; fall back to a runtime best-effort.
    option_env!("TARGET").unwrap_or("unknown")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_compare_equal_and_greater() {
        assert!(version_at_least("2.14", "2.14"));
        assert!(version_at_least("2.15", "2.14"));
        assert!(version_at_least("3.0", "2.14"));
        assert!(!version_at_least("2.13", "2.14"));
        assert!(!version_at_least("2.8", "2.14"));
    }

    #[test]
    fn version_compare_with_prefix() {
        // dvisvgm --version prints e.g. "dvisvgm 2.14.2"
        assert!(version_at_least("dvisvgm 2.14.2", "2.14"));
        assert!(!version_at_least("dvisvgm 2.8.1", "2.14"));
    }

    #[test]
    fn version_compare_different_lengths() {
        assert!(version_at_least("2.14.0", "2.14"));
        assert!(version_at_least("2.14", "2.14.0"));
        assert!(version_at_least("2.14.1", "2.14"));
    }

    #[test]
    fn parse_sty_version_provides_line() {
        let src = "\\NeedsTeXFormat{LaTeX2e}\n\
                   \\ProvidesPackage{preview}[2017/04/15 v13.2 preview]\n";
        assert_eq!(parse_sty_version(src).as_deref(), Some("2017/04/15 v13.2"));
    }
}
