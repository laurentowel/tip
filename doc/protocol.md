# The TIP Communication Protocol

## Overview

TIP uses **newline-delimited JSON over stdio pipes** — the same pattern as LSP (Language Server Protocol). Emacs spawns `tip-server` as a child process and talks to it through stdin/stdout. No TCP, no HTTP, no port configuration.

```
Emacs (tip.el)                    tip-server (Rust)
     │                                  │
     │──── stdin (JSON + newline) ────▶│
     │                                  │  parse → handle → respond
     │◀── stdout (JSON + newline) ─────│
     │                                  │
```

Each message is a single line of JSON terminated by `\n`. The server reads one line, parses it, handles it synchronously, writes one response line, and waits for the next request. There is no multiplexing, no streaming, no notifications from server to client.

## Why This Design

### Why stdio, not TCP?

- **Zero config**: No port to configure, no firewall issues, no "address already in use"
- **Process lifecycle**: Emacs owns the process. When Emacs exits, the pipe closes, the server gets EOF and exits cleanly
- **Security**: No network surface. The server only talks to the Emacs process that spawned it
- **Docker compatible**: `docker run -i` connects stdio. Same protocol works with local binary or Docker container

### Why JSON, not a binary protocol?

- **Debuggable**: `tip-enable-debug` logs every message as human-readable text
- **Emacs native**: `json-encode`/`json-parse-string` are built-in and fast (C implementation since Emacs 27)
- **Extensible**: Adding fields doesn't break old clients (unknown keys are ignored)
- **Good enough**: SVG data is the bulk of each response, and it's already text. Binary encoding wouldn't help much

### Why synchronous request/response?

Each request gets exactly one response with the same `id`. No out-of-order responses, no server-initiated messages. This makes the Emacs side trivial: send request, store callback keyed by id, process response when it arrives.

The server handles requests sequentially. This is fine because:
- Fragment compilation takes 2-10ms per fragment
- Batch requests (50+ fragments) are sent as a single request with a vector of fragment locations
- The bottleneck is Emacs overlay creation, not server computation

## The Messages

This file is the human-readable spec.  The canonical, machine-checked
source for field types and serde attributes is
[`tip-server/crates/tip-protocol/src/messages.rs`](../tip-server/crates/tip-protocol/src/messages.rs)
— if the two disagree, that file wins for types, this one wins for
intent.  Keep them aligned: any wire-visible change in messages.rs
needs a paragraph here.

### URI Semantics

The `uri` field on `sync` / `compile_fragments` / `compile_live` is
typed `String` (not `Option<String>`) on the Rust side.  Sending
`null` from elisp would JSON-encode to `null`, which the deserializer
rejects with "invalid type: null, expected a string" — and the server
exits.  The elisp side enforces three conventions to avoid that:

1. **File-backed buffer** → send `buffer-file-name` verbatim.  This
   is the common case.  Project-root walk starts from the URI's
   parent directory looking for `typst.toml`, `Kodama.toml`, `.git`
   markers.

2. **Unsaved buffer** → send the empty string `""`.  The server
   stores content under that key (so subsequent compiles match) but
   the project-root walk gives nothing — appropriate for a buffer
   with no on-disk anchor.  Imports against `@local/` packages still
   work; relative imports against the source's tree don't (no tree to
   anchor against).

3. **`tip-edit-indirect` synthetic compile** → send
   `tip-edit-virtual://<source-buffer-name-or-path>`.  The edit
   buffer compiles a *spliced* version of the source's content
   (edit-buffer text replacing the fragment region in-place); using
   the source's real URI would clobber the source's cached content
   on the server when `tip-mode` in source resyncs concurrently.
   The virtual scheme keeps the two document caches separate.
   Project root is sent explicitly via the `project_root` field so
   imports keep resolving against the source's tree.

These conventions are elisp-side only — the server treats every URI
as an opaque string key into its document store.  A future protocol
revision could change `uri` to `Option<String>` and let the server
synthesize a placeholder; until then, the rules above are the
contract.

### Request Envelope

Every request has an `id` and a `method`:

```json
{"id": 1, "method": "sync", "params": {...}}
```

The `id` is a monotonically increasing integer. The response carries the same `id` so the client can match it to the pending callback.

### `sync` — Send Buffer Content

```json
{"id": 1, "method": "sync", "params": {
  "uri": "/path/to/file.typ",
  "content": "The full buffer content as a string"
}}
```

Response: `{"id": 1, "result": {"kind": "sync", "ok": true}}`

This must be sent before any `compile_fragments` request. The server:
1. Stores the content in an in-memory document store
2. Walks up from the file's directory to find the project root (`typst.toml`, `Kodama.toml`, `.git`)
3. Sets the root on the `TipWorld` so relative imports resolve correctly
4. Sets the main file's virtual path relative to root (critical for `#import "../..."`)

### `compile_fragments` — Compile Math Fragments

```json
{"id": 2, "method": "compile_fragments", "params": {
  "uri": "/path/to/file.typ",
  "fragments": [
    {"start": 42, "end": 58},
    {"start": 100, "end": 115}
  ],
  "color": "#000000",
  "preamble": "#show math.equation: set text(rgb(\"#000000\"))\n#set page(fill: rgb(\"#ffffff\"))\n",
  "page_setup": null
}}
```

`start` and `end` are **0-indexed byte offsets** into the synced content. Not character positions — Emacs converts via `position-bytes`.

Response:
```json
{"id": 2, "result": {"kind": "fragments", "fragments": [
  {"start": 42, "end": 58, "svg": "<svg>...</svg>", "height_pt": 12.5, "depth_pt": 2.3, "error": null},
  {"start": 100, "end": 115, "svg": "", "height_pt": 0.0, "depth_pt": 0.0, "error": "unknown variable: foo"}
]}}
```

Each fragment result includes:
- `svg`: Inline SVG string (empty on error)
- `height_pt`: Cropped SVG height in points (for Emacs display scaling)
- `depth_pt`: Below-baseline depth in points (for ascent calculation)
- `error`: Error message string, or null on success

### `compile_live` — Compile Single Fragment for Live Preview

```json
{"id": 3, "method": "compile_live", "params": {
  "uri": "/path/to/file.typ",
  "start": 42, "end": 58,
  "color": "#000000",
  "preamble": "...",
  "page_setup": null
}}
```

Response: `{"id": 3, "result": {"kind": "live", "start": 42, "end": 58, "svg": "...", "height_pt": 12.5, "depth_pt": 2.3}}`

Same as `compile_fragments` but for a single fragment, used by the live preview childframe.

### `shutdown` — Graceful Shutdown

```json
{"id": 4, "method": "shutdown"}
```

Response: `{"id": 4, "result": {"kind": "shutdown", "ok": true}}`

The server sets a flag and exits the main loop after sending the response.

## The Emacs Side

### Process Management

```elisp
(make-process
 :name "tip-server"
 :command (list exe)
 :connection-type 'pipe      ; stdio, not pty
 :filter #'tip--process-filter
 :sentinel #'tip--process-sentinel
 :noquery t)                  ; don't ask before killing
```

`:connection-type 'pipe` is critical. A pty would add line buffering and terminal escape handling. Pipes give raw byte streams.

### Sending Requests

```elisp
(defun tip--send-request (method params &optional callback)
  (let* ((id (tip--next-id))
         (request `(("id" . ,id)
                    ("method" . ,method)
                    ("params" . ,params))))
    (when callback
      (puthash id callback tip--pending-callbacks))
    (process-send-string tip--server-process
                         (concat (json-encode request) "\n"))))
```

The callback is stored in `tip--pending-callbacks` (a hash table keyed by id). Fire-and-forget requests (like `sync`) omit the callback.

### Receiving Responses

The process filter accumulates output in `tip--response-buffer` and processes complete lines:

```elisp
(defun tip--process-filter (_proc output)
  (setq tip--response-buffer (concat tip--response-buffer output))
  (while (string-match "\n" tip--response-buffer)
    (let* ((line (substring tip--response-buffer 0 (match-beginning 0))))
      (setq tip--response-buffer (substring tip--response-buffer (1+ (match-beginning 0))))
      ;; Parse JSON, look up callback by id, call it
      (let* ((response (json-parse-string line :object-type 'alist))
             (id (alist-get 'id response))
             (result (alist-get 'result response))
             (callback (gethash id tip--pending-callbacks)))
        (remhash id tip--pending-callbacks)
        (when callback (funcall callback result))
        (run-hook-with-args 'tip-server-response-functions result)))))
```

Key details:
- Output arrives in arbitrary chunks (the OS buffers pipes). The `\n` search handles partial lines correctly
- `json-parse-string` with `:object-type 'alist` returns alists, not hash tables — faster for small objects
- The callback runs synchronously inside the filter. This means overlay creation happens in the same event loop cycle as response reception
- `tip-server-response-functions` hook runs after every response for extensions (like the spinner)

### Byte Offset Conversion

Emacs positions are 1-indexed character positions. Typst uses 0-indexed byte offsets. The conversion:

```elisp
;; Emacs position → byte offset for server
(1- (position-bytes emacs-pos))

;; Byte offset from server → Emacs position
(byte-to-position (1+ byte-offset))
```

This is exact for ASCII. For multibyte characters (Unicode math symbols, accented text), `position-bytes` correctly accounts for UTF-8 encoding. The server indexes into the raw UTF-8 byte string.

### Docker Transport

Same protocol, different process:

```elisp
(make-process
 :command (list "docker" "run" "--rm" "-i"
                "-v" (concat project-dir ":/project")
                tip-docker-image)
 :connection-type 'pipe
 :filter #'tip--process-filter ...)
```

`-i` keeps stdin open. `-v` mounts the project directory. The server inside Docker sees files at `/project/...`, and URIs are mapped accordingly.

## Typical Session

```
→ {"id":1,"method":"sync","params":{"uri":"/home/user/paper.typ","content":"#let x = 1\n$x + 1$\n"}}
← {"id":1,"result":{"kind":"sync","ok":true}}
→ {"id":2,"method":"compile_fragments","params":{"uri":"/home/user/paper.typ","fragments":[{"start":12,"end":19}],"color":"#000000","preamble":"#show math.equation: set text(rgb(\"#000000\"))\n#set page(fill: rgb(\"#ffffff\"))\n"}}
← {"id":2,"result":{"kind":"fragments","fragments":[{"start":12,"end":19,"svg":"<svg ...>...</svg>","height_pt":12.55,"depth_pt":3.25,"error":null}]}}
→ {"id":3,"method":"shutdown"}
← {"id":3,"result":{"kind":"shutdown","ok":true}}
[EOF]
```

Total: 3 messages, 2 round-trips (sync doesn't need a response wait — Emacs fires compile immediately after). The entire session takes <50ms for a single fragment.

## Future Considerations

**Incremental sync**: Currently sends the full buffer content on every `sync`. Could send diffs (like LSP's `textDocument/didChange`). Not a priority — full sync of a 50KB document takes <1ms.

**Streaming results**: For 1000-fragment batches, the server could stream individual results as they complete instead of buffering all of them. Would require a protocol extension (multiple response lines per request).

**emacs-lsp-booster**: The JSON-over-stdio protocol is compatible with [emacs-lsp-booster](https://github.com/blahgeek/emacs-lsp-booster), which buffers I/O and optionally pre-compiles JSON into Emacs bytecode for faster parsing.

## Files

| File | Role |
|------|------|
| `tip-protocol/src/messages.rs` | Request/Response type definitions (serde) |
| `tip-protocol/src/transport.rs` | Read/write newline-delimited JSON |
| `tip-server/src/main.rs` | Main loop: read → handle → write |
| `tip-server/src/handler.rs` | Dispatches methods to core functions |
| `tip.el` | `tip--send-request`, `tip--process-filter`, `tip--start-server-process` |
