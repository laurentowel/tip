;;; generate-bench-file.el --- Generate Typst files with many math fragments -*- lexical-binding: t; -*-
;; Run with: emacs --batch -l generate-bench-file.el

(defun gen--random-inline ()
  "Generate a random inline math fragment."
  (let ((templates
         '("$alpha + beta$"
           "$sum_(i=0)^n i^2$"
           "$integral_0^1 f(x) dif x$"
           "$frac(a + b, c - d)$"
           "$lim_(n -> infinity) a_n$"
           "$norm(T)_(\"op\")$"
           "$angle.l u, v angle.r$"
           "$mat(1, 0; 0, 1)$"
           "$sqrt(x^2 + y^2)$"
           "$product_(k=1)^n (1 + a_k)$"
           "$binom(n, k) = frac(n!, k!(n-k)!)$"
           "$nabla times bold(F) = bold(0)$"
           "$det(bold(A)) = sum_(sigma in S_n) op(\"sgn\")(sigma) product_(i=1)^n a_(i, sigma(i))$"
           "$e^(i pi) + 1 = 0$"
           "$zeta(s) = sum_(n=1)^infinity n^(-s)$"
           "$Gamma(z) = integral_0^infinity t^(z-1) e^(-t) dif t$"
           "$cal(F)[f](xi) = integral_(-infinity)^infinity f(x) e^(-2 pi i x xi) dif x$"
           "$partial_t u = Delta u + f$"
           "$norm(f)_(L^p) = (integral abs(f)^p dif mu)^(1/p)$"
           "$op(\"dim\") ker(T) + op(\"dim\") op(\"im\")(T) = op(\"dim\") V$")))
    (nth (random (length templates)) templates)))

(defun gen--random-display ()
  "Generate a random display math fragment."
  (let ((templates
         '("$ sum_(i=0)^n i^2 = frac(n(n+1)(2n+1), 6) $"
           "$ integral_0^infinity e^(-x^2) dif x = frac(sqrt(pi), 2) $"
           "$ mat(a, b; c, d) dot mat(e, f; g, h) = mat(a e + b g, a f + b h; c e + d g, c f + d h) $"
           "$ e^(i theta) = cos theta + i sin theta $"
           "$ (dif)/(dif x) integral_a^x f(t) dif t = f(x) $"
           "$ norm(f + g)_p leq norm(f)_p + norm(g)_p $"
           "$ det mat(a_(1 1), dots.h, a_(1 n); dots.v, dots.down, dots.v; a_(n 1), dots.h, a_(n n)) $"
           "$ lim_(n->infinity) (1 + 1/n)^n = e $"
           "$ f(x) = sum_(n=0)^infinity frac(f^((n))(a), n!) (x-a)^n $"
           "$ nabla^2 phi = -frac(rho, epsilon_0) $")))
    (nth (random (length templates)) templates)))

(defun gen--bench-file (n-fragments filepath)
  "Generate a Typst file with N-FRAGMENTS math fragments."
  (with-temp-file filepath
    (insert "#let bb = sym.beta\n")
    (insert "#let aa = sym.alpha\n")
    (insert "#let gg = sym.gamma\n\n")
    (let ((i 0))
      (while (< i n-fragments)
        ;; Mix inline and display, with text between
        (if (= (% i 5) 0)
            ;; Every 5th is display math
            (progn
              (insert (format "\nEquation %d:\n" i))
              (insert (gen--random-display))
              (insert "\n"))
          ;; Inline math with surrounding text
          (insert (format "Text %d: %s more text. " i (gen--random-inline))))
        ;; Paragraph break every 10
        (when (= (% i 10) 9)
          (insert "\n\n"))
        (cl-incf i)))))

(let ((dir (file-name-directory load-file-name)))
  (gen--bench-file 50 (expand-file-name "bench_50.typ" dir))
  (gen--bench-file 200 (expand-file-name "bench_200.typ" dir))
  (gen--bench-file 1000 (expand-file-name "bench_1000.typ" dir))
  (message "Generated bench_50.typ, bench_200.typ, bench_1000.typ"))
