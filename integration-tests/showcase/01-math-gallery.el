;;; 01-math-gallery.el --- Walk through varied math, one per scene  -*- lexical-binding: t; -*-

;; Paces through a handful of intricate typeset expressions so a
;; watcher can eye-ball that tip handles them.  Each spec pauses on
;; its own rendered result (see the macro's inter-test sleep).

(defun tip-test--wait-rendered (&optional secs)
  (tip-render-all)
  (tip-test-wait-for-pending (or secs 20))
  (redisplay t))

(tip-test-deftest showcase-plancherel
  :doc "Plancherel identity — inline math with hats and integrals."
  :tags (showcase)
  (tip-test-with-fresh-typst-buffer
   (concat "== Plancherel identity\n\n"
           "$ integral_(-oo)^oo abs(f(x))^2 dif x "
           "= integral_(-oo)^oo abs(hat(f)(xi))^2 dif xi $\n")
    (tip-test--wait-rendered)))

(tip-test-deftest showcase-sum-of-cubes
  :doc "Sum-of-cubes closed form — one-line display."
  :tags (showcase)
  (tip-test-with-fresh-typst-buffer
   (concat "== Sum of cubes\n\n"
           "$ sum_(k=1)^n k^3 = ( (n(n+1))/2 )^2 $\n")
    (tip-test--wait-rendered)))

(tip-test-deftest showcase-align-derivatives
  :doc "Multi-line align with iterated derivatives of exp(f(x))."
  :tags (showcase)
  (tip-test-with-fresh-typst-buffer
   (concat "== Iterated derivatives\n\n"
           "$ (d)/(d x) e^(f(x)) &= f'(x) thin e^(f(x)) \\\n"
           "  (d^2)/(d x^2) e^(f(x)) &= (f''(x) + f'(x)^2) thin e^(f(x)) \\\n"
           "  (d^3)/(d x^3) e^(f(x)) &= (f'''(x) + 3 f'(x) f''(x) "
           "+ f'(x)^3) thin e^(f(x)) $\n")
    (tip-test--wait-rendered 30)))

(tip-test-deftest showcase-rotation-matrix
  :doc "4×4 rotation matrix acting on a homogeneous vector."
  :tags (showcase)
  (tip-test-with-fresh-typst-buffer
   (concat "== Rotation in homogeneous coordinates\n\n"
           "$ mat(\n"
           "  cos theta, -sin theta, 0, 0;\n"
           "  sin theta,  cos theta, 0, 0;\n"
           "  0,          0,         1, 0;\n"
           "  0,          0,         0, 1;\n"
           ") vec(x, y, z, 1) $\n")
    (tip-test--wait-rendered)))

(tip-test-deftest showcase-greens-identity
  :doc "Green's identity — multi-line display with nabla and sqrt."
  :tags (showcase)
  (tip-test-with-fresh-typst-buffer
   (concat "== Green's identity\n\n"
           "$ integral_Omega\n"
           "    (nabla f dot nabla g) / sqrt(1 + abs(nabla f)^2)\n"
           "    dif V\n"
           "  = integral_(partial Omega)\n"
           "    g thin (partial f) / (partial n)\n"
           "    dif S\n"
           "  - integral_Omega g thin\n"
           "    \"div\" ((nabla f) / sqrt(1 + abs(nabla f)^2))\n"
           "    dif V $\n")
    (tip-test--wait-rendered 30)))
