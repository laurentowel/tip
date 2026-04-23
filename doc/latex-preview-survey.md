# LaTeX preview design survey

A reverse-engineering of AUCTeX's `preview-latex` (hereafter **preview.el**) and
tec's fork of `org-latex-preview` (hereafter **OLP**), to inform `tip-latex.el`.

Sources:
- `.ref/auctex-ref/preview.el` (4723 lines, mature, ~2001–present)
- `.ref/auctex-ref/latex/preview.dtx` (the `preview.sty` package itself)
- `.ref/org-mode-ref/lisp/org-latex-preview.el` (3354 lines, 2023 rewrite by
  Karthik Chikmagalur, further iteration by TEC)

Both share one foundational trick: **the `preview.sty` package**. Everything
else is variation on "how do we get a bounding box + SVG out of TeX fastest."

---

## The common foundation: `preview.sty`

`preview.sty` is an AUCTeX-shipped LaTeX package with one job: **typeset each
previewable thing onto its own tightly-bounded page** and emit `\special`
messages in the log describing each snippet's bounding box + baseline.

With `\usepackage[active,tightpage,auctex]{preview}` the compiler:
1. Suppresses all normal document output (pages, running heads, etc.).
2. Wraps every `\begin{preview}...\end{preview}` block (or any environment
   listed in the option set — `displaymath`, `textmath`, `floats`, `graphics`,
   `sections`, `footnotes`) into a "snippet" that gets its own tight-bounded
   single-page output.
3. Writes messages to the terminal/log like:
   ```
   ! Preview: Snippet 1 started.
   <-><->
   l.42 $E = mc^2$
   ...
   Preview: Tightpage -32891 -32891 32891 32891
   ! Preview: Snippet 1 ended.(392832+181502x1256832)
   ```
   `(height+depth×width)` in scaled points (sp, 65536 per pt). `tightpage`
   reports the four margin offsets separately.
4. Exits with code 1 (expected — `preview` raises a fake error per snippet to
   force a page break). Both preview.el and OLP treat exit 1 as success.

**Output format**: DVI by default. Every host-side renderer reads the DVI
(faster) or the log (for metrics) to get baseline + bbox, then runs
`dvisvgm`/`dvipng`/`gs` to rasterize.

This is the single most important piece to reuse. Don't roll our own.

---

## preview.el (AUCTeX) — design

**Flow** (`preview-region`/`preview-buffer`/`preview-document`):
1. Write the region (or master file) out via AUCTeX's `TeX-region-create`.
   AUCTeX knows the master file, handles includes, sets `TEXINPUTS`.
2. Invoke `latex` (or `pdftex`) with `preview.sty` options bolted on via
   `preview-LaTeX-command` (default starts with `` \nonstopmode\nofiles
   \PassOptionsToPackage{active,tightpage,auctex}{preview}\input ``).
3. Parse the log asynchronously in a sentinel/filter: `preview-parse-messages`
   walks snippet start/end/tightpage markers, extracts bbox+baseline, records
   per-snippet buffer positions (using `!offset(N)` and `!name(file)` messages
   AUCTeX injects into the region file).
4. Pass DVI + snippet list to a rendering backend.

**Rendering backends** (pluggable via `preview-image-creators`):

| backend       | pipeline                          | notes                                         |
|---------------|-----------------------------------|-----------------------------------------------|
| `dvipng`      | dvi → png                         | fastest, native depth detection               |
| `dvisvgm`     | dvi → svg                         | crisp; added later                            |
| `png` (gs)    | dvi → dvips → ps → gs → png       | historical default; persistent `gs` process   |
| `pdf2dsc+gs`  | pdf → pdf2dsc → gs → png          | for `pdflatex`                                |
| `tiff`/`jpeg` | similar                           | rare                                          |

The ghostscript path keeps a **persistent `gs` subprocess** (`preview-gs-open`)
that serves page requests on demand. Pages are rendered lazily when the
overlay becomes visible. Preview.el invented this for perf; the idea later
inspired org-latex-preview's async placement.

**Format-file precompile**: `preview-cache-preamble` dumps the preamble into
a `.fmt` file via `-ini`/`mylatexformat` once, subsequent compiles load the
format and skip preamble parsing entirely. 5–10× speedup on large preambles
(TikZ, chemfig, etc.).

**Overlays**:
- One overlay per snippet, toggled open/closed by cursor position.
  `preview-visibility-style 'off-point` (default) hides preview when point
  is inside, shows otherwise — the same UX our `preview-toggle.el` provides.
- `preview-ascent-from-bb` derives Emacs `:ascent` from the bbox origin.
- Colors baked into the SVG/PNG from `preview-get-colors` at compile time.
  No live recolor — a theme change requires rebuild.

**Coupling to AUCTeX** is deep: uses `TeX-master-file`, `TeX-current-offset`,
`TeX-region-create`, `LaTeX-current-environment`, and many buffer-local TeX
state vars. Not easy to lift out.

---

## org-latex-preview.el (TEC) — design

A 2023 rewrite that keeps the `preview.sty` foundation but modernizes
essentially everything else.

**Flow** (`org-latex-preview-place`):
1. Collect fragments by regex + `org-element-context` on each hit; filter out
   nested fragments.
2. Build preamble (`org-latex-preview--get-preamble`) from the buffer's
   `#+LATEX_HEADER` lines + `org-latex-default-packages-alist`.
3. Optionally `mylatexformat`-precompile it (`--precompile`). The `.fmt` path
   is cached.
4. Write a single `.tex` with `\documentclass{article}` + header +
   `\begin{document}` + one `\begin{preview}...\end{preview}` per fragment.
5. Compile async via `org-async-call`; **process filters parse stdout in
   real time**. Each time `preview-parse-messages`-style markers yield
   another snippet's metrics, AND `dvisvgm`'s "output written to X.svg"
   matches → place that fragment's overlay immediately. User sees
   progressively-filling previews rather than waiting for the whole batch.
6. dvisvgm invocation: `dvisvgm --page=1- --optimize --clipjoin --relative
   --no-fonts --bbox=preview -o %B-%%9p.svg %f`. Key flags:
   - `--no-fonts` — SVG uses glyph path outlines, not font refs.
     Portable, no fonts needed at render time. (This is what we do too.)
   - `--bbox=preview` — trust preview.sty's tightpage computation exactly.
   - `--clipjoin` + `--optimize` — SVG size reduction.

**Caching** (`--cache-image` / `--get-cached`):
- Key = `sha1(processing-type + preamble + fragment-text + imagetype + fg + bg [+ number])`.
- Store: `persist.el`-backed cache in `user-emacs-directory`.
- Expiry: 7 days default (`org-latex-preview-persist-expiry`).
- **Cached before compile** — if all fragments hit cache, no TeX at all.

**Color handling** (`--tex-styled` / `--colors-around`):
- Fragment string is wrapped with `\color[rgb]{...}` and (optional)
  `\pagecolor[rgb]{...}` derived from buffer face attributes at point.
- On **dvisvgm ≥ 3.2**, emits `\special{dvisvgm:currentcolor on}` which
  makes the SVG use `currentColor` for the foreground. Post-compile theme
  change becomes CSS recolor (fast, no recompile).
- On older dvisvgm, colors are baked in → theme change forces rebuild.

**Live preview**: `org-latex-preview-mode-display-live` runs a throttled +
debounced compile of the fragment at point, shows in eldoc or overlay.
Duration-based throttle adjusts to actual LaTeX compile time
(`live--update-times`).

**Equation numbering**: counts `equation`/`align` environments from buffer
start, emits `\setcounter{equation}{N-1}` per fragment so numbers line up
with the real document.

**Multiple engines**: `org-latex-preview-process-alist` is a plist registry
of engine configs — `(pdflatex → dvipng)`, `(latex → dvisvgm)`,
`(pdflatex → imagemagick)`. Each specifies `:latex-compiler`,
`:image-converter`, `:image-input-type`. Well-factored; easy to add a new
one.

---

## Comparison matrix

| topic                      | preview.el                                 | org-latex-preview.el                                    |
|----------------------------|--------------------------------------------|---------------------------------------------------------|
| fragment detection         | AUCTeX `LaTeX-current-environment` etc.    | regex + org-element-context                             |
| batch strategy             | one compile per region/document            | one compile per batch; all cached fragments skipped     |
| placement timing           | after full compile + render                | **streaming** — place each fragment as its SVG lands    |
| includes / multi-file      | `TeX-master-file` + `TEXINPUTS`            | single file; relative `\input` checked but not resolved |
| preamble precompile        | `preview-cache-preamble` (`.fmt` dump)     | `mylatexformat` (`.fmt` dump)                           |
| caching                    | none — always rebuild                      | persistent sha1 key cache, 7-day expiry                 |
| dvi→svg                    | supported backend (`dvisvgm`)              | **default**; `--no-fonts` + `--bbox=preview`            |
| dvi→png                    | dvipng or dvips+gs (persistent gs proc)    | dvipng or imagemagick                                   |
| color                      | baked in, no live update                   | `currentColor` via dvisvgm 3.2+; CSS recolor            |
| overlay toggle             | `preview-visibility-style 'off-point`      | `org-latex-preview-auto-mode` (similar)                 |
| async                      | sentinel/filter pattern                    | `org-async-call`, filters place as they go              |
| live preview at point      | no                                         | yes (`org-latex-preview-live-mode`)                     |
| equation numbering         | `preview-preserve-counters` (off by def.)  | yes, buffer-wide counting                               |
| error reporting            | parsed from `.log`; mouse-clickable        | per-snippet `:errors` plist                             |
| engine pluggability        | `preview-image-creators`                   | `process-alist`                                         |

---

## Includes: the nasty part

User called this out specifically — worth its own section.

### preview.el's approach

AUCTeX already solves multi-file projects for compilation, so preview.el
piggybacks:

1. **Master file convention.** Every buffer has a `TeX-master-file`, either
   auto-detected (`%&` line, local vars, per-project config) or prompted.
   When you hit `C-c C-p C-b`, preview.el compiles the *master*, not the
   current file.
2. **Region writing.** `TeX-region-create` writes the region to
   `_region_.tex` **in the master's directory** and copies enough preamble
   context (inherited from the master) that `\input{chapters/intro}` works
   exactly as in the real build.
3. **TEXINPUTS.** `preview-set-texinputs` prepends the AUCTeX style dir to
   `TEXINPUTS` in `process-environment`. If the user has a `latexmkrc`-style
   setup with custom paths, AUCTeX's master-file config carries those.
4. **Known failure modes.** If the user's master uses `\graphicspath{...}`
   with relative paths the region file won't find images. AUCTeX has no fix;
   users edit the actual master to compile region-with-images.

### OLP's approach

Org is essentially single-file (includes via `#+INCLUDE`, rarely with
cross-cutting LaTeX preamble). So OLP largely sidesteps the problem:

1. Treats the current buffer as self-contained.
2. Builds the temp `.tex` in `temporary-file-directory`, **not** beside the
   source file. Means relative `\input{../lib/macros}` from the header fails.
3. Detects this case (`relative-file-p`): if the preamble contains
   `\input{non/absolute/path}` AND we're editing a **remote** file, it errors
   out. For local files it goes ahead anyway and relies on the `default-directory`
   being right at compile time — which works only if `default-directory` equals
   the real project root.
4. No `TEXINPUTS` handling. If the project uses a styles subdirectory for
   custom `.sty`s, OLP won't find them unless they're on the system TeX path.

### The actual difficulty

LaTeX's include semantics are a nightmare surface:
- `\input{file}`, `\include{file}`, `\includegraphics{file}`,
  `\usepackage{style}`, `\RequirePackage`, `\bibliography{...}`,
  `\addbibresource{...}`, `\lstinputlisting{...}`, `\subfile{...}`,
  `\import{dir}{file}` (from the `import` package)...
- Resolution order: CWD → `TEXINPUTS` → `kpsewhich` database → TeX Live/MiKTeX
  tree. Different behavior for `\input` (kpsewhich-searched) vs
  `\includegraphics` (graphicspath + CWD + TEXINPUTS).
- Subfiles (`subfiles` package) want each child to be independently
  compilable with a `\documentclass[...]{subfiles}` pointing back at the
  parent.
- Shared preambles via `\input{preamble}` from a sibling dir — the most
  common real-world case.

### What this means for tip-latex

Three realistic positions:

**(A) Single-file only.** Refuse to preview anything whose preamble contains
`\input` or `\include`. Works for Org-style usage and short notes. Matches
OLP's effective behavior. **Simplest, and probably the right v1.**

**(B) "Project root" marker + CWD.** Walk up looking for `latexmkrc`,
`.latexmk`, `main.tex`, `.git`, etc. Compile the temp `.tex` in that
directory, so relative `\input` and `\graphicspath` work. Don't touch
`TEXINPUTS`. Covers ~70% of real projects where the only multi-file use is
a shared preamble or includegraphics. **Probably the right v2.**

**(C) AUCTeX-style master + TEXINPUTS.** Copy preview.el's full model. Ask
the user for the master file (or auto-detect), inherit its
`default-directory` + `TEXINPUTS` state. Powerful but requires AUCTeX or
re-implementing its master-file detection. **Too much for the initial scope.**

Note: our Rust server naturally helps here — the server runs with whatever
`default-directory` Emacs sends via the `uri` field, same as the Typst
backend already does. So "change CWD" is a protocol-level free lunch; the
hard part is deciding *which* directory.

---

## What tip-latex should steal

Ranked by leverage per engineering cost:

1. **`preview.sty` with `active,tightpage`.** Non-negotiable. It's the only
   sane way to get exact baselines + tight crops from LaTeX. ~2 lines of
   preamble.
2. **`dvisvgm --no-fonts --bbox=preview`.** Matches our "render SVG, display
   as overlay" pipeline perfectly. `--no-fonts` means no font installation
   needed at render time — fragments are portable.
3. **Batched multi-fragment compile.** One TeX invocation per batch, one
   dvisvgm invocation for all pages. Amortizes the ~200ms TeX startup cost
   across N fragments. OLP's default.
4. **`mylatexformat` precompile.** After the first compile of a buffer,
   subsequent batches skip preamble parsing. 5–10× speedup on heavy
   preambles. Cache the `.fmt` path per-preamble-hash.
5. **Streaming placement via stdout filter.** While TeX and dvisvgm run,
   parse their output live and place each fragment as soon as its SVG
   lands. Better UX than waiting for the whole batch to finish.
6. **Persistent sha1 cache.** Cache key = hash of preamble + fragment +
   color. Before compiling, skip anything already cached. Dramatic on
   re-open of a buffer with many unchanged fragments.
7. **`currentColor` SVG (dvisvgm 3.2+).** Emit the LaTeX special, get
   SVG that recolors via CSS — our existing `tip--recolor-overlays` works
   out of the box.
8. **Equation numbering.** `\setcounter{equation}{N-1}` per fragment,
   computed by counting `equation`/`align` envs before it. OLP does this,
   preview.el only via `preview-preserve-counters`.

What **not** to steal:
- preview.el's persistent `gs` subprocess. Ghostscript is heavy and
  its render quality is worse than dvisvgm. Skip.
- preview.el's DVI-specials parsing for baseline. We have preview.sty's
  log-based Tightpage + dvisvgm's `--bbox=preview` — no need to parse DVI
  directly.
- AUCTeX master-file machinery. See the includes discussion above;
  defer to v2+.

---

## Proposed tip-latex architecture

```
tip-latex.el (emacs)                 tip-server-latex (rust binary)
────────────────                     ─────────────────────────────
collect fragments                    on `compile_fragments`:
  regex: \(...\), \[...\],             for each fragment: hash
  $..$, $$..$$, \begin{equation}…      check persistent cache (sha1)
                                       build batch .tex:
bounds-at-point                          preamble + \usepackage[…]{preview}
  same regex                             one \begin{preview}...\end{preview}
                                         per cache-miss fragment
build-preamble                         if preamble changed, run
  read \usepackage lines from            mylatexformat precompile → .fmt
  buffer + optional user override      spawn `latex -fmt=X ...`
                                       stream stdout to parser (snippet marks,
classify-fragment                        tightpage bbox per snippet)
  \[...\] / \begin{display} → display  spawn `dvisvgm --page=1- --no-fonts …`
  \(...\) / $...$         → inline     stream stdout to parser (page → svg path)
  (no block for v1 —                   for each fragment: read svg, resolve
   figures deferred until we           currentColor, emit {svg, h_pt, d_pt, w_pt}
   figure out the scope story)         cache result
                                       return all fragments in one response
server-executable
  "tip-server-latex"
```

Dispatch is already in place: `tip-latex.el` registers a `tip-backend` with
`:major-modes '(latex-mode LaTeX-mode)` and the five hook functions. No
changes needed to tip-render, tip-live, tip-server-proc, or tip.el.

The Rust server reuses **tip-protocol** and **tip-svg-post** (once the latter
exists — see Rust workspace plan in CLAUDE.md). The LaTeX-specific crate is
much thinner than the Typst one: no embedded compiler, just subprocess
orchestration + log parsing + svg stitching. ~400–600 Rust LOC estimate.

---

## Open questions to resolve before coding

1. **Engine default**: plain `latex` (DVI) or `pdflatex` + `pdf2svg`? My
   lean: `latex` + dvisvgm. User override via a defcustom.
2. **Include policy for v1**: refuse, or try-and-hope? My lean: refuse
   (warn the user that includes aren't supported, require project-root
   setup for v2).
3. **Preamble source**: auto-extract from buffer's `\usepackage` /
   `\newcommand` lines, or require explicit `tip-latex-preamble`
   defcustom? OLP auto-extracts (works well for notes). preview.el relies
   on AUCTeX master. My lean: auto-extract with an override.
4. **Project root detection**: `latexmkrc`, `.latexmk`, `main.tex`, `.git`
   — same cascade as typst's `typst.toml`/`Kodama.toml`/`.git`? Yes.
5. **AUCTeX compatibility**: use AUCTeX's master-file machinery when
   AUCTeX is loaded, fall back to our own detection otherwise? Nice to
   have, not blocking.
6. **`currentColor` baseline**: require dvisvgm ≥ 3.2 for theme-change
   without recompile, or fall back to rebuild on theme change? My lean:
   require 3.2 for the `tip-follow-theme-mode` fast path; emit a
   one-time message if older.

None of these block writing `tip-latex.el` — they're knobs to decide
once the basics work.
