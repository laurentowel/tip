#let bb = sym.beta

Simple: $a + b$

In list:
#list[
  $lambda(mu, pi) = norm(pi(mu))_("op")$ and
][
  $cal(L)(mu,pi) = -log lambda(mu,pi)$
][
  $mu$ has the spectral gap property for $pi$ if $lambda(mu,pi) < 1$ or alternatively $cal(L)(mu,pi) > 0$.
][
  Similarly define spectral gap property for action $G arrow.cw.half (X, nu_(X))$ where $mu$ finite support on $G$. Say $mu arrow.cw.half X$ has spectral gap property if $mu$ has the spectral gap property for $pi: G arrow.r U(L^(2)(X)^(o))$.
]

After list: $bb + bb$

#import "@preview/theorion:0.5.0": *
#definition[
  (quantification of "displacement")
  Set
  $
    delta_(S)(v) = max_(s in S) frac(norm(pi(s)v-v), norm(v))
  $
  for $v in cal(H) without {0}$, set $delta_(mu)(v) = delta_(op("supp")(mu))(v)$.

  Set
  $
    kappa(mu \; pi) = inf_(norm(v)=1) delta_(mu)(v).
  $
]


