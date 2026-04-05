use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};

use tip_protocol::messages::{RequestMessage, ResponseMessage};

/// A handle to a running tip-server process for integration tests.
pub struct TestServer {
    child: Child,
    reader: BufReader<std::process::ChildStdout>,
    writer: std::process::ChildStdin,
}

impl TestServer {
    /// Spawn the tip-server binary.
    /// `bin_path` should be the path to the compiled tip-server executable.
    pub fn spawn(bin_path: &str) -> Self {
        let mut child = Command::new(bin_path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("failed to spawn tip-server");

        let writer = child.stdin.take().expect("no stdin");
        let reader = BufReader::new(child.stdout.take().expect("no stdout"));

        Self {
            child,
            reader,
            writer,
        }
    }

    /// Send a request to the server.
    pub fn send(&mut self, msg: &RequestMessage) {
        let json = serde_json::to_string(msg).expect("serialize request");
        self.writer
            .write_all(json.as_bytes())
            .expect("write request");
        self.writer.write_all(b"\n").expect("write newline");
        self.writer.flush().expect("flush");
    }

    /// Read one response from the server.
    pub fn recv(&mut self) -> ResponseMessage {
        let mut line = String::new();
        self.reader.read_line(&mut line).expect("read response");
        serde_json::from_str(line.trim()).expect("parse response")
    }

    /// Send a request and return the response.
    pub fn request(&mut self, msg: &RequestMessage) -> ResponseMessage {
        self.send(msg);
        self.recv()
    }

    /// Shut down the server gracefully.
    pub fn shutdown(mut self) -> ResponseMessage {
        let msg = RequestMessage {
            id: u64::MAX,
            request: tip_protocol::messages::Request::Shutdown,
        };
        let resp = self.request(&msg);
        self.child.wait().expect("wait for child");
        resp
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        // Best-effort kill if still running
        let _ = self.child.kill();
    }
}
