#let SL = math.op("SL")
#let norm(x) = $lr(|| #x ||)$
#let innerproduct(u, v) = $lr(angle.l #u, #v angle.r)$
#let iprod = innerproduct
#let bluem(m) = text(blue)[$#m$]
#let greenm(m) = text(green)[$#m$]
#let orangem(m) = text(orange)[$#m$]
#let res(f, K) = $lr(#f |)_#K$
#let leq = $<=$
#let tensor = math.times.o
#let oplus = math.plus.o
#let dsum = oplus
