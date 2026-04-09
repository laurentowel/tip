# Custom Font Directories

TIP needs to find the same fonts that `typst compile` would use. By default, `tip-server` scans system font directories and Typst's embedded fonts. For fonts installed elsewhere — project-local directories, custom paths, or non-standard locations — you need to tell TIP where to look.

## Three Layers of Font Discovery

Fonts are discovered in order, and all layers combine:

### 1. Embedded + System Fonts (automatic)

`tip-server` always scans:
- Typst's built-in embedded fonts (New Computer Modern, etc.)
- System font directories (`/usr/share/fonts`, `~/.local/share/fonts`, platform equivalents)

No configuration needed.

### 2. `TYPST_FONT_PATHS` Environment Variable

Set this to add directories, same as `typst compile --font-path`:

```sh
export TYPST_FONT_PATHS="/home/user/fonts/math:/opt/custom-fonts"
```

Paths are separated by `:` on Unix, `;` on Windows. `tip-server` reads this at startup. This gives parity with `typst compile` — if your fonts work with the CLI, they work with TIP.

### 3. `tip-font-dirs` Emacs Variable

For per-project font directories, set `tip-font-dirs`. Each entry is either:

- **An absolute path** (string) — used as-is
- **A cons pair** `(anchor . relative-path)` — resolved relative to the anchor directory

```elisp
;; Global: absolute path, applies to all buffers
(setq-default tip-font-dirs '("/home/user/.local/share/fonts/math"))
```

```elisp
;; Per-project: in .dir-locals.el at the project root
((typst-ts-mode . ((tip-font-dirs . (("." . "fonts"))))))
```

The `"."` anchor means "the directory containing this `.dir-locals.el`", which is the project root. Emacs resolves all entries to absolute paths before sending them to the server.

### How `.dir-locals.el` Works Across Subdirectories

A `.dir-locals.el` at the project root applies to **all files in all subdirectories**. Emacs searches upward from each file to find the nearest `.dir-locals.el`. So this structure:

```
my-project/
  .dir-locals.el       ← sets tip-font-dirs to (("." . "fonts"))
  fonts/
    MyMathFont.otf
  typst.toml
  src/
    chapter1.typ       ← gets tip-font-dirs = (("." . "fonts"))
    figures/
      diagram.typ      ← also gets tip-font-dirs = (("." . "fonts"))
```

Both `chapter1.typ` and `figures/diagram.typ` see the same `tip-font-dirs` value. The `"."` resolves to `/path/to/my-project/` in both cases — the directory where `.dir-locals.el` lives, not the file's own directory.

### Examples

**Single project-local font directory:**
```elisp
;; .dir-locals.el
((typst-ts-mode . ((tip-font-dirs . (("." . "fonts"))))))
```

**Multiple directories, mixing global and project-local:**
```elisp
;; .dir-locals.el
((typst-ts-mode . ((tip-font-dirs . ("/usr/share/fonts/opentype/math"
                                      ("." . "fonts")
                                      ("." . "assets/otf"))))))
```

**Global-only, no project fonts:**
```elisp
;; init.el
(setq-default tip-font-dirs '("/home/user/fonts"))
```

## Protocol

Emacs sends resolved font directories to the server via the `init` message, sent once after the server starts:

```json
{"id": 1, "method": "init", "params": {"font_dirs": ["/absolute/path/to/fonts"]}}
```

The server scans these directories (combined with `TYPST_FONT_PATHS` and system fonts) and builds its font database. This happens once per session — font scanning is a startup cost, not a per-compile cost.
