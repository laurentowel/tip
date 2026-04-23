#import "utils.typ": *

#let inner-product(a, b) = $angle.l #a, #b angle.r$

#set text(font: "New Computer Modern")
#show math.equation: set text(font: "New Computer Modern Math")

= Functional Analysis Notes

Let $V$ be a Hilbert space over $CC$ with inner product $inner-product(dot, dot)$.

== Definitions

#let opnorm(T) = $norm(T)_("op")$

A bounded linear operator $T: V -> V$ satisfies
$ opnorm(T) = sup_(norm(x) <= 1) norm(T x) < infinity $

The spectrum of $T$ is
$ sigma(T) = { lambda in CC : T - lambda I "is not invertible" } $

== Properties

#{
  let adjoint(T) = $T^*$

  For self-adjoint operators, $adjoint(T) = T$ and $sigma(T) subset.eq RR$.

  The spectral radius satisfies
  $ rho(T) = lim_(n -> infinity) opnorm(T^n)^(1/n) $
}

For compact operators on infinite-dimensional spaces, $0 in sigma(T)$.

The resolvent set $rho(T) = CC without sigma(T)$ is always open, and
$ R(lambda, T) = (T - lambda I)^(-1) $
is analytic on $rho(T)$.
