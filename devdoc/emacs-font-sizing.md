# How Emacs Sizes Text and Images (pgtk port)

Traced from the Emacs 30.2 C source. Goal: understand the chain from font size to pixels to image alignment, so TIP can compute `tip-scale` automatically.

## Chain 1: Font Size → Pixel Size

The face `:height` attribute is in **tenths of a point** (e.g., 110 = 11pt).

```
pixel_size = (face_height / 10) * dpi_y / 72.27 + 0.5
```

- `72.27` is `PT_PER_INCH` (TeX convention, defined in `font.h:563`)
- `dpi_y` comes from `FRAME_DISPLAY_INFO(f)->resy` (GTK/Wayland provides this)
- The `+ 0.5` is for rounding to integer

Example: 11pt at 96 DPI → `11 * 96 / 72.27 + 0.5 ≈ 15 pixels`

**Source**: `font.c:3340` (`font_open_for_lface`), `font.h:572` (`POINT_TO_PIXEL` macro)

## Chain 2: `frame-char-height`

```
frame-char-height = font->ascent + font->descent
```

Where `font->ascent` and `font->descent` come from Cairo's scaled font extents (`cairo_scaled_font_extents`), rounded via `lround()`.

**Source**: `pgtkterm.c:865` (`pgtk_new_font`), `ftcrfont.c:272-282` (`ftcrfont_open`)

## Chain 3: Image `(N . em)` Height → Pixels

When TIP creates an image with `:height (N . em)`:

```
height_pixels = ceil(N * face->font->pixel_size)
```

And for `(N . ch)`:

```
height_pixels = ceil(N * (font->ascent + font->descent))
```

So `em` uses `pixel_size` (the nominal font size) while `ch` uses the actual character height (ascent + descent). These differ because fonts typically have ascent + descent > pixel_size.

**Source**: `image.c:2649-2671` (`image_get_dimension`), `image.c:2627-2639` (`scale_image_size`)

## Chain 4: Image `:ascent N` → Vertical Position

`:ascent N` means N% of the image height is above the text baseline:

```
image_ascent_px = height * (N / 100.0)
image_descent_px = height - image_ascent_px
```

The image is then positioned so `image_ascent_px` pixels sit above the text baseline and `image_descent_px` below.

For `:ascent center` (used for display math):

```
ascent = (height + font_ascent - font_descent + 1) / 2
```

This centers the image on the font's visual center, biased slightly upward.

**Source**: `image.c:1888-1925` (`image_ascent`), `xdisp.c:31588` (glyph placement)

## The Complete TIP Scaling Formula

TIP currently does:

```elisp
height_em = svg_height_pt / emacs_font_pt * tip_scale
```

Then creates `:height (height_em . em)`. Emacs converts this to pixels:

```
pixels = ceil(height_em * font_pixel_size)
       = ceil((svg_height_pt / emacs_font_pt * tip_scale) * font_pixel_size)
```

For the SVG to render at its natural size (1pt SVG = 1pt on screen), we need:

```
pixels = svg_height_pt * dpi / 72.27
```

Setting them equal:

```
svg_height_pt * dpi / 72.27 = (svg_height_pt / emacs_font_pt * tip_scale) * font_pixel_size
```

Since `font_pixel_size = emacs_font_pt * dpi / 72.27`:

```
svg_height_pt * dpi / 72.27 = (svg_height_pt / emacs_font_pt * tip_scale) * (emacs_font_pt * dpi / 72.27)
```

Simplifying: **`tip_scale = 1.0`** should be correct!

But in practice, `tip_scale = 1.0` doesn't look right because:

1. **Typst renders at 11pt** (its default) regardless of the Emacs font size
2. **Emacs font may not be 11pt** — if the user has a 13pt font, the math looks too small
3. **Font metrics differ** — New Computer Modern's ascent/descent proportions differ from the Emacs text font, so even at matching sizes the visual weight differs
4. **Cairo rounding** — `lround()` on ascent/descent and `ceil()` on image height introduce ±1px errors

## What TIP Should Do

The ideal `tip-scale` compensates for the mismatch between the Typst rendering size (11pt) and the Emacs font size:

```elisp
;; Automatic: match Typst's 11pt to the Emacs font's visual size
(setq tip-scale (/ (face-attribute 'default :height) 110.0))
```

For a 13pt Emacs font (`:height 130`): `tip-scale = 130/110 = 1.18`
For an 11pt Emacs font (`:height 110`): `tip-scale = 1.0`

This makes the math text the same size as the surrounding Emacs text. The baseline alignment (via `:ascent`) is independent of scale — it's a percentage of the final image height.

## pgtk-Specific Notes

- Uses Cairo + FreeType for font rendering (`ftcrfont.c`), not Xft
- Font metrics from `cairo_scaled_font_extents()`, rounded with `lround()`
- DPI from GTK/Wayland display info, no X11 resources
- No anisotropic scaling — X and Y use same pixel_size
- `font->baseline_offset` set in `pgtkterm.c:862` (usually 0)
