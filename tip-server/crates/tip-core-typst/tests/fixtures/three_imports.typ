// Test file using all 3 import types:
// 1. Relative file import
// 2. Local package (@local/mmm)
// 3. Remote package (@preview/fletcher for diagrams)

#import "mystyle.typ": *
#import "@local/mmm:0.0.0": *
#import "@preview/fletcher:0.5.7" as fletcher: diagram, node, edge

= Three Import Types Test

== Relative import (mystyle.typ): blackboard bold
$ alpha + beta  $

$alpha + b^2 n+ b$

$a + b$

$a + beta$

The Hilbert space $cH$ over $CC$ with $RR$-structure.

Field extensions $QQ subset RR subset CC$.

== Local package (mmm): operators and macros

The group $SL(2, ZZ)$ acts on $cH$.

Spectral gap: $lambda(mu sc pi) leq sqrt(1 - p_0^2 kappa(mu sc pi)^2)$

Operator norm $norm(T)_("op") = sup_(norm(x) leq 1) norm(T x)$

Inner product $iprod(u, v) = overline(iprod(v, u))$

Colored: $bluem(alpha) + greenm(beta) = orangem(gamma)$

Restriction $res(f, K)$ of $f$ to $K$.

== Remote package (fletcher): commutative diagram

#diagram(
  node((0, 0), $RR^n$),
  node((1, 0), $RR^m$),
  node((0, 1), $CC^n$),
  node((1, 1), $CC^m$),
  edge((0, 0), (1, 0), $T$, "->"),
  edge((0, 1), (1, 1), $T_CC$, "->"),
  edge((0, 0), (0, 1), $iota$, "hook->"),
  edge((1, 0), (1, 1), $iota$, "hook->"),
)

== Mixed: all three in one equation

For $pi : SL(2, ZZ) to U(cH)$ unitary, the $cL$-function satisfies
$ cL(mu, pi) = -log norm(pi(mu))_("op") > 0 $
when $mu$ has spectral gap.

The Kazhdan constant $kappa(S)$ for generating set $S$ gives
$ lambda(mu_S sc pi) leq sqrt(1 - 1/abs(S)^2 kappa(S sc pi)^2) $
