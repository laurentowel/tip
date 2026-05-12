# External corpus

Single-file Typst documents from the wild, used by `tests/external_corpus.rs`
as a smoke-test that the bottom-up compile path doesn't choke on
documents written in styles other than the maintainer's own.

Each `<name>.typ` is paired with `<name>.LICENSE` recording the
upstream license (CC-BY-SA-4.0 / MIT etc.).

## Sources

- **`undergradmath.typ`** — Typst port of Jim Hefferon's *undergradmath*
  math reference.  ~1080 lines, almost entirely math content (inline,
  display, accents, big operators, matrices, sub/super-script towers).
  Source: <https://github.com/johanvx/typst-undergradmath>,
  CC-BY-SA-4.0.

- **`cheat-sheet.typ`** — mewmew's Typst cheat sheet.  ~460 lines,
  mixed text + math + lists + tables + headings.  Source:
  <https://github.com/mewmew/typst-cheat-sheet>, MIT.

## Adding new docs

Single-file (or self-contained) `.typ` only — no local sibling
`#import` files.  `@preview/...` package imports work but require
network on first run, so prefer pure-standalone docs.  Drop the file
in this directory and copy the upstream LICENSE alongside; the
integration test picks it up automatically.
