# Word fidelity investigation — May 2026

## Real-world templates investigated

- **Apex Surveys quotation** (Conga migration, NY Sprint customer) — 6-page quote with first-page-distinct header/footer, anchored logo, 7.9" decorative banner
- **Mantis UBM ROM Proposal** — complex 4-header sales proposal with 5MB+ images sized 15068×5731 px native (Word displays at 8.46"×2.39")

Both surfaced the same class of fidelity issues in PDF render output.

## What's confirmed working

### Image dimension extraction is correct

`DocGenHtmlRenderer.processDrawing` already extracts `<wp:extent cx="…" cy="…">` and emits explicit `<img style="width:Xpx;height:Ypx">` matching Word's display dimensions.

Verified against Mantis header1.xml:

- 8.46"×2.39" Word display → `<img style="width:813px;height:229px">` (96 DPI conversion exact)
- 2.05"×0.78" Word display → `<img style="width:197px;height:75px">` (exact)

The `EMU_TO_PX = 0.000104987` constant (1/9525) is correct: 914400 EMU/inch ÷ 96 px/inch = 9525 EMU/px.

### Image extraction walks ALL header/footer rels

`extractAndSaveTemplateImages` reads every `word/_rels/header*.xml.rels` and `footer*.xml.rels` regardless of how `<w:sectPr>` references them. First-page-distinct templates extract all images from both "first" and "default" headers.

### Pre-decomposed XML parts match ZIP path byte-for-byte

`docgen_tmpl_xml_<verId>_word__styles.xml` and `docgen_tmpl_xml_<verId>_word__document.xml` ContentVersions match the ZIP-extracted equivalents byte-for-byte. The pre-decomp VS ZIP path divergence is NOT in the source XML.

## What's broken — confirmed bugs

### Bug 1: Pre-decomp render produces different visual output than ZIP path — FIXED v1.80

**Symptom:** The same template, same record, generated different PDFs depending on whether `extractAndSaveTemplateImages` had run. Pre-decomp PDFs showed right-aligned text where ZIP path showed left-aligned.

**Actual root cause:** `DocGenHtmlRenderer.isDefaultStyleRtl()` used `stylesXml.contains('<w:bidi ')` to detect RTL. That naive check matched `<w:bidi w:val="0"/>` — the **disabled** form — as truthy. LibreOffice's `.doc → .docx` conversion injects `<w:bidi w:val="0"/>` into the Normal style for every English LTR document. Pre-decomp passed styles.xml to the renderer (the ZIP path didn't, which is why it appeared as a divergence rather than a global bug). When the renderer thought the doc was RTL, it emitted `text-align: right` on body CSS, which cascaded to every paragraph that didn't override it.

**Fix:** Added `isOoxmlOnOffElementTrue(xml, elementName)` helper that parses `w:val` correctly per ECMA-376 §17.17.4 (`"1"`/`"true"`/`"on"` truthy, `"0"`/`"false"`/`"off"` falsy, absent attribute defaults to true). Replaced 11 naive `<w:elementName ` checks across the renderer (b, i, strike, caps, smallCaps, rtl, bidi, bidiVisual, titlePg, pageBreakBefore, keepNext, keepLines, tblHeader). Three regression tests added.

The original asymmetry between pre-decomp and ZIP paths (only pre-decomp populates `processedXmlEntries['word/styles.xml']`) is intentional — keeping it means ZIP path now still works even on docs whose styles.xml has unrelated bugs we haven't anticipated. We left that asymmetry in place; the fix is in the parser.

### Bug 2: First-page-distinct headers/footers (`<w:titlePg/>`) ignored — FIXED v1.80

**Symptom:** Templates with separate "first" and "default" header/footer references rendered only the "default" pair on every page. The page-1-specific design was lost.

**Fix:** `DocGenService.combineXmlWithHeadersFooters` now walks the document's `<w:sectPr>` `<w:headerReference w:type="X" r:id="...">` entries, resolves each relId via document rels, and emits separate marker pairs (`DOCGEN_HEADER_FIRST_START/END`, `DOCGEN_FOOTER_FIRST_START/END`, plus the default pair). `DocGenHtmlRenderer.convertToHtml` extracts both, hoists the first-page divs into named running elements (`docgen-running-header-first`, `docgen-running-footer-first`), and emits a `@page :first { @top-center { content: element(docgen-running-header-first); } }` rule alongside the default `@page`. Even-page distinct headers (rare) are accepted by the parser but folded into the default pair for now — Flying Saucer's `@page :left/:right` support is partial. Three regression tests added.

### Bug 3: `width:Xpx` on `<img>` not honored for floating/anchored images — FIXED v1.80

**Symptom:** Renderer correctly emitted `<img style="width:Xpx;height:Ypx">` per Word's wp:extent. But high-resolution embedded images (Mantis ROM example: 15068×5731 native) rendered at native pixel size in PDF, overflowing the page.

**Root cause:** Flying Saucer's image scaler resolves dimensions in this order: HTML `width=`/`height=` attributes → CSS `width`/`height` → natural image bytes. Without HTML attributes, the engine reads the image's natural pixel dimensions during decode, then _maybe_ applies CSS — but for very large source images the CSS path silently fell back to natural size.

**Fix:** `DocGenHtmlRenderer.processDrawing` now emits HTML `width="N" height="N"` attributes on every `<img>` alongside the existing CSS, locking dimensions at the engine's authoritative attribute layer. Defense-in-depth: CSS still emitted, body's `img { max-width: 100% }` rule still in place. Autosize mode (rich text images without explicit width/height) skips the HTML attrs since it intentionally relies on max-width. One regression test added asserts both attribute and CSS emission for Mantis-style 813×229 px display dimensions.

## What's NOT broken but customers think might be

### `<w:titlePg/>` extractor coverage

I initially thought `extractAndSaveTemplateImages` might be skipping "first"-typed rels, missing the footer image. Verified: extractor walks every `header*.xml.rels` and `footer*.xml.rels` regardless of which sectPr type points at them. The footer image was correctly extracted in v.1; I misread a truncated table view earlier.

### Pre-decomposed XML content corruption

I initially thought pre-decomp `styles.xml` or `document.xml` might be encoded differently (BOM, whitespace, etc.) than the ZIP-extract counterparts. Verified: byte-for-byte identical via Apex `String.equals` test.

## Genuinely unfixable (Flying Saucer wall)

Per CLAUDE.md `reference_flying_saucer_limits.md` and existing watermark deep-dive:

- `transform: rotate()` — no
- `@font-face` custom fonts — no
- `background-size` — no
- `opacity` (CSS3) — no
- Word's exact anchored-image x/y offsets — approximated, not exact

These are platform constraints. Don't re-attempt.

## Honest path forward for customers with complex Word templates

### Tier 1 — high-fidelity PDF possible

Templates that:

- Use only inline images (no `behindDoc`, no anchored floating)
- Have one default header/footer (no `<w:titlePg/>`)
- Embed images at native pixel dimensions matching desired display at 96 DPI
- Don't rely on rotated text, custom fonts, or precise margin/spacing

These templates render predictably in PDF.

### Tier 2 — degraded PDF acceptable

Templates that have anchored images or first-page-distinct layouts but where users will accept "approximately right" rendering. Edit out the `<w:titlePg/>` and behindDoc anchoring before saving.

### Tier 3 — Word-fidelity required → use DOCX output

Templates that need pixel-perfect Word fidelity should output DOCX, not PDF. DocGen's DOCX output preserves everything because it IS Word XML — no Flying Saucer in the loop. Customer opens the result in Word and gets exact rendering.

## v1.80.0 ship list

What this branch (`feature/v1.80-word-fidelity`) actually shipped:

1. **#54 — `IsLatest = TRUE` guards on pre-decomp + image-map queries**. Prevents "entity is deleted" UNKNOWN_EXCEPTION when extractAndSaveTemplateImages runs against a template with stale (recycled) ContentVersions from a prior version.
2. **#53 — OOXML on/off element parsing**. Renderer now correctly handles `<w:elementName w:val="0"/>` as disabled across 11 element types. Fixes the pre-decomp alignment regression for LibreOffice-converted templates.
3. **#57 — First-page-distinct headers/footers**. `<w:titlePg/>` + `<w:headerReference w:type="first">` now produces a `@page :first` ruleset with the right running elements. Page-1-specific layouts work end-to-end.
4. **#58 — Flying Saucer image dimension binding**. `<img>` tags now emit HTML `width=`/`height=` attributes alongside CSS so high-resolution embedded images respect Word's wp:extent display size instead of falling back to natural pixel dimensions.
5. **#56 — Pre-flight image-overflow warning**. `extractAndSaveTemplateImages` walks every `wp:extent` against the parsed page content area and emits `System.debug` WARN entries for oversized images. Helps admins spot authoring issues that #58 can't fully fix (when the authored display size itself exceeds the page).

What was investigated and confirmed working as designed:

- #55 wp:extent → CSS emission (already correct in renderer)
- Image extractor coverage of "first"-typed rels (already complete)
- Pre-decomp XML byte-equivalence to ZIP path (already correct)
