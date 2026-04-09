use serde::{Deserialize, Serialize};

/// A fragment location in the source buffer.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FragmentLocation {
    pub start: usize,
    pub end: usize,
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
    /// Compilation error message, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
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
    pub uri: String,
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SyncParams {
    pub uri: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CompileFragmentsParams {
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
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CompileLiveParams {
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
    #[serde(rename = "error")]
    Error { error: String },
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
                uri: "/tmp/test.typ".into(),
                fragments: vec![FragmentLocation { start: 10, end: 20 }],
                color: "#ffffff".into(),
                page_setup: None,
                preamble: None,
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
                    error: None,
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
