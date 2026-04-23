# Digestif extraction plan

Design extraction: reimplement **only** the four things we need from
[digestif](https://github.com/astoff/digestif) in Emacs Lisp + Rust, dropping
everything else (LSP machinery, completion, signature hints, package tag DB).

Goal: correctness of digestif's catcode-aware scanning, none of its runtime
footprint.

## What we want from digestif

| # | feature                 | digestif source                         | our target layer  |
|---|-------------------------|-----------------------------------------|-------------------|
| 1 | math fragment ranges    | `Parser.lua`: `scan_patt`+`mathshift`   | elisp + rust      |
| 2 | preamble extraction     | `init_callbacks.newcommand` / …         | elisp             |
| 3 | nested/outermost filter | `group` LPeg pattern (recursive)        | elisp + rust      |
| 4 | `\input` / `\include`   | `ManuscriptLaTeX.init_callbacks.input`  | rust (v2+)        |

## What we drop

- **Package tag database** (`data/*.lua`, hundreds of files). We're not doing
  completion or diagnostics.
- **`scan_patt` with `things` plist** — the full machinery for "dispatch
  on any registered command's action." We only need to dispatch on a handful
  of things (`\begin`, `\end`, `\input`, `\include`, `\usepackage`).
- **LPeg itself.** We're not porting the grammar combinators; we're porting
  the catcode logic into idiomatic scanners in each host language.
- **Snippets, signature info, completion, doc lookup.** All LSP concerns.
- **Context inference** (`get_context`, `local_scan_parse_keys`, tikzpath
  parsing). Orthogonal to math preview.
- **The Manuscript/child DAG.** We'll reuse the *model* (parent + child
  scripts per included file) in Rust for v2, but not the code. Lazy
  instantiation stays on our side.

## Feature 1 — Math fragment ranges

### What digestif does

`Parser.lua`'s `scan_patt` builds an LPeg pattern that finds the next `cs`
(control sequence), `mathshift` (`$` or `$$`), or `par` (paragraph break) —
honouring catcodes so escaped `\$` is not a mathshift and `% $x$` inside a
comment is ignored. `Manuscript:scan(callbacks, pos)` drives the loop.

Digestif **does not** have a ready-made "collect all math ranges" callback —
it emits mathshift events and leaves aggregation to the caller. That's fine;
it's the aggregation we write anyway.

### Elisp port

The catcode concerns map cleanly onto tools Emacs already has:

| digestif concern      | emacs equivalent                                     |
|-----------------------|------------------------------------------------------|
| `comment` catcode     | `syntax-ppss`: `(nth 4 …)` is t inside comments      |
| `escape` (`\$`)       | `char-before` check or `\\\\$` lookbehind in regex   |
| `mathshift` (`$`/`$$`)| regex `\\$\\$?`                                      |
| `bgroup`/`egroup`     | `scan-sexps` with latex-mode syntax table            |
| paragraph             | regex `\n[\t ]*\n`                                   |
| verbatim environments | explicit pre-pass (syntax-ppss doesn't cover these)  |

Sketch:

```elisp
(defconst tip-latex--math-begin-re
  (rx (or
       ;; \( ... \)          inline
       "\\("
       ;; \[ ... \]          display
       "\\["
       ;; $...$  or  $$...$$ (branch in post-processing)
       (seq (not (any ?\\ ?$)) "$")
       ;; \begin{equation}   display, named environments
       (seq "\\begin{"
            (group (or "equation" "equation*" "align" "align*"
                       "gather" "gather*" "multline" "multline*"
                       "eqnarray" "eqnarray*" "displaymath" "math"))
            "}"))))

(defun tip-latex--verbatim-ranges (beg end)
  "Return list of (VBEG . VEND) ranges covering verbatim-like environments."
  (save-excursion
    (goto-char beg)
    (let (result)
      (while (re-search-forward
              (rx "\\begin{" (group (or "verbatim" "lstlisting"
                                        "minted" "Verbatim"
                                        "alltt")) "}")
              end t)
        (let ((vbeg (match-beginning 0))
              (envname (match-string 1)))
          (when (re-search-forward (format "\\\\end{%s}" envname) end t)
            (push (cons vbeg (match-end 0)) result))))
      (nreverse result))))

(defun tip-latex--in-verbatim-p (pos ranges)
  (cl-some (lambda (r) (and (>= pos (car r)) (< pos (cdr r)))) ranges))

(defun tip-latex-collect-fragments (beg end &optional avoid-pos)
  "Collect math fragment byte positions in BEG..END.
Honors comments and verbatim environments.  Returns same shape as the
typst backend (list of alists with \"start\"/\"end\" byte offsets)."
  (let ((verbatim (tip-latex--verbatim-ranges beg end))
        ranges)
    (save-excursion
      (goto-char beg)
      (while (re-search-forward tip-latex--math-begin-re end t)
        (let ((start (match-beginning 0)))
          (unless (or (nth 4 (syntax-ppss start))           ; in comment
                      (tip-latex--in-verbatim-p start verbatim))
            (let ((frag-end (tip-latex--find-math-end start)))
              (when (and frag-end
                         (or (null avoid-pos)
                             (not (and (>= avoid-pos start)
                                       (<= avoid-pos frag-end)))))
                (push (cons start frag-end) ranges)))))))
    ;; Filter nested, convert to byte offsets (same as typst backend).
    (tip-latex--to-fragment-alist (tip-latex--outermost (nreverse ranges)))))
```

`tip-latex--find-math-end` dispatches on the matched opener (`\(` → `\)`,
`\[` → `\]`, `$` → next unescaped `$`, `\begin{…}` → `\end{…}`). Each is a
5-line helper.

**Estimated size**: ~150 Elisp lines, including helpers and tests.

### Rust port (optional — only if we want server-side scope analysis)

For v1 the Emacs side sends byte ranges; the Rust server just receives them
and compiles. No Rust tokenizer needed. Mentioned here because v2 (include
resolution) will need a matching Rust tokenizer for the same catcode rules,
and it should share a single module with a shared test corpus.

Prefer a hand-written tokenizer in Rust over `logos` — catcode-sensitive
escape handling is cleaner with explicit state. ~200 LOC. Uses the same
catcode model as digestif's `default_catcodes`.

## Feature 2 — Preamble extraction

### What digestif does

Walks the document, dispatches on commands that define new commands
(`\newcommand`, `\newenvironment`, `\NewDocumentCommand`,
`\NewDocumentEnvironment`) and commands that load packages (`\usepackage`,
`\RequirePackage`). Records each in `self.commands` / `self.environments`
indexes. Very thorough.

### What we actually need

For v1 preview, we just want the **raw preamble string** — everything
between buffer start and `\begin{document}`. Not structured; the LaTeX
compiler will parse it the normal way.

```elisp
(defun tip-latex--preamble-end ()
  "Return position of `\\begin{document}' or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "\\\\begin{document}" nil t)
      (match-beginning 0))))

(defun tip-latex-build-preamble ()
  "Return the document preamble as a string, or a minimal default."
  (or (and (tip-latex--preamble-end)
           (buffer-substring-no-properties
            (point-min) (tip-latex--preamble-end)))
      tip-latex-default-preamble))

(defcustom tip-latex-default-preamble
  "\\documentclass{article}
\\usepackage{amsmath,amssymb}"
  "Preamble used when the buffer has no `\\begin{document}'."
  :type 'string)
```

**That's the whole preamble extractor.** ~20 lines.

We could later mirror digestif's richer analysis if we ever need per-fragment
scope (e.g. which `\newcommand`s are visible at this position). Not needed
for v1 — preview.sty takes the whole preamble for every fragment.

## Feature 3 — Nested/outermost filter

### What digestif does

`group` LPeg pattern is recursive (`V(1)`) — matches balanced `{...}`
skipping nested groups. This is how it walks command arguments without
treating nested braces as ending the current scope.

### What we need

Same thing our Typst side already does: given a list of ranges, drop any
range contained in another. Identical to
`tip-collect-fragment-locations`'s nesting filter.

```elisp
(defun tip-latex--outermost (ranges)
  (let (outer)
    (dolist (r ranges)
      (unless (cl-some (lambda (o)
                         (and (not (equal o r))
                              (<= (car o) (car r))
                              (>= (cdr o) (cdr r))))
                       ranges)
        (push r outer)))
    (nreverse outer)))
```

Already in `tip-typst.el` with the exact same logic — we could lift it into
`tip-backend.el` as a shared helper.

The interesting nesting case LaTeX brings: `\[ \text{foo $x$ bar} \]`. The
inner `$x$` is inside the outer `\[..\]` so the filter drops it. Correct.

Pure `{...}` balance (tracking argument boundaries) isn't needed for math
fragment detection — the math delimiters themselves are unambiguous given
comment/verbatim filtering.

**Estimated size**: ~15 Elisp lines (already written, reused).

## Feature 4 — `\input` / `\include` (v2)

### What digestif does

On `\input{filename}`:
1. Parse argument via `parse_command` → `argument_items`.
2. `substring_stripped` to get the filename.
3. Apply template (add `.tex` if no extension).
4. Try `add_package` — if the file matches a known package, load tags.
5. Else push `{name, pos, cont, manuscript = self}` onto `child_index`.
6. Return continuation position so scanning resumes after the command.

Children are instantiated lazily via `Manuscript:child(name)`. Each child
has its own `src`, own parser state, own indexes. The whole project forms a
DAG queryable via `Manuscript:find_manuscript(filename)`.

### Our v2 plan (Rust-side)

v1 refuses any buffer whose preamble contains `\input` / `\include` /
`\subimport` (warn once, fall back to rendering only fragments that don't
depend on the missing scope).

v2 mirrors digestif's child-Manuscript model in Rust:

```rust
struct TexProject {
    root_path: PathBuf,
    scripts: HashMap<PathBuf, Script>,
}

struct Script {
    path: PathBuf,
    src: String,
    /// Parent → child resolution order.
    children: Vec<PathBuf>,
    /// Positions of \input / \include / \subimport references.
    includes: Vec<IncludeSite>,
}

impl TexProject {
    fn load(root: &Path) -> io::Result<Self> { /* read root, scan, follow */ }
    fn preamble_for(&self, frag_path: &Path) -> String {
        // Walk from frag_path up to root, concatenate preambles.
    }
}
```

Key design choices inherited from digestif:
- **Lazy loading**: don't follow `\input` until a fragment in that subfile
  is actually compiled.
- **No TEXINPUTS**: resolve relative to the current file's directory, then
  `root_path`. Kpathsea and TeX Live trees are the compiler's job.
- **No master-file configuration**: the `\input` edges form the project
  graph. If a child is not reachable from the buffer-under-edit via
  ancestor `\input`s, we don't care about it.

The Rust tokenizer from Feature 1 gets reused here — same catcode rules
to spot `\input` / `\include` control sequences.

**Estimated size (v2)**: ~400 Rust lines (TexProject + Script + tokenizer
shared with Feature 1).

## What the full tip-latex looks like

**Emacs side — v1** (~300 LOC total, mostly reused from tip-typst shape):

- `tip-latex.el`:
  - `tip-latex-collect-fragments` (Feature 1, ~150 LOC)
  - `tip-latex-bounds-at-point` (same regex, walking up from POS, ~30 LOC)
  - `tip-latex-build-preamble` (Feature 2, ~20 LOC)
  - `tip-latex-classify-fragment` (`\[...\]` / `\begin{eqn}` → display,
    `$...$` / `\(...\)` → inline, ~15 LOC)
  - Backend registration (~15 LOC, mirror of tip-typst)
  - `tip-latex-default-preamble` defcustom
  - Preamble refusal check for `\input` / `\include` with a single warning
    (v1 safety rail)

**Rust side — v1** (~500 LOC total):

- `tip-core-latex/`:
  - `compiler.rs`: build batch `.tex`, spawn `latex`, parse preview.sty
    stdout markers, spawn `dvisvgm`, parse its stdout, collect SVG paths
    and dimensions.
  - `metrics.rs`: translate tightpage sp values → pt, compute ascent.
- `tip-server-latex/`:
  - `main.rs`: stdio JSON-RPC loop.
  - `handler.rs`: protocol dispatch (shares shape with tip-server-typst).

**Dropped explicitly from digestif (and why)**:

| digestif feature            | why we skip                                  |
|-----------------------------|----------------------------------------------|
| `Parser.lua` LPeg combinators | overkill for our surface; regex + syntax-ppss + hand tokenizer are enough |
| Package tag DB (`data/*.lua`) | completion/hints, not preview                |
| `init_callbacks.label`/`section`/`bibitem` | not needed for math preview       |
| `NewDocumentCommand` (xparse) parsing | irrelevant — we pass preamble whole to `latex`; the compiler handles xparse |
| ConTeXt / BibTeX / Plain TeX Manuscripts | out of scope                     |
| `get_context` / local scope inference | preview.sty inherits the preamble via `\input`; no per-fragment scope logic needed |
| Snippets / pretty-printing | editor-assist concerns, not preview          |

## Open questions (the same three from before, sharpened)

1. **Include policy for v1**: refuse hard (no previews at all if `\input`
   found in preamble), or refuse soft (warn + preview only fragments that
   compile with the detected preamble)?
   Lean: soft refuse. Let the user see partial output; they'll notice
   what's missing.
2. **Rust tokenizer scope for v1**: ship it now (ready for v2) or defer
   until we actually do includes? Lean: defer. v1 server just receives
   ranges, no tokenizer needed.
3. **Preamble caching key**: use the raw preamble string's sha1 as the
   mylatexformat cache key? (Equal strings → same `.fmt`.) Lean: yes,
   simple and correct.

## Proposed build order

1. `tip-latex.el` — Feature 1 (math collector) + Feature 2 (preamble
   splitter) + Feature 3 (reuse filter) + backend registration. Tests that
   detect fragments in a buffer with comments and verbatim. No server yet.
2. `tip-server-latex` (Rust) — minimal batch compiler with preview.sty +
   dvisvgm. Protocol-only; no include resolution. E2E test: Emacs sends a
   buffer, gets back SVGs.
3. `mylatexformat` precompile — add preamble caching.
4. `\input` support — Feature 4, Rust-side TexProject. Emacs lifts the v1
   refusal warning.

Each step leaves a working system.
