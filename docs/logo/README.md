# The Lex logo

A glass L standing on its corner, lit from the inside in marker yellow. The
mark is the place; the light is the memory in it.

Every file except `original.png` has a transparent background and is cut from
`original.png`, so the artwork never changes, only its ground.

| File | Size | Use it for |
|:--|:--|:--|
| `lex-logo.png` | 972 × 541 | the lockup on a **dark** background; the wordmark is white |
| `lex-logo-light.png` | 972 × 541 | the lockup on a **light** background; the wordmark is re-inked dark grey |
| `lex-mark.png` | 386 × 541 | the L alone, full resolution, no wordmark |
| `lex-icon-512.png` … `-32.png` | square | app icons, favicons, an avatar; the mark centred with a margin |
| `lex-banner.png` | 1152 × 721 | a social preview or a slide, where a dark card of its own is wanted |
| `original.png` | 1447 × 1087 | the source. Cut new variants from this one |

The mark reads on light and on dark alike, because it is dark metal and yellow
light. The **wordmark does not**: white letters vanish on white. Pick the
lockup that matches the ground, or use `lex-mark.png` and set the name in text.

In a README, let the reader's own theme choose:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo/lex-logo.png">
  <img src="docs/logo/lex-logo-light.png" alt="Lex" width="340">
</picture>
```

## Colours

| Role | Value |
|:--|:--|
| the light in the corner, as drawn | `#F9C432`, rising to `#FEEB19` in the core |
| the product colour in the editor | `#EACB4A`, the same family, calmer, because it sits under code all day |
| the ground of `original.png` and `lex-banner.png` | `#07080C` |
| the wordmark, light lockup | `#17191C` to `#4A4F55` |

## How the cutout was made

The ground is near-black and even, so a flood fill from the four corners at 8%
tolerance lifts it away and leaves the glass whole. A higher tolerance eats
into the dark inner face of the L. The alpha edge is left hard at full size and
softens by itself when the image is scaled down.

```sh
magick original.png -alpha set -fuzz 8% -fill none \
  -draw 'color 0,0 floodfill'       -draw 'color 1446,0 floodfill' \
  -draw 'color 0,1086 floodfill'    -draw 'color 1446,1086 floodfill' \
  cutout.png
```
