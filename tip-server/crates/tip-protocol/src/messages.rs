use serde::{Deserialize, Serialize};

/// Which backend handles a request.  The client picks this from its
/// buffer's active backend (derived from `major-mode`), not from the
/// URI extension — buffers may have nonstandard extensions or no file
/// at all.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BackendId {
    Typst,
    Latex,
}

impl Default for BackendId {
    fn default() -> Self {
        BackendId::Typst
    }
}

/// A fragment location in the source buffer.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FragmentLocation {
    pub start: usize,
    pub end: usize,
}

/// Severity of a fragment compilation error.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ErrorSeverity {
    Error,
    Warning,
}

/// Structured compilation error attached to a fragment.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FragmentError {
    pub severity: ErrorSeverity,
    /// Single-line human-readable message.  E.g. "Undefined control
    /// sequence: \\foo" or "Missing } inserted".
    pub message: String,
    /// Multi-line context / surrounding log lines if any.  Clients
    /// present this as an expandable detail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// Line offset within the fragment (0-based).  For a one-line
    /// fragment this is 0; for a multi-line display math it's the
    /// offset from the fragment's first line.  Computed as
    /// (l.M reported by LaTeX) − (fragment start line in batch).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_in_fragment: Option<u32>,
    /// The source text reported on the `l.M HINT` line.  Useful for
    /// clients to locate the exact character range in the buffer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
}

/// A compiled fragment result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FragmentResult {
    pub start: usize,
    pub end: usize,
    pub svg: String,
    pub height_pt: f64,
    pub depth_pt: f64,
    /// Ink width in points (content only, no margins).
    #[serde(default)]
    pub width_pt: f64,
    /// Base font size used by the backend when rendering this fragment.
    /// The client uses this to pick a natural display scale (math appears
    /// at the same visual size as the surrounding buffer text).  Typst
    /// always renders at 11pt; LaTeX reads the value preview.sty reports
    /// (usually 10, 11, or 12 depending on the document class).  Absent
    /// when the backend can't report it reliably.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font_size_pt: Option<f64>,
    /// Compilation error message, if any (one-line summary — mirrors
    /// `error_detail.message` when the latter is present).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Structured error information (severity, hint, line).
    /// When present, clients should prefer this over `error`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_detail: Option<FragmentError>,
}

// --- Requests ---

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "method", content = "params")]
pub enum Request {
    #[serde(rename = "init")]
    Init(InitParams),
    #[serde(rename = "sync")]
    Sync(SyncParams),
    #[serde(rename = "compile_fragments")]
    CompileFragments(CompileFragmentsParams),
    #[serde(rename = "compile_live")]
    CompileLive(CompileLiveParams),
    #[serde(rename = "debug_skeleton")]
    DebugSkeleton(DebugSkeletonParams),
    #[serde(rename = "health_check")]
    HealthCheck,
    #[serde(rename = "shutdown")]
    Shutdown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct InitParams {
    #[serde(default)]
    pub font_dirs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DebugSkeletonParams {
    #[serde(default)]
    pub backend: BackendId,
    pub uri: String,
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SyncParams {
    #[serde(default)]
    pub backend: BackendId,
    pub uri: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CompileFragmentsParams {
    #[serde(default)]
    pub backend: BackendId,
    pub uri: String,
    pub fragments: Vec<FragmentLocation>,
    pub color: String,
    /// Optional Typst page setup string prepended to the compiled source.
    /// If omitted, a sensible default is used.
    /// Example: "#set page(height: auto, width: auto, margin: 0.2em, fill: none)"
    #[serde(default)]
    pub page_setup: Option<String>,
    /// Optional Typst preamble injected before the fragment.
    /// Use for rendering tweaks like bounded(), custom show rules, etc.
    /// If omitted, tip-server injects bounded() to prevent clipping.
    #[serde(default)]
    pub preamble: Option<String>,
    /// Target width for display-math SVGs, as a LaTeX dimension string
    /// (e.g. "20em" or "400pt").  When set, the LaTeX backend runs
    /// `\setlength{\textwidth}{...}` before each batch, so
    /// `\begin{preview}\[...\]\end{preview}` produces a full-textwidth
    /// SVG with the math centered by LaTeX itself.  Inline `$...$`
    /// is unaffected.  Typst and other backends may ignore this.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_math_width: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CompileLiveParams {
    #[serde(default)]
    pub backend: BackendId,
    pub uri: String,
    pub start: usize,
    pub end: usize,
    pub color: String,
    #[serde(default)]
    pub page_setup: Option<String>,
    #[serde(default)]
    pub preamble: Option<String>,
}

/// Envelope wrapping a request with an ID.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RequestMessage {
    pub id: u64,
    #[serde(flatten)]
    pub request: Request,
}

// --- Responses ---

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind")]
pub enum ResponseResult {
    #[serde(rename = "init")]
    Init { ok: bool },
    #[serde(rename = "sync")]
    Sync { ok: bool },
    #[serde(rename = "fragments")]
    Fragments { fragments: Vec<FragmentResult> },
    #[serde(rename = "live")]
    Live {
        #[serde(flatten)]
        fragment: FragmentResult,
    },
    #[serde(rename = "shutdown")]
    Shutdown { ok: bool },
    #[serde(rename = "debug_skeleton")]
    DebugSkeleton { source: String },
    #[serde(rename = "health")]
    Health { report: HealthReport },
    #[serde(rename = "error")]
    Error { error: String },
}

/// Diagnostic snapshot of the server and its optional external
/// dependencies.  Returned by `health_check`.  Also used as the body
/// of a bug report (server version + OS + dep versions + warnings is
/// exactly what we'd want a user to paste into a Github issue).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HealthReport {
    /// tip-server crate version (set at compile time from CARGO_PKG_VERSION).
    pub server_version: String,
    /// Target triple the binary was built for.
    pub target_triple: String,
    /// OS as reported by `std::env::consts::OS`.
    pub os: String,
    /// CPU arch as reported by `std::env::consts::ARCH`.
    pub arch: String,
    /// Per-backend probe results.  A backend is only probed if its
    /// core can run at all; missing keys mean "not compiled in".
    pub typst: Option<TypstHealth>,
    pub latex: Option<LatexHealth>,
    /// Non-fatal warnings (e.g. "dvisvgm 2.8 detected; 2.14+ recommended").
    #[serde(default)]
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TypstHealth {
    pub ok: bool,
    pub typst_version: String,
    /// Number of fonts discovered by the FontSearcher.
    pub fonts_found: usize,
}

/// A probed external binary (path + version string + ok-flag).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BinaryProbe {
    pub found: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// For binaries with a minimum-version requirement: whether the
    /// found version meets it.  `true` if no minimum applies.
    pub meets_min_version: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LatexHealth {
    /// Overall: all mandatory deps found and meet version floors.
    pub ok: bool,
    /// `latex` command (pdflatex/xelatex/lualatex probed separately
    /// in the future if we add an engine picker).
    pub latex: BinaryProbe,
    /// `dvisvgm`; we require >= 2.14 for stable `--bbox=preview`.
    pub dvisvgm: BinaryProbe,
    /// `preview.sty`; probed via `kpsewhich preview.sty`.
    pub preview_sty: BinaryProbe,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ResponseMessage {
    pub id: u64,
    pub result: ResponseResult,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_init_request() {
        let msg = RequestMessage {
            id: 1,
            request: Request::Init(InitParams {
                font_dirs: vec!["/home/user/fonts".into(), "/opt/math-fonts".into()],
            }),
        };
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: RequestMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, decoded);
    }

    #[test]
    fn roundtrip_init_empty() {
        let json = r#"{"id": 1, "method": "init", "params": {}}"#;
        let msg: RequestMessage = serde_json::from_str(json).unwrap();
        match msg.request {
            Request::Init(params) => assert!(params.font_dirs.is_empty()),
            other => panic!("expected Init, got {:?}", other),
        }
    }

    #[test]
    fn roundtrip_sync_request() {
        let msg = RequestMessage {
            id: 1,
            request: Request::Sync(SyncParams {
                backend: BackendId::Typst,
                uri: "/tmp/test.typ".into(),
                content: "$a + b$".into(),
            }),
        };
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: RequestMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, decoded);
    }

    #[test]
    fn roundtrip_compile_fragments_request() {
        let msg = RequestMessage {
            id: 2,
            request: Request::CompileFragments(CompileFragmentsParams {
                backend: BackendId::Typst,
                uri: "/tmp/test.typ".into(),
                fragments: vec![FragmentLocation { start: 10, end: 20 }],
                color: "#ffffff".into(),
                page_setup: None,
                preamble: None,
                display_math_width: None,
            }),
        };
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: RequestMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, decoded);
    }

    #[test]
    fn roundtrip_shutdown_request() {
        let msg = RequestMessage {
            id: 99,
            request: Request::Shutdown,
        };
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: RequestMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, decoded);
    }

    #[test]
    fn roundtrip_fragment_response() {
        let msg = ResponseMessage {
            id: 2,
            result: ResponseResult::Fragments {
                fragments: vec![FragmentResult {
                    start: 10,
                    end: 20,
                    svg: "<svg></svg>".into(),
                    height_pt: 12.5,
                    depth_pt: 2.3,
                    width_pt: 24.0,
                    font_size_pt: Some(11.0),
                    error: None,
                    error_detail: None,
                }],
            },
        };
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: ResponseMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, decoded);
    }

    #[test]
    fn deserialize_sync_from_json() {
        let json = r#"{"id": 1, "method": "sync", "params": {"uri": "/test.typ", "content": "hello"}}"#;
        let msg: RequestMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg.id, 1);
        assert_eq!(
            msg.request,
            Request::Sync(SyncParams {
                backend: BackendId::Typst,
                uri: "/test.typ".into(),
                content: "hello".into(),
            })
        );
    }

    #[test]
    fn deserialize_shutdown_from_json() {
        // shutdown has no params
        let json = r#"{"id": 4, "method": "shutdown"}"#;
        let msg: RequestMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg.id, 4);
        assert_eq!(msg.request, Request::Shutdown);
    }
}
