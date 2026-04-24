= tip-mode demo — Typst

== Inline

The Plancherel identity
$integral_(-oo)^oo abs(f(x))^2 dif x
  = integral_(-oo)^oo abs(hat(f)(xi))^2 dif xi$
holds for $f in L^2(RR)$, and more generally
$angle.l f, g angle.r = angle.l hat(f), hat(g) angle.r$.

== Short display

$ sum_(k=1)^n k^3 = ((n(n+1))/2)^2 $

== Cases

$ abs(x) = cases(
  x\,   & "if " x >= 0,
  -x\,  & "if " x < 0,
) $

== Multi-line derivation (align)

$ (d)/(d x) e^(f(x)) &= f'(x) thin e^(f(x)) \
  (d^2)/(d x^2) e^(f(x)) &= (f''(x) + f'(x)^2) thin e^(f(x)) \
  (d^3)/(d x^3) e^(f(x)) &= (f'''(x) + 3 f'(x) f''(x) + f'(x)^3) thin e^(f(x))
$

== Big rotation matrix

$ mat(
  cos theta, -sin theta, 0, 0;
  sin theta,  cos theta, 0, 0;
  0,          0,         1, 0;
  0,          0,         0, 1;
) vec(x, y, z, 1) $

== Scope detection

Typst lets you bind names before math uses them.  tip-server walks
the document up to each fragment and replays all `#let` / `#import` /
`#show` / `#set` that would be in scope — so the fragment compiles
with exactly the meaning it would have in the full document.

Custom macros via `#let`:
#let D(f, x) = $(diff f) / (diff x)$
#let lapl = $nabla^2$
#let bra(x) = $angle.l #x bar$
#let ket(x) = $bar #x angle.r$
#let braket(x, y) = $angle.l #x mid(|) #y angle.r$
#let hbar = $planck.reduce$

Now use them in math — the server must pull all the `#let` bindings
above into scope to make sense of these:

$ D(u, t) = alpha lapl u $

$ braket(phi, psi) = bra(phi) ket(psi)
    = integral overline(phi(x)) psi(x) dif x $

== Font from `TYPST_FONT_PATHS`

tip-server's Typst world reads `TYPST_FONT_PATHS` at startup.  The
nix demo sets it to a flake-managed dir containing Pennstander Math
(a distinctive display math face) — so this renders identically
across machines, regardless of what the host has installed.

#show math.equation: set text(font: "Pennstander Math")

$ hat(H) psi = i hbar (diff psi) / (diff t) $

$ cal(L)[u](s) = integral_0^oo e^(-s t) u(t) dif t $

== Font from system fontconfig

Typst's FontSearcher also scans the host's system font dirs
(fontconfig XDG + /usr/share/fonts).  If Latin Modern Math is
installed (comes with most TeX Live installs), this block uses it;
otherwise Typst falls back to its default.

#show math.equation: set text(font: "Latin Modern Math")

$ hat(H) psi = i hbar (diff psi) / (diff t) $

// Reset so baseline-align stays honest for the next section.
#show math.equation: set text(font: "New Computer Modern Math")

== Green's identity (multi-line display)

$ integral_Omega
    (nabla f dot nabla g) / sqrt(1 + abs(nabla f)^2)
    dif V
  = integral_(partial Omega)
    g thin (partial f) / (partial n)
    dif S
  - integral_Omega g thin
    "div" ((nabla f) / sqrt(1 + abs(nabla f)^2))
    dif V $
