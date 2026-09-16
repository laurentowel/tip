use testkit::server::TestServer;
use tip_protocol::messages::*;

fn server() -> TestServer {
    TestServer::spawn(env!("CARGO_BIN_EXE_tip-server"))
}

fn request(server: &mut TestServer, request: Request) -> ResponseResult {
    let response = server.request(&RequestMessage { id: 73, request });
    assert_eq!(response.id, 73);
    response.result
}

#[test]
fn unsupported_backends_leave_connection_usable() {
    let mut server = server();
    for backend in [BackendId::Latex, BackendId::Katex] {
        let result = request(
            &mut server,
            Request::Validate(ValidateParams {
                backend,
                uri: "".into(),
            }),
        );
        assert!(
            matches!(result, ResponseResult::Error { error } if error.contains("not supported"))
        );
    }
    #[cfg(not(feature = "typst"))]
    assert!(
        matches!(request(&mut server, Request::Validate(ValidateParams {
        backend: BackendId::Typst, uri: "".into(),
    })), ResponseResult::Error { error } if error.contains("not compiled in"))
    );
    assert!(matches!(request(&mut server, Request::Init(InitParams {
        font_dirs: vec![], client_version: Some("0.1".into()),
    })), ResponseResult::Init { ok: true, server_version, version_mismatch }
        if server_version == "0.1" && version_mismatch.is_empty()));
    server.shutdown();
}

#[cfg(feature = "typst")]
mod typst {
    use super::*;

    fn sync(server: &mut TestServer, uri: &str, content: &str, root: Option<&str>) {
        assert_eq!(
            request(
                server,
                Request::Sync(SyncParams {
                    backend: BackendId::Typst,
                    uri: uri.into(),
                    content: content.into(),
                    project_root: root.map(str::to_owned),
                    latex_engine: None,
                })
            ),
            ResponseResult::Sync { ok: true }
        );
    }

    fn validate(server: &mut TestServer, uri: &str) -> ValidateResult {
        match request(
            server,
            Request::Validate(ValidateParams {
                backend: BackendId::Typst,
                uri: uri.into(),
            }),
        ) {
            ResponseResult::Validate(result) => result,
            other => panic!("expected validate, got {other:?}"),
        }
    }

    #[test]
    fn requires_sync_and_recovers_after_errors() {
        let mut server = server();
        assert!(
            matches!(request(&mut server, Request::Validate(ValidateParams {
            backend: BackendId::Typst, uri: "".into(),
        })), ResponseResult::Error { error } if error.contains("not synced"))
        );
        let content = "é\r\nα #missing\r\n";
        sync(&mut server, "", content, None);
        let result = validate(&mut server, "");
        assert!(!result.ok);
        let d = &result.diagnostics[0];
        assert_eq!(d.severity, ErrorSeverity::Error);
        assert!(d.message.contains("unknown variable: missing"));
        assert_eq!(d.path, None);
        assert_eq!((d.line, d.column), (Some(2), Some(4)));
        assert_eq!(d.byte_start, Some(content.find("missing").unwrap() as u32));
        assert_eq!(
            d.byte_end,
            Some((content.find("missing").unwrap() + 7) as u32)
        );
        assert_eq!(d.hint.as_deref(), Some("α #missing"));
        assert_eq!(validate(&mut server, ""), result);
        sync(&mut server, "", "#let x = 2\n$x + 1$", None);
        let result = validate(&mut server, "");
        assert!(result.ok);
        assert!(result.diagnostics.is_empty());
        server.shutdown();
    }

    #[test]
    fn warnings_survive_success_and_failure() {
        let mut server = server();
        let warning = "#set text(font: \"tip-nonexistent-font-xyz\")\nHello";
        sync(&mut server, "", warning, None);
        let result = validate(&mut server, "");
        assert!(result.ok);
        assert!(!result.diagnostics.is_empty());
        assert!(result
            .diagnostics
            .iter()
            .all(|d| d.severity == ErrorSeverity::Warning));
        // A warning from evaluation and an error from layout in one compile.
        sync(
            &mut server,
            "",
            "#let unused = decimal(0.1)\n@missing-label",
            None,
        );
        let result = validate(&mut server, "");
        assert!(!result.ok);
        assert!(result
            .diagnostics
            .iter()
            .any(|d| d.severity == ErrorSeverity::Error));
        assert!(result
            .diagnostics
            .iter()
            .any(|d| d.severity == ErrorSeverity::Warning));
        server.shutdown();
    }

    #[test]
    fn imported_diagnostics_refresh_after_edits_and_deletion() {
        let dir = tempfile::tempdir().unwrap();
        let imported = dir.path().join("lib.typ");
        std::fs::write(&imported, "é\n#missing").unwrap();
        let uri = dir.path().join("main.typ").display().to_string();
        let mut server = server();
        sync(&mut server, &uri, "#include \"lib.typ\"", None);
        let result = validate(&mut server, &uri);
        assert!(!result.ok);
        let d = &result.diagnostics[0];
        assert_eq!(d.path.as_deref(), imported.to_str());
        assert_eq!(
            (d.line, d.column, d.byte_start, d.byte_end),
            (Some(2), Some(2), Some(4), Some(11))
        );
        assert_eq!(d.hint.as_deref(), Some("#missing"));
        std::fs::write(&imported, "Hello").unwrap();
        assert!(validate(&mut server, &uri).ok);
        std::fs::remove_file(&imported).unwrap();
        assert!(!validate(&mut server, &uri).ok);
        server.shutdown();
    }

    fn preview(
        server: &mut TestServer,
        uri: &str,
        content: &str,
        strategy: &str,
    ) -> ResponseResult {
        let start = content.find('$').unwrap();
        let end = content.rfind('$').unwrap() + 1;
        let result = request(
            server,
            Request::CompileFragments(CompileFragmentsParams {
                backend: BackendId::Typst,
                uri: uri.into(),
                fragments: vec![FragmentLocation { start, end }],
                color: "#000000".into(),
                page_setup: None,
                preamble: None,
                display_math_width: None,
                strategy: Some(strategy.into()),
                display_math_border_opacity: None,
            }),
        );
        assert!(matches!(&result, ResponseResult::Fragments { fragments }
            if fragments.len() == 1 && fragments[0].error.is_none() && fragments[0].svg.contains("<svg")));
        result
    }

    #[test]
    fn validation_preserves_preview_state_and_per_uri_roots() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        std::fs::write(a.path().join("lib.typ"), "#let value = 1").unwrap();
        std::fs::write(b.path().join("lib.typ"), "#let value = 9").unwrap();
        let a_uri = a.path().join("main.typ").display().to_string();
        let b_uri = b.path().join("main.typ").display().to_string();
        let content = "#import \"lib.typ\": value\n$value + 1$";
        let mut server = server();
        sync(&mut server, &a_uri, content, None);
        sync(&mut server, &b_uri, content, None);
        for strategy in ["bottom-up", "top-down"] {
            let before = preview(&mut server, &b_uri, content, strategy);
            assert!(validate(&mut server, &a_uri).ok);
            assert!(validate(&mut server, &b_uri).ok);
            assert_eq!(preview(&mut server, &b_uri, content, strategy), before);
            std::fs::write(a.path().join("lib.typ"), "#missing").unwrap();
            assert!(!validate(&mut server, &a_uri).ok);
            assert!(validate(&mut server, &b_uri).ok);
            assert_eq!(preview(&mut server, &b_uri, content, strategy), before);
            std::fs::write(a.path().join("lib.typ"), "#let value = 1").unwrap();
        }
        // An explicit root for a synthetic URI must be replaced on resync.
        sync(
            &mut server,
            "tip-edit-virtual://validate",
            content,
            a.path().to_str(),
        );
        assert!(validate(&mut server, "tip-edit-virtual://validate").ok);
        std::fs::write(b.path().join("lib.typ"), "#missing").unwrap();
        sync(
            &mut server,
            "tip-edit-virtual://validate",
            content,
            b.path().to_str(),
        );
        assert!(!validate(&mut server, "tip-edit-virtual://validate").ok);
        server.shutdown();
    }
}
