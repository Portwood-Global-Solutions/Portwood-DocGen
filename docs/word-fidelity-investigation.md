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

### Bug 1: Pre-decomp render produces different visual output than ZIP path

**Symptom:** The same template, same record, generates different PDFs depending on whether `extractAndSaveTemplateImages` has run. Pre-decomp PDFs show right-aligned/justified text where ZIP path shows left-aligned. Images render as broken in pre-decomp, fine in ZIP.

**What's NOT the cause:** Source XML (verified byte-identical), styles.xml (verified byte-identical).

**What IS the cause (hypothesis):** `mr.relsXml` differs. Pre-decomp concatenates document rels + ALL header/footer rels into one string. ZIP path keeps only document rels in `mr.relsXml` and stores header/footer rels separately in `passthroughEntries`. The renderer's image-resolution logic likely hits duplicate or overlapping relIds in the concatenated string and produces wrapping markup that cascades right-alignment.

**Workaround:** Delete `docgen_tmpl_xml_<verId>_*` ContentVersions to force the ZIP path. Loses ~75% heap savings but fixes alignment.

**Real fix (v1.81+):** Either (a) keep header/footer rels separate in pre-decomp by saving each `header1_rels`, `header2_rels`, etc. as their own CVs, or (b) update the renderer to walk multiple rels strings instead of one concatenated string.

### Bug 2: First-page-distinct headers/footers (`<w:titlePg/>`) ignored

**Symptom:** Templates with separate "first" and "default" header/footer references (set via `<w:headerReference w:type="first"/>` + `<w:headerReference w:type="default"/>`) render only the "default" pair on every page. The page-1-specific design is lost.

**What's NOT the cause:** Image extraction (extractor walks all rels).

**What IS the cause:** `DocGenHtmlRenderer.convertToHtmlWithHeaderFooter` takes a single header HTML and a single footer HTML. There's no code path that emits Flying Saucer's `@page :first { @top-center { content: element(firstHeader) } }` ruleset alongside the default `@page`. The first-typed reference gets dropped during sectPr parsing.

**Workaround:** Edit the .docx to remove `<w:titlePg/>` and consolidate headers/footers into one default pair per type. Lose page-1-specific layout, gain a working PDF.

**Real fix (v1.81+):** ~1-2 day feature. Walk all 6 possible header/footer references (default/first/even × header/footer), emit each as a `position: running()` block, and emit `@page :first` and `@page` rules pointing to the right running elements. Genuine win for Conga/Word migrations.

### Bug 3: `width:Xpx` on `<img>` not honored for floating/anchored images

**Symptom:** Renderer correctly emits `<img style="width:Xpx;height:Ypx">` per Word's wp:extent (verified above). Yet templates with high-resolution embedded images render at native pixel size in PDF, overflowing the page.

**What's NOT the cause:** wp:extent extraction (verified correct), EMU→px conversion (verified correct), CSS emission (verified correct in renderer output).

**What IS the cause (hypothesis):** Flying Saucer ignores `width:Xpx` on `<img>` tags inside floating containers (i.e., Word's `<wp:anchor>` blocks with `behindDoc="1"`, `wrapNone`, etc.). Inline images (`<wp:inline>`) probably render correctly; anchored images probably don't.

**Workaround for users:** Pre-resize source images so native pixel dimensions equal desired display size at 96 DPI. For an 8.5"-wide image at 96 DPI, native PNG should be 816 px wide.

**Real fix (v1.81+):** Investigation task. Render a known anchored image to PDF outside Apex, see if Flying Saucer emits at native or styled size. If Flying Saucer is the wall, document as a Word-template authoring constraint.

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

1. **#54 — `IsLatest = TRUE` guards on pre-decomp + image-map queries**. Prevents "entity is deleted" UNKNOWN_EXCEPTION when extractAndSaveTemplateImages runs against a template with stale (recycled) ContentVersions from a prior version. Confirmed via triple-extract regression test.

What was investigated but not fixed (deferred to v1.81.0+):

- #53 pre-decomp alignment regression (real bug, needs deeper diff)
- #57 first-page-distinct headers/footers (real feature gap, ~1-2 day lift)
- #58 Flying Saucer image width binding (investigation, may be platform wall)

What was investigated and confirmed working as designed:

- #55 wp:extent → CSS emission (already correct in renderer)
- Image extractor coverage of "first"-typed rels (already complete)
- Pre-decomp XML byte-equivalence to ZIP path (already correct)
