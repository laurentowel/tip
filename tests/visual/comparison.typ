#set page(margin: 1.5cm)
#set text(size: 11pt)

= TIP Visual Comparison

Each row: *Native Typst* (left) vs *tip-server SVG* (right). They should look identical.

#let row(label, native-content, svg-file) = {
  (
    [*#label*],
    native-content,
    image(svg-file, height: 1.5em),
  )
}

== Scope-Aware Compilation

#let al = sym.alpha
#let cl = math.cal("L")
#let ff = math.cal("F")
#let gg = math.cal("G")
#let aa = sym.alpha
#let bb = sym.beta
#let cc = sym.gamma

#table(
  columns: (auto, 1fr, 1fr),
  inset: 8pt,
  align: (left, center, center),
  table.header([*Test*], [*Native*], [*tip-server SVG*]),

  ..row("top-level let: L(α)",
    $cl(al)$,
    "scope_top_level_let.svg"),

  ..row("block let: β+β",
    $bb + bb$,
    "scope_block_let.svg"),

  ..row("nested blocks: α+β+γ",
    $aa + bb + cc$,
    "scope_nested_blocks.svg"),

  ..row("set rule (blue): a+b",
    text(fill: blue, $a + b$),
    "scope_set_rule_color.svg"),

  ..row("multi frag 1: F",
    $ff$,
    "scope_multi_frag1.svg"),

  ..row("multi frag 2: G",
    $gg$,
    "scope_multi_frag2.svg"),

  ..row("multi frag 3: F∘G",
    $ff compose gg$,
    "scope_multi_frag3.svg"),
)

== Inline Math (standalone)

#table(
  columns: (auto, 1fr, 1fr),
  inset: 8pt,
  align: (left, center, center),
  table.header([*Test*], [*Native*], [*tip-server SVG*]),

  ..row("simple: a+b=c",
    $a + b = c$,
    "inline_simple.svg"),

  ..row("fraction: a/b",
    $frac(a, b)$,
    "inline_fraction.svg"),

  ..row("block sum",
    $ sum_(i=0)^n i^2 = frac(n(n+1)(2n+1), 6) $,
    "block_sum.svg"),
)
