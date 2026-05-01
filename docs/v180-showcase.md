# DocGen v1.80 Word-Fidelity Showcase

A purpose-built two-page Word template that exercises every v1.80 PDF-rendering
fix in a single document. Authored from raw OOXML primitives — no Conga, no
LibreOffice, no third-party authoring tool — so the demo is reproducible and
exactly captures the conditions each fix addresses.

## Files

- **`v180-showcase.docx`** — the authored template
- **`v180-showcase.pdf`** — the rendered output proving the fixes work

## What each fix does, mapped to the document

### Fix #53 — OOXML on/off element parser

**The trap:** LibreOffice's `.doc → .docx` conversion injects
`<w:bidi w:val="0"/>` into the Normal style of every English document.
Pre-v1.80 the renderer matched the substring `<w:bidi ` and incorrectly flagged
the doc as right-to-left, emitting `text-align: right` on body CSS. The result
was every paragraph silently right-aligning.

**Showcased on page 1:** the styles.xml in this template intentionally contains:

```xml
<w:style w:type="paragraph" w:styleId="Normal" w:default="1">
  <w:pPr><w:widowControl /><w:bidi w:val="0" /></w:pPr>
  ...
</w:style>
```

**What to look for:** every body paragraph on page 1 (the title-page heading,
the prose under "Fix #53", "Fix #58", "Fix #56") renders **left-aligned**. If
you see it right-aligned, the fix has regressed.

### Fix #57 — First-page-distinct headers and footers

**The trap:** templates with `<w:titlePg/>` plus separate
`<w:headerReference w:type="first"/>` and `<w:headerReference w:type="default"/>`
got their headers concatenated and rendered together on every page. The
page-1-specific design was lost, and pages 2+ showed both the title-page header
and the default header stacked on top of each other.

**Showcased across both pages:**

- The sectPr declares `<w:titlePg/>` plus four references —
  `headerReference w:type="first" → header2.xml`,
  `headerReference w:type="default" → header1.xml`,
  same pattern for footers.
- **Page 1** has `header2.xml` (a centered blue "DocGen v1.80 — Title Page
  Header" + a horizontal banner) and `footer2.xml` (a centered blue
  "Title-Page Footer · v1.80 Fix #57").
- **Page 2** has `header1.xml` (a small grey right-aligned label "DocGen v1.80
  Showcase — default header (pages 2+)") and `footer1.xml` (a small grey
  centered "Default footer — rendered on pages 2 and beyond").

**What to look for:** page 1 and page 2 must have _visually different_ headers
and footers. Page 1 should NOT show the small grey label; page 2 should NOT
show the big blue banner.

### Fix #58 — Image dimension binding

**The trap:** Flying Saucer's image scaler resolves dimensions in this order:
HTML `width=`/`height=` attributes → CSS `width`/`height` → natural image
bytes. Pre-v1.80 the renderer emitted only CSS sizing. For high-resolution
embedded images (and edge cases like images with mismatched native vs display
dimensions) Flying Saucer fell through to natural pixel dimensions, ignoring
the CSS width/height. Mantis ROM Proposal images sized 15068×5731 px native
overflowed the page.

**Showcased on page 1:** a centered 1-inch test image. Its `wp:extent` is
`914400×914400` EMU (Word's "1 inch" in EMU at 914400 EMU/inch). The native
PNG is intentionally 1×1 px. Pre-fix, Flying Saucer would have rendered a
1-pixel red dot. Post-fix, the renderer emits:

```html
<img src="..." width="96" height="96" style="width:96px;height:96px;image-orientation:from-image;" />
```

The HTML `width=`/`height=` attributes lock the display size at Flying
Saucer's authoritative attribute layer.

**What to look for:** a 1-inch red square in the middle of page 1. If you see
a tiny dot, the fix has regressed.

### Fix #56 — Pre-flight image-overflow warning

**The trap:** even with #58, a template author can make wp:extent itself
exceed the page content area. The renderer can't recover from that — the
image will physically not fit. Pre-v1.80 there was no early signal.

**Showcased on page 1:** the title-page header banner is intentionally
authored at 8.27" wide. The page content area on US Letter with 0.5" margins
is 7.5". When `extractAndSaveTemplateImages` runs against this template, the
debug log emits:

```
DocGen image-overflow: template version <Id> part word/header2.xml has
wp:extent 8.27" wide vs 7.50" content area — image will overflow page margins
DocGen image-overflow summary: 1 oversized image(s) detected. Authors:
resize images so wp:extent ≤ 7.50" (or widen page margins).
```

**What to look for:** check the Apex debug log when uploading this template
or re-running extraction. The two WARN entries above must appear.

## How to reproduce

1. **Upload the .docx** as a new DocGen template (Type=Word, Output=PDF,
   Base Object=Opportunity, Test Record = any Opp).
2. **Wait for pre-decomposition** to complete (or trigger
   `extractAndSaveTemplateImages` synchronously in anonymous Apex).
3. **Generate a PDF** against any Opportunity record. The template uses only
   `{Name}` so no field config is required.
4. **Compare** to the rendered `v180-showcase.pdf` in this folder.

## Quick assertion summary

The Apex render harness (`scripts/render-showcase.apex`) prints these — all
must be `true`:

| Assertion                                      | Fix |
| ---------------------------------------------- | --- |
| body has NO `text-align:right`                 | #53 |
| `@page :first` ruleset emitted                 | #57 |
| first-page header running element wired        | #57 |
| first-page footer running element wired        | #57 |
| first-page header div in body                  | #57 |
| first-page footer div in body                  | #57 |
| default header running element wired           | #57 |
| image HTML `width="96"` attribute emitted      | #58 |
| image HTML `height="96"` attribute emitted     | #58 |
| extraction debug log contains "image-overflow" | #56 |

## Provenance

The .docx was authored by `/tmp/v180-proof/build-demo-docx.py` — a single
Python script that emits every part of the OOXML zip from primitives. Total
size: 6.6 KB unpacked, 14 files. No graphical editor was used; every byte is
in the script. Re-running the script regenerates a byte-identical .docx, so
this showcase doubles as an integration regression for the four fixes.
