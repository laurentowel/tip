#set page(margin: 1.5cm)
#set text(size: 11pt)

= TIP Insane Scope Tests

Native (left) vs tip-server SVG (right).

#let row(label, native-content, svg-file, ht: 1.5em) = {
  (
    [*#label*],
    native-content,
    image(svg-file, height: ht),
  )
}

// Definitions for native column
#let oplus = sym.plus.o
#let aa = sym.alpha
#let bb = sym.beta
#let cc = sym.gamma
#let dd = sym.delta
#let ee = sym.epsilon
#let zz = sym.zeta
#let hh = sym.eta
#let tt = sym.theta
#let ii = sym.iota
#let kk = sym.kappa
#let RR = math.bb("R")
#let dim = 3
#let fold(..args) = {
  let items = args.pos()
  let result = items.first()
  for item in items.slice(1) {
    result = $( #result oplus #item )$
  }
  result
}
#let eye = math.mat(
  (1, 0),
  (0, 1),
)
#let val = sym.infinity
#let AA = math.bold("A")
#let BB = math.bold("B")
#let CC = math.bold("C")
#let DD = math.bold("D")
#let EE = math.bold("E")

#table(
  columns: (auto, 1fr, 1fr),
  inset: 8pt,
  align: (left, center, center),
  table.header([*Test*], [*Native*], [*tip-server SVG*]),

  ..row("recursive fold: (((α⊕β)⊕γ)⊕δ)",
    $#fold(aa, bb, cc, dd)$,
    "insane_recursive_op.svg"),

  ..row("show rewrite: red underlined a+b",
    text(fill: red, underline($a + b$)),
    "insane_show_rewrite.svg"),

  ..row("matrix let: 2×2 identity",
    $eye$,
    "insane_matrix_let.svg",
    ht: 2.5em),

  ..row("4× shadow chain: δ",
    $dd$,
    "insane_shadow_chain.svg"),

  ..row("set cascade: large blue a+b",
    text(fill: blue, size: 20pt, $a + b$),
    "insane_set_cascade.svg",
    ht: 2em),

  ..row("conditional let: ∞",
    $val$,
    "insane_conditional_let.svg"),

  ..row("10 greek lets: αβγδεζηθικ",
    $aa bb cc dd ee zz hh tt ii kk$,
    "insane_greek_soup.svg"),

  ..row("operator override: a⊕b",
    $a oplus b$,
    "insane_operator_override.svg"),
)
