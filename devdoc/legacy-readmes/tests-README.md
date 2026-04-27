# TIP Tests

Numbered by difficulty/importance. Lower = more essential.

## Running

```bash
# From repo root. All need --init-directory for typst-ts-mode.

# 00-09: Core automated (run on every change)
emacs -Q --init-directory tests/emacs-sandbox -l tests/00-open-close.el
emacs -Q --init-directory tests/emacs-sandbox -l tests/01-cursor-into-overlay.el
emacs -Q --init-directory tests/emacs-sandbox -l tests/02-on-the-fly.el
emacs -Q --init-directory tests/emacs-sandbox -l tests/03-bugs.el
emacs -Q --init-directory tests/emacs-sandbox -l tests/04-childframe.el

# 10-19: Stress tests
emacs -Q --init-directory tests/emacs-sandbox -l tests/10-edit-cycle.el
emacs -Q --init-directory tests/emacs-sandbox -l tests/11-rapid-movement.el
emacs -Q --init-directory tests/emacs-sandbox -l tests/12-stress-edit.el
emacs -Q --init-directory tests/emacs-sandbox -l tests/13-childframe-stress.el

# 20-29: Feature tests
emacs -Q --init-directory tests/emacs-sandbox -l tests/20-diagrams.el
emacs -Q --init-directory tests/emacs-sandbox -l tests/21-highlight-fragments.el

# 30-39: Interactive visual (stays open)
emacs -Q --init-directory tests/emacs-sandbox -l tests/30-visual.el
emacs -Q --init-directory tests/emacs-sandbox -l tests/31-scale-slider.el

# 40-49: Performance
emacs -Q --init-directory tests/emacs-sandbox -l tests/40-perf.el

# 50-59: Exploratory / debug
emacs -Q --init-directory tests/emacs-sandbox -l tests/50-ascent-debug.el
```

## Naming Convention

```
NN-description.el
```

| Range | Category | Auto-exit? |
|-------|----------|------------|
| 00-09 | Core (open/close, bugs, childframe) | Yes |
| 10-19 | Stress (rapid movement, edit cycles) | Yes |
| 20-29 | Features (diagrams, highlights) | Yes |
| 30-39 | Interactive visual | No |
| 40-49 | Performance benchmarks | Yes |
| 50-59 | Exploratory / debug | Varies |
