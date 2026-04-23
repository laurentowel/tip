//! End-to-end tests: spawn the tip-server-latex binary, drive it over
//! stdio with the same protocol shape the Emacs side uses.
//!
//! Skips when `latex` + `dvisvgm` aren't on PATH (CI-friendly).

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
    path.push("tip-server-latex");
    path.to_str().unwrap().to_string()
}

fn tools_available() -> bool {
    fn which(c: &str) -> bool {
        std::env::var_os("PATH")
            .map(|paths| {
                std::env::split_paths(&paths).any(|p| {
                    let p = p.join(c);
                    p.is_file()
                })
            })
            .unwrap_or(false)
    }
    which("latex") && which("dvisvgm")
}

#[test]
fn sync_and_shutdown() {
    let mut server = TestServer::spawn(&bin_path());
    let resp = server.request(&RequestMessage {
        id: 1,
        request: Request::Sync(SyncParams {
            uri: "/tmp/test.tex".into(),
            content: "$x$".into(),
        }),
    });
    assert_eq!(resp.result, ResponseResult::Sync { ok: true });
    let resp = server.request(&RequestMessage {
        id: 2,
        request: Request::Shutdown,
    });
    assert_eq!(resp.result, ResponseResult::Shutdown { ok: true });
}

#[test]
fn compile_fragment_returns_svg() {
    if !tools_available() {
        eprintln!("SKIP: latex/dvisvgm not on PATH");
        return;
    }
    let mut server = TestServer::spawn(&bin_path());
    let content = "Intro $a + b$ trailing.";
    let start = content.find('$').unwrap();
    let end = start + "$a + b$".len();

    server.request(&RequestMessage {
        id: 1,
        request: Request::Sync(SyncParams {
            uri: "/tmp/test.tex".into(),
            content: content.into(),
        }),
    });
    let resp = server.request(&RequestMessage {
        id: 2,
        request: Request::CompileFragments(CompileFragmentsParams {
            uri: "/tmp/test.tex".into(),
            fragments: vec![FragmentLocation { start, end }],
            color: "#000000".into(),
            page_setup: None,
            preamble: Some("\\documentclass{article}\n\\usepackage{amsmath}\n".into()),
            display_math_width: None,
        }),
    });
    match resp.result {
        ResponseResult::Fragments { fragments } => {
            assert_eq!(fragments.len(), 1);
            let f = &fragments[0];
            assert!(f.error.is_none(), "error: {:?}", f.error);
            assert!(f.svg.contains("<svg"), "svg missing");
            assert!(f.height_pt > 0.0, "height_pt = {}", f.height_pt);
            assert!(f.width_pt > 0.0, "width_pt = {}", f.width_pt);
        }
        other => panic!("unexpected result: {:?}", other),
    }
}

#[test]
fn multiple_fragments_in_one_batch() {
    if !tools_available() {
        eprintln!("SKIP: latex/dvisvgm not on PATH");
        return;
    }
    let mut server = TestServer::spawn(&bin_path());
    let content = "A $x$ and B $y^2$ and C.";
    let s1 = content.find("$x$").unwrap();
    let e1 = s1 + "$x$".len();
    let s2 = content.find("$y^2$").unwrap();
    let e2 = s2 + "$y^2$".len();
    server.request(&RequestMessage {
        id: 1,
        request: Request::Sync(SyncParams {
            uri: "/tmp/test.tex".into(),
            content: content.into(),
        }),
    });
    let resp = server.request(&RequestMessage {
        id: 2,
        request: Request::CompileFragments(CompileFragmentsParams {
            uri: "/tmp/test.tex".into(),
            fragments: vec![
                FragmentLocation { start: s1, end: e1 },
                FragmentLocation { start: s2, end: e2 },
            ],
            color: "#000000".into(),
            page_setup: None,
            preamble: None,
            display_math_width: None,
        }),
    });
    match resp.result {
        ResponseResult::Fragments { fragments } => {
            assert_eq!(fragments.len(), 2);
            for f in &fragments {
                assert!(f.error.is_none(), "error: {:?}", f.error);
                assert!(f.svg.contains("<svg"));
            }
        }
        other => panic!("unexpected result: {:?}", other),
    }
}
