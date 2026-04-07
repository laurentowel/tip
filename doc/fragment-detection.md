# Fragment Detection: What Gets Previewed

## Overview

TIP must decide which regions of the buffer are previewable math or diagram fragments. This sounds simple — "find all `$...$`" — but in practice involves five layers of filtering, each solving a real problem discovered during development.

## The Pipeline

```
tree-sitter query: all (math) nodes
    │
    ├─ Filter: skip empty ($$ and $ $)
    ├─ Filter: skip math inside #let bindings
    ├─ Filter: skip nested math (keep outermost)
    │
    ├─ Tree walk: find diagram calls (cetz.canvas, diagram, etc.)
    │   └─ Filter: skip diagram calls inside #let bindings
    │
    └─ Merge → deduplicate → convert to byte offsets → send to server
```

Two distinct detection paths feed into one unified pipeline:

1. **`tip-collect-fragment-locations`** — batch: collects all fragments in a region, used by `tip-render-all`, `tip-send-nbd`
2. **`tip--get-bounds-of-math-at-point`** — point: finds the fragment at a specific position, used by preview-toggle and live preview

## Layer 1: Tree-sitter Math Query

```elisp
(treesit-query-range 'typst "((math) @math)")
```

Returns ALL `(math)` nodes in the buffer — including nested ones, empty ones, and ones inside definitions. This is the raw input that the filters refine.

## Layer 2: Empty Math Filtering

```typst
$$        ← 2 chars, skipped (length check)
$ $       ← whitespace only, skipped (string-blank-p)
$
  
$         ← multi-line whitespace, also skipped
```

Empty math produces nothing useful from the server and wastes a compile cycle. The check: `(> (- end beg) 2)` and `(not (string-blank-p inner))`.

## Layer 3: Let Binding Filtering

```typst
#let score(i) = $op("score")(x_(#i), p)$    ← SKIPPED
$score(1) = score(2)$                         ← compiled
```

Math inside `#let` RHS is a function definition, not rendered document content. Compiling it would produce a fragment from a template — wrong and confusing.

Detection: `tip--inside-let-binding-p` walks tree-sitter parents looking for a `let` ancestor node. Applied to both math ranges and diagram calls.

This also prevents preview-toggle from triggering open/close when the cursor moves through math inside `#let` bodies — `tip--get-bounds-of-math-at-point` returns nil for these.

**Performance**: 0.002ms per check (tree-sitter parent walk). Negligible even for 1000 fragments.

## Layer 4: Nesting Deduplication

```typst
$a + #text[$b$]$
```

Tree-sitter returns TWO math nodes: the outer `$a + #text[$b$]$` and the inner `$b$`. TIP keeps only the **outermost** for overlay compilation:

```elisp
(unless (cl-some (lambda (o)
                   (and (not (equal o r))
                        (<= (car o) (car r))
                        (>= (cdr o) (cdr r))))
                 ranges)
  (push r outer))
```

Any range fully contained within another is dropped.

### Why outermost for overlays, innermost for live preview

The overlay system (`tip-collect-fragment-locations`) compiles outermost fragments because:
- The overlay must span the entire visible `$...$` region
- Inner math is part of the outer fragment's content — the server compiles it as part of the whole expression

But `tip--get-bounds-of-math-at-point` (used by live preview and preview-toggle) finds the **innermost** math at point. When the cursor is inside `$b$` within `$a + #text[$b$]$`:
- The **overlay** shows the full `a + b` expression (outermost)
- The **live preview childframe** shows just `b` (innermost, the thing you're currently editing)

This is a feature, not a bug — the live preview shows what you're typing right now, while the overlay shows the complete expression.

## Layer 5: Diagram Detection

Math fragments are found by tree-sitter query. Diagrams are found by a recursive tree walk because they're function calls, not a distinct grammar node:

```elisp
(defun tip--collect-diagram-ranges (node beg end avoid-pos)
  ;; Walk tree, check each 'call' node against tip-diagram-functions
  ;; Skip calls inside #let bindings
  ...)
```

Recognized function names (customizable via `tip-diagram-functions`):
- `cetz.canvas`, `canvas` — CeTZ diagrams
- `diagram`, `fletcher.diagram` — Fletcher diagrams
- `comm-diag` — commutative diagrams

### The `#` prefix problem

In tree-sitter, `#cetz.canvas(...)` has `#` as a sibling of the `call` node, not a child:

```
(hash)                 ← sibling
(call "cetz.canvas")   ← sibling
```

When cursor is on `#`, walking up from the hash token never reaches `call`. Fix: if the tree walk fails and `char-after` is `#`, retry at position+1 to find the sibling call.

The overlay spans from `#` to the end of the call: `(cons (1- node-start) node-end)`.

### Wrapper definitions skipped

```typst
#let canvas(..args) = html.elem("div")[#html.frame(cetz.canvas(..args))]

#canvas(length: 1cm, { ... })   ← this IS previewed
```

The `#let` body contains `cetz.canvas(..args)` which matches `tip-diagram-functions`. Without filtering, it would be detected as a fragment. `tip--inside-let-binding-p` prevents this.

The wrapper call `#canvas(...)` IS detected because `canvas` is in the function list and it's not inside a `#let` body.

## HTML-Targeting Documents

Files targeting HTML export (kodama) use `html.elem`, `html.frame` which are no-ops in paged mode. The wrapper pattern:

```typst
#let canvas(..args) = html.elem("div")[cetz.canvas(..args)]
```

produces empty SVGs (0 width, 40pt height). These are filtered by the height check:

```elisp
(> height-pt 0.01)
```

## Text Size Override (PDF-targeting)

For PDF-targeting documents, the server enforces `#show math.equation: set text(size: 11pt)` so all fragments render at the same size regardless of the document's own font settings. This is skipped for HTML-targeting documents because Typst forbids setting text size in html export mode. Detection: the scope skeleton is checked for `html.elem`/`html.frame`/`html.figure`.

## The Two Detection Functions

### `tip-collect-fragment-locations` (batch)

Used by: `tip-render-all`, `tip-send-nbd`, `tip-send-region`

```
Input: region (BEG, END), optional AVOID-POS
Output: list of (("start" . byte) ("end" . byte)) alists

Steps:
1. treesit-query-range → all math ranges
2. Filter: in-region, non-empty, not-in-let, not-at-avoid-pos
3. Tree walk → all diagram ranges (same filters)
4. Merge, deduplicate (outermost only)
5. Convert positions to 0-indexed byte offsets
```

### `tip--get-bounds-of-math-at-point` (point)

Used by: preview-toggle (inside-p, close-at-marker), live preview

```
Input: position X
Output: (BEG . END) or nil

Steps:
1. treesit-node-at X → leaf node
2. Walk up to first "math" ancestor
3. Check: BEG <= X < END (half-open), not in #let
4. If no math: walk up looking for diagram call
5. If at #: retry at X+1 for sibling call
6. Check: BEG <= X < END, not in #let
```

This is O(tree depth), not O(buffer). Runs on every `pre-command-hook` and `post-command-hook` — must be fast.

## Files

| File | Function | Role |
|------|----------|------|
| `tip.el` | `tip-collect-fragment-locations` | Batch collection |
| `tip.el` | `tip--get-bounds-of-math-at-point` | Point detection |
| `tip.el` | `tip--inside-let-binding-p` | Let binding check |
| `tip.el` | `tip--diagram-node-p` | Diagram call check |
| `tip.el` | `tip--collect-diagram-ranges` | Recursive diagram walk |
| `tip.el` | `tip-diagram-functions` | Customizable function name list |
