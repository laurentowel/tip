# LaTeX error handling — design

Context: `tip-latex` v1 treats compile errors as opaque strings attached to
`FragmentResult.error`.  When a fragment fails, the overlay shows a muted
background (via `tip-error-face`) and the full error lives only in the
response payload — invisible unless the user ran with `tip-enable-debug`.
This is worse than OLP, which at least shows a hover tooltip.

Goal: give users meaningful, actionable error feedback without forcing
them into tooltip-hover or buffer-switching workflows.

## References studied

**texlab** (Rust, LSP for LaTeX) — `crates/parser/src/build_log.rs`,
`crates/diagnostics/src/build_log.rs`, `crates/diagnostics/src/types.rs`:

- Parses `.log` files with three regexes covering TEX_ERROR, WARNING,
  BAD_BOX.
- Each match yields `{ relative_path, level, message, line, hint }`.
- `find_range_of_hint` searches for the hint text within the reported
  line of the source document, producing a precise `TextRange` to
  highlight.
- Fallbacks: when hint isn't found, uses zero-width range at line start.
- Surfaces via LSP `textDocument/publishDiagnostics` → Flymake / Eglot.

Presentation is whatever the LSP client chooses; typical Emacs setup
shows Flymake squigglies, gutter markers, and eldoc hover.

**digestif**: has no diagnostic layer at all.  It's a completion /
hover / signature-help LSP only.  Not a reference for our purposes.

**org-latex-preview** (tec's fork):

- Per-snippet error extraction from `! Preview: Snippet N started ... !
  Preview: Snippet N ended` blocks in stdout.
- Line remapping: the `l.M` in the error text is snippet-local; OLP
  offsets by the `Preview: Snippet N started.\nl.OFFSET` line number to
  get the buffer position.
- Attaches to `fragment-info :errors`.
- Surfaces as: fringe indicator, hover tooltip, and a separate
  `*Org LaTeX Preview Output*` buffer.

## What we adopt from each

| from texlab | why |
|---|---|
| three-regex error taxonomy (TEX / WARNING / BAD_BOX) | separates severity cleanly; lets us ignore BAD_BOX by default |
| hint-text matching to get precise range inside a source line | gives Flymake an underline range, not just a line |
| Flymake integration as primary UI | users already know it; LSP-style muscle memory |

| from OLP | why |
|---|---|
| per-snippet extraction via `Snippet N started/ended` markers | we batch, so whole-log matching is ambiguous — snippet markers disambiguate |
| snippet-local `l.M` → buffer-line offset remapping | more reliable than hint-search for our case |
| fringe indicator as secondary UI | at-a-glance "which fragments failed?" |

What we explicitly **don't** adopt:

- OLP's dedicated `*Preview Output*` buffer as the PRIMARY error view.
  It's buffer-switching friction; users hit it to escape tooltips.
- Texlab's whole-log approach.  Our batches already mark snippet
  boundaries; using OLP's per-snippet segmentation is more precise.

## Data model

Server returns per fragment:

```rust
pub struct FragmentError {
    pub severity: ErrorSeverity,        // Error | Warning
    pub message: String,                 // human-readable, single line
    pub detail: Option<String>,          // multi-line context if any
    pub line_in_fragment: Option<u32>,   // 0-based; the `l.M` - offset
    pub hint: Option<String>,            // source text near the error
}

pub enum ErrorSeverity { Error, Warning }

pub struct FragmentResult {
    // ... existing fields ...
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_detail: Option<FragmentError>,
    // `error: Option<String>` stays as backward-compat single-line
    // summary.  When `error_detail` is present, `error` equals
    // `error_detail.message`.
}
```

Emacs overlay gains:

- `tip-error-severity` — `'error` or `'warning` or nil.
- `tip-error-message` — the one-line message.
- `tip-error-detail` — the full multi-line text (lazy display).
- `tip-error-point` — buffer position of the exact error character,
  computed from `(overlay-start) + line_offset + column`.

## Presentation modes (all orthogonal, each independently toggleable)

### 1. Inline overlay (default, always on)

Replace the failed fragment's image display with a compact inline
indicator: a red "⚠" or "⚑" glyph before the source text, plus red
underline face on the exact error region (from `tip-error-point`
outwards to end of the offending construct).  The source text stays
visible so the user can fix it in-place.

Implementation: in `tip--apply-fragment-results`, when a fragment has
`error_detail`, don't create a display-image overlay; create a range
overlay with `face 'tip-error-range` (red underline) spanning the
hint region, plus `before-string` with the glyph.

### 2. Flymake integration (opt-in via `tip-latex-diagnostics-flymake`)

Register a Flymake backend that reports all fragments-with-errors.
On each `compile_fragments` response, translate errors to
`flymake-diagnostic` values with type `:error` or `:warning` and the
buffer range.  Flymake handles squigglies, gutter bitmaps, and
`M-x flymake-goto-next-error`/`prev-error`.

Default off for now (users without Flymake config shouldn't see
nothing change); flip to on-by-default if there's demand.

### 3. Echo area (opt-in via `tip-echo-errors`, existing defcustom)

When on, and the cursor is inside a failed fragment, echo the error
message.  Already implemented in `tip-live--compile-partial`; just
update it to read `error_detail.message` when present (cleaner) and
to show severity prefix: `"TIP [warning]: …"`.

### 4. Eldoc (automatic if eldoc-mode is on)

A `tip-eldoc-documentation-function` that returns the error message
when point is in a failed fragment.  Eldoc users get the message in
the echo area / eldoc popup without configuring `tip-echo-errors`.
Integrates with `eldoc-documentation-strategy 'eldoc-documentation-compose`
so other providers coexist.

### 5. Dedicated buffer (opt-in via `M-x tip-list-errors`)

A `*tip-errors*` buffer listing all current errors (across all
tip-mode buffers) with clickable links.  Useful for triaging "what's
broken in this paper".  Lowest priority; add when someone asks.

## Server-side implementation (Rust)

Add `parse_preview_error_blocks` that scans stdout for
`! Preview: Snippet N started.\nl\.X (...)` and the matching
`! Preview: Snippet N ended` or `! Something-Error: ...` between them.
Extract:

- snippet index N → fragment i = N - 1.
- `l.X` → start line of the snippet in the batch file.
- Error text: all lines between `! ERROR` and the next `!` boundary or
  `Preview: Snippet N ended`.
- Line of error: grep for `l\.Y` inside the error block; line_in_fragment
  = Y - X.
- Severity: `! LaTeX Error` / `! Undefined control sequence` etc. →
  Error.  `LaTeX Warning:` / `Package … Warning` → Warning.

Populate `error_detail` on the appropriate `FragmentResult`.  Also keep
the one-line summary in `error` for backward compat.

Estimated size: ~120 Rust LOC (regex + dispatch logic + protocol wiring)
+ ~80 Emacs LOC (inline-overlay renderer, optional Flymake backend,
optional eldoc function).

## Open questions

1. **Per-fragment Flymake backend or buffer-level?** Flymake is
   buffer-scoped.  Every compile response clears and republishes.
   Simplest: buffer-level backend that holds a list of current
   diagnostics; re-publishes on each compile response.
2. **Hint range heuristic**: for `l.M\\sqrt{x` the hint is `\sqrt{x`.
   Should we underline the whole hint or just the first token?  Texlab
   does full-hint; simpler to match.
3. **Error deduplication**: preview.sty sometimes emits the same error
   twice (once as `!` and once as Package Warning).  Keep both or
   dedupe by message?  Dedupe; the user only cares once.
4. **Severity default**: should warnings block rendering?  No — warnings
   leave the SVG intact, just mark the fragment.

## Build order

1. Server-side structured error extraction (FragmentError struct,
   regex parser, populate response).  Shippable without any Emacs
   changes; just moves one-line error → better one-line error.
2. Emacs-side inline overlay (presentation mode 1) — read
   `error_detail`, render red underline + glyph.  Users see rich
   errors in-place.
3. Echo-area/eldoc tweaks — already ~90% there; flip to use
   `error_detail` when present.
4. Flymake backend (mode 2) — opt-in defcustom.
5. Optional extras: dedicated buffer, jump-to-error, etc.  Only if
   requested.
