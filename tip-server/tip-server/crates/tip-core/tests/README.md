# tip-core Tests

## Test Files

| File | What |
|------|------|
| `baseline_test.rs` | Verifies depth/ascent values for various expressions |
| `font_check.rs` | Visual: default vs Pennstander math font |
| `font_weights.rs` | Visual: all 9 Pennstander weight variants |
| `frame_dump2.rs` | Debug: dumps frame tree with/without bounded() |
| `frac_dump.rs` | Debug: fraction frame structure |
| `imports_and_packages.rs` | Relative, @local, @preview imports |
| `inline_vs_display.rs` | Verifies size differences inline vs display |
| `real_world.rs` | Compiles all fragments from a real .typ file |
| `scope_check.rs` | Visual: scope-aware compilation basics |
| `scope_insane.rs` | Visual: closures, shadowing, operator override |
| `scope_nesting.rs` | Visual: math→code→markup→math mode nesting |
| `scope_stress.rs` | Visual: deep nesting, set cascades, conditionals |
| `three_imports_test.rs` | All 3 import types in one file |
| `visual_check.rs` | Basic visual: inline, fraction, block, colored |

## Fixtures

`tests/fixtures/` contains `.typ` test files:
- `utils.typ`, `operators.typ` — imported by other fixtures
- `mystyle.typ` — relative import definitions
- `three_imports.typ` — exercises relative + @local + @preview
- `real_world.typ` — functional analysis notes with custom operators
- `baseline_stress.typ` — expressions designed to stress baseline alignment

## Visual Output

Tests with `write_svg()` output to `tip-server/test-output/`. Run with `--nocapture` to see paths:

```bash
cargo test -p tip-core --test scope_check -- --nocapture
```

## Comparison PDFs

`tests/visual/` contains Typst comparison documents (native vs SVG side-by-side):

```bash
cd tests/visual
typst compile --root /path/to/tip-server comparison_all.typ
```
