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

### Versioning

The protocol carries an explicit version: `PROTOCOL_VERSION` on the
Rust side (`messages.rs`), `tip-protocol-version` on the elisp side
(`tip-server-proc.el`).  Format: `MAJOR.MINOR`.  Current value:
**`0.1`**.

Bump rules:

- **Bump major** on a breaking change: removed field, renamed enum
  variant, type change, removed method, semantics change a client
  written for the old version would handle wrong.
- **Bump minor** on an additive change a client can ignore: new
  optional field with `#[serde(default)]`, new method, new optional
  response variant.
- **Don't bump** on doc-only edits, internal refactors that don't
  cross the wire, test-only additions.

The `init` request carries a `client_version` field; the `init`
response echoes the server's version as `server_version` and
records any mismatch in `version_mismatch`.  See [`init`](#init--initialize-server-state)
for the wire shape.  Mismatch is **non-fatal** — both sides log a
warning (`display-warning` on the elisp side, `eprintln!` on the
Rust side) but the session proceeds.  Strict refusal is reserved
for a 1.x bump where the protocol stabilizes.

### Backend Dispatch

Most requests carry a `backend` field selecting which subsystem
handles them.  Values:

| Wire string | Implementation                              |
|-------------|---------------------------------------------|
| `"typst"`   | tip-core-typst (default; omitted = typst)   |
| `"latex"`   | tip-core-latex                              |
| `"katex"`   | tip-core-katex (web/HTML targets)           |

The client chooses the backend from the buffer's active major mode
(`major-mode` → `tip-backend` struct → backend id), not from the URI
extension — buffers may have nonstandard extensions or no file at
all.  When `backend` is omitted on the wire, the server defaults to
`typst` (matches `BackendId::default()`).

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

Every request has an `id` and a `method`; methods that carry params
have a `params` object:

```json
{"id": 1, "method": "sync", "params": {...}}
```

The `id` is a monotonically increasing integer. The response carries
the same `id` so the client can match it to the pending callback.

The full set of methods is enumerated by `Request` in `messages.rs`:

| Method                 | Params type                  | Response `kind`      |
|------------------------|------------------------------|----------------------|
| `init`                 | `InitParams`                 | `init`               |
| `sync`                 | `SyncParams`                 | `sync`               |
| `compile_fragments`    | `CompileFragmentsParams`     | `fragments`          |
| `compile_live`         | `CompileLiveParams`          | `live`               |
| `debug_skeleton`       | `DebugSkeletonParams`        | `debug_skeleton`     |
| `health_check`         | (none)                       | `health`             |
| `list_project_files`   | `ListProjectFilesParams`     | `project_files`      |
| `shutdown`             | (none)                       | `shutdown`           |

Any method may also yield `{"kind": "error", "error": "..."}` on a
server-side failure (deserialization error, panic boundary, missing
backend).

### `init` — Initialize Server State

```json
{"id": 0, "method": "init", "params": {
  "font_dirs": ["/home/user/fonts", "/opt/math-fonts"],
  "client_version": "0.1"
}}
```

Response:

```json
{"id": 0, "result": {
  "kind": "init",
  "ok": true,
  "server_version": "0.1",
  "version_mismatch": ""
}}
```

Sent once per session, before any other backend-touching method.

`font_dirs` (optional, default `[]`): paths added to the Typst
backend's `FontSearcher`, on top of the embedded font set and the
system fonts already discovered.

`client_version` (optional): wire-protocol version the client was
built against — the elisp side reads `tip-protocol-version`, the
Rust side reads `PROTOCOL_VERSION`.  Omitted = pre-handshake client.

The response carries `server_version` (the server's
`PROTOCOL_VERSION`) and `version_mismatch`.  When the client's
version differs, `version_mismatch` is a human-readable summary like
`"client speaks 9.99-bogus but server speaks 0.1"`; otherwise it's
empty (and may be omitted from the wire by `skip_serializing_if`).
Mismatch is non-fatal — see [Versioning](#versioning).

### `sync` — Send Buffer Content

```json
{"id": 1, "method": "sync", "params": {
  "backend": "typst",
  "uri": "/path/to/file.typ",
  "content": "The full buffer content as a string",
  "project_root": "/path/to/project"
}}
```

Response: `{"id": 1, "result": {"kind": "sync", "ok": true}}`

Must precede any `compile_fragments` / `compile_live` /
`debug_skeleton` request for the same `uri`.  The server:

1. Stores `content` in an in-memory document store keyed by `uri`.
2. Resolves the project root: `project_root` if present (used as-is,
   no walk); else walks up from the URI's parent directory looking
   for `typst.toml`, `Kodama.toml`, `.git`.
3. Sets the root on `TipWorld` so relative imports resolve.
4. Sets the main file's virtual path relative to root (critical for
   `#import "../..."`).

`project_root` is optional and omitted from the wire when absent
(`#[serde(skip_serializing_if = "Option::is_none")]`).  Used to
honor a buffer-local `tip-project-root-path` override and (future)
to anchor multi-file LaTeX projects.

See [URI Semantics](#uri-semantics) above for `uri` rules.

### `compile_fragments` — Batch Compile

```json
{"id": 2, "method": "compile_fragments", "params": {
  "backend": "typst",
  "uri": "/path/to/file.typ",
  "fragments": [
    {"start": 42, "end": 58},
    {"start": 100, "end": 115}
  ],
  "color": "#000000",
  "preamble": "#show math.equation: set text(rgb(\"#000000\"))\n",
  "page_setup": null,
  "display_math_width": null
}}
```

Field reference:

| Field                | Type                | Default | Notes                                                                                                |
|----------------------|---------------------|---------|------------------------------------------------------------------------------------------------------|
| `backend`            | string              | `typst` | See [Backend Dispatch](#backend-dispatch).                                                           |
| `uri`                | string              | —       | Required.  See [URI Semantics](#uri-semantics).                                                      |
| `fragments`          | array               | —       | Required.  Each `{start, end}` is a half-open byte range.                                            |
| `color`              | string              | —       | Foreground color as `#RRGGBB`.  Used in the preamble and as a sentinel for `currentColor` rewriting. |
| `preamble`           | string \| null      | null    | Backend-specific prelude injected before each fragment.  Typst docs above; LaTeX expects packages.   |
| `page_setup`         | string \| null      | null    | Typst page-setup string.  When null the server uses a sensible default (margin 0.2em, fill none).    |
| `display_math_width` | string \| null      | null    | LaTeX dimension string (`"20em"`, `"400pt"`).  LaTeX uses for display-math centering.  Typst ignores. |

`start` / `end` are **0-indexed byte offsets** into the synced
`content`.  Emacs converts via `position-bytes`.

Response:

```json
{"id": 2, "result": {"kind": "fragments", "fragments": [
  {"start": 42, "end": 58, "svg": "<svg>...</svg>",
   "height_pt": 12.5, "depth_pt": 2.3, "width_pt": 38.2,
   "font_size_pt": 11.0,
   "error": null, "error_detail": null},
  {"start": 100, "end": 115, "svg": "",
   "height_pt": 0.0, "depth_pt": 0.0, "width_pt": 0.0,
   "font_size_pt": null,
   "error": "unknown variable: foo",
   "error_detail": {"severity": "error", "message": "unknown variable: foo",
                    "detail": null, "line_in_fragment": null, "hint": "foo"}}
]}}
```

`FragmentResult` fields:

| Field           | Type                  | Notes                                                                                                                      |
|-----------------|-----------------------|----------------------------------------------------------------------------------------------------------------------------|
| `start`, `end`  | usize                 | Echo of the request's range.                                                                                               |
| `svg`           | string                | Inline SVG.  Empty on error.                                                                                               |
| `height_pt`     | f64                   | Cropped SVG height in points.  Used to scale the Emacs image height.                                                       |
| `depth_pt`      | f64                   | Ink below the baseline in points.  Used for `:ascent` calculation.                                                         |
| `width_pt`      | f64                   | Ink width in points (no margins).  Default 0 when omitted.                                                                 |
| `font_size_pt`  | f64 \| null           | Base font size used by the backend.  Typst always reports 11.0.  LaTeX reports the document class's value.  Null when unknown. |
| `error`         | string \| null        | One-line summary; mirrors `error_detail.message` when both are present.  Clients targeting the new structured form should prefer `error_detail`. |
| `error_detail`  | `FragmentError` \| null | Structured error.  See below.                                                                                              |

`FragmentError`:

| Field               | Type                | Notes                                                                                          |
|---------------------|---------------------|------------------------------------------------------------------------------------------------|
| `severity`          | `"error"` \| `"warning"` | Required.                                                                                      |
| `message`           | string              | Single-line human-readable summary.                                                            |
| `detail`            | string \| null      | Multi-line context (LaTeX log surroundings, Typst error trace).                                |
| `line_in_fragment`  | u32 \| null         | 0-based line offset within the fragment.  LaTeX-only today; Typst reports null.                |
| `hint`              | string \| null      | Source text reported on the error line.  Useful for locating the exact range in the buffer.   |

### `compile_live` — Single-Fragment Live Preview

```json
{"id": 3, "method": "compile_live", "params": {
  "backend": "typst",
  "uri": "/path/to/file.typ",
  "start": 42, "end": 58,
  "color": "#000000",
  "preamble": "...",
  "page_setup": null
}}
```

Response: `{"id": 3, "result": {"kind": "live", ...flat FragmentResult fields}}`

`compile_live`'s response flattens `FragmentResult` into the
top-level result object (no enclosing `fragment` key).  Contrast
`compile_fragments`, where results are an array under `fragments`.
Used by `tip-live-mode`'s 0.3 s idle compile and historically by
the childframe preview.

`compile_live` is a strict subset of `compile_fragments` with one
range — there's no `display_math_width` because live preview always
operates on whatever the cursor's currently inside.

### `debug_skeleton` — Show the Compile Skeleton

```json
{"id": 4, "method": "debug_skeleton", "params": {
  "backend": "typst",
  "uri": "/path/to/file.typ",
  "start": 42, "end": 58
}}
```

Response: `{"id": 4, "result": {"kind": "debug_skeleton", "source": "...synthetic source..."}}`

Returns the exact synthesized source the bottom-up compile strategy
*would* feed to Typst for the fragment at `[start, end)`.  Used by
`M-x tip-show-skeleton-at-point` for debugging scope-resolution
issues — when a compile error mentions a name that isn't visible in
the user's buffer, the skeleton shows what context the server saw.

### `health_check` — Server Diagnostics

```json
{"id": 5, "method": "health_check"}
```

Response:

```json
{"id": 5, "result": {"kind": "health", "report": {
  "server_version": "0.1.0",
  "target_triple": "x86_64-unknown-linux-gnu",
  "os": "linux", "arch": "x86_64",
  "typst": {"ok": true, "typst_version": "0.14.2", "fonts_found": 142},
  "latex": {"ok": true,
            "latex":       {"found": true, "path": "/usr/bin/pdflatex", "version": "TeX Live 2024", "meets_min_version": true},
            "dvisvgm":     {"found": true, "path": "/usr/bin/dvisvgm",  "version": "2.14.2",        "meets_min_version": true},
            "preview_sty": {"found": true, "path": null,                "version": "12.3",          "meets_min_version": true}},
  "warnings": []
}}}
```

Diagnostic snapshot — server build info, per-backend probe results,
non-fatal warnings (e.g., "dvisvgm 2.8 detected; 2.14+ recommended").
Used by `M-x tip-server-info` and as the body of bug reports.

A backend's probe is `null` when the backend isn't compiled in (not
"detected absent" — actually missing from the binary).

### `list_project_files` — Enumerate Project Files

```json
{"id": 6, "method": "list_project_files", "params": {
  "backend": "latex",
  "uri": "/path/to/main.tex"
}}
```

Response:

```json
{"id": 6, "result": {"kind": "project_files",
  "root": "/path/to",
  "files": ["/path/to/main.tex", "/path/to/chapters/intro.tex", "/path/to/macros.tex"]
}}
```

Backends that track a project graph (LaTeX's `TexProject`) return
the connected component reachable via `\input` / `\include` from the
queried URI.  Backends without a graph (Typst today) return just the
URI itself; clients fall back to a root-marker walk locally.

`files` is guaranteed non-empty (at minimum the queried URI).  All
paths absolute; all sit under `root` so a client can preserve
relative layout when packing into a tar (e.g. for Docker transport).

### `shutdown` — Graceful Shutdown

```json
{"id": 7, "method": "shutdown"}
```

Response: `{"id": 7, "result": {"kind": "shutdown", "ok": true}}`

The server sets an exit flag and leaves the main loop after sending
the response.  No new requests should be sent after `shutdown`; the
process exits cleanly within ~1 ms.

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
