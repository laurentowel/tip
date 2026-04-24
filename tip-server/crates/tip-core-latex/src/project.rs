//! Multi-file LaTeX project graph.
//!
//! A [`TexProject`] is rooted at a single `.tex` file and walks the
//! `\input` / `\include` / `\subimport` / etc. graph eagerly.  For
//! any file in the graph, [`TexProject::preamble_for`] returns the
//! compile-time preamble (v1: root's preamble regardless of the
//! queried file — see plan A in the design thread).
//!
//! Design notes distilled from the texlab + digestif survey:
//!
//! - **Include command set** follows texlab: `\input`, `\include`,
//!   `\subfile`, `\subfileinclude`, `\import`, `\subimport`,
//!   `\inputfrom`, `\subinputfrom`, `\includefrom`, `\subincludefrom`.
//! - **Extension rules** follow texlab: `\input{foo}` tries `foo`
//!   then `foo.tex`; `\include{foo}` always appends `.tex`.
//! - **Cycle detection** follows digestif's ancestor-chain walk,
//!   which allows diamond re-entry (A includes B and C, both include
//!   D — D is visited once; that's fine) while preventing loops.
//! - **Comment + verbatim skipping**: comments are stripped
//!   line-by-line (`%` ends a line, `\%` is literal); `\begin{env}
//!   ... \end{env}` for `verbatim` / `lstlisting` / `minted` /
//!   `Verbatim` / `alltt` is a no-scan region.
//! - **kpathsea / TEXINPUTS not honored** — per both refs, roll our
//!   own relative-to-current + relative-to-root resolution.  If the
//!   user's project needs TEXINPUTS magic the real `latex` subprocess
//!   still honors it; we just don't chase includes that depend on it.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// Error surface for the public API.  Intentionally coarse; the
/// diagnostic backend already handles per-fragment compile errors.
#[derive(Debug)]
pub enum ProjectError {
    /// Couldn't read the root file (or, on `sync`, the file being replaced).
    Io(String),
}

/// One parsed file in the project.
#[derive(Debug, Clone)]
pub struct Script {
    /// Absolute canonical path on disk.
    pub path: PathBuf,
    /// The file's contents, either freshly read or overridden via `sync`.
    pub src: String,
    /// Direct includes (resolved), in textual order.
    pub children: Vec<PathBuf>,
    /// Include targets we couldn't resolve to a real file.  Kept for
    /// diagnostics — missing includes are NOT fatal (real `latex`
    /// might still find them via TEXINPUTS, or the user might not
    /// need them compiled).
    pub missing: Vec<String>,
}

#[derive(Debug)]
pub struct TexProject {
    root: PathBuf,
    scripts: HashMap<PathBuf, Script>,
}

impl TexProject {
    /// Open the project rooted at `root`, walking the include graph
    /// eagerly (DFS, ancestor-chain cycle check).
    pub fn load(root: impl AsRef<Path>) -> Result<Self, ProjectError> {
        let root = canonicalize_lossy(root.as_ref());
        let mut project = Self {
            root: root.clone(),
            scripts: HashMap::new(),
        };
        project.walk_from_disk(&root, &mut Vec::new())?;
        Ok(project)
    }

    /// Absolute path of the root file.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Iterator over every file the walker discovered.
    pub fn files(&self) -> impl Iterator<Item = &Path> {
        self.scripts.keys().map(PathBuf::as_path)
    }

    /// True if `path` is part of the project graph.
    pub fn contains(&self, path: impl AsRef<Path>) -> bool {
        self.scripts.contains_key(&canonicalize_lossy(path.as_ref()))
    }

    /// Return the preamble to feed a fragment compiled from `file`.
    ///
    /// v1 (plan A): always the root's preamble — text up to the first
    /// unescaped `\begin{document}`.  `file` is accepted for API
    /// forward-compat with plan B (per-file macro harvesting).
    pub fn preamble_for(&self, _file: impl AsRef<Path>) -> Result<String, ProjectError> {
        let root = self
            .scripts
            .get(&self.root)
            .ok_or_else(|| ProjectError::Io(format!("root not loaded: {:?}", self.root)))?;
        Ok(extract_preamble(&root.src))
    }

    /// Replace the cached source of one file (e.g. because the editor
    /// synced a dirty buffer), and re-walk its children.  New
    /// descendants are added to the graph; gone descendants stay in
    /// the graph for now (harmless — they just stop being reachable).
    pub fn sync(&mut self, path: impl AsRef<Path>, src: String) -> Result<(), ProjectError> {
        let path = canonicalize_lossy(path.as_ref());
        self.scripts.remove(&path);
        self.walk_with_src(&path, src, &mut Vec::new())
    }

    fn walk_from_disk(
        &mut self,
        path: &Path,
        ancestors: &mut Vec<PathBuf>,
    ) -> Result<(), ProjectError> {
        if self.scripts.contains_key(path) {
            return Ok(()); // already walked via another branch
        }
        if ancestors.iter().any(|a| a == path) {
            return Ok(()); // cycle
        }
        let src = fs::read_to_string(path)
            .map_err(|e| ProjectError::Io(format!("read {}: {e}", path.display())))?;
        self.walk_with_src(path, src, ancestors)
    }

    fn walk_with_src(
        &mut self,
        path: &Path,
        src: String,
        ancestors: &mut Vec<PathBuf>,
    ) -> Result<(), ProjectError> {
        let dir = path.parent().unwrap_or_else(|| Path::new(""));
        let mut children = Vec::new();
        let mut missing = Vec::new();
        for inc in scan_includes(&src) {
            match resolve(&inc, dir, &self.root) {
                Some(resolved) => children.push(resolved),
                None => missing.push(inc.arg),
            }
        }
        self.scripts.insert(
            path.to_path_buf(),
            Script {
                path: path.to_path_buf(),
                src,
                children: children.clone(),
                missing,
            },
        );
        ancestors.push(path.to_path_buf());
        for child in children {
            self.walk_from_disk(&child, ancestors)?;
        }
        ancestors.pop();
        Ok(())
    }
}

/// Best-effort canonicalization.  If the path doesn't exist on disk
/// (e.g. a sync for an unsaved buffer) we fall back to `absolutize`.
fn canonicalize_lossy(p: &Path) -> PathBuf {
    fs::canonicalize(p).unwrap_or_else(|_| {
        if p.is_absolute() {
            p.to_path_buf()
        } else {
            std::env::current_dir().unwrap_or_default().join(p)
        }
    })
}

/// A single `\input{foo}` (or similar) site in a file.
#[derive(Debug, Clone, PartialEq)]
struct IncludeSite {
    cmd: IncludeCmd,
    /// Literal argument as it appears in the source, no extension
    /// fixup applied yet.
    arg: String,
    /// For `\subimport{dir/}{file}` and friends — the dir part.
    dir: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum IncludeCmd {
    /// `\input{foo}` — try as-is, then `foo.tex`.
    Input,
    /// `\include{foo}` — always `.tex`.
    Include,
    /// `\subfile` / `\subfileinclude` — treat like `Input`.
    Subfile,
    /// `\import` / `\includefrom` / `\inputfrom` — first arg is a dir,
    /// second is the file, resolved relative to root.
    Import,
    /// `\subimport` / `\subincludefrom` / `\subinputfrom` — dir
    /// relative to *current* file's directory, then file.
    Subimport,
}

impl IncludeCmd {
    fn from_name(name: &str) -> Option<Self> {
        match name {
            "input" => Some(Self::Input),
            "include" => Some(Self::Include),
            "subfile" | "subfileinclude" => Some(Self::Subfile),
            "import" | "includefrom" | "inputfrom" => Some(Self::Import),
            "subimport" | "subincludefrom" | "subinputfrom" => Some(Self::Subimport),
            _ => None,
        }
    }

    fn takes_dir_arg(self) -> bool {
        matches!(self, Self::Import | Self::Subimport)
    }

    fn always_tex(self) -> bool {
        matches!(self, Self::Include)
    }
}

/// Resolve an include site to an absolute path on disk, or None if
/// nothing matches.  Rules (cheap, deliberately not kpathsea):
///
/// 1. `{Import}`:    `root / dir / arg[.tex]`
/// 2. `{Subimport}`: `current_dir / dir / arg[.tex]`
/// 3. Otherwise:     `current_dir / arg`, then `current_dir / arg.tex`
///                   (except `\include` which is always `.tex`).
fn resolve(site: &IncludeSite, current_dir: &Path, root_dir: &Path) -> Option<PathBuf> {
    let base = match site.cmd {
        IncludeCmd::Import => root_dir.to_path_buf(),
        IncludeCmd::Subimport => current_dir.to_path_buf(),
        _ => current_dir.to_path_buf(),
    };
    let base = match &site.dir {
        Some(d) if site.cmd.takes_dir_arg() => base.join(d),
        _ => base,
    };
    // Candidate 1: arg as-is (unless \include which always appends .tex).
    if !site.cmd.always_tex() {
        let p = base.join(&site.arg);
        if p.is_file() {
            return Some(canonicalize_lossy(&p));
        }
    }
    // Candidate 2: arg + .tex.
    if !site.arg.ends_with(".tex") {
        let p = base.join(format!("{}.tex", site.arg));
        if p.is_file() {
            return Some(canonicalize_lossy(&p));
        }
    }
    None
}

/// Extract the preamble: text up to the first unescaped, non-commented
/// `\begin{document}`.  If that sentinel isn't found, return the whole
/// source (child files have no `\begin{document}` — they're body fragments).
fn extract_preamble(src: &str) -> String {
    // Walk line-by-line, strip comments per line, search for the sentinel.
    let mut byte_offset = 0;
    for line in src.split_inclusive('\n') {
        let uncommented = strip_line_comment(line);
        if let Some(pos) = uncommented.find("\\begin{document}") {
            return src[..byte_offset + pos].to_string();
        }
        byte_offset += line.len();
    }
    src.to_string()
}

/// Scan `src` for all include commands, skipping line comments and
/// verbatim-style environments.  Returns sites in source order.
fn scan_includes(src: &str) -> Vec<IncludeSite> {
    let mut out = Vec::new();
    let masked = mask_verbatim(src);
    let bytes = masked.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        // Skip line comments: unescaped % → jump to end of line.
        if bytes[i] == b'%' && !is_escaped_percent(bytes, i) {
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if bytes[i] != b'\\' {
            i += 1;
            continue;
        }
        // Read control word.
        let name_start = i + 1;
        let mut j = name_start;
        while j < bytes.len() && bytes[j].is_ascii_alphabetic() {
            j += 1;
        }
        let name = std::str::from_utf8(&bytes[name_start..j]).unwrap_or("");
        if let Some(cmd) = IncludeCmd::from_name(name) {
            // Parse one or two {...} groups.
            let (first, after) = match read_brace_arg(bytes, j) {
                Some(x) => x,
                None => {
                    i = j;
                    continue;
                }
            };
            let (dir, arg, next) = if cmd.takes_dir_arg() {
                match read_brace_arg(bytes, after) {
                    Some((second, next)) => (Some(first), second, next),
                    None => {
                        i = after;
                        continue;
                    }
                }
            } else {
                (None, first, after)
            };
            out.push(IncludeSite { cmd, arg, dir });
            i = next;
        } else {
            i = j;
        }
    }
    out
}

/// Replace verbatim / lstlisting / minted / Verbatim / alltt content
/// (between matching `\begin{env}` and `\end{env}`) with spaces, so
/// include-scanning ignores them without disturbing byte offsets.
fn mask_verbatim(src: &str) -> String {
    const ENVS: &[&str] = &["verbatim", "lstlisting", "minted", "Verbatim", "alltt"];
    let mut out = src.to_string();
    for env in ENVS {
        let open = format!("\\begin{{{}}}", env);
        let close = format!("\\end{{{}}}", env);
        let mut search_from = 0;
        while let Some(rel_start) = out[search_from..].find(&open) {
            let start = search_from + rel_start + open.len();
            let end = match out[start..].find(&close) {
                Some(rel_end) => start + rel_end,
                None => break,
            };
            // Replace in-place with spaces preserving length.
            let replacement: String = out[start..end]
                .chars()
                .map(|c| if c == '\n' { '\n' } else { ' ' })
                .collect();
            out.replace_range(start..end, &replacement);
            search_from = end + close.len();
        }
    }
    out
}

/// Is the `%` at `i` escaped (`\%`)?  Count preceding backslashes;
/// escape iff the count is odd.
fn is_escaped_percent(bytes: &[u8], i: usize) -> bool {
    let mut backslashes = 0;
    let mut k = i;
    while k > 0 && bytes[k - 1] == b'\\' {
        backslashes += 1;
        k -= 1;
    }
    backslashes % 2 == 1
}

/// Strip a trailing line comment starting at an unescaped `%`.
/// Preserves the newline so offset math stays stable.
fn strip_line_comment(line: &str) -> String {
    let bytes = line.as_bytes();
    for i in 0..bytes.len() {
        if bytes[i] == b'%' && !is_escaped_percent(bytes, i) {
            let mut out = String::from(&line[..i]);
            if line.ends_with('\n') {
                out.push('\n');
            }
            return out;
        }
    }
    line.to_string()
}

/// Starting at an optional whitespace run, read one `{...}` group.
/// Returns (contents, index just past the closing brace).  Supports
/// one level of internal brace nesting.
fn read_brace_arg(bytes: &[u8], mut i: usize) -> Option<(String, usize)> {
    while i < bytes.len() && bytes[i].is_ascii_whitespace() {
        i += 1;
    }
    if i >= bytes.len() || bytes[i] != b'{' {
        return None;
    }
    let mut depth = 1;
    let mut j = i + 1;
    let start = j;
    while j < bytes.len() && depth > 0 {
        match bytes[j] {
            b'{' => depth += 1,
            b'}' => depth -= 1,
            b'\\' if j + 1 < bytes.len() => {
                j += 1; // skip escaped char
            }
            _ => {}
        }
        if depth > 0 {
            j += 1;
        }
    }
    if depth != 0 {
        return None;
    }
    let content = std::str::from_utf8(&bytes[start..j]).ok()?.to_string();
    Some((content, j + 1))
}

// ---------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn tmp_with(files: &[(&str, &str)]) -> TempDir {
        let tmp = tempfile::tempdir().unwrap();
        for (name, content) in files {
            let p = tmp.path().join(name);
            if let Some(parent) = p.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(p, content).unwrap();
        }
        tmp
    }

    #[test]
    fn single_file_project_is_just_the_root() {
        let tmp = tmp_with(&[(
            "root.tex",
            "\\documentclass{article}\n\
             \\usepackage{amsmath}\n\
             \\begin{document}\nhello\n\\end{document}\n",
        )]);
        let proj = TexProject::load(tmp.path().join("root.tex")).unwrap();
        assert_eq!(proj.files().count(), 1);
        let pre = proj.preamble_for(proj.root()).unwrap();
        assert!(pre.contains("\\usepackage{amsmath}"));
        assert!(!pre.contains("\\begin{document}"));
    }

    #[test]
    fn input_without_extension_resolves() {
        let tmp = tmp_with(&[
            (
                "root.tex",
                "\\documentclass{article}\n\
                 \\begin{document}\n\\input{body}\n\\end{document}\n",
            ),
            ("body.tex", "$a + b$\n"),
        ]);
        let proj = TexProject::load(tmp.path().join("root.tex")).unwrap();
        assert_eq!(proj.files().count(), 2);
        assert!(proj.contains(tmp.path().join("body.tex")));
    }

    #[test]
    fn input_with_extension_resolves() {
        let tmp = tmp_with(&[
            (
                "root.tex",
                "\\documentclass{article}\\begin{document}\\input{body.tex}\\end{document}",
            ),
            ("body.tex", "x"),
        ]);
        let proj = TexProject::load(tmp.path().join("root.tex")).unwrap();
        assert!(proj.contains(tmp.path().join("body.tex")));
    }

    #[test]
    fn include_always_appends_tex() {
        let tmp = tmp_with(&[
            (
                "root.tex",
                "\\documentclass{article}\\begin{document}\\include{chap1}\\end{document}",
            ),
            ("chap1.tex", "x"),
        ]);
        let proj = TexProject::load(tmp.path().join("root.tex")).unwrap();
        assert!(proj.contains(tmp.path().join("chap1.tex")));
    }

    #[test]
    fn subimport_resolves_relative_to_current_file() {
        let tmp = tmp_with(&[
            (
                "root.tex",
                "\\documentclass{article}\\begin{document}\
                 \\subimport{sections/}{intro}\\end{document}",
            ),
            ("sections/intro.tex", "x"),
        ]);
        let proj = TexProject::load(tmp.path().join("root.tex")).unwrap();
        assert!(proj.contains(tmp.path().join("sections/intro.tex")));
    }

    #[test]
    fn commented_input_is_skipped() {
        let tmp = tmp_with(&[(
            "root.tex",
            "\\documentclass{article}\\begin{document}\n\
             % \\input{ignored}\n\
             \\end{document}",
        )]);
        let proj = TexProject::load(tmp.path().join("root.tex")).unwrap();
        assert_eq!(proj.files().count(), 1);
    }

    #[test]
    fn verbatim_input_is_skipped() {
        let tmp = tmp_with(&[(
            "root.tex",
            "\\documentclass{article}\\begin{document}\n\
             \\begin{verbatim}\n\\input{ignored}\n\\end{verbatim}\n\
             \\end{document}",
        )]);
        let proj = TexProject::load(tmp.path().join("root.tex")).unwrap();
        assert_eq!(proj.files().count(), 1);
    }

    #[test]
    fn missing_include_is_not_fatal() {
        let tmp = tmp_with(&[(
            "root.tex",
            "\\documentclass{article}\\begin{document}\\input{nothere}\\end{document}",
        )]);
        let proj = TexProject::load(tmp.path().join("root.tex")).unwrap();
        assert_eq!(proj.files().count(), 1);
        let root = &proj.scripts[proj.root()];
        assert_eq!(root.missing, vec!["nothere".to_string()]);
    }

    #[test]
    fn cycle_is_not_fatal() {
        let tmp = tmp_with(&[
            (
                "a.tex",
                "\\documentclass{article}\\begin{document}\\input{b}\\end{document}",
            ),
            ("b.tex", "\\input{a}"),
        ]);
        let proj = TexProject::load(tmp.path().join("a.tex")).unwrap();
        assert_eq!(proj.files().count(), 2);
    }

    #[test]
    fn preamble_stops_at_begin_document() {
        let src = "\\documentclass{article}\n\
                   \\usepackage{amsmath}\n\
                   \\newcommand{\\F}{\\mathcal{F}}\n\
                   \\begin{document}\n\
                   body $\\F$\n\
                   \\end{document}\n";
        let pre = extract_preamble(src);
        assert!(pre.contains("\\newcommand{\\F}"));
        assert!(!pre.contains("\\begin{document}"));
        assert!(!pre.contains("body"));
    }

    #[test]
    fn preamble_ignores_commented_begin_document() {
        let src = "\\documentclass{article}\n\
                   % \\begin{document} fake\n\
                   \\usepackage{amsmath}\n\
                   \\begin{document}\nbody\n\\end{document}\n";
        let pre = extract_preamble(src);
        assert!(pre.contains("\\usepackage{amsmath}"));
        assert!(!pre.contains("\nbody"));
    }
}
