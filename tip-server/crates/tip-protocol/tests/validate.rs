use tip_protocol::messages::*;

#[test]
fn validate_defaults_to_typst_and_requires_uri() {
    let msg: RequestMessage =
        serde_json::from_str(r#"{"id":7,"method":"validate","params":{"uri":""}}"#).unwrap();
    assert_eq!(
        msg.request,
        Request::Validate(ValidateParams {
            backend: BackendId::Typst,
            uri: String::new(),
        })
    );
    for params in [r#"{}"#, r#"{"uri":null}"#] {
        assert!(serde_json::from_str::<RequestMessage>(&format!(
            r#"{{"id":7,"method":"validate","params":{params}}}"#
        ))
        .is_err());
    }
}

#[test]
fn validate_response_is_flat_and_locations_are_nullable() {
    let json = r#"{"id":7,"result":{"kind":"validate","ok":false,"diagnostics":[{"severity":"error","message":"oops","path":null,"line":null,"column":null,"byte_start":null,"byte_end":null,"hint":null}]}}"#;
    let msg: ResponseMessage = serde_json::from_str(json).unwrap();
    assert!(
        matches!(&msg.result, ResponseResult::Validate(r) if !r.ok && r.diagnostics.len() == 1)
    );
    assert_eq!(
        serde_json::to_value(msg).unwrap(),
        serde_json::from_str::<serde_json::Value>(json).unwrap()
    );
}
