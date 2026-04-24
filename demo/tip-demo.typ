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
