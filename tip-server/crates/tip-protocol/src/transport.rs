use std::io::{self, BufRead, Write};

use crate::messages::{RequestMessage, ResponseMessage};

/// Read one newline-delimited JSON request from a buffered reader.
/// Returns `None` on EOF.
pub fn read_request<R: BufRead>(reader: &mut R) -> io::Result<Option<RequestMessage>> {
    let mut line = String::new();
    loop {
        line.clear();
        let n = reader.read_line(&mut line)?;
        if n == 0 {
            return Ok(None); // EOF
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue; // skip blank lines
        }
        let msg: RequestMessage = serde_json::from_str(trimmed)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        return Ok(Some(msg));
    }
}

/// Write one newline-delimited JSON response to a writer.
pub fn write_response<W: Write>(writer: &mut W, msg: &ResponseMessage) -> io::Result<()> {
    let json = serde_json::to_string(msg)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    writer.write_all(json.as_bytes())?;
    writer.write_all(b"\n")?;
    writer.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::messages::*;
    use std::io::Cursor;

    #[test]
    fn read_single_request() {
        let input = r#"{"id": 1, "method": "shutdown"}"#.to_string() + "\n";
        let mut reader = Cursor::new(input.as_bytes());
        let msg = read_request(&mut reader).unwrap().unwrap();
        assert_eq!(msg.id, 1);
        assert_eq!(msg.request, Request::Shutdown);
    }

    #[test]
    fn read_skips_blank_lines() {
        let input = "\n\n".to_string()
            + r#"{"id": 5, "method": "shutdown"}"#
            + "\n";
        let mut reader = Cursor::new(input.as_bytes());
        let msg = read_request(&mut reader).unwrap().unwrap();
        assert_eq!(msg.id, 5);
    }

    #[test]
    fn read_returns_none_on_eof() {
        let mut reader = Cursor::new(b"" as &[u8]);
        let msg = read_request(&mut reader).unwrap();
        assert!(msg.is_none());
    }

    #[test]
    fn read_returns_error_on_bad_json() {
        let input = "not json\n";
        let mut reader = Cursor::new(input.as_bytes());
        let result = read_request(&mut reader);
        assert!(result.is_err());
    }

    #[test]
    fn write_response_newline_delimited() {
        let msg = ResponseMessage {
            id: 1,
            result: ResponseResult::Sync { ok: true },
        };
        let mut buf = Vec::new();
        write_response(&mut buf, &msg).unwrap();
        let output = String::from_utf8(buf).unwrap();
        assert!(output.ends_with('\n'));
        let decoded: ResponseMessage =
            serde_json::from_str(output.trim()).unwrap();
        assert_eq!(decoded, msg);
    }

    #[test]
    fn roundtrip_through_transport() {
        let request = RequestMessage {
            id: 42,
            request: Request::Sync(SyncParams {
                backend: crate::messages::BackendId::Typst,
                project_root: None,
            latex_engine: None,
                uri: "/test.typ".into(),
                content: "$x^2$".into(),
            }),
        };

        // Write request as a line
        let req_json = serde_json::to_string(&request).unwrap() + "\n";

        // Read it back
        let mut reader = Cursor::new(req_json.as_bytes());
        let decoded = read_request(&mut reader).unwrap().unwrap();
        assert_eq!(decoded, request);

        // Write response
        let response = ResponseMessage {
            id: 42,
            result: ResponseResult::Sync { ok: true },
        };
        let mut buf = Vec::new();
        write_response(&mut buf, &response).unwrap();

        // Read response back
        let resp_decoded: ResponseMessage =
            serde_json::from_str(String::from_utf8(buf).unwrap().trim()).unwrap();
        assert_eq!(resp_decoded, response);
    }
}
