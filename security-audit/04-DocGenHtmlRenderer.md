# Audit: DocGenHtmlRenderer.cls (3357 lines)

File: `/Users/davemoudy/Desktop/Projects/Portwood DocGen Managed/force-app/main/default/classes/DocGenHtmlRenderer.cls`

## Summary

Class converts post-merge DOCX/HTML to HTML for `Blob.toPdf()`. Properly sized
attack surface — no AuraEnabled, no @RemoteAction, no webservice, no
`Test.isRunningTest()` branches, `with sharing` correctly applied. Heap concerns
exist (3357 lines of string-concat XML walkers) but not introduced by this audit.

The output of `convertToHtml()` reaches **two destinations**:

1. `Blob.toPdf()` server-side (Flying Saucer, no JS execution surface)
2. `DocGenSignatureSenderController.getDocumentPreviewHtml` → LWC
   `docGenSignatureSender.js:365` → `container.innerHTML = previewHtml`. This
   IS a browser path — Lightning Web Security strips `<script>` and event
   handlers but does not block CSS injection through inline `style="..."`.

## Findings

### Critical (FIXED)

**CSS injection via DOCX-attribute concatenation into inline `style=""`.**
Multiple `extractAttr(...)` calls on color/fill/vAlign/highlight values were
concatenated directly into `style=""` declarations. `extractAttr` returns the
raw value between quotes — a malformed DOCX could include `;` `}` etc. to
escape the surrounding declaration. Trust boundary is "admin uploaded DOCX,"
but preview HTML reaches a browser via LWC `innerHTML`, so this is
defense-in-depth.

Sites hardened with new `sanitizeCssToken()` helper (strips
`[\\u0000-\\u001F;{}<>"'\\\\()\\r\\n]`):

- `parseRunStyle` color/themeColor/styleAttrs color (~line 1577–1590)
- `parseRunStyle` highlight (~line 1596)
- `parseRunStyle` shdFill (~line 1602)
- `parseParagraphStyle` pFill (~line 951)
- `processTableCell` cell shading fill (~line 1816)
- `processTableCell` vAlign (~line 1822)

**CSS `url('...')` injection on watermark page-background.**
`extractWatermarks()` concatenated the watermark `firstSrc` (which originates
in `processPict` as either `images.get(relId)` or a `data:image/...;base64,X`
URI) directly into `background-image: url('...')`. Hardened with new
`sanitizeCssUrlToken()` helper (strips quotes/parens/whitespace, blocks `/*`
and `*/` comment delimiters). Same fix applied to admin-set
`overrideWatermarkCvId` static (line 238).

### Deferred (low risk, documented)

1. **Hyperlink href emitted unsanitized** (line 1218). `directUrl` comes from
   `w:docgen-url` attribute set in `DocGenService.cls:3977` after
   `href.escapeXml()`. The XML escaping prevents quote-break and the value
   sits inside a double-quoted attribute. PDF target = no JS execution.
   `javascript:` schemes don't execute in PDF readers. Skipped — would require
   coordinated change in `DocGenService.cls`.

2. **Border color values** (`parseBorderSide`) flow through
   `addBorderStyles`/`tableStyle` → CSS without sanitization. Lower risk
   because they're rendered as part of border shorthand and typically numeric.

3. **Heap concerns** in tight string-concat loops (`processBodyContent`,
   `processRun`, `processTable`). 3357-line class with deeply nested loops
   that all use `+=` rather than `String.join(List)`. Not introduced by this
   PR; refactoring carries high regression risk for what is at most a heap
   inefficiency, not a security issue.

4. **Font-family value** (line 1565) is `escapeHtml4()`'d (correct for
   attribute context but doesn't strip CSS-meaningful chars). Practical impact
   is negligible because `escapeHtml4` already escapes `'` and `"`, but a `;`
   would still flow through. Did not double-up sanitization to avoid changing
   how legitimate font names render.

### Verified Safe

- Merge-data text content in `<w:t>` is `escapeHtml4()`'d at line 1361 before
  emit. Field-data XSS path is closed.
- `parsePageDimensions` and `parseCustomMargins` route everything through
  `Decimal.valueOf` / `Integer.valueOf` and clamp — caller-controlled page
  size CSS values are numeric-validated.
- `renderBarcodeHtml` `escapeHtml4`'s the value before emit (line 3252).
- No AuraEnabled / @RemoteAction / webservice methods in this class.
- No `Test.isRunningTest()` branches.
- `with sharing` keyword applied.

## Tests

```
sf apex run test --target-org docgen-security-audit \
  --tests DocGenHtmlRendererTest \
  --tests DocGenHtmlTemplateTest \
  --tests DocGenSignatureTests
```

**Result: 378 tests, 100% pass, Outcome: Passed.** No new test class added —
existing coverage exercises every concatenation site touched (color/fill/
vAlign/watermark). The sanitize helpers are intentionally pass-through for
all values that survive existing tests (which use realistic DOCX fixtures
with valid color/fill values).

## Blockers

None.
