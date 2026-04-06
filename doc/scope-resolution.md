# Scope Resolution in TIP: How a Math Fragment Sees Its World

## The Problem

In Typst, a math fragment like `$alpha + beta$` might appear anywhere in a document:

```typst
#import "@preview/cetz:0.4.2"

#let alpha = $a$
#set text(fill: blue)

#subtree(title: "Theorem")[
  #let beta = $b$
  
  We have $alpha + beta$    ← this fragment
]
```

To compile `$alpha + beta$` correctly, the compiler needs to see:
- The `#import` (for packages)
- The `#let alpha = $a$` (variable definition)
- The `#set text(fill: blue)` (style rule)
- The `#let beta = $b$` (scoped variable)
- The `[` content block that creates the scope for `beta`

But it must NOT include:
- The text "We have" (irrelevant content)
- The `#subtree(title: "Theorem")` function call (layout container)
- Any content after the fragment

The result is a **scope skeleton**: a minimal synthetic document that compiles exactly the fragment with its full scope context.

## The Key Function: `build_scoped_source`

Located in `tip-server/crates/tip-core/src/compiler.rs`, this function takes a full document and a fragment's byte range, and produces a compilable Typst source:

```
INPUT:  full document source + fragment position [start, end)
OUTPUT: synthetic source string ready for typst::compile
```

The generated source has this structure:

```
{DEFAULT_RENDERING_PREAMBLE}     ← bounded() for anti-clipping
{skeleton}                        ← scope-defining statements only
{client_preamble}                 ← colors from Emacs theme
{page_setup}                      ← page dimensions, text size
{fragment}                        ← the actual math: $alpha + beta$
{closers}                         ← } and ] to close skeleton blocks
```

## The Algorithm: `extract_scope_skeleton`

The skeleton extractor walks the Typst AST (parsed via `typst::syntax::parse`) and applies three rules to each node based on its position relative to the fragment:

### Case 1: Node entirely before the fragment

If the node is a **scope-defining statement**, include its full source text:
- `LetBinding` → `#let x = 1`
- `SetRule` → `#set text(fill: blue)`
- `ShowRule` → `#show math.equation: set text(size: 11pt)`
- `ModuleImport` → `#import "@preview/cetz:0.4.2"`
- `ModuleInclude` → `#include "header.typ"`

Everything else (text content, other math, function calls) is **silently dropped**.

A subtlety: the `#` prefix is a separate sibling node in the AST, not part of the statement. The code checks `source.as_bytes().get(offset - 1) == Some(&b'#')` to include it.

### Case 2: Node contains the fragment

This is where it gets interesting. The node's children are recursed into, but the node itself may or may not emit syntax:

- **Transparent containers** (`Markup`, `Code`): just recurse, emit nothing.
- **Code blocks** (`CodeBlock`): emit `{`, track `}` as a closer, recurse.
- **Content blocks** (`ContentBlock`): only emit `[` if the block contains scope-defining children. This prevents spurious brackets from non-scoping containers like `#list[content]`.
- **Everything else** (FuncCall, Args, Hash, etc.): strip the node entirely, recurse only into the child that contains the fragment.

This last rule is critical. For `#subtree(title: "Theorem")[$alpha + beta$]`:
- The `FuncCall` node for `subtree(...)` is stripped
- The `Args` node is stripped  
- The `ContentBlock` `[...]` is recursed into
- If the content block has scope children (like `#let beta`), it emits `[` and tracks `]`

### Case 3: Node at or after the fragment

Skip entirely. The fragment and everything after it is not part of the skeleton.

## Example Walkthrough

Given this document:

```typst
#import "./_lib/kodama.typ": kodama
#import "@preview/cetz:0.4.2"

#show: kodama

#let canvas(..args) = html.elem("div")[
  #html.frame(cetz.canvas(..args))
]

Text before.

#subtree(slug: "A3K0", title: "Theorem")[
  #let C = 42

  We prove $C > 0$    ← compile this
]
```

The skeleton for `$C > 0$`:

```typst
#import "./_lib/kodama.typ": kodama
#import "@preview/cetz:0.4.2"
#show: kodama
#let canvas(..args) = html.elem("div")[
  #html.frame(cetz.canvas(..args))
]
[
#let C = 42
```

And the closers: `]`

Notice:
- All imports preserved (they define scope)
- `#show: kodama` preserved (transforms the document)
- `#let canvas` preserved (even though it uses html — it's a scope-defining statement before the fragment)
- "Text before." dropped (not scope-defining)
- `#subtree(slug: "A3K0", ...)` stripped (it's a FuncCall container, not scope)
- The `[` from subtree's content block IS emitted (it contains `#let C`)
- `#let C = 42` preserved
- "We prove" dropped
- `]` is the closer

The final compiled source:

```typst
#let bounded(content) = text(top-edge: "bounds", bottom-edge: "bounds", content)
#import "./_lib/kodama.typ": kodama
#import "@preview/cetz:0.4.2"
#show: kodama
#let canvas(..args) = html.elem("div")[
  #html.frame(cetz.canvas(..args))
]
[
#let C = 42

#show math.equation: set text(rgb("#000000"))
#set page(fill: rgb("#ffffff"))
#show math.equation: set text(size: 11pt)
#set page(height: auto, width: auto, margin: (top: 20pt, bottom: 20pt, rest: 0pt), fill: none, header: none, footer: none)

$C > 0$
]
```

This is a valid, self-contained Typst document that compiles to a single page containing exactly the rendered `$C > 0$` with correct scope.

## Design Decisions and Their Rationale

### Why not just truncate the document?

The naive approach: take everything before the fragment and append it. This fails because:
1. It includes megabytes of irrelevant text content
2. Layout from that content affects the page (pushing the fragment to page 2+)
3. Other math fragments get compiled unnecessarily
4. Performance degrades linearly with document size

The skeleton approach: O(tree depth) walk, output is typically <1KB regardless of document size.

### Why track closers in the skeleton, not separately?

The original design used a separate `compute_closing_delimiters` function that walked the document tree to count unclosed blocks. This was **fundamentally broken** because Typst allows unpaired delimiters in math: `$[0, 1)$` has an unmatched `[` and `)`. The function couldn't distinguish skeleton-opened blocks from math content.

The fix: `collect_scope_nodes` tracks what it opens in a `closers` vec. When it emits `{`, it pushes `}`. When it emits `[`, it pushes `]`. The closers are reversed and joined. No guessing, no counting.

### Why strip FuncCall containers transparently?

Consider `#list[$a$][$b$]`. The `#list` call is a layout function — it produces a bullet list. If we included `#list(...)` in the skeleton, the math would be inside a list item, affecting rendering. By stripping the FuncCall and recursing into its children, we find the ContentBlock containing `$a$` and preserve only scope-defining statements within it.

### Why only emit `[` for scoped ContentBlocks?

A content block like `[hello world]` has no scope definitions — emitting `[...]` around the fragment would be pointless and could cause nesting issues. We only emit `[` when the block contains `LetBinding`, `SetRule`, `ShowRule`, `ModuleImport`, or `ModuleInclude` — i.e., when the block actually creates a scope that the fragment depends on.

## Performance

The skeleton extraction is the main per-fragment cost:
- Parse: `typst::syntax::parse(document_source)` — cached by comemo across fragments
- Walk: O(tree depth × branching at each level) — typically microseconds
- Output: small string, a few hundred bytes

For a 1000-fragment document, total skeleton extraction is <50ms. The compilation itself (via `typst::compile`) benefits from comemo caching: the skeleton is similar across fragments, so most intermediate results are cached.

## Files

| File | Function |
|------|----------|
| `tip-core/src/compiler.rs` | `build_scoped_source`, `extract_scope_skeleton`, `collect_scope_nodes` |
| `tip-server/src/handler.rs` | `handle_compile_fragments` calls `compile_fragment_scoped` |
| `tip.el` | `tip-send-region` sends fragment byte ranges to the server |
