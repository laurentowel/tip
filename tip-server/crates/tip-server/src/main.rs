mod diagnostics;
mod handler;
mod katex_backend;
mod latex_backend;
mod typst_backend;

use std::io::{self, BufReader};

use handler::Handler;
use tip_protocol::transport::{read_request, write_response};

fn main() -> io::Result<()> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut writer = stdout.lock();
    let mut handler = Handler::new();

    loop {
        let msg = match read_request(&mut reader)? {
            Some(msg) => msg,
            None => break, // EOF
        };

        let response = handler.handle(msg);
        write_response(&mut writer, &response)?;

        if handler.should_shutdown() {
            break;
        }
    }

    Ok(())
}
