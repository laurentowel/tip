#set page(margin: 1.2cm)
#set text(size: 10pt)

= TIP Import Resolution Comparison

All 3 import types: relative file, local package, remote package.
Native (left) vs tip-server SVG (right).

#let row(label, native-content, svg-file, ht: 1.5em) = {
  ([*#label*], native-content, image(svg-file, height: ht))
}

#import "../crates/tip-core/tests/fixtures/mystyle.typ": *
#import "@local/mmm:0.0.0": *

#table(
  columns: (auto, 1fr, 1fr),
  inset: 6pt,
  align: (left, center, center),
  table.header([*Test*], [*Native*], [*tip-server SVG*]),

  // Relative import (mystyle.typ)
  ..row("relative: H", $cH$, "3imp_0.svg"),
  ..row("relative: ℂ", $CC$, "3imp_1.svg"),
  ..row("relative: ℚ⊂ℝ⊂ℂ", $QQ subset RR subset CC$, "3imp_3.svg"),

  // Local package (@local/mmm)
  ..row("local: SL(2,ℤ)", $SL(2, ZZ)$, "3imp_4.svg"),
  ..row("local: spectral gap",
    $lambda(mu sc pi) leq sqrt(1 - p_0^2 kappa(mu sc pi)^2)$,
    "3imp_6.svg", ht: 2em),
  ..row("local: op norm",
    $norm(T)_("op") = sup_(norm(x) leq 1) norm(T x)$,
    "3imp_7.svg", ht: 1.8em),
  ..row("local: inner product",
    $iprod(u, v) = overline(iprod(v, u))$,
    "3imp_8.svg", ht: 1.8em),
  ..row("local: colored",
    $bluem(alpha) + greenm(beta) = orangem(gamma)$,
    "3imp_9.svg"),
  ..row("local: restriction",
    $res(f, K)$,
    "3imp_10.svg"),

  // Remote package (fletcher diagram nodes)
  ..row("remote: ℝⁿ node", $RR^n$, "3imp_13.svg"),
  ..row("remote: ℂᵐ node", $CC^m$, "3imp_16.svg"),
  ..row("remote: T_ℂ", $T_CC$, "3imp_18.svg"),

  // Mixed: all three in one equation
  ..row("mixed: π:SL→U(H)",
    $pi : SL(2, ZZ) to U(cH)$,
    "3imp_21.svg"),
  ..row("mixed: L-function (display)",
    $ cL(mu, pi) = -log norm(pi(mu))_("op") > 0 $,
    "3imp_23.svg", ht: 2em),
  ..row("mixed: Kazhdan bound (display)",
    $ lambda(mu_S sc pi) leq sqrt(1 - 1/abs(S)^2 kappa(S sc pi)^2) $,
    "3imp_27.svg", ht: 3em),
)
