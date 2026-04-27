#set page(margin: 1.2cm)
#set text(size: 10pt)

= TIP Comprehensive Visual Comparison

Native Typst (left) vs tip-server SVG (right). They should match.

#let row(label, native-content, svg-file, ht: 1.5em) = {
  ([*#label*], native-content, image(svg-file, height: ht))
}

#let tbl(..rows) = table(
  columns: (auto, 1fr, 1fr),
  inset: 6pt,
  align: (left, center, center),
  table.header([*Test*], [*Native*], [*tip-server SVG*]),
  ..rows.pos().flatten(),
)

// --- Definitions for native column ---
#let RR = math.bb("R")
#let CC = math.bb("C")
#let ZZ = math.bb("Z")
#let ff = math.cal("F")
#let gg = math.cal("G")
#let cl = math.cal("L")
#let al = sym.alpha
#let bb = sym.beta
#let cc = sym.gamma
#let dd = sym.delta
#let oplus = sym.plus.o
#let norm(x) = $lr(|| #x ||)$
#let eye = math.mat((1, 0), (0, 1))
#let fold(..args) = {
  let items = args.pos()
  let result = items.first()
  for item in items.slice(1) { result = $( #result oplus #item )$ }
  result
}
#let AA = math.bold("A")
#let BB = math.bold("B")
#let CC2 = math.bold("C")
#let DD = math.bold("D")
#let EE = math.bold("E")

== Basic Rendering

#tbl(
  row("inline: a+b=c", $a + b = c$, "inline_simple.svg"),
  row("fraction: a/b", $frac(a, b)$, "inline_fraction.svg"),
  row("block sum", $ sum_(i=0)^n i^2 = frac(n(n+1)(2n+1), 6) $, "block_sum.svg", ht: 2.5em),
)

== Scope: Let Bindings & Rules

#tbl(
  row("top-level let: L(α)", $cl(al)$, "scope_top_level_let.svg"),
  row("block let: β+β", $bb + bb$, "scope_block_let.svg"),
  row("nested 3 levels: α+β+γ", $al + bb + cc$, "scope_nested_blocks.svg"),
  row("set rule (blue)", text(fill: blue, $a + b$), "scope_set_rule_color.svg"),
  row("multi frag: F∘G", $ff compose gg$, "scope_multi_frag3.svg"),
)

== Imports

#tbl(
  row("wildcard import: ℝ³", $RR^3$, "import_wildcard.svg"),
  row("named import: ℝ×ℂ", $RR times CC$, "import_named.svg"),
  row("renamed import: ℝ", $RR$, "import_renamed.svg"),
  row("imported func: ‖x‖", $norm(x)$, "import_function.svg"),
  row("multi-file: ℝ⊗ℤ", $RR times.o ZZ$, "import_multi_file.svg"),
  row("import+let: ℝⁿ", $RR^"n"$, "import_with_let.svg"),
)

== Inline vs Display Style

#tbl(
  row("inline sum: limits beside", $sum_(i=0)^n i$, "style_inline_sum.svg"),
  row("display sum: limits above/below", $ sum_(i=0)^n i $, "style_display_sum.svg", ht: 3em),
  row("inline frac: compact", $frac(a,b)$, "style_inline_frac.svg"),
  row("display frac: full-size", $ frac(a,b) $, "style_display_frac.svg", ht: 2.5em),
  row("inline integral", $integral_0^1 f(x) dif x$, "style_inline_integral.svg"),
  row("display integral", $ integral_0^1 f(x) dif x $, "style_display_integral.svg", ht: 3em),
)

== Mode Nesting (math→code→markup→math)

#let sumsq(x, y) = $#x^2 + #y^2$

#tbl(
  row("math→text→math", $a + #text[$b$]$, "nest_math_text_math.svg"),
  row("func returning math", $sumsq(x, y)$, "nest_func_returning_math.svg"),
  row("styled box", box(stroke: 1pt + blue, inset: 4pt, radius: 2pt, fill: blue.lighten(90%), $a + b$), "nest_math_in_box.svg", ht: 2em),
  row("show in block: red", text(fill: red, $a + b$), "nest_show_inside_block.svg"),
)

== Stress: Shadowing, Closures, Cascades

#tbl(
  row("4× shadow: δ", $dd$, "insane_shadow_chain.svg"),
  row("recursive fold", $#fold(al, bb, cc, dd)$, "insane_recursive_op.svg"),
  row("matrix let", $eye$, "insane_matrix_let.svg", ht: 2.5em),
  row("conditional let: ∞", $infinity$, "insane_conditional_let.svg"),
  row("5 bold lets", $AA dot BB dot CC2 dot DD dot EE$, "stress_multi_import_let.svg"),
  row("operator override: a⊕b", $a oplus b$, "insane_operator_override.svg"),
  row("set cascade: large blue", text(fill: blue, size: 20pt, $a + b$), "insane_set_cascade.svg", ht: 2em),
  row("show rewrite: red underline", text(fill: red, underline($a + b$)), "insane_show_rewrite.svg"),
  row("10 greek soup", $al bb cc dd epsilon zeta eta theta iota kappa$, "insane_greek_soup.svg"),
)
