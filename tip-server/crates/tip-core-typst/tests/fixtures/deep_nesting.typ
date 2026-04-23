#let bb = sym.beta
#let gg = sym.gamma
#let RR = math.bb("R")

= Deep Nesting Stress Test

Top level $a + b$ and $RR^3$.

== Lists

#list[
  First item $alpha + bb$ here
][
  Second $gg^2$ item $x + y$
][
  Third with display $ sum_(i=0)^n i $
]

== Nested lists

#list[
  Outer $a$ then #list[
    Inner $b$ and $c$
  ][
    More inner $d + e$
  ]
][
  Another outer $f$
]

== Enum

#enum[
  $lambda(mu) = norm(pi(mu))_("op")$
][
  $cal(L)(mu) = -log lambda(mu)$
][
  $kappa(S) = inf_(norm(v)=1) delta(v)$
]

== Box and styling

#box(stroke: 1pt + blue)[
  In a box: $a^2 + b^2 = c^2$
]

#text(red)[
  Red text with $sin(x) + cos(x)$
]

#block(fill: luma(240), inset: 8pt)[
  In a block: $integral_0^infinity e^(-x) dif x = 1$
]

== Grid

#grid(columns: 2, gutter: 10pt)[
  Cell 1: $x^2$
][
  Cell 2: $y^2$
][
  Cell 3: $x + y$
][
  Cell 4: $frac(x, y)$
]

== Deep function nesting

#box[#text(blue)[#emph[$alpha + bb + gg$]]]

#block[
  #list[
    #box[Inside box in list: $RR^n$]
  ][
    #text(green)[Green: $pi r^2$]
  ]
]

== Align

#align(center)[
  Centered: $E = m c^2$
]

== Pad

#pad(left: 20pt)[
  Padded: $F = m a$
]

== Stack

#stack(dir: ltr, spacing: 10pt)[
  First: $p$
][
  Second: $q$
][
  Third: $p and q$
]

== Table

#table(columns: 3)[
  $a$][$b$][$c$][
  $d$][$e$][$f$][
  $sum a$][$product b$][$integral c$
]

== Complex: show rule + list + definition-like

#let mydef(body) = block(
  fill: rgb("#f0f0ff"),
  inset: 10pt,
  radius: 4pt,
  body,
)

#mydef[
  *Definition.* Let $V$ be a vector space over $RR$ with norm $norm(dot)$.
  A sequence $(x_n)$ converges to $x$ if
  $ lim_(n -> infinity) norm(x_n - x) = 0. $

  #list[
    $norm(x) >= 0$ for all $x in V$
  ][
    $norm(alpha x) = abs(alpha) norm(x)$ for $alpha in RR$
  ][
    $norm(x + y) <= norm(x) + norm(y)$ (triangle inequality)
  ]
]

After everything: $bb + gg = delta$
