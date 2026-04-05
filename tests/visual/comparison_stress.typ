#set page(margin: 1.5cm)
#set text(size: 11pt)

= TIP Stress Tests

Each row: *Native Typst* (left) vs *tip-server SVG* (right).

#let row(label, native-content, svg-file) = {
  (
    [*#label*],
    native-content,
    image(svg-file, height: 1.5em),
  )
}

#let xxouter = sym.alpha
#let xxinner = sym.beta
#let sq(x) = $x^2 + 1$
#let RR = math.bb("R")
#let dim = 3
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

  ..row("shadow: β (not α)",
    $xxinner$,
    "stress_shadow.svg"),

  ..row("closure: x²+1",
    $sq(x)$,
    "stress_closure.svg"),

  ..row("chained let: ℝ³",
    $RR^dim$,
    "stress_chained_let.svg"),

  ..row("show+set: red a+b",
    text(fill: red, style: "italic", $a + b$),
    "stress_show_set_combo.svg"),

  ..row("5-deep nest: 1+1+1+1+1",
    $1 + 1 + 1 + 1 + 1$,
    "stress_deep_nest.svg"),

  ..row("set override: 16pt a+b",
    text(size: 16pt, $a + b$),
    "stress_set_overrides.svg"),

  ..row("content block: ω",
    $omega$,
    "stress_content_block.svg"),

  ..row("after for loop: x",
    $x$,
    "stress_for_scope.svg"),

  ..row("5 bold lets: A·B·C·D·E",
    $AA dot BB dot CC dot DD dot EE$,
    "stress_multi_import_let.svg"),

  ..row("show rule: boxed a=b",
    box(stroke: 0.5pt + blue, inset: 3pt, $a = b$),
    "stress_equation_numbering.svg"),
)
