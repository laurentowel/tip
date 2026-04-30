use testkit::server::TestServer;
use tip_protocol::messages::*;

fn bin_path() -> String {
    let mut path = std::env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    path.push("tip-server");
    path.to_str().unwrap().to_string()
}

#[test]
fn sync_and_shutdown() {
    let mut server = TestServer::spawn(&bin_path());

    let resp = server.request(&RequestMessage {
        id: 1,
        request: Request::Sync(SyncParams { backend: BackendId::Typst, project_root: None, latex_engine: None,
            uri: "/test.typ".into(),
            content: "$a + b$".into(),
        }),
    });
    assert_eq!(resp.id, 1);
    assert_eq!(resp.result, ResponseResult::Sync { ok: true });

    let resp = server.shutdown();
    assert_eq!(resp.result, ResponseResult::Shutdown { ok: true });
}

#[test]
fn compile_without_sync_returns_error() {
    let mut server = TestServer::spawn(&bin_path());

    let resp = server.request(&RequestMessage {
        id: 1,
        request: Request::CompileFragments(CompileFragmentsParams { backend: BackendId::Typst,
            uri: "/missing.typ".into(),
            fragments: vec![],
            color: "#000000".into(),
            page_setup: None,
            preamble: None,
            display_math_width: None,
        }),
    });
    match &resp.result {
        ResponseResult::Error { error } => {
            assert!(error.contains("not synced"));
        }
        other => panic!("expected error, got {:?}", other),
    }

    server.shutdown();
}

#[test]
fn compile_fragment_returns_svg() {
    let mut server = TestServer::spawn(&bin_path());

    server.request(&RequestMessage {
        id: 1,
        request: Request::Sync(SyncParams { backend: BackendId::Typst, project_root: None, latex_engine: None,
            uri: "/test.typ".into(),
            content: "$a + b$".into(),
        }),
    });

    let resp = server.request(&RequestMessage {
        id: 2,
        request: Request::CompileFragments(CompileFragmentsParams { backend: BackendId::Typst,
            uri: "/test.typ".into(),
            fragments: vec![FragmentLocation { start: 0, end: 7 }],
            color: "#000000".into(),
            page_setup: None,
            preamble: None,
            display_math_width: None,
        }),
    });
    assert_eq!(resp.id, 2);
    match &resp.result {
        ResponseResult::Fragments { fragments } => {
            assert_eq!(fragments.len(), 1);
            assert!(fragments[0].svg.contains("<svg"), "should contain SVG");
            assert!(fragments[0].height_pt > 0.0, "height should be positive");
        }
        other => panic!("expected fragments, got {:?}", other),
    }

    server.shutdown();
}

#[test]
fn multiple_fragments_in_one_batch() {
    let mut server = TestServer::spawn(&bin_path());

    let content = "some text $a+b$ more text $x^2$ end";
    server.request(&RequestMessage {
        id: 1,
        request: Request::Sync(SyncParams { backend: BackendId::Typst, project_root: None, latex_engine: None,
            uri: "/test.typ".into(),
            content: content.into(),
        }),
    });

    // Find the positions of $a+b$ and $x^2$
    let frag1_start = content.find("$a+b$").unwrap();
    let frag1_end = frag1_start + "$a+b$".len();
    let frag2_start = content.find("$x^2$").unwrap();
    let frag2_end = frag2_start + "$x^2$".len();

    let resp = server.request(&RequestMessage {
        id: 2,
        request: Request::CompileFragments(CompileFragmentsParams { backend: BackendId::Typst,
            uri: "/test.typ".into(),
            fragments: vec![
                FragmentLocation {
                    start: frag1_start,
                    end: frag1_end,
                },
                FragmentLocation {
                    start: frag2_start,
                    end: frag2_end,
                },
            ],
            color: "#000000".into(),
            page_setup: None,
            preamble: None,
            display_math_width: None,
        }),
    });
    match &resp.result {
        ResponseResult::Fragments { fragments } => {
            assert_eq!(fragments.len(), 2);
            for frag in fragments {
                assert!(frag.svg.contains("<svg"), "each fragment should have SVG");
                assert!(frag.height_pt > 0.0);
            }
        }
        other => panic!("expected fragments, got {:?}", other),
    }

    server.shutdown();
}

#[test]
fn list_project_files_typst_fallback() {
    // Typst has no graph → returns the URI itself.
    let mut server = TestServer::spawn(&bin_path());
    let resp = server.request(&RequestMessage {
        id: 1,
        request: Request::ListProjectFiles(ListProjectFilesParams {
            backend: BackendId::Typst,
            uri: "/tmp/ex.typ".into(),
        }),
    });
    match resp.result {
        ResponseResult::ProjectFiles { root: _, files } => {
            assert_eq!(files, vec!["/tmp/ex.typ"]);
        }
        other => panic!("unexpected: {:?}", other),
    }
    server.shutdown();
}

#[test]
fn list_project_files_latex_without_project_returns_self() {
    let mut server = TestServer::spawn(&bin_path());
    let resp = server.request(&RequestMessage {
        id: 1,
        request: Request::ListProjectFiles(ListProjectFilesParams {
            backend: BackendId::Latex,
            uri: "/tmp/foo.tex".into(),
        }),
    });
    match resp.result {
        ResponseResult::ProjectFiles { files, .. } => {
            assert_eq!(files, vec!["/tmp/foo.tex"]);
        }
        other => panic!("unexpected: {:?}", other),
    }
    server.shutdown();
}
