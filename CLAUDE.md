# CLAUDE.md — SalesforceDocGen (Bug Fix Branch)

## Mission

This branch exists solely to fix three reported bugs in v1.82.0. Do not add features, refactor unrelated code, or expand scope.

- **#47** — Rich text HTML→OOXML converter ignores `<ul>`/`<ol>`/`<li>` tags.
  Lives in `DocGenService.processInlineHtml` (~line 4262), called by `convertRichTextToDocxXml` (~line 4211). List tags fall through the catch-all and items concatenate into one paragraph.
- **#48** — Asymmetric falsy logic between `{#Field}` and `{^Field}`; neither handles "visually empty" rich text (e.g. `<p><br></p>`).
  Lives in `DocGenService.processXml`. Truthy path ~line 2839 (only checks `val != null`), inverse path ~line 2877 (uses `String.isBlank`). Reporter has filed a clean two-step fix in the issue.
- **#49** — Tables nested inside `{#Rel}…{/Rel}` loop-expanded containers render data cells as bold even when run XML has `<w:b w:val="false"/>`.
  Either (a) loop-expansion substitution in `DocGenService.processXml` (~line 2645) is dropping run properties on iteration clones, or (b) `DocGenHtmlRenderer.processBodyContent`/`processRun` applies a default bold inside nested tables. Reporter recommends diffing pre-merge vs post-merge `document.xml` for an inner data cell to disambiguate.

## Critical: three merge-tag resolution paths (relevant to #48)

`DocGenGiantQueryAssembler` does **not** call `processXml()`. A fix to section-tag logic in `processXml` only covers row-level loop bodies. Parent-level tags outside the loop are resolved by `DocGenGiantQueryAssembler.resolveParentMergeTags()`, and grand-total aggregates by `resolveGiantAggregateTags()`. If #48 needs to behave consistently for templates that fall into the giant-query path (>2000 child rows), the falsy logic has to be mirrored or routed through `processXmlForTest` the same way format-suffix tags already are. Before shipping #48, decide whether the giant-query parent path needs the same change and add an e2e-07 assertion either way.

## Critical: zero-heap PDF image rendering (don't accidentally regress)

For PDF output, `{%ImageField}` tags with ContentVersion IDs skip blob loading. `currentOutputFormat` is set to `'PDF'` before `processXml()` calls; in `buildImageXml()`, when `currentOutputFormat == 'PDF'` and value is `068xxx`, query only `Id, FileExtension` (NOT `VersionData`) and store the relative URL `/sfc/servlet.shepherd/version/download/<cvId>`. Image URLs in HTML for `Blob.toPdf()` MUST be relative — absolute URLs and data URIs render broken.

If your fix touches `processXml`, do not add `VersionData` to the PDF-path SOQL and do not prepend `URL.getOrgDomainUrl()` anywhere in the image pipeline.

## Package info

- Package: Portwood DocGen, Unlocked 2GP, namespace `portwoodglobal`
- Current shipped version: v1.82.0 (`04tal000006rKBdAAM`)
- DevHub: `Portwood Global - Production` (dave@portwoodglobalsolutions.com)
- Staging org for release validation: `portwood-staging`
- Dev scratch: `docgen-test-ux`

## Release validation checklist

All three checks MUST pass before release. No exceptions.

### 1. E2E test suite

```bash
sf apex run --target-org <org> -f scripts/e2e-01-permissions.apex
sf apex run --target-org <org> -f scripts/e2e-02-template-crud.apex
sf apex run --target-org <org> -f scripts/e2e-03-generate-pdf.apex
sf apex run --target-org <org> -f scripts/e2e-04-generate-docx.apex
sf apex run --target-org <org> -f scripts/e2e-05-generate-bulk.apex
sf apex run --target-org <org> -f scripts/e2e-06-signatures.apex
sf apex run --target-org <org> -f scripts/e2e-07-syntax1.apex
sf apex run --target-org <org> -f scripts/e2e-07-syntax2.apex
sf apex run --target-org <org> -f scripts/e2e-08-cleanup.apex
```

Each script must print `PASS: N  FAIL: 0  ALL TESTS PASSED`. Sequence: 01 standalone, 02 creates test data, 03–06 depend on 02, 07-syntax1/2 standalone (use `processXmlForTest`), 08 cleans up.

For these three bugs:

- #47 → add a `processXmlForTest` assertion in `e2e-07-syntax2` that a rich text field containing `<ul><li>a</li><li>b</li></ul>` survives merge with per-item separation.
- #48 → add assertions in `e2e-07-syntax1` for both `{#Field}` and `{^Field}` against null, empty string, whitespace, and `<p><br></p>` rich-text values. Both tags must agree on falsy.
- #49 → add a `processXmlForTest` assertion that exercises the stacked nested-loop pattern (outer 1-cell row containing `{#Rel}…{/Rel}`, inner table with header + data rows) and asserts the data row's run XML still carries `<w:b w:val="false"/>` after merge.

Each script must stay under 18,000 chars (Anonymous Apex limit is 20,000).

### 2. Apex test suite

```bash
sf apex run test --target-org <org> --test-level RunLocalTests --wait 15 --code-coverage
```

Expected: `Outcome: Passed`, `Pass Rate: 100%`, org-wide coverage ≥ 75%.

### 3. Code Analyzer

```bash
sf code-analyzer run --workspace "force-app/" --rule-selector "Security" --rule-selector "AppExchange" --view table
```

Expected: `0 High severity violation(s) found`. ~30 Moderate false positives are acceptable (see `code-analyzer.yml`).

## Out of scope

Don't touch signatures, HTML templates, watermarks, client-side DOCX assembly, font handling, command hub, or query config formats unless a bug fix forces it. Historical context for those subsystems was removed from this file in the bug-fix-branch trim — recover from `git log -- CLAUDE.md` if needed.
