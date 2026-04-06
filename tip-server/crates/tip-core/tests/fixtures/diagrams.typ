#import "@preview/cetz:0.4.2"
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge

= CeTZ Diagrams

Simple circle:
#cetz.canvas({
  import cetz.draw: *
  circle((0, 0), radius: 1, fill: blue.lighten(80%))
  line((-1, 0), (1, 0), stroke: red)
})

Triangle:
#cetz.canvas(length: 0.8cm, {
  import cetz.draw: *
  line((0, 0), (2, 0), (1, 1.7), close: true, fill: green.lighten(80%))
  content((1, 0.6), $Delta$)
})

= Fletcher Diagrams

Simple arrow:
#diagram(
  node((0, 0), $A$),
  edge("->"),
  node((1, 0), $B$),
)

Commutative square:
#diagram(
  node((0, 0), $X$),
  node((1, 0), $Y$),
  node((0, 1), $Z$),
  node((1, 1), $W$),
  edge((0, 0), (1, 0), $f$, "->"),
  edge((0, 1), (1, 1), $g$, "->"),
  edge((0, 0), (0, 1), $h$, "->"),
  edge((1, 0), (1, 1), $k$, "->"),
)

Exact sequence:
#diagram(
  node-stroke: 0.5pt,
  node((0, 0), $0$),
  node((1, 0), $A$),
  node((2, 0), $B$),
  node((3, 0), $C$),
  node((4, 0), $0$),
  edge((0, 0), (1, 0), "->"),
  edge((1, 0), (2, 0), $f$, "->"),
  edge((2, 0), (3, 0), $g$, "->"),
  edge((3, 0), (4, 0), "->"),
)
