# testkit — Shared Test Utilities

Provides reusable test infrastructure for tip-server:

## `server.rs` — TestServer

Spawns the `tip-server` binary as a child process for e2e testing:

```rust
let mut server = TestServer::spawn("/path/to/tip-server");
let resp = server.request(&RequestMessage { id: 1, request: Request::Shutdown });
server.shutdown();
```

- `spawn(bin_path)` — start server with stdin/stdout pipes
- `send(msg)` / `recv()` — raw protocol communication
- `request(msg)` — send + receive in one call
- `shutdown()` — graceful shutdown, waits for exit
- Auto-kills on `Drop`

## `assertions.rs` — SVG Assertions

```rust
assert_valid_svg(data);                          // has <svg> root
assert_svg_height(data, expected_pt, tolerance); // height within range
assert_svg_depth(depth_pt, expected_pt, tol);    // depth within range
assert_baseline_sane(height, depth);             // depth < height, ascent 0-100%
```
