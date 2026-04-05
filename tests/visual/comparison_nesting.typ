#set page(margin: 1.5cm)
#set text(size: 11pt)

= TIP Mode-Nesting Tests

Math→code→markup→math and deeper. Native (left) vs tip-server SVG (right).

#let row(label, native-content, svg-file, ht: 1.5em) = {
  (
    [*#label*],
    native-content,
    image(svg-file, height: ht),
  )
}

#let RR = math.bb("R")
#let ww = sym.omega
#let sumsq(x, y) = $#x^2 + #y^2$

#table(
  columns: (auto, 1fr, 1fr),
  inset: 8pt,
  align: (left, center, center),
  table.header([*Test*], [*Native*], [*tip-server SVG*]),

  ..row("math→text→math: a + b",
    $a + #text[$b$]$,
    "nest_math_text_math.svg"),

  ..row("3-level mode switch",
    $a + #[#let x = $b$; #x] + c$,
    "nest_deep_mode_switch.svg"),

  ..row("let in content block: ω+ω",
    $ww + ww$,
    "nest_let_in_content.svg"),

  ..row("let across modes: ℝ",
    $RR$,
    "nest_let_across_modes.svg"),

  ..row("show inside #{}: red a+b",
    text(fill: red, $a + b$),
    "nest_show_inside_block.svg"),

  ..row("func returning math: x²+y²",
    $sumsq(x, y)$,
    "nest_func_returning_math.svg"),

  ..row("styled box: blue bordered a+b",
    box(stroke: 1pt + blue, inset: 4pt, radius: 2pt, fill: blue.lighten(90%), $a + b$),
    "nest_math_in_box.svg",
    ht: 2em),

  ..row("set in content block: red a+b",
    text(fill: red, $a + b$),
    "nest_set_inside_content_block.svg"),
)
