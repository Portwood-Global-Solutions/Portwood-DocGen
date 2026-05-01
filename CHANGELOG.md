# Changelog

## v1.81.0 — Special characters

Promoted package: `04tal000006rKA1AAM` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rKA1AAM)

Two-part fix for special-character rendering in PDF output. Driven by a tester who saw `&#8212;` and `&#183;` render as literal text in the v1.80 showcase, plus a follow-up where the showcase template's Greek/CJK/Hebrew/Arabic lines came out blank.

### Numeric entity decoding

`DocGenHtmlRenderer.unescapeXmlEntities` now decodes numeric character references in addition to named XML entities. Adds `decodeNumericEntities()` which:

- Handles decimal (`&#NNNN;`) and hex (`&#xHH;` / `&#XHH;`) forms
- Preserves malformed sequences (`&#abc;`, `&#xZZ;`) untouched
- Skips C0 control codes (NUL, BEL) other than tab/LF/CR
- Bounded to valid Unicode range U+0000–U+10FFFF

This fixes em-dash, smart quotes, ©, ™, €, accented Latin, and any other content where the source DOCX/HTML embedded numeric entities (programmatically-generated docs, copy-paste from Notion/ChatGPT, hand-edited XML).

### Full Unicode glyph rendering

Flying Saucer's default fonts (Helvetica/Times/Courier) cover Latin-1 plus a small General Punctuation allowlist — they lack glyphs for Greek, CJK, Hebrew, Arabic, math operators, ₹ rupee, dingbats, and arrows. CSS body-level `font-family` fallback is **ignored** by Flying Saucer; only inline spans force the engine to swap fonts.

New `wrapNonLatinGlyphs()` in both `DocGenHtmlRenderer` (DOCX→PDF path) and `DocGenService` (HTML template path):

1. Walks body content (skipping markup), wraps each contiguous run of non-Latin codepoints in `<span style="font-family:'Arial Unicode MS',sans-serif;">`
2. Pre-decodes high-codepoint named HTML entities (`&pi;`, `&sum;`, `&alpha;`, ~100 entries) back to literal Unicode before scanning — `String.escapeHtml4()` upstream converts these chars to named entities, hiding them from a raw-codepoint scan
3. Allowlist for chars Helvetica DOES cover (en/em dash, smart quotes, bullet, ellipsis, dagger, trademark, euro)

Result: full Unicode renders correctly in PDF — Greek alphabet, math operators (≠ ≤ ≥ ≈ ∞ √ ∑), CJK (Chinese/Japanese/Korean), Hebrew, Arabic, ₹ rupee, dingbat suits, arrows.

### Validation

Visual proof: `docs/special-chars-proof.pdf` demonstrates em-dash, en-dash, bullet, smart quotes, ©®™§¶, currencies (€£¥¢₹), math operators, fractions, accented Latin, Greek, CJK, Hebrew, Arabic, plus edge-case preservation.

- RunLocalTests: 1183/1183 (100% pass, 75% org-wide coverage)
- Code Analyzer: 0 High violations, 41 Moderate (known false positives)

### Upgrade notes

Drop-in upgrade. No breaking changes, no data model changes, no permission set updates. Customers running v1.80.0 can install directly. Only renderer-internal helpers added; existing templates render exactly as before for all already-supported characters, with broader Unicode now correctly rendering instead of falling back to empty glyph boxes.

## v1.80.0 — Word fidelity

Promoted package: `04tal000006rJkDAAU` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rJkDAAU)

A targeted release polishing Word→PDF rendering fidelity, plus two GitHub-issue cleanups (#42 packet naming, #46 image aspect) and a UX simplification on the signature sender. Driven by reviewing real-world DOCX samples (Apex Surveys quotation, Conga-style proposals) where Flying Saucer was producing visibly-off output even though the rendering pipeline reported success.

### Word-fidelity fixes

Four bugs that all shipped together because they share the same XML-parsing surface area:

- **#53 — LibreOffice RTL false-positive.** `<w:bidi w:val="false"/>` was being treated as RTL because the renderer matched on element presence (`<w:bidi `) rather than value. Touched 11 sites across `DocGenHtmlRenderer.cls`; consolidated through one helper `isOoxmlOnOffElementTrue(xml, elementName)` that parses `w:val` per ECMA-376 §17.17.4 (treats `false`, `0`, `off` as off; default-on when omitted).
- **#56 — Pre-flight overflow warning.** Templates with images sized larger than the section's content area would silently render clipped. Added `DocGenService.logImageOverflowWarnings()` which walks `wp:extent cx/cy` against `pgSz` minus `pgMar` and writes a Job Log entry naming the offending image and the overflow amount in inches.
- **#57 — First-page-distinct headers/footers.** Section properties marked `<w:titlePg/>` weren't differentiating type=`first` references from type=`default`. Combined-XML construction in `combineXmlWithHeadersFooters` now buckets header/footer fragments by sectPr type, and Flying Saucer's `@page :first` margin boxes pick the right `position: running()` flow.
- **#58 — Image dimension binding.** `<wp:extent cx="..." cy="..."/>` values were carried into HTML as CSS-only sizing, which Flying Saucer interprets at 96 DPI even when the EMU values were calibrated for 72 DPI. Added explicit `width="N" height="N"` attributes alongside the CSS so the PDF engine has the same answer from both directions.

While fixing #57 also caught a one-line trap in `mapHeaderFooterTypes`: Apex `String.substringAfterLast('/')` returns the **empty string** when the separator is absent, not the original string. Header rels with bare filenames (`header1.xml`, no path) were collapsing every entry to the same empty key. Now guarded.

### #46 — Image aspect-ratio preservation on PDF (Joe)

Single-axis Word images (e.g. `cx="3000000"` with no `cy`, or `data-max-width-px="600"` with no height) were being rendered at the missing axis's _page-content area_, which stretched portrait images into squares on PDF. New `DOCGEN_AUTOSIZE` marker emitted from `DocGenService.buildImageXml` when only one axis is fixed; `processDrawing` resolves it through the image's intrinsic dimensions before final layout.

### #42 — Packet document naming with merge tokens

New field `DocGen_Signature_Request__c.Document_Title_Format__c` — Text(255) supporting merge tokens like `{Account.Name} - MSA - {Today}`. Resolved at PDF-stamp time by `TemplateSignaturePdfQueueable` via `DocGenService.loadRecordDataForTitle()` + `generateDocTitle()`. Falls back to template title when blank. Wired through both single-template and packet paths via two new sender methods (`createTemplateSignerRequestWithTitle`, `createPacketSignerRequestWithTitle`); old methods preserved as backward-compat wrappers passing `null`. Added to all three permission sets.

### Sender UX — simpler role pills

Curated picklist of common signer roles is gone. Pill suggestions in `docGenSignatureSender` now derive **only** from `{@Signature_Role:N:Type}` placements detected in the actual template. Rationale: the curated list was creating noise on templates with non-standard roles; pulling from the document is what users actually want.

### Showcase template

`docs/v180-showcase.docx` — a from-scratch OOXML showcase demonstrating all four word-fidelity fixes in a single render. Built by `scripts/build-v180-showcase.py` (Python, no external deps). Companion writeup in `docs/v180-showcase.md` walks through each fix with before/after PDF stills.

### Validation

- E2E: 196/196 across all 10 scripts
- RunLocalTests: **1141/1141** (100% pass, **75% org-wide coverage**)
- Code Analyzer: 0 High violations
- Manual rendering: Apex Surveys quotation template + new showcase template, both producing pixel-aligned PDFs

### Upgrade notes

Drop-in upgrade. One new field (`Document_Title_Format__c`) with permission set updates already in the package; no migration steps. Customers on v1.79.0 can install directly.

## v1.79.0 — Sprint NY hotfix

Promoted package: `04tal000006rD8XAAU` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rD8XAAU)

Two field-reported bugs fixed in a combined release. Both were blocking real users.

### Fix 1 — Object picker no longer hides standard objects behind namespaced lookalikes

Reported at the NY Sprint (April 2026): a customer using a payment-processor managed package that ships ~30 namespaced `Opportunity_*` custom objects could not select the **standard** Opportunity object in the template wizard. The picker rendered the first 12 alphabetical `*_Opportunity_*` matches and stopped — no "see more," no API-name typeahead. Customer was completely blocked.

**Fix:** new ranking algorithm in `docGenAdmin._filterObjects` — exact match → standard object with API/label prefix → custom object prefix matches → contains. Standard objects (no `__` in API name) always rank above custom on otherwise-tied scores. Result cap raised 12 → 50, dropdown scroll surface 200px → 380px, and a green **Standard** pill on standard-object rows so users can visually distinguish `Opportunity` from `CnP_PaaS__Opportunity_*` at a glance.

### Fix 2 — Single verification certificate per packet

Reported by Dustin Bystrom (April 2026): when sending a multi-template signature packet (MSA + SOW + NDA bundle), the verification certificate was appearing after **every** template instead of once at the end of the packet.

**Root cause:** `DocGenSignatureService.renderPacketSignaturePdf` concatenates one full `<html>...</html>` per template (each with its own `</body>`), then injected the verification block via `String.replace('</body>', verifyBlock + '</body>')`. Apex `String.replace` replaces **all** occurrences — so a 5-template packet had 5 verification blocks, one wedged into the body of every doc except the last.

**Fix:** new `injectVerifyBlockBeforeLastBody()` helper uses `lastIndexOf('</body>')` + substring-splice to insert the block exactly once before the final `</body>`. Both packet and single-template paths now route through the helper.

### Note on v1.78.0

v1.78.0 was built as an internal artifact (`04tal000006rD5JAAU`) carrying only the packet verification fix, but **was not promoted**. The Sprint NY object-picker bug landed before it could ship, and rolling both fixes into v1.79.0 saved customers from a back-to-back release. v1.78.0 is unavailable for install; subscribers should upgrade directly from v1.77.0 to v1.79.0.

### Validation

- DocGenSignatureTests: 260/260 pass (4 new tests pin the verification-block helper behavior)
- E2E: 196/196 across all 10 scripts (existing) + manual smoke-test of the picker ranking
- RunLocalTests: 1123/1123 (100% pass, 75% org-wide coverage)
- Code Analyzer: 0 High, 41 Moderate

### Upgrade notes

Drop-in upgrade. No breaking changes, no data model changes, no required permission set updates. Customers running v1.77.0 can install directly. Subscribers on v1.78.0-beta (if any) — re-install v1.79.0 over the top.

## v1.77.0 — Running-user merge tags

Promoted package: `04tal000006rCxFAAU` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rCxFAAU)

### New: `{RunningUser.X}` standard merge tags

Adds a built-in `{RunningUser.X}` namespace that resolves against the **executing user's** record (whoever clicks Generate, runs the Flow, or owns the bulk job). No configuration — works on every template, every record, every output format. Use it for "Prepared by:" lines, sender contact info, or audit stamps.

```
Prepared by: {RunningUser.Name}
Email:       {RunningUser.Email}
Title:       {RunningUser.Title} · {RunningUser.Department}
Phone:       {RunningUser.Phone}
```

**Allowlist (23 fields):** `Id`, `Name`, `FirstName`, `LastName`, `Email`, `Username`, `Alias`, `Title`, `Department`, `CompanyName`, `EmployeeNumber`, `Phone`, `MobilePhone`, `Extension`, `Fax`, `Street`, `City`, `State`, `PostalCode`, `Country`, `TimeZoneSidKey`, `LocaleSidKey`, `LanguageLocaleKey`. Any field name not on this list resolves to empty by design (defense in depth — signed templates can't be edited to leak arbitrary User columns).

**Where it works:** sync generation, bulk runs, giant-query PDFs (headers/footers/title blocks), Flow-triggered docs, HTML templates. The User row is queried **once per transaction** and cached, so a 60K-row PDF with `{RunningUser.Name}` in the header costs one extra SOQL total. Format suffixes from §6.2 of the User Guide all apply.

**Case-insensitive:** `{runninguser.name}` resolves the same as `{RunningUser.Name}`.

### Drive-by fixes

Repositioned NOPMD suppressions in `DocGenDataRetriever` (lines 473, 1137) so they survive prettier-plugin-apex's trailing-comment normalization. Code Analyzer now reports 0 High violations across the workspace; previously the suppressions drifted off the violation line on every commit and the Highs would re-appear.

### Validation

- E2E: 196/196 across 10 scripts (new `e2e-07-syntax3.apex` script for user-context tags)
- RunLocalTests: 1113/1113 (100% pass, 75% org-wide coverage)
- Code Analyzer: 0 High, 41 Moderate

### Upgrade notes

Drop-in upgrade from v1.76.0. No breaking changes, no data model changes, no required permission set updates. Existing templates render exactly as before; new templates can use `{RunningUser.X}` immediately.

## v1.76.0 — Domain migration hotfix

Promoted package: `04tal000006rCu1AAE` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rCu1AAE)

**Single-purpose hotfix.** Fixes the in-app Community link that v1.75.0 customers see in the DocGen Command Hub sidebar. After v1.75.0 was promoted, the company website moved from `portwoodglobalsolutions.com` to `portwood.dev` and the Community page route changed from `/DocGenCommunity` to `/community`. The LWC source was updated on `main` but not folded into a package version, so v1.75.0 subscribers were clicking a path that no longer existed on the new domain (404).

Customers running v1.75.0 should upgrade to v1.76.0 to restore the in-app Community link. No other code changes vs 1.75.0 — security hardening, IDOR fixes, admin gates, etc. all already shipped in v1.75.0 and remain.

## v1.75.0 — AppExchange security review hardening

Promoted package: `04tal000006rCZ3AAM` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rCZ3AAM)

Comprehensive line-by-line audit of every guest + AuraEnabled surface in preparation for AppExchange Security Review. Customer impact: tighter authorization on every Apex endpoint, public preview links now expire after 48 hours, every signature-page CV fetch is bound to the signing token's request context, and a handful of XSS / SQLi / CSS-injection defense-in-depth fixes.

### Critical security fixes

- **`DocGenSignatureController.getImageBase64`** — IDOR closed. A valid signing token previously granted access to any ContentVersion in the org by Id. Now the requested CV must be one of: the signer's request source document, a version-scoped template image (`docgen_tmpl_img_<versionId>_*`), or an HTML-template image (`docgen_html_img_<templateId>_*`). Anything else returns "Image not authorized for this signing session".
- **`DocGenSignatureController.getOrCreatePublicLink`** — public ContentDistribution preview links now expire after 48 hours (matching the signing token lifetime) and disable original/PDF download. Previously these links never expired.
- **`DocGenSignatureController.convertSignatureRequestToPdf`** — cross-template image collision closed. The `docgen_tmpl_img_*` lookup is now scoped to the request's active template version (was unscoped with a `LIMIT 50`), so an `rId1` from template A can't shadow `rId1` from template B in the wrong PDF.
- **`DocGenController` — six IDOR fixes**: `getContentVersionBase64`, `deleteContentVersionDocument`, `getContentVersionSize`, `saveWatermarkImage`, `clearWatermarkImage`, `saveHtmlTemplateImage`, `saveHtmlTemplateBody` now USER*MODE-first with SYSTEM_MODE fallback gated to `docgen*\*` managed files. A logged-in user can no longer read or delete arbitrary CVs by Id.
- **`DocGenAuthenticatorController`** — strict input validation. `verifyDocument` requires a 64-char hex SHA-256 digest; `verifyByRequestId` requires a 15- or 18-char alphanumeric Salesforce Id. Malformed inputs return early without ever reaching SOQL. Dead `Error_Message__c` column removed from the audit query.
- **`DocGenSetupController`** — admin gate added to `getOrgWideEmailAddresses` and `validateSignatureSetup`. Previously any logged-in user could enumerate all Org-Wide Email Addresses; now requires `DocGen_Admin_Access` permission or admin profile.
- **`DocGenSignaturePdfTrigger`** — SOQL bulkified out of the trigger loop (single template-name lookup before the per-event loop, was per-event). Sequential next-signer email now writes `Email_Status__c` (was missing the `requestId` arg).
- **`DocGenGiantQueryAssembler` / `DocGenGiantQueryBatch`** — `lookupField` validated against child object schema before SOQL build (was only `escapeSingleQuotes`'d). V3 scout fallback `whereCls` routed through canonical sanitizer.
- **LWC `docGenSignatureSender.handleShowPreview`** — XSS closed. Template name and error message now escaped before `innerHTML` assignment.

### Defense-in-depth hardening

- **`DocGenSignatureEmailService`** — `escapeHtml()` now escapes apostrophe; brand color hex regex with safe `#1589EE` fallback so admin-supplied CSS can't break out of `style=""`.
- **`DocGenHtmlRenderer`** — new `sanitizeCssToken` / `sanitizeCssUrlToken` helpers applied to every CSS-attribute concatenation site (color, themeColor, highlight, shdFill, pFill, cell shading, watermark URL). Browser preview path is the trust boundary; PDF rendering is server-side via Flying Saucer.
- **`DocGenService`** — NPE guard in `mergeTemplateForGiantQueryPdf`; `Security.stripInaccessible` on `extractAndSaveHtmlTemplateAssets` ContentVersion DML.
- **`DocGenDataRetriever`** — V3 scout `lookupField` allowlist-validated (was only escape-quoted). NOPMD placement corrected on two `Database.countQuery` calls so PMD's ApexSOQLInjection check resolves clean.

### Quality gates

- **0 High Code Analyzer violations** across the workspace (was 4 pre-fix). 41 Moderate findings remain — all documented false positives in `code-analyzer.yml` (intentional event bubbling in `docGenTreeNode`; `pmd:ProtectSensitiveData` mis-flagging `Signer_*` and `Signature_*` fields as auth tokens).
- **1139 / 1139 Apex tests pass**, 75% org-wide coverage.
- **188 / 188 E2E assertions pass** across all 9 release-validation scripts.
- **23 new security-focused tests** added across 4 test classes (3 new: `DocGenAuthenticatorControllerTest`, `DocGenSetupControllerTest`, `DocGenDataRetrieverSecurityTest`; 1 expanded: `DocGenSignatureTests`).

### CI improvement

GitHub Actions `format-check.yml` workflow expanded to run on every push and every PR (was main-only). Catches Prettier failures at PR review time rather than at release-prep, surfacing prettier-plugin-apex parser bugs before they accumulate. The pre-existing `verifyPin` parser bug (CxSAST comment wedged between `@AuraEnabled` and `@RemoteAction`) was caught and fixed during this release as a concrete example.

### Architectural deferrals (documented; not fixed this release)

These are flagged in `security-audit/00-SUMMARY.md` and require deliberate architectural decisions, not silent agent fixes:

1. Two-path signature creation consolidation in `DocGenSignatureSenderController` (LWC vs Flow methods duplicate ~80% of logic).
2. Flow action throw-vs-catch unification across `DocGenFlowAction` / `DocGenBulkFlowAction` / `DocGenGiantQueryFlowAction`.
3. Giant Query system-vs-user context decision (async runs as Automated Process; document or impersonate).
4. `Test.isRunningTest()` bypass refactor in `DocGenSignatureController.captureClientIp` / `convertSignatureRequestToPdf` and `DocGenService.renderPdf`.
5. `Database.update(..., false, AccessLevel.SYSTEM_MODE)` allOrNothing=false review for state-correctness paths (signer status transitions especially).

None block AppExchange re-review — they're tech-debt sweeps for a future minor.

### Per-file findings

Eight detailed audit reports under `security-audit/`:

- `00-SUMMARY.md` — overview + deferral list
- `01-DocGenSignatureController.md`
- `02-DocGenService.md`
- `03-DocGenDataRetriever.md`
- `04-DocGenHtmlRenderer.md`
- `05-DocGenGiantQuery.md`
- `06-LWC.md` — full LWC → Apex call inventory
- `07-RemainingServiceClasses.md` — Batch / MergeJob / TemplateManager / DataProvider / BarcodeGenerator

## v1.74.0 — Async template decompose, 10 MB upload guard, 2-step Save to Record, Flow doc title fix

Promoted package: `04tal000006rBTJAA2` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rBTJAA2)

### Bug fix — Flow Document Title input is now honored

`DocGen Generate Document` Flow action accepted a `Document Title` input but the resulting file always used the template default. Threaded the title through both branches of the invocable into a new `DocGenService.generateDocument(templateId, recordId, outputFormatOverride, documentTitle)` overload. Verified end-to-end with a regression test in `DocGenMiscTests` and an `e2e-05` assertion. (Bug #41 — reported by Joe.)

### Bug fix — Save to Record button no longer hidden, and DOCX corruption fixed

The runner used to hide Save to Record for Word/Excel/giant-query templates and offer a runtime "Output As" picker that produced corrupt files in either direction (PDF template → Word output → Word reported "file is corrupt"; Word template → PDF override → 6 MB sync heap blow on real templates). Both removed:

- **Output As picker is gone.** Templates render in whatever format they were saved with — one template, one output. Customers needing both formats save the template twice. Cross-format generation was a recurring source of subtle bugs and the cleanest fix was to make output binding.
- **Save to Record is always offered** for every output format (PDF, DOCX, XLSX). The Aura RPC inbound cap (~5 MB) means client-assembled DOCX/XLSX above 5 MB can't round-trip back to a single ContentVersion — those drop into a clean **2-step flow**: file downloads to the user's machine + a "drag the downloaded file here" panel appears under the Generate button with `lightning-file-upload` bound to the record. Native uploader handles up to 2 GB, no heap involved. (Bug #40.)

### Feature — Async template decomposition (Queueable)

Save-time `extractAndSaveTemplateImages` was running inline in the LWC Save flow's 6 MB sync heap. Real-world templates above ~3 MB silently failed pre-decomposition (try/catch swallowed the heap exception), leaving every PDF generation falling through to the heap-heavy full-ZIP path. Now wrapped in `DocGenTemplateDecomposeQueueable` (12 MB async heap). Skipped the `getTemplateFileContent` base64 round-trip (was putting ~12 MB of redundant string in heap), reads the CV's `VersionData` directly as a `Blob`, dropped the `allEntries` map (held every entry simultaneously), and skips extracting unused entries (`theme.xml`, `settings.xml`, `fontTable.xml`, etc.).

New `Pre_Decomposition_Status__c` picklist field on `DocGen_Template_Version__c` — `Pending` / `Complete` / `Failed`. Set by the Queueable on completion so admins can spot a failed decompose instead of debugging "why is my PDF blank?" later. Granted in `DocGen_Admin` (editable) and `DocGen_User` (read-only) perm sets, surfaced read-only on the Version page layout under Version Details.

### Feature — 10 MB upload guard with friendly Compress Pictures hint

`.docx` / `.pptx` template uploads above 10 MB are rejected at upload time with a toast pointing to the **Compress Pictures → Email (96 ppi)** workaround in Word — most 20 MB templates drop to under 2 MB with no visible quality loss. The orphan `ContentVersion` from the rejected upload is auto-deleted. Hint text appears under the picker so users see the limit before they pick a file.

### UX — Document Packet existing-PDFs picker now appears

Toggling "Include other PDFs from this record" used to do nothing — the checkbox set a flag but the picker UI was never rendered. Added a `lightning-dual-listbox` that appears below the toggle when on, fetches the record's PDFs via `getRecordPdfs`, and a friendly empty-state message when the record has no PDFs.

### UX — Combine PDFs and Document Packet are Download-only

Both flows merge multiple PDFs in the browser. Save to Record would round-trip the merged bytes through Aura's 5 MB inbound cap (collapses for any non-trivial packet) AND duplicate content already on the record. The Output Destination toggle in those two modes shows only Download.

### UX — Always-visible Save to Record + better size hints

- Save to Record pill is no longer hidden by output format or giant-query mode.
- Pre-generation hint under the Output Destination toggle reads "Files under 5 MB save to the record automatically. Larger files will download to your computer and a drag-and-drop upload box will appear so you can attach the file in one extra step." — only shown for non-PDF output (PDF generation is fully server-side, no Aura ceiling).

### Docs

`UserGuide.md` §13.8 added — comprehensive template & output size guidance with a tradeoff table per generation flow. §4.1 updated with the one-template-one-output model and a 10 MB upload note.

### Code Analyzer cleanup

Resolved 3 pre-existing High severity findings (`pmd:ApexSOQLInjection` × 2, `pmd:ApexCRUDViolation` × 1) by moving `// NOPMD` comments onto the violation lines so PMD actually honors them. False positives all along — dynamic queries are protected by `Schema.describeSObjects()` allowlist + `USER_MODE`, and the OWA query is read-only system metadata in an admin-only AuraEnabled — but they're now suppressed properly so future releases pass cleanly.

---

## v1.73.0 — Subscriber Apex API + Prettier baseline + e2e fixes

Promoted package: `04tal000006rAYrAAM` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rAYrAAM)

### Feature — `DocGenService` and `DocGenException` are now `global`

Subscriber Apex can now call DocGen directly. Six methods + the exception class are exposed in the `portwoodglobal` namespace:

| Method                                                                                   | Purpose                                                             |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `generateDocument(Id templateId, Id recordId)`                                           | Generate, save as File on the record, return ContentDocumentId.     |
| `generateDocument(Id templateId, Id recordId, String outputFormatOverride)`              | Same, with `'PDF'` / `'Word'` / `'PowerPoint'` / `'HTML'` override. |
| `generatePdfBlob(Id templateId, Id recordId)`                                            | Render a PDF in-memory without saving.                              |
| `generateDocumentFromData(Id templateId, Id recordId, Map<String,Object> data)`          | Skip the per-record SOQL, use the supplied data map.                |
| `generatePdfBlobFromData(Id templateId, Map<String,Object> data)`                        | Render PDF from a caller-built map — no SOQL, no recordId required. |
| `generateAndSaveFromData(Id templateId, Id attachmentRecordId, Map data, String format)` | Build wrapper → render → attach in one call.                        |

`portwoodglobal.DocGenException` is now catchable by name from subscriber code.

```apex
// Trigger PDF generation from an approval process
Id contentDocId = portwoodglobal.DocGenService.generateDocument(
    System.Label.Invoice_Document_Template_Id,
    invRecordId
);

// Render in-memory and email without ever creating a File
Map<String, Object> result = portwoodglobal.DocGenService.generatePdfBlob(templateId, oppId);
Blob pdf = (Blob) result.get('blob');
```

**Security note:** the `…FromData` overloads accept a caller-supplied data map and bypass DocGen's SOQL boundary. Calling code is responsible for FLS/CRUD enforcement on values it places in the map. See UserGuide section 10A.1 for the full contract.

This was always documented as available (UserGuide section 10A.1 listed the methods since 1.50) but the underlying class was declared `public`, so subscriber Apex got `Type is not visible: portwoodglobal.DocGenService` on every call. Joe (external tester) hit it first; this release closes the doc/code gap.

### Tooling — Prettier baseline pinned and enforced

Repository now pins formatter versions and enforces them on every commit and PR:

- `package.json` ships `prettier@3.8.3`, `prettier-plugin-apex@2.2.6`, `@prettier/plugin-xml@3.4.2` as exact-pinned devDependencies. `package-lock.json` committed for full reproducibility.
- `.husky/pre-commit` runs `lint-staged` so prettier formats staged files automatically. Drift becomes structurally impossible.
- `.github/workflows/format-check.yml` runs `prettier --check` on every PR. Build fails if any file isn't prettier-clean.
- 333-file format-everything sweep applied across `force-app/`, `scripts/`, and root markdown to establish the baseline.

Existing contributors don't need to do anything — `npm install` after pulling sets up the hooks via the `prepare` script. Any `prettier --write` from any machine now produces identical output.

### Test infra fixes

Three pre-existing e2e test bugs surfaced when validating against a clean staging org:

- **e2e-03** — filtered-subset template body had orphan text inside `<tr>` (outside any `<td>`). Flying Saucer's strict parser rejected it as `Internal Salesforce.com Error`. Template body restructured to put marker text in `<div>` containers.
- **e2e-07** — script grew to 33,207 chars, exceeding Anonymous Apex's 20,000-char limit. Split into `e2e-07-syntax1.apex` (sections 1–29) and `e2e-07-syntax2.apex` (sections 30–53).
- **VML watermark assertion** — checked for an intermediate `docgen-watermark` div that the renderer correctly converts into `@page background-image` CSS in the final pass. Assertion updated to match the shipping output.

None were code regressions — all three are test-side bugs that were latent because the scripts had never been run against a clean org without accumulated state.

### Coverage

`DocGenZeroCoverageTest` added to cover three previously uncovered classes (`DocGenException`, `HeapPressureException`, `DocGenPdfSaveQueueable`). Org-wide coverage 75.06% (was 73% before, blocking promote).

### Contributors

Two community PRs landed in this release, with full commit attribution preserved:

- [@anushpoudel](https://github.com/anushpoudel) — [PR #36](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/pull/36) (Prettier configuration baseline) + [PR #35](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/pull/35) (configurable `docGenRunner` visibility options for FlexiPage / Flow embeds).

## v1.72.0 — Nested IF blocks + AND/OR/NOT + empty-rel totalSize + bare-boolean IF

Promoted package: `04tal000006r0xiAAA` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006r0xiAAA)

Three IF/relationship bugs surfaced by Joe (external tester) when building a nontrivial Work Order template with multiple conditionally-visible sections. All three are pre-existing — the v1.69 IF-operator fix made nontrivial IF templates viable, which made these latent bugs reachable.

### Bug 1 — Nested `{#IF expr}` blocks paired incorrectly

`DocGenService.findBalancedEnd` matched openers with `content.equals('#' + key)`. When `key == 'IF'` and the opener is `{#IF Field != 0}`, the content equals `#IF Field != 0` — not bare `#IF` — so the depth tracker never incremented past 1. The first `{/IF}` the function found (the inner one) got returned as the outer's match, the parser desynced, and runtime threw `Malformed loop tag: missing closing "" for ""`.

Fix: `findBalancedEnd` now branches on `key == 'IF'` and matches openers by prefix (`#IF`, `#IF `, `^IF`, `^IF `). Closer remains exact-equals `/IF`. All other keys keep exact-equals matching, so non-IF balancing is unchanged.

### Bug 2 — `{Rel.totalSize}` resolved to null (not 0) when SOQL child subqueries returned zero rows

`record.getPopulatedFieldsAsMap()` strips empty child relationships. The V1 and V2 retriever paths called `mapSObject(parent)` and exited — the empty rel never made it into the data map. So `{Rel.totalSize}` resolved to null, `{#IF Rel.totalSize != 0}` compared `'' != '0'` (truthy via string fallback) and rendered the body that should have been suppressed.

Fix: V1 (`getRecordData`) and V2 (`getRecordDataV2`) now synthesize `{records:[], totalSize:0}` wrappers for every declared subquery / junction relationship not present after `mapSObject`. The synthesis runs before `stitchGrandchildren` and `stitchJunctionTargets` so deeper levels still work as before. V3 was already correct (`processChildNodes` writes empty wrappers explicitly when no rows return); no V3 changes needed.

### Bug 3 — Bare-boolean `{#IF FieldName}` and `{#IF FieldName == true}` always evaluated false

Discovered while writing smoke tests for Bug 1. Two sub-bugs in `evaluateIfExpression`:

- The operator parser returned `false` unconditionally when no operator was present in the expression. So `{#IF Active__c}` (a bare boolean reference) never rendered its body.
- The operator list `['!=', '>=', '<=', '=', '>', '<']` checked `=` before `==`, so `==` got matched as `=` against the wrong byte position — `Active__c == true` parsed as field=`Active__c`, op=`=`, value=`= true`. Always false.

Fix: when no operator parses, the expression is treated as a single field reference and evaluated with truthy semantics — Boolean direct, lists/records-wrappers truthy when non-empty, null/blank/`'false'`/`'0'` falsy, everything else truthy. `==` added to the operator list before `=` so it matches first.

### Feature — `AND` / `OR` / `NOT` / parens in IF expressions

The IF expression evaluator was previously single-comparison only — `{#IF A AND B}` silently parsed as `field=A, op=AND, value=B` and evaluated false. Templates with multiple conditions had to nest IFs (for AND) or duplicate content (for OR).

v1.72 ships a real recursive-descent parser supporting:

- Word-form `AND` / `OR` / `NOT` (case-insensitive, word-boundary detection)
- Symbolic form `&&` / `||` / `!`
- Parentheses for grouping and precedence override
- Standard precedence: `NOT` (highest) → comparison → `AND` → `OR`
- Arbitrarily long chains: `(C1) OR (C2 AND C3) OR (C4)` works natively
- Quoted-string contents opaque — `'big AND small'` is preserved as a literal

Usage examples:

```
{#IF Amount > 100000 AND Stage = 'Closed Won'} … {/IF}
{#IF Stage = 'Closed Won' OR Stage = 'Closed - Pending Funding'} … {/IF}
{#IF NOT IsPrivate__c} … {/IF}
{#IF (Region = 'NA') OR (Region = 'EU' AND Tier__c = 'Gold')} … {/IF}
```

Existing single-comparison IFs are unchanged — they tokenize to one TERM and skip the recursive descent.

### Tests

Six new assertions in `scripts/e2e-07-syntax.apex`:

- `NESTED IF (both true)` / `(inner false)` / `(outer false)` / `(triple)`
- `EMPTY REL totalSize` (returns 0)
- `EMPTY REL IF` (suppressed)
- `EMPTY REL render` (renders `[0]`)

Plus `scripts/smoke-v172.apex` with 9 assertions covering all three bugs end-to-end.

### Template lint script

`scripts/docgen-template-lint.js` (Joe's contribution) bundled into the repo. Pure-JS, no dependencies, runs against a `.docx` file pre-upload to catch fragmented merge tags, loop pairing issues, structural placement problems, and 9 named anti-patterns including the nested-IF and entity-encoded operator bugs (so templates stay portable to customers on older versions).

### Credit

All three bugs reported by **Joe** with full code traces, fix sketches, and repro test cases. The lint script bundled with the package is his contribution. Excellent bug report.

---

## v1.71.0 — Checkmarks & Symbols (Wingdings → Unicode auto-translate)

Promoted package: `04tal000006r0jBAAQ` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006r0jBAAQ)

Word checkboxes and Unicode symbols now render reliably in PDF instead of dropping to tofu boxes.

### What changed

Salesforce's PDF engine (Flying Saucer) ships with four fonts — Helvetica, Times, Courier, Arial Unicode MS — and **cannot load Wingdings, Symbol, or any custom symbol font**. That's a platform constraint we can't move. Two parts of the rendering pipeline now work around it:

1. **Word `<w:sym>` elements** (Insert → Symbol → Wingdings 0xFE / 0xA8, Word content-control checkboxes) are translated to their Unicode equivalents (☐ ☑ ☒ ✓ ✔ ✗ ✘) at PDF render time and wrapped in an Arial Unicode MS span. Previously these silently dropped — the rels existed, the runs rendered, but no glyph appeared.
2. **Unicode symbols typed directly into templates** (Word, Google Docs, Notion, ChatGPT, raw HTML) are auto-wrapped in the same Arial Unicode MS span on output. A literal ✓ in your template now actually renders in PDF — without users having to know which font carries which glyph.

The HTML-template path (`DocGenService.wrapHtmlForPdf`) gets the same treatment, so symbols typed into Google Docs / Notion exports render the same way.

### Symbol palette

DocGen ships with a curated copy-paste palette in the User Guide and Learning Center — checkboxes, checks/crosses, bullets, arrows, stars, and common punctuation. All entries verified to render in both PDF and DOCX.

### What still doesn't work

- **Wingdings glyphs other than checkboxes** — translated codepoints cover Wingdings F0A8/F0FE/F0FD/F0FB/F0FC/F0A2 and Wingdings 2 F050–F053/F0A3/F0A4. Anything else falls back to a neutral □ placeholder rather than tofu.
- **Emoji** (😀 🎉) — out of Arial Unicode MS coverage. Not a regression; just not supported in PDF.
- **Custom decorative fonts** — same as before; generate as DOCX and open in Word.

### Files changed

- `DocGenHtmlRenderer.cls` — `<w:sym>` walker case in `processRun`, `processSym()` translator with Wingdings/Symbol map, `wrapUnicodeCheckmarks()` post-process on every text run.
- `DocGenService.cls` — `wrapHtmlCheckmarks()` applied inside `wrapHtmlForPdf` body.
- `UserGuide.md`, `docGenCommandHub.html` — new "Checkmarks & symbols (PDF-safe)" section with copy-paste palette, conditional checkbox pattern, and what-doesn't-work table.

---

## v1.70.0 — Word Table Fidelity (widths, spacing, source margins)

Promoted package: `04tal000006qyhNAAQ` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006qyhNAAQ)

PDF rendering now honors Word's table layout the way Word does — fixes a family of related symptoms (tables blowing up in landscape, totals tables stretching full-width, multi-column tables overflowing margins, flabby paragraph spacing in tight address blocks).

### Table widths now respect `<w:tblW>` types

`processTable` previously only handled `w:type="pct"`. Tables authored with `w:type="dxa"` (twips, by far the most common case) and `w:type="auto"` (shrink-wrap to content, used for right-aligned totals) silently fell through to the global `table { width: 100% }` default. In portrait that coincidentally looked right because 100% of a 6.5" container ≈ a 6.5" authored table. In landscape with a 9–10" container, tables expanded ~50% beyond their authored width, cells widened, paragraphs reflowed, rows visually grew taller. Now both branches emit the correct CSS (`width:Xpt` for dxa, `width:auto` for auto). Also fixed a latent scientific-notation bug on the `pct` branch where `50.0` serialized as `5E+1%`.

### `box-sizing: border-box` on `td`, `th`

Word's `<w:tcW>` is the OUTER cell width (including its tcMar padding). HTML's default `content-box` adds padding ON TOP of the declared width. With Word's default 5.4pt left/right tcMar, every cell rendered ~10.8pt wider than authored — multi-column tables overflowed margins by `(N cells × 10.8pt)`. Switching to `border-box` makes declared widths inclusive of padding, matching Word's semantics exactly.

### `max-width: 100%` clamp on tables

Tables authored slightly wider than the page content area (e.g. 14696 twips / 10.21" on a 10" landscape area with 0.5" margins) now shrink-to-fit instead of getting clipped at the page edge. Word silently does this; Flying Saucer didn't. The clamp is one-way — tables narrower than the container keep their authored width.

### Tight defaults: paragraph and list margins

Was: `p { margin: 0 0 8pt 0 }`, `li { margin: 0 0 2pt 0 }`, `ul, ol { margin: 0 0 8pt 0 }`. Now: all zero. Word source is authoritative — when authors want spacing between paragraphs, Word emits explicit `<w:spacing w:before/after>` (or it's resolved through styles.xml). The implicit 8pt-after default produced "flabby" output in tight address blocks and quote tables where the author had explicitly set zero spacing in Word. Templates that rely on Word's "Normal" style for spacing will continue to render with that style's spacing if it's emitted inline; templates authored tight will now render tight.

### `Page_Margins__c = 'FromSource'` honored when admin sets orientation override

When `Page_Orientation__c` is set on the template (forcing canonical landscape/portrait dims), the renderer can now honor the source DOCX's `<w:pgMar>` for margin values via the existing "From source DOCX margins" preset. Avoids the "I have to set custom 0.2,0.2,0.2,0.2 to match my Word doc's Narrow margins" workaround.

### Tests

3 new regression tests in `scripts/e2e-07-syntax.apex`: `<w:tblW>` for `dxa`, `auto`, and `pct`. Locks the widths-honored behavior across all three OOXML width types.

---

## v1.69.0 — IF Operators in Word Templates

Promoted package: `04tal000006qyB7AAI` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006qyB7AAI)

### Bug fix: `{#IF Field > 0}` always evaluated false in Word templates

`DocGenService.evaluateIfExpression()` parsed the operator without HTML-decoding the expression first. Word/OOXML stores `>`, `<`, `&` in text runs as `&gt;`, `&lt;`, `&amp;`. The expression `Step_Count__c > 0` arrived as `Step_Count__c &gt; 0`. The operator loop walked `!=`, `>=`, `<=` (no match), tried `=`, and matched the `=` _inside `&gt;`_ — producing a mangled "field part / value part" split that always fell through to a false string comparison. Affected operators: `<`, `>`, `<=`, `>=`. `=` and `!=` were unaffected (no reserved XML chars in their syntax).

Fix is one block at the top of `evaluateIfExpression`: decode `&gt;`, `&lt;`, `&apos;`, `&quot;`, `&amp;` before parsing. Reported by Joe with a complete repro and root-cause writeup; the fix matched his suggestion exactly.

3 new regression tests in `scripts/e2e-07-syntax.apex` covering entity-encoded `>`, `<`, `>=` forms.

---

## v1.68.0 — Page Setup (Size, Orientation, Margins) + Save-as-New-Version persistence fix

Promoted package: `04tal000006qt1lAAA` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006qt1lAAA)

### Admin-driven PDF page setup (size × orientation × margins)

Four new picklist/text fields on `DocGen_Template__c` (mirrored on `DocGen_Template_Version__c` for snapshot):

- **`Page_Size__c`** — Letter (default) / Legal / A4
- **`Page_Orientation__c`** — Portrait (default) / Landscape
- **`Page_Margins__c`** — Default for size / **From source DOCX margins** / Narrow (0.5") / Normal (1.0") / Wide (1.5") / Custom
- **`Custom_Margins__c`** — text "T,R,B,L" inches when Custom selected (single value applies to all sides; range clamped 0.1–3.0in)

When set, `DocGenHtmlRenderer.parsePageDimensions` resolves canonical dimensions from the (size × orientation) matrix instead of reading source DOCX `<w:pgSz>` — so admins can flip a Word template authored in portrait into a landscape PDF without re-authoring. The "From source DOCX margins" preset keeps the canonical page dims but reads `<w:pgMar>` from the source so authored margins survive (HTML templates fall back to size-default).

### `wrapHtmlForPdf` honors page setup

HTML-template PDFs now emit explicit `@page { size: <width>in <height>in; margin: ...; }` based on the renderer override statics. Backward-compat: when no override is set, falls back to the v1.61–1.67 default (`size: letter; margin: 1in`).

### LWC wizard — Step 1 Page Setup

`docGenAdmin` Step 1 of the create wizard and the edit-modal Settings tab now expose Page Orientation, Page Size, Page Margins, and (conditionally) Custom Margins comboboxes — all gated on Output Format = PDF. Both **Save Details** and **Save as New Version** persist the four fields on Template + version snapshot.

### Save-as-New-Version persistence fix

`DocGenController.getAllTemplates()` was missing the four new fields in its SOQL — so the LWC's edit-modal load fell back to default values, and Save-as-New-Version then wrote those defaults regardless of what the user chose. SOQL extended; the wired result now carries the persisted page setup correctly.

### Validation

- 1043 Apex tests passing (added `DocGenPageSetupTest` covering size×orientation matrix, margin presets, custom-margin parsing/clamping, FromSource fallback, save persistence, wired SOQL inclusion)
- 75% org-wide coverage maintained
- Code Analyzer Security + AppExchange: 0 High violations (38 Moderate baseline)
- 6-combo size×orientation MediaBox matrix validated end-to-end (Letter/Legal/A4 × Portrait/Landscape) in `e2e-03-generate-pdf.apex`

---

## v1.67.0 — V4 Apex Data Provider wizard, watermark carry-forward, IP capture hardening

Promoted package: `04tal000006qqOrAAI` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006qqOrAAI)

### V4 Apex Data Provider — wizard + edit modal + Copy-Paste Tags

The V4 `DocGenDataProvider` interface (class-backed templates that bypass SOQL) now has full UI parity with the visual query builder:

- **New template wizard, Step 1** introduces a "Data source" radio: **Salesforce records** (existing path) or **Apex class (V4 provider)**. The Apex path lets admins pick any class implementing `portwoodglobal.DocGenDataProvider`, validates it server-side, and stamps `{"v":4,"provider":"ClassName"}` into `Query_Config__c`.
- **Edit modal** auto-detects v4 templates from their Query Config and switches the Query Configuration tab into provider-picker mode without flattening config back to a default.
- **Copy-Paste Tags section** now understands v4: groups bare names under "Provider — fields", dotted-with-loop-prefix into loop sections, dotted-without into parent lookup sections — same UX customers expect for V3 query trees.
- **Save Details** and **Save as New Version** both preserve the v4 binding through round-trip — the previous code path collapsed v4 configs back to V3 default on the standard "Save Details" button.
- New `DocGenService.generatePdfBlobFromData(templateId, dataMap)` and `generateAndSaveFromData(templateId, attachmentRecordId, dataMap, outputFormatOverride)` overloads expose the runtime DTO injection path to Apex callers; both go through the same merge engine the SOQL paths use.
- See [UserGuide.md §5.4](UserGuide.md#54-apex-data-provider-v4--class-backed-templates) for the interface skeleton, walkthrough, and common patterns.

### Bulk Flow action — ID collection input

`DocGenBulkFlowAction` now accepts a `recordIds: List<String>` invocable input. When supplied, the action validates each ID (15- or 18-char Salesforce ID pattern) and AND-combines an `Id IN ('aaa','bbb',…)` clause with any existing `Where Clause`. Lets a Flow pass a Get Records collection straight into bulk generation without hand-rolling a SOQL fragment.

### `DocGenFlowAction` — JSON Data input

`DocGenFlowAction` (single-doc invocable) gained an optional **JSON Data** input. Supplying it bypasses the SOQL data retrieval entirely — the merge engine consumes the parsed Map directly. Three routing modes coexist:

1. JSON Data only → standalone PDF as ContentVersion
2. JSON Data + Record ID → render with custom data, attach to the supplied record
3. Record ID only (existing path) → SOQL retrieve + render

Unblocks Flows that need to render documents from external API responses, computed values, or cross-object aggregations without persisting to records first.

### Watermark carry-forward fix (Nathan's report)

Save as New Version was dropping the template-level watermark. `DocGenController.saveTemplate` now captures the prior active version's `Watermark_Image_CV_Id__c` in the same SELECT that deactivates it, then stamps it onto the new version. Regression test added (`testSaveTemplateWithVersion_carriesForwardWatermark`).

### Signature flow — IP capture hardening

Two distinct gaps closed:

- **Server side** — `DocGenSignatureController.saveSignature` and `declineSignature` were ignoring the `ipAddress` parameter the page was supposed to send. New `resolveClientIp(supplied)` helper validates the supplied value via IPv4/IPv6 regex (length ≤ 45) and falls back to `captureClientIp()` for guest users where `Auth.SessionManagement.getCurrentSession()` is unreachable.
- **Client side** — `DocGenSignature.page` now fetches the signer's IP from `https://api.ipify.org?format=json` on page load and threads `capturedIp` into the three remoting calls (`saveSignature`, `saveSignature` legacy fallback, `declineSignature`). Browser IP fetch happens once at session start, no per-action overhead.

### Free-text role input + suggestions

The signer-row role picker was a closed `lightning-combobox` that customers couldn't extend without re-packaging. Replaced with a `lightning-input` (free text) plus a suggestion-pills row below it: template-detected roles + curated picklist values, deduped, capped at 14. Anything typed is accepted as-is.

### Cleanup

- HTML/Excel templates no longer log the harmless `ZipFile unknown archive` warning during save. `extractAndSaveTemplateImages` now short-circuits for non-Word/PowerPoint types instead of attempting a ZIP read.
- 0 High / 0 Critical Code Analyzer violations (re-scanned post-changes).

## v1.66.0 — Filtered Subsets: multiple loops against the same relationship

Promoted package: `04tal000006qiUXAAY` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006qiUXAAY)

### Filtered Subsets

Templates can now declare multiple loops against the **same** child relationship with different filters. The classic example: an Opportunity quote with two tables — `{#Subscriptions}…{/Subscriptions}` and `{#Setup}…{/Setup}` — both reading from `OpportunityLineItems` but each with its own WHERE clause and field selection.

- **V3 query config** gained an optional `alias` field on each child node. When set, the alias becomes the merge-tag name (`{#Alias}…{/Alias}`) and the data-map key. Multiple sibling nodes can share the same `relationshipName` if their aliases differ.
- **Aggregates respect aliases**: `{SUM:Subscriptions.TotalPrice:currency}`, `{COUNT:Setup}`, `{AVG:Hardware.UnitPrice}` all scope to the alias's filtered records.
- **Empty subsets render gracefully** — outer table markup, headers, totals all stay even when zero rows match the WHERE.
- **Conditional visibility** on empty subsets via `{#IF Alias.totalSize > 0}…{:else}…{/IF}`. The data map for any alias is `{records:[…], totalSize:N}`, so IF branches cleanly off the count. Bare `{#X}{:else}{/X}` and `{^X}` don't fire for empty lists — wrap in IF to get that behavior.
- **Visual builder** support: each expanded child relationship now has a **Tag name** input next to **Filter (WHERE)**. Clicking the same related list a second time in the picker spawns a new filtered-subset slot (auto-suggested alias, fully editable).
- **Backward compatible**: existing templates with no aliases stay on V1 SOQL emit. V3 emit kicks in automatically when an alias is set or a relationship is duplicated.
- **Giant-query path** routes correctly per alias — each filtered subset gets its own scout/batch/assembler pass.

### Fixes

- `sanitizeClause` ORDER BY validator now accepts standard parent-relationship fields (`Account.Name`, `Owner.Name`, `Product2.Name`). Previously rejected silently, causing child queries to return empty.
- `editTemplateTags` getter emits `{#alias}…{/alias}` when alias is set, with section labels showing the alias for clarity.
- `_updateQueryTree` now understands V3 JSON; loop labels surface aliases instead of going blank.
- Stopped flattening V3 → V1 SOQL when loading templates for edit — preserves filtered-subset slots through the round-trip. Manual textarea formats V1 only at display time.

### Demo

Run `scripts/demo-filtered-subsets.apex` against any org with a Standard Pricebook. Builds an Opportunity with three product families, generates a quote PDF with subscription / setup / (empty) hardware tables and grand totals, attaches the PDF to the Opportunity. 11 assertions cover bleed, empty subsets, aggregates, parent tags, and currency formatting.

## v1.65.0 — First-class Watermark / Background Image tab + @page bleed rendering + signature watermark wiring

Promoted package: `04tal000006qiG1AAI` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006qiG1AAI)

### Signature flow (added during release window)

- Admin-uploaded watermark now flows through every signature path: sender preview modal, customer signing page, signed PDF (single-template), signed PDF (packet).
- Customer signing page renders the watermark via a screen-only overlay (data-URI img) so it shows behind the document; suppressed via `@media print` so it doesn't double-render in the final signed PDF (which uses the `@page background-image` mechanism).
- Watermark CV lookup runs in a `without sharing` inner class so guest signers can resolve the bytes despite no sharing access to the CV.
- Bug fix: signed-PDF was generating twice on multi-signer requests. `stampMultiSignerAndSavePdf` was publishing a duplicate platform event after `saveSignature` had already published one. Removed.

### New: dedicated Watermark / Background Image tab

Templates with PDF output now have a dedicated **Watermark / Background** tab in the template builder. Admins upload a pre-sized image; it stores as a ContentVersion linked to the active template version (`Watermark_Image_CV_Id__c`) and renders as the @page background in PDF output. Bypasses Word's Watermark dialog entirely — no VML quirks, no Scale/Washout/rotation confusion, no fighting with Flying Saucer's quirks.

Both paths now work for adding a watermark/background:

- **Option A (recommended):** Upload via the new tab in the template builder
- **Option B:** Insert via Word's Design → Watermark with these constraints — Scale **must be 100%**, Washout **must be OFF**, rotation not preserved (pre-rotate the image)

The renderer uses a single resolution path: explicit watermark CV (set by admin via the tab) takes precedence over Word VML watermark extraction. New `applyWatermarkOverride(templateId)` helper threads the override CV ID into the renderer at all 6 `convertToHtml` call sites including the bulk-generation batch path.

### @page background-image rendering

Watermark rendering rebuilt around `@page { background-image: url(...) }` instead of `position:fixed` `<div>` overlays. The previous approach was clipped at the page content area boundary (margin gap visible around the watermark); the new approach extends edge-to-edge across the full page bleed by definition (CSS Paged Media spec).

### Rendering changes

- **`@page background-image`** — extracted watermark URL is injected directly into the dynamic `@page` rule with `background-position: center; background-repeat: no-repeat; background-size: contain;`. Watermark spans the full page including margin areas.
- **CSS @page rule order** — properties (background) come BEFORE nested margin boxes (`@top-center`, `@bottom-center`). Strict parsers (Flying Saucer included) drop the entire rule if margin boxes appear first; we silently lost body content + headers when this got reversed.
- **`<v:shape>` parsing fix** — `extractAttr(pictXml, 'v:shape ', 'style')` (with trailing space) to disambiguate from `<v:shapetype>`. Previous code grabbed the shape definition's empty style instead of the actual instance with `width:Xpt; height:Ypt`.
- **VML inline-style sizing** for rich text — added `parseStylePx` to read `width:Npx; height:Npx` from rich text image style attributes (Lightning RTA stores drag-resize this way, not via `width=`/`height=` HTML attributes).
- **Watermark drawing dropped** from body DOM — no more `<div class="docgen-watermark">` injection, no more `<div class="docgen-watermark-wash">` overlay (the @page background approach replaces both).

### Documented constraints

`@page background-size` is fundamentally ignored by Flying Saucer regardless of value. We tried explicit pt, percentages, `cover`, `contain` — all render the source at native pixel size. The only way to control display dimensions is to physically resize the watermark image file before inserting in Word.

**Users should:** open watermark image in any editor → resize to intended display dimensions in pixels (e.g., 816×1056 for letter at 96 DPI) → save → insert in Word with **Scale at 100%**. Same constraint S-Docs / Conga / Nintex impose.

This is now documented in:

- CLAUDE.md (DOCX Watermarks section, "Watermark scaling is NOT supported" + dead-end matrix)
- UserGuide.md §6.10.1 (Word watermarks)
- Command Hub Learning Center (Watermarks section with step-by-step pre-resize instructions)
- Website DocGenGuide.page (Watermarks section)

### Whitewash overlay removed

Earlier versions layered an `rgba(255,255,255,0.95)` div on top of the watermark to create the "washed-out" look. With the @page background approach there's no DOM element to overlay. To get a faded watermark, users pre-fade the image file (reduce opacity to ~15-20% over white in their image editor) before inserting in Word.

## v1.64.0 — Rich text DOCX color + transparency via PDF-extract pipeline

Promoted package: `04tal000006qhYTAAY` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006qhYTAAY)

This is a polish release on top of v1.63.0's "rich text inline images in DOCX" feature. v1.63.0 shipped the path that made inline images appear in DOCX; v1.64.0 makes them appear _correctly_ — full color, alpha transparency, and respecting any drag-resize the user did in the rich text editor.

### Color preservation for RGBA PNG sources

`Blob.toPdf()` splits RGBA PNG sources into two PDF objects: a `CalRGB` color image plus a `DeviceGray` SMask alpha channel, with the color image referencing the SMask via `/SMask N 0 R`. v1.63.0's extractor took the first `/Subtype /Image` it found — which is the alpha mask, not the color — so DOCX images came through as black silhouettes of the alpha channel.

`docGenPdfImageExtractor.js` now:

- Indexes ALL image XObjects in the PDF up-front, classifying each by color space (`CalRGB`/`DeviceRGB` vs `CalGray`/`DeviceGray`) and SMask reference
- Prefers color images over grayscale (skipping SMask siblings)
- When the color image has an SMask reference, decodes both `FlateDecode` streams (color via `DecompressionStream('deflate')`), composes RGB + alpha into an 8-bit RGBA PNG (color type 6), and re-encodes via `CompressionStream('deflate')` + manual IHDR/IDAT/IEND chunks with proper CRC32

Pure browser-native — no pako or PNG library bundled. Works in Chrome 80+ and Firefox 113+ (DecompressionStream support).

### Inline-style sizing in rich text

Lightning Rich Text Area stores drag-resized image dimensions as inline `style="width:Npx; height:Npx"` rather than `width=`/`height=` HTML attributes. v1.63.0's `processRichTextImage` only checked the attributes and fell back to a 4×3 inch default for resized images, ignoring the user's chosen size.

`processRichTextImage` now also parses the `style` attribute via a new `parseStylePx` helper (handles `px` and `pt` units). When BOTH width AND height come through (attribute or style), the drawing's `<wp:docPr>` gets a `descr="DOCGEN_EXPLICIT_SIZE"` marker. `DocGenHtmlRenderer.processDrawing` reads that marker and emits exact `width:Npx;height:Npx` instead of `max-width;width:auto`, so a small native image scales up to the user's requested display size in the PDF instead of rendering tiny.

### Implementation notes for future maintainers

- **Document-like wrapper for `Blob.toPdf()`** — the `renderImageAsPdfBase64` HTML now includes text + styles around the `<img>` tag. Bare single-image renders triggered Flying Saucer's grayscale-FlateDecode encoding for color PNGs; document-style renders preserve full color via the same path that real PDF generation uses
- **Native size auto-rewrite (parked)** — a client-side helper that reads the extracted PNG's IHDR dimensions and rewrites `wp:extent` for unsized rich text images is implemented in `docGenRunner.js` (`_updateDocxImageSizeIfNotExplicit`) but currently disabled. It worked in Chrome but broke DOCX rendering for reasons we suspect are Aura return-object mutability. When no rich text style is set, the default 4×3 inch sizing applies; users resize via the editor (drag handles set the style → DOCX honors via DOCGEN_EXPLICIT_SIZE)

## v1.63.0 — Word watermarks in PDF + Lightning rich text inline images in DOCX

Promoted package: `04tal000006qZmEAAU` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006qZmEAAU)

### Word watermarks render in PDF output

Picture watermarks inserted in Word templates via Design → Watermark → Picture now extract during template save and render centered on every page of the generated PDF. Watermark image is layered with a 95% white wash overlay (`rgba(255,255,255,0.95)`) for the "washed-out" look — Salesforce's PDF engine doesn't honor CSS opacity, so we use a CSS 2.1 layered approach instead. Body text sits above via `z-index:2`.

- **VML pict parsing in `DocGenHtmlRenderer`** — added `<w:pict>` recognition alongside `<w:drawing>` in both paragraph-level and run-level parsing loops.
- **Header/footer image relId namespacing** — `DocGenService.namespaceImageRelIds` now rewrites `r:id="..."` on `<v:imagedata>` elements (in addition to `r:embed="..."` for DrawingML), scoped via `lastIndexOf('<')` so hyperlinks aren't clobbered.

**Limitations** (see UserGuide §6.10.1, Learning Center "Watermarks", CLAUDE.md): rotation isn't preserved, Word's "Washout" checkbox is ignored (we apply our own 95% wash), text watermarks (DRAFT/CONFIDENTIAL via VML textpath) aren't supported.

### Lightning rich text inline images render in DOCX output

Images pasted/inserted directly into Lightning Rich Text Area fields (stored as `0EM` ContentReference records) now embed in DOCX output via the Document Generator runner. Salesforce architecturally blocks every direct way of fetching these bytes — Apex SOQL doesn't expose 0EM, Apex callouts to rtaImage redirect-loop, frontdoor.jsp redacts the bridged session from response headers, LWC fetch fails CORS `Allow-Credentials: false`, and `<img>`+canvas extraction taints the canvas. Only one path works:

1. **Server (`DocGenController.renderImageAsPdfBase64`)** — wraps the rtaImage URL in minimal HTML, calls `Blob.toPdf()` (privileged internal resolver fetches the image), returns a single-image PDF as base64.
2. **Client (`docGenPdfImageExtractor.js`)** — parses the PDF object stream, finds the first `/Subtype /Image` XObject with `/Filter /DCTDecode`, returns the JPEG bytes directly. Pure JS, no library deps, ~100 lines.
3. **DOCX assembly** — bytes embed into `word/media/`, existing rels machinery references them.

PDF is in-memory only at every step (Apex Blob → base64 across Aura → JS Uint8Array → garbage collected). Zero ContentDocument records, zero filesystem writes, zero session ID exposure in our code, zero AppExchange security review surface.

**Limitations**: server-side preview ("Generate Sample" in template builder) still shows broken placeholders for inline rich text images — Apex has no PDF parser, only the client-side path can extract. PDF re-encodes inline images as JPEG; for pixel-perfect rendering use `{%Field}` with attached Files.

### Cleanup

- Removed deprecated `docGenImageFetcher.js` (browser fetch + canvas approach abandoned)
- Removed unused `Enable_Rich_Text_Image_Fetch__c` setting field and associated Remote Site Settings (gated callout approach abandoned)
- New `DocGenControllerTests.testRenderImageAsPdfBase64_*` unit tests (URL safety + entry-point)
- New `DocGenHtmlRendererTest.testVmlPictWatermarkRendering` covers the VML pict → watermark + whitewash flow
- E2E coverage in `e2e-04-generate-docx.apex` and `e2e-07-syntax.apex`

## v1.62.0 — HTML bulk merge fix, `{%Image:N}` HTML rendering, recursive deep-nesting stitch, Learning Center + UserGuide expansion

Promoted package: `04tal000006q929AAA` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006q929AAA)
v1.61.x subscribers should upgrade — bulk merge for HTML templates was producing blank / cut-off PDFs on v1.61.0.

### HTML template fixes

- **Bulk merge blank pages, fixed.** v1.61.0 concatenated full `<html>…</html>` per-record snippets; Flying Saucer abandoned rendering after ~10 records, producing a tiny PDF with most records missing. `DocGenMergeJob` now strips the per-snippet `<html>`/`<head>`/`<body>` wrappers, dedupes `<style>` blocks, and assembles the body content under a single outer shell before calling `Blob.toPdf`. Branches on template Type — DOCX merge is untouched.
- **Spurious "Completed with Errors" on clean runs, fixed.** NPE in the merge notification path was being caught and overwriting the job status. Captured `snippetCount` before nulling for heap reasons.
- **`generateHtmlForRecord` returned empty HTML for HTML templates.** Was routing through `DocGenHtmlRenderer.convertToHtml` which has no DOCX XML to convert for HTML-type templates. Now early-returns `mr.documentXml`. This produced the blank bulk-merge snippets in the first place.

### `{%Image:N}` + `{%FieldName}` for HTML templates

`DocGenService.buildImageXml` previously emitted DOCX DrawingML regardless of template type, which leaked as broken XML into HTML PDFs. Now emits `<img src="/sfc/..."/>` for HTML templates with the resolved ContentVersion URL or data URI. Record-attached images (`{%Image:1}`, `{%Image:2}`) and field-based images (`{%PhotoField__c}`) both render correctly now.

### Inline `data:image/...` URI extraction

Rich-text editors (Notion, ChatGPT, Apple Pages, anything with paste-from-clipboard) commonly emit `<img src="data:image/png;base64,...">`. Flying Saucer can't decode data URIs. The LWC now scans uploaded HTML for data-URI `src` attributes, uploads each base64 blob as its own ContentVersion via `DocGenController.saveHtmlTemplateImage`, and rewrites the HTML to `/sfc/...` URLs. Round-trip works for any HTML source with inline images.

### Deep-nested subquery stitching

`DocGenDataRetriever.stitchGrandchildren` previously handled one level of grandchildren only (line 1371 had a TODO: "Deep recursion beyond grandchildren not yet implemented"). It now recurses into `grandchildSpec.children` by aggregating grandchild records across all parents into one synthetic data map and re-entering the stitcher. **One SOQL per depth level** — scales to arbitrary nesting without N+1 queries. V1-flat configs like `Name, (SELECT Id, (SELECT Id, (SELECT Id FROM Level3Rel) FROM Level2Rel) FROM Level1Rel)` now populate every level. NPSP-style queries (Opportunity → Payments → GAU Allocations) are now fully supported.

### Admin UI polish

Header / Footer tab on HTML templates gained a **Show HTML** / **Show Editor** toggle per field. Flips the WYSIWYG editor to a monospace textarea showing the raw HTML — useful for setting image widths, inline styles, or markup the rich editor can't expose.

### Documentation — Learning Center + website User Guide + UserGuide.md

All four in-sync doc surfaces got substantial additions:

- **Learning Center** (in-app, `docGenCommandHub` LWC): full HTML Templates section (authoring, Google Docs zip workflow, images, headers/footers, page numbers, loops, known gaps, troubleshooting), new **Apex API Reference** section with method signatures for `DocGenService`, `DocGenController`, `DocGenBulkController`, Flow invocables, `DocGenDataProvider` interface example, and namespace prefix notes.
- **Website User Guide** (`portwoodglobalsolutions.com/guide`): previously missing Comparisons (`{#IF …}`) section, Today/Now tag examples, International Currency + Locale formatting, E-Signatures (5 subsections), and Apex API Reference — all ported to full parity with the Learning Center.
- **Managed package `DocGenGuide.page`** (ships in-org with the package): added International Currency / Today/Now / Apex API Reference.
- **`UserGuide.md`** (markdown source): new §4.7 HTML Templates (9 sub-sections) and §10A Apex API Reference.

### Tests

- `DocGenHtmlTemplateTest` 19/19 pass
- `DocGenGiantQueryTest` 39/39 pass (added `testThreeLevelNestedSubqueryStitch`)
- e2e-03 / e2e-04 / e2e-07 pass

---

## v1.61.0 — HTML templates (Google Docs, Notion, any HTML source) with header/footer + page numbers

Promoted package: `04tal000006pzu1AAA` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006pzu1AAA)
v1.60.x subscribers can install directly.

DocGen now accepts HTML as a first-class template type alongside Word, Excel, and PowerPoint. Upload a Google Docs "Download → Web Page" zip, a raw `.html`/`.htm` export from Notion / ChatGPT / Apple Pages, or anything else that produces HTML — DocGen merges it to PDF using the same merge-tag engine Word templates use.

### New template type

- `Type__c` picklist gains `HTML`. Output format is locked to PDF.
- New `Header_Html__c` and `Footer_Html__c` LongTextArea fields edited via a WYSIWYG editor with a **Show HTML** / **Show Editor** toggle for raw-source edits (image widths, inline styles, markup the rich editor can't expose).
- Accepted uploads: `.html`, `.htm`, `.zip` (Google Docs Web Page export).

### Google Docs zip handling

The LWC unzips the export client-side using a pure-JS ZIP reader (native `DecompressionStream('deflate-raw')` + manual central-directory parse, zero external dependencies). Each image is uploaded as its own ContentVersion linked to the template, and every `<img src="images/...">` reference in the HTML is rewritten to `/sfc/servlet.shepherd/version/download/<cvId>`. The zip itself never becomes a ContentVersion, so Salesforce's default File Upload Security block on `.zip` files doesn't apply. Heap stays flat regardless of template size because each image is uploaded in its own Apex call.

### Inline data URI images

Source HTML from Notion, ChatGPT, Apple Pages, or any rich-text paste often contains `<img src="data:image/...;base64,...">`. The LWC scans those URIs and uploads each as a ContentVersion, rewriting the src the same way it handles zipped image files. `Blob.toPdf()` doesn't decode data URIs, so this conversion is required for the images to render in the final PDF.

### Merge tags and loops

- Every existing merge tag works in HTML body, header, and footer — `{Name}`, `{Owner.Name}`, `{Field:format}`, `{SUM:Rel.Field}`, `{#Rel}…{/Rel}` loops, `{#IF …}`, `{:else}`, `{Today}`, `{Now}`, etc.
- `{#Rel}…{/Rel}` auto-expands to the enclosing `<tr>` or `<li>` — same smart-container behavior Word templates get for `<w:tr>` / `<w:p>`.
- `{%Image:N}` and `{%Field}` image tags emit `<img>` tags pointing at the resolved ContentVersion URL (previously leaked DOCX DrawingML into HTML output).
- WYSIWYG editors that HTML-entity-encode curly braces (`&#123;Name&#125;`) are handled — entities are decoded before merge.

### Page numbers

`{PageNumber}` and `{TotalPages}` in header/footer fields compile to Flying Saucer `@page` margin-box content CSS with `counter(page)` / `counter(pages)` calls. The tokens survive `processXml` via a passthrough (same mechanism as `{@Signature_…}`).

Limitation: Flying Saucer resolves CSS counters only inside `@page` rules, not in `::before` on DOM elements. Headers/footers that contain counter tokens render as plain text in the margin box. Headers/footers without counters keep rich HTML (images, tables, formatting) via the CSS running-element pattern.

### Giant-query PDF parity

HTML templates share the DOCX giant-query pipeline. When a parent record has >2000 child rows in a declared relationship, DocGen routes to `DocGenGiantQueryBatch` + `DocGenGiantQueryAssembler` — both now detect HTML source and skip the DOCX XML conversion. Same 60K+ row capacity, same heap bounds.

### Tests

Nineteen new Apex tests in `DocGenHtmlTemplateTest` covering body/header/footer merge, page counters, loop containers, zip extraction, giant-query PDF, and data URI round-trips. E2E-03 extended with HTML assertions. DocGen's existing DOCX giant-query tests (38) untouched and passing.

### Limitations worth knowing

- Headers/footers that combine rich content (images, tables) with page counters flatten to plain text. Use image-in-header + counter-in-footer, or vice versa.
- HTML templates don't currently support `{@Signature_…}` flows — untested.
- Bulk generation, preview modal, Flow invocable, template export/import, and version restore are wired up but haven't been explicitly validated end-to-end for HTML.

---

## v1.60.0 — Correct image extension filter for `{%Image:N}`

Promoted package: `04tal000006lrGjAAI` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006lrGjAAI)
Upgrade-safety validator: passed. v1.59.x subscribers can install directly.

Tightens the extension filter used by `{%Image:N}`, the giant-query parent resolver, and the 30 MB save-to-record pre-flight. v1.59's filter included `webp` (which Salesforce's Flying Saucer PDF engine does not support — Salesforce doesn't include the twelvemonkeys imageio plugin that handles it) and excluded `bmp` + `tif`/`tiff` (both are renderable by the JDK's native ImageIO).

**Before (v1.59.0):** `png`, `jpg`, `jpeg`, `gif`, `svg`, `webp`
**After (v1.60.0):** `png`, `jpg`, `jpeg`, `gif`, `bmp`, `tif`, `tiff`, `svg`

Effect on subscribers:

- **BMP / TIFF attachments** on a record are now picked up by `{%Image:N}` and included in the 30 MB save-to-record size calculation.
- **WebP attachments** are no longer reported as image attachments by DocGen — previously they'd be fetched but render as broken images in the PDF because Flying Saucer can't decode them. The scout's size count is now accurate for what will actually render.

Docs (Learning Center, UserGuide, website guide) updated to list the new extension set.

No other changes in v1.60.0.

---

## v1.59.0 — Image aspect/rotation preservation, async Save-to-Record, 30 MB pre-flight

Promoted package: `04tal000006lrDVAAY` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006lrDVAAY)
Upgrade-safety validator: passed. v1.58.x subscribers can install directly.

Three related changes that together make image-heavy PDF generation actually usable in the field — portrait phone photos render correctly, large documents save to records without silent failure, and the UI warns up-front if the attachment size exceeds the platform ceiling.

### Image aspect ratio + EXIF orientation preserved in PDFs

Previous versions rendered attached images with hardcoded `width="X" height="Y"` HTML attributes, which squashed phone photos (3:4 portrait) into whatever fixed box the DrawingML specified (commonly 4:3 landscape — visibly distorted). v1.59 switches to CSS `max-width + max-height + height:auto` so every image preserves its intrinsic aspect ratio, up to the declared bounds. Also added `image-orientation:from-image` so sideways-stored phone photos (EXIF `Orientation:6/8`) render upright. End result: `{%Image:1}` on a portrait inspection photo now looks like the photo you took, not a squashed landscape cousin of it.

### Save-to-Record runs fully async (no more "Illegal Request" on big files)

The single-call Save-to-Record path held the Aura request open through the entire render + ContentVersion insert, which for image-heavy PDFs (~15 MB+) frequently exceeded Salesforce's ~30s CSRF timeout and returned an HTML "Illegal Request" page instead of the expected JSON. v1.59 introduces:

- **`DocGenController.generatePdfAsync(templateId, recordId)`** — enqueues a Queueable that does the full server-side render + CV insert + CDL creation.
- **`DocGenPdfSaveQueueable`** — the Queueable that runs in the background. Has the full 12 MB heap and 10 minute wall-clock window of the async context.

The LWC now routes Save-to-Record through this async path for PDFs. User sees an immediate "PDF is being generated. It will appear on the record in a moment — refresh the page to see it." toast; the file lands on the record when the Queueable completes (typically 30–60 s even for image-heavy cases).

### Pre-flight 30 MB image-size check

Rather than letting Save-to-Record fail silently inside the Queueable when the record has too many/too-large attachments, the LWC now calls `DocGenController.scoutAttachedImageSize(recordId)` before enqueueing. If total PNG/JPG/GIF/BMP/TIFF/SVG attachment size exceeds **30 MB**, the user gets a sticky error toast:

> _"Cannot Save to Record. This record has 35.2 MB of attached images — above the 30 MB Save-to-Record limit. Use Download instead (no size limit), or remove some images and try again."_

Download still works at a higher ceiling for these cases.

### Documentation

- **Learning Center** (`docGenCommandHub`) — added an orange warning callout under the Images section explaining the 30 MB Save-to-Record ceiling and the Download fallback.
- **`UserGuide.md`** — added `{%Image:N}` documentation (was missing) and the 30 MB limit note.
- **Website guide** (`DocGenGuide.page` in the Portwood Website repo) — mirror of the Learning Center callout.

### Validation

- Full e2e suite still passes
- Code Analyzer Security + AppExchange — 0 High / Critical / Serious violations
- Queueable tested in DevBox: image-heavy Case (29.76 MB of photos) successfully saves PDF to record after ~5–7 s

---

## v1.58.0 — `{%Image:N}` record-attached images, textarea newline fix, mobile signing pinch-zoom

Promoted package: `04tal000006lpoPAAQ` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006lpoPAAQ)
Supersedes v1.57.0, which failed its install validator because the attempted `docGenTreeBuilder` `isExposed=true → false` change violated the managed-package upgrade rule (once a component is exposed to subscribers, you can't un-expose it in an upgrade). v1.58.0 reverts that specific change — the tree-builder component stays exposed — and ships the rest of v1.57.0 intact. v1.56.x subscribers can install v1.58.0 directly; no one successfully installed v1.57.0, so there is no v1.57 → v1.58 upgrade path to worry about.

The headline feature is a merge tag that makes images intuitive: drag a photo onto any record, write `{%Image:1}` in your template, and it renders. No ContentVersion ID field, no query-builder setup, no lookup. Plus three community bug fixes and a signing UX rework for mobile.

### New: `{%Image:N}` — record-attached images

`{%Image:N}` renders the Nth oldest image (PNG/JPG/GIF/BMP/TIFF/SVG) attached to the current record. Non-image attachments are silently skipped so a PDF contract mixed in with photos won't break rendering.

```
{%Image:1}                First image attached to the record, natural size
{%Image:1:200}            Max 200px in either dimension (preserves aspect)
{%Image:1:200x200}        Explicit 200px × 200px
{%Image:1:400x}           400px wide, auto height
{%Image:1:x150}           Auto width, 150px tall
{%Image:2}, {%Image:3}    Second, third, … attached image
```

**Inside a loop, the tag scopes to the iterating record's images**, not the parent's — ideal for inspection reports, real estate listings, product catalogs:

```
{#OpportunityLineItems}
  | {Product2.Name} | {Quantity} | {%Image:1:100} |
{/OpportunityLineItems}
```

Out-of-range indexes (`{%Image:5}` on a record with 2 images) render empty silently, so templates can set up more slots than records will always have.

**Governor-safe at scale:** a pre-scan detects `{%Image:N}` tags in loop bodies and bulk-fetches `ContentDocumentLink` for all iteration records in a single SOQL query, then resolves each iteration from an in-memory cache. 60 line items with photos = 1 CDL query, not 60. Works in `processXml` (row path), in `{#Relationship}` loops, and in the giant-query parent resolver (headers/footers/summaries) for big-volume PDFs.

Both PDF and DOCX output paths supported. PDF uses zero-heap URL references (`/sfc/servlet.shepherd/version/download/...`), DOCX uses the existing client-side ZIP assembly. No new heap limits.

### Fixed: `#32` — textarea newline loses formatting _(contributed by [@raykeating](https://github.com/raykeating))_

Multi-line textarea fields were losing their run formatting (font, size, bold, italic) on everything after the first line. The bug was in `convertMultilineToXml` emitting bare `<w:r>` runs for each `<w:br/>` without carrying the original run's `<w:rPr>` (run properties) block. Ray's fix ([PR #33](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/pull/33)) extracts the currently-open `<w:rPr>` from the output buffer and re-emits it on every line after a break. Formatting is now preserved across every line break in textarea fields, including RTL (`<w:rtl/>`) markers.

### Fixed: `#34` — `DocGenDataProvider` interface must be `global`

The Apex Provider feature (V4 query config) was completely unusable in subscriber orgs: the `DocGenDataProvider` interface was declared `public`, which makes it package-private after install. Subscribers trying to implement `portwoodglobal.DocGenDataProvider` got `Type is not visible`. Changed to `global`, unblocks the feature for all installed orgs.

### Mobile signing UX — pinch-to-zoom instead of forced shrink

Previous versions tried to shrink the merged document to fit a phone viewport — which ruined QR codes, image details, and fine print. v1.57 switches to a natural-width layout with pinch-to-zoom enabled, so signers can inspect full-fidelity content on mobile just like they would a native PDF. The action bar stays pinned to the bottom of the viewport regardless of scroll position or zoom level, with a stronger orange outline + glow on the active placement so signers can find where to sign even when zoomed out. Vertical-only auto-scroll when advancing between placements keeps the document's left edge anchored on phones.

**Recommended mobile orientation:** landscape. A Word document at natural width (~8.5") fits phone screens cleanly in landscape and gives signers room to draw/type. Portrait mode works (pinch-zoom + pan) but landscape is the expected signing posture on mobile — consistent with how most e-sign tools are used in the field.

Also on the signing stack:

- `docGenSignatureSender` LWC now supports mobile form factors (Small + Large) with responsive column layouts for signer rows, action buttons, and the preview modal.

### Validation

- **27 new Apex unit tests** in `DocGenImageTagTests.cls` — 100% pass, cover all `{%Image:N}` helpers, size parsing, cache behavior, the `#32` fix, and the giant-query parent resolver
- **e2e-09-images.apex** — new script, 8/8 pass (base-record, in-loop, out-of-range, size variants, no-attachments fallback)
- **e2e-07-syntax.apex** — 43/43 pass, includes 2 new `#32` assertions (font-size preservation + RTL preservation across line breaks)
- **Full e2e suite (9 scripts)** — 165 assertions pass end-to-end
- **Code Analyzer Security + AppExchange** — 0 High / Critical / Serious violations
- **Learning Center + Website user guide** — both updated with `{%Image:N}` documentation including in-loop examples

---

## v1.56.0 — `{Today}` and `{Now}` built-in tags + Learning Center sync

Promoted package: `04tal000006i1rNAAQ` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006i1rNAAQ)
Upgrade-safety validator: passed. v1.55.x subscribers can install directly.

Two new built-in merge tags resolve to the current date/datetime without needing a formula field:

```
{Today}                       2026-04-20 (default ISO format)
{Today:MM/dd/yyyy}            04/20/2026
{Today:date}                  Running user's locale default
{Today:date:de_DE}            20.04.2026 (German)
{Now}                         2026-04-20 14:30:00
{Now:yyyy-MM-dd HH:mm}        2026-04-20 14:30
{Now:date:ja_JP}              2026/04/20 (Now formatted as Japanese date)
```

All format suffixes from v1.50 locale formatting (`:MM/dd/yyyy`, `:date`, `:date:<locale>`) apply. Case-insensitive. Works in sync, giant-query, bulk, and e-signature stamped documents.

Also shipped:

- **Learning Center sync** — added a "Built-in Date & Time Tags" subsection under Date & Number Formatting, plus `{Today}` / `{Now}` pills in the Quick Tags gallery.
- **`UserGuide.md`** added at the project root as the source of truth for feature documentation. All future doc updates (Learning Center, website) flow from this file.
- **Stale doc fix** — template sharing section in UserGuide.md now correctly describes standard Salesforce sharing (the custom `docGenSharing` LWC was deprecated to stubs long ago; doc was catching up).

### Validation

- 968 / 968 Apex tests pass, 75% org-wide coverage
- 8 / 8 e2e scripts pass (156 assertions — 41 syntax assertions in e2e-07, up from 36, with 5 new Today/Now cases)
- Code analyzer: 0 High severity violations

---

## v1.55.0 — Try-and-retry heap fallback + PDF-aware estimator

Promoted package: `04tal000006i0thAAA` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006i0thAAA)
Upgrade-safety validator: passed. v1.54.x subscribers can install directly.

v1.54.0's heap estimator underestimated PDF output: 400 line items still blew sync heap because `Blob.toPdf()` holds the entire HTML DOM in heap while rendering (~5-10× raw XML size). Two improvements in 1.55.0:

### 1. Output-format-aware estimator constants

- **PDF**: 10 KB per row + 1 MB base overhead (accounts for `Blob.toPdf()` DOM parse)
- **DOCX / Excel / PowerPoint**: 2 KB per row + 200 KB base (server just merges XML, ships base64 to client)
- PDF giant threshold is now ~260 records; DOCX ~1700 records. Threshold still at 60% of 6 MB sync limit.

### 2. Try-and-retry fallback in the controller

`processAndReturnDocumentWithOverride` and `generatePdf` now catch **any** heap-related error — including `System.LimitException` thrown from `Blob.toPdf()` itself, which isn't our typed `HeapPressureException`. The controller returns the same `{ heapPressure: true }` signal and the runner LWC auto-retries via the giant-query batch path. When the server can't identify the giant relationship, the runner picks the largest-count child from scout cache.

Net result: customers never see a "heap size too large" error. Worst case, they see a "large dataset — switching modes" toast while the giant path takes over.

Also tightened the in-flight heap check ratio from 75% → 60% so `processXml` bails earlier, leaving more headroom for the still-pending `Blob.toPdf()` call.

### Validation

- 968 / 968 Apex tests pass, 75% org-wide coverage
- 8 / 8 e2e scripts pass (151 assertions)
- Code analyzer: 0 High severity violations

---

## v1.54.0 — Heap-aware giant-path auto-routing

Promoted package: `04tal000006i0qTAAQ` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006i0qTAAQ)
Upgrade-safety validator: passed. v1.53.x subscribers can install directly.

Replaced the hardcoded "2000 child records = giant query" threshold with real heap-pressure signals. The runner now routes to the giant-query batch path when the _data_ would overflow sync heap — regardless of record count.

### Pre-flight estimator

`DocGenController.scoutChildCounts` now returns `heapEstimates` and `useGiantPath` per child relationship. Peak sync heap is estimated as `childCount × (fieldsPerRow × 150 + 300) × 3` (peak multiplier covers string-concatenation overhead). If that exceeds 60% of the 6MB sync limit, the relationship is flagged for the giant path. No hardcoded record thresholds.

### In-flight safety net

During sync merge, `DocGenService.processXml` checks `Limits.getHeapSize()` every 50 loop iterations. If we cross 75% of the heap limit, it throws a typed `HeapPressureException` carrying the giant relationship name. `DocGenController.processAndReturnDocumentWithOverride` and `DocGenController.generatePdf` catch it and return `{ heapPressure: true, giantRelationship: 'OpportunityLineItems' }` instead of erroring out.

### Runner auto-fallback

`docGenRunner.js` reads the estimator's `useGiantPath[rel]` flag and routes upfront when it's true. For edge cases the estimator misses, the in-flight `heapPressure` signal is caught by the runner and transparently redirects to `_assembleGiantQueryPdf`, showing a "large dataset — switching to giant-query mode" toast. No manual retry required.

### Validation

- 968 / 968 Apex tests pass, 75% org-wide coverage
- 8 / 8 e2e scripts pass (151 assertions)
- Code analyzer: 0 High severity violations
- Three new focused unit tests: estimator above threshold, estimator under threshold, in-flight trigger

---

## v1.53.0 — Giant-query aggregates for V1 flat query configs

Promoted package: `04tal000006hyYXAAY` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006hyYXAAY)
Upgrade-safety validator: passed. v1.52.x subscribers can install directly.

Aggregate tags (`{SUM:...}`, `{COUNT:...}`, etc.) rendered as literal template text in giant-query PDFs when the template used the legacy V1 flat query config format (`Name, (SELECT ... FROM OpportunityLineItems)`) instead of V3 JSON.

Root cause: the aggregate resolver re-parsed `Query_Config__c` as V3 JSON to find the child object, lookup field, and WHERE clause. V1's flat-string format isn't valid JSON; `JSON.deserializeUntyped` threw, the catch block returned the HTML unchanged, and every aggregate tag silently passed through.

Fix: `DocGenGiantQueryBatch` now passes `childObjectName`, `lookupField`, and `whereClause` into a new 7-arg `DocGenGiantQueryAssembler` constructor. The resolver reads those from instance fields regardless of config format. The old 4-arg constructor stays in place with a V3-JSON fallback for direct invocations that bypass the batch.

### Validation

- 965 / 965 Apex tests pass, 75% org-wide coverage
- 8 / 8 e2e scripts pass (151 assertions)
- Code analyzer: 0 High severity violations
- New test `testGiantAggregateV1FlatConfig` reproduces the exact V1-flat failure mode and locks in the fix

---

## v1.52.0 — Giant-query aggregate-tag format fix

Promoted package: `04tal000006hyVJAAY` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006hyVJAAY)
Upgrade-safety validator: passed. v1.51.x subscribers can install directly.

Aggregate tags with format suffixes — `{COUNT:Rel:number}`, `{SUM:Rel.Field:currency}`, `{AVG:Rel.Field:currency}`, `{MIN:Rel.Field:currency}`, `{MAX:Rel.Field:currency}` — rendered unresolved in v1.50.0–v1.51.0 when the aggregated field was _not_ also declared as a rendered column in the template's query config.

This was overly restrictive: most real templates aggregate fields like `UnitPrice`, `TotalPrice`, `Amount` that are _not_ shown as rendered columns — they're summary-row totals. The resolver now validates field names against the child object's schema instead of the query config's declared fields. The regex already restricts field names to `[A-Za-z0-9_]+` so SOQL injection remains impossible; schema existence is the second line of defense.

### Validation

- 964 / 964 Apex tests pass, 75% org-wide coverage
- 8 / 8 e2e scripts pass (151 assertions)
- Code analyzer: 0 High severity violations on changed classes
- New focused unit test `testGiantAggregateFormatSuffixes` covers all five aggregate functions with format suffixes AND the "aggregate field not in rendered columns" scenario that caused the regression

---

## v1.51.0 — Giant-query parent-tag format fix (currency/date/number)

Promoted package: `04tal000006hyThAAI` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006hyThAAI)
Upgrade-safety validator: passed. v1.50.x subscribers can install directly.

Parent-level merge tags with format specifiers (`{AnnualRevenue:currency}`, `{CloseDate:date:de_DE}`, etc.) in the HTML wrapper of giant-query PDFs — headers, titles, totals rows — were left unresolved in v1.50.0. The assembler's `resolveParentMergeTags` regex matched bare `{Name}` but not tags with format suffixes, and even where it matched it skipped the formatter.

Fixed by extending the regex to capture an optional format suffix and routing matched tag+value through `DocGenService.processXmlForTest`, so the existing locale/currency/date formatter is reused — full parity with the in-loop row path.

Aggregate tags (`{SUM:...}`, `{COUNT:...}`, etc.) were already correctly formatted in 1.50.0 via a separate resolver and are unaffected.

### Validation

- 963 / 963 Apex tests pass, 75% org-wide coverage
- 8 / 8 e2e scripts pass (151 assertions)
- Code analyzer: 0 High severity violations on changed classes
- New focused unit test: `testAssemblerParentFieldFormatting` exercises `{AnnualRevenue:currency}` on a real giant-query pipeline

---

## v1.50.0 — Locale-aware formatting + grand-total aggregates for giant queries

Promoted package: `04tal000006hyNFAAY` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006hyNFAAY)
Upgrade-safety validator: passed. v1.49.x subscribers can install directly.

### Locale-aware number, currency, and date formatting

Merge-tag formatting now honors the user's Salesforce locale instead of always using US conventions:

- **Currency** — 35+ ISO currency codes map to their native symbols (`EUR → €`, `JPY → ¥`, `GBP → £`, `INR → ₹`, etc.). Zero-decimal currencies (JPY, KRW, CLP, HUF...) render without decimals automatically.
- **Locale override** — `{Amount:currency:EUR:de_DE}` forces German grouping/decimal separators (`1.234,56 €`) regardless of the viewing user's locale.
- **Dates** — new `{Field:date}` and `{Field:date:<locale>}` forms pick the locale's default short-date pattern.
- Thousands and decimal separators now come from the locale too: French `de_DE`, Swiss `de_CH`, Indian `en_IN` grouping all render correctly.

Backward compatible — existing `{Amount:currency}` and `{Price:#,##0.00}` templates keep working unchanged.

### Grand-total aggregates in giant-query PDFs

Previously `{SUM:Items.Amount}`, `{COUNT:Items}`, `{AVG:Items.Amount}`, `{MIN:…}`, `{MAX:…}` tags only computed against in-memory record lists. For giant queries (60K+ rows processed in batch pages), the full list is never materialized at once, so aggregates returned zero or partial values.

Now resolved via a single SOQL aggregate query inside `DocGenGiantQueryAssembler`, using the same lookup + WHERE clause that drove the row pages. Totals are authoritative regardless of dataset size, governor-safe (aggregates don't hit row limits), and piggyback on the new locale formatter so `{SUM:Lines.Amount:currency:EUR:de_DE}` works at any scale.

### Tests

- 962 / 962 Apex tests pass, 75% org-wide coverage
- 8 / 8 e2e scripts pass (129+ assertions)
- Code analyzer: 0 High severity violations on changed classes
- 3 new focused unit tests for giant-query aggregate resolution (COUNT, SUM, non-matching-relationship passthrough)

---

## v1.49.0 — Signature PDF table-border + font-color fix + Sign In Person

Promoted package: `04tal000006hlZhAAI` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006hlZhAAI)
Upgrade-safety validator: passed. v1.48.x subscribers can install directly.

Closes GitHub issue [#28](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/issues/28).

### Signature PDF: table borders now render correctly

Reported by Elijah Veihl — templates with bordered tables rendered correctly via the regular DocGen runner but dropped all cell borders in the signature preview and signed PDF. Three independent issues had to be fixed before borders survived the async queueable render path:

1. **Renderer statics weren't primed before async `convertToHtml`.** `mergeTemplateForSignature` now primes `DocGenHtmlRenderer.stylesXml` + `numberingXml` as a side effect AND returns them in the response map so async callers can re-prime right before rendering.
2. **Pre-decomposed XML loader blocked by `WITH USER_MODE`.** The signed-PDF queueable runs as Automated Process user which had no FLS access to the package-internal pre-decomposed XML ContentVersions. Added a private `without sharing` inner class (`PreDecompXmlLoader`) to run that one query in system context.
3. **Automated Process has a hard-coded ContentVersion restriction that `without sharing` can't override.** The sender now pre-extracts two compact style maps at request creation (admin context) and caches them in `Signature_Data__c`. The queueable hydrates them before rendering. The renderer's `resolveTableStyleBorder` + `resolveStyleTextAttributes` check the cached maps before falling back to parsing `stylesXml`.

### Font color / named-style attributes now render

Pre-existing bug uncovered during #28 testing — the renderer parsed inline `<w:color w:val="...">` on runs but silently dropped color/font/size/bold defined via a named Word style (Heading 1, custom styles, etc.) — affected both the signature path AND the regular DocGen runner.

New `DocGenHtmlRenderer.resolveStyleTextAttributes(styleName)` reads color, fontFamily, fontSize, bold, italic from `<w:style w:styleId="X">`. Called from:

- `parseRunStyle` — a run's `<w:rStyle>` reference fills in missing attributes; inline `rPr` still overrides.
- `processParagraph` — a paragraph's `<w:pStyle>` applies color/font as paragraph-level inline CSS so runs without explicit rPr inherit them.
- Via `styleTextAttrsMap` for async signature queueable fallback (same caching pattern as the borders map).

### Sign In Person (admin action)

New "Sign In Person" button on each signer row in `docGenSignatureSender`. When an admin confirms they've verified the signer's identity in person, email PIN verification is bypassed:

- `@AuraEnabled markSignerVerifiedInPerson(signerId)` — perm-gated to `DocGen_Admin`. Sets `PIN_Verified_At__c = System.now()`, writes a `DocGen_Signature_Audit__c` row capturing who bypassed, when, and attestation metadata. Returns the signing URL.
- LWC opens the signing URL in a new tab after a browser confirm dialog.
- `SignerResult` gained a `signerId` field so the LWC can target the signer directly.

### Tests — 6 new unit tests in `DocGenSignatureTests`

- `testExtractTableStyleBorderMap_happyPath` + `testExtractTableStyleBorderMap_blank`
- `testExtractStyleTextAttributeMap_happyPath`
- `testResolveStyleTextAttrs_asyncFallback_viaMap`
- `testMarkSignerVerifiedInPerson_happyPath` + `testMarkSignerVerifiedInPerson_alreadySignedThrows`

### Validation

- 950 / 950 Apex tests pass, 75% org-wide coverage
- Code analyzer: 0 High / 0 Critical, 37 Moderate (same documented false positives)
- Upgrade-safety validator: passed

### Backward compatibility

- No schema changes. Only additive static maps + Apex methods.
- All v1.48.0 API surfaces preserved.
- Re-signing an existing request on v1.49.0 produces correctly-rendered output.

---

## v1.48.0 — Record Filter (SOQL WHERE) + runner namespace fix

Promoted package: `04tal000006hhhNAAQ` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006hhhNAAQ)
Upgrade-safety validator: passed. v1.47.x subscribers can install directly.

### Record Filter (power-user SOQL WHERE clause)

- New `Record_Filter__c` (LongTextArea) on `DocGen_Template__c`. Evaluated against the current record. When set, the template only appears for records matching the clause.
- Examples: `Type = 'Customer'` · `Industry IN ('Technology','Media','Finance')` · `Annual_Revenue__c > 1000000 AND BillingCountry = 'US'` · `Id IN ('001...', '001...')`.
- When both `Record_Filter__c` and `Specific_Record_Ids__c` are set, `Record_Filter__c` wins (clearer than ANDing).
- Evaluation: parameterized SOQL `SELECT Id FROM <base> WHERE Id = :recordId AND (<clause>) LIMIT 1`. Clause sanitized via `DocGenDataRetriever.sanitizeWhereClause` — DML keywords, semicolons, comments, and subqueries are blocked. Results cached per `(baseObject, recordId, clause)` tuple so templates sharing a clause incur only one SOQL per record load. Malformed clause → template hidden (safer default for a noise-reduction feature).

### Admin UX — "Test Against Sample Record" button

- New `testRecordFilter` @AuraEnabled endpoint returns `{ matched, error }` for a `(baseObject, sampleRecordId, whereClause)` tuple.
- `docGenAdmin` template editor: Record Filter textarea + Test button inside the Visibility & Sort panel. Green ✓ for match, grey ✗ for no match, red for sanitizer/runtime error. Uses the template's `Test_Record_Id__c` as the sample.
- Page layout: new "Record Filter (Power Users, 1.48)" single-column section.

### Runner namespace-safety fix (bug introduced in v1.47)

- `docGenRunner` was accessing template fields via raw property names (`t.Category__c`, `t.Lock_Output_Format__c`). In a namespaced managed-package install the wire returns `portwoodglobal__Category__c` — raw access silently returned `undefined`, so the v1.47 category dropdown stayed hidden and the output-picker lock always read as false.
- Switched to `@salesforce/schema/...` imports + `t[FIELD.fieldApiName]` resolution, matching the namespace-safe pattern already used in `docGenAdmin`.

### Tests — 7 new unit tests in `DocGenControllerTests`

- `testRecordFilter_matchesCurrentRecord`
- `testRecordFilter_hidesNonMatchingRecord`
- `testRecordFilter_precedenceOverSpecificRecordIds` (contradictory config → `Record_Filter__c` wins)
- `testRecordFilter_malformedClauseHidesTemplate`
- `testRecordFilter_emptyFilterFallsBackToIdList` (backward compat)
- `testTestRecordFilter_sanitizesBlockedKeywords`
- `testTestRecordFilter_happyPath`

### Validation

- 944 / 944 Apex tests pass, 75% org-wide coverage
- Code analyzer: 0 High / 0 Critical, 37 Moderate (same documented false positives)
- Upgrade-safety validator: passed

### Backward compatibility

- `Specific_Record_Ids__c` continues to work unchanged for templates that don't set `Record_Filter__c`.
- All v1.47 API surfaces preserved.

---

## v1.47.0 — Runner UX: per-record templates, category filter, output format override, audience visibility

Promoted package: `04tal000006hQwfAAE` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006hQwfAAE)
Upgrade-safety validator: passed. v1.43.x+ subscribers can install directly.

Closes GitHub issue [#25](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/issues/25).

### Per-record templates

- New `Specific_Record_Ids__c` (LongTextArea) on `DocGen_Template__c` — comma-separated 18-char record Ids. When set, the template only appears for the listed records in the runner, signature sender, bulk picker, and Flow. Empty = template applies to all records of its Base Object (today's behavior).

### Category browsing + explicit sort

- New Category dropdown in the runner — auto-populates from distinct `Category__c` values, hidden when only one category exists. Template options prefixed with `★` for defaults and `[Category]` when set.
- New `Sort_Order__c` (Number) on `DocGen_Template__c` — lower numbers appear higher. `Sort_Order__c ASC NULLS LAST, Is_Default__c DESC, Name ASC` is the new universal ORDER.

### Output format override at runtime

- New "Output As" picker in the runner — Word templates offer PDF + DOCX; PowerPoint templates show PPTX only (picker hidden). `Lock_Output_Format__c` checkbox on the template hides the picker entirely for contractual/compliance use cases.
- New "Output Format Override" input on the `DocGen: Generate Document` Flow invocable — same validation rules.
- Enables shipping one logical template (e.g. "Quote") and letting users pick format at runtime instead of cloning "Quote PDF" + "Quote DOCX".

### Audience visibility

- New `Required_Permission_Sets__c` (LongTextArea) on `DocGen_Template__c` — comma-separated perm set API names (any-of). Empty = visible to all DocGen users. Non-empty = only users assigned at least one of the listed perm sets see the template anywhere. Soft enforcement (UI filter, not native sharing) — adequate for noise reduction; admins tag "Executive Templates" with a perm set and sales reps no longer see executive content in any entry point.

### Admin UX

- New "Visibility & Sort" section in the template editor (Settings tab) with field-level-help for all four new fields. Fields also exposed on the standard page layout in a "Visibility & Sort (1.47)" section.

### Validation

- 937 / 937 Apex tests pass (9 new 1.47 tests in `DocGenControllerTests`).
- 75% org-wide code coverage.
- Code analyzer: 0 High / 0 Critical.
- Upgrade-safety validator: passed.

### Backward compatibility

- All four new fields are nullable / default-falsy — existing templates behave identically.
- `getTemplatesForObject(objectApiName)` preserved as 1-arg shim (delegates with `recordId=null`).
- `getDocGenTemplates()` preserved as 0-arg shim.
- `DocGenService.generateDocument`, `DocGenService.processDocument`, `DocGenController.processAndReturnDocumentWithImages` all gained `outputFormatOverride` overloads; old signatures preserved.

---

## v1.46.0 — Signature consolidation, image helper, email status visibility

Promoted package: `04tal000006hQ73AAE` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006hQ73AAE)
Upgrade-safety validator: passed. v1.43.x subscribers can install directly.

### Signature subsystem consolidation

- Removed dead `createTemplateSignatureRequestForFlow` from `DocGenSignatureSenderController` — Flow path was already routed through the LWC entry point. −73 LOC.
- Removed `Test.isRunningTest()` bypass in `DocGenSignatureEmailService`. The no-OWA branch is now properly tested with assertions on `Email_Status__c` content + zero email invocations.
- Removed v2 signature tag fallback in `stampSignaturesInXml` (+6 obsolete tests). Bare `{@Signature_Role}` tags continue to work via the v3 placement pipeline (`parseSignaturePlacements` already auto-promotes them to `:1:Full`).

### Merge engine

- Extracted `applyPendingImages` helper in `DocGenService` — collapses 3 duplicate call sites (full-ZIP merge, pre-decomposed merge, giant-query parts builder) into one helper.

### Email delivery visibility

- New `Email_Status__c` (LongTextArea, 1000 chars) on `DocGen_Signature_Request__c` surfaces on the page layout in a new "Email Delivery" section. Admins can see per-signer email send status, OWA configuration errors, deliverability problems, and daily-limit hits without leaving the record.
- Field added to `DocGen_Admin` (RW) and `DocGen_User` (R).

### Phase 4-lite integration tests (DocGenSignatureTests)

- `testCreateTemplateSignerRequest_integration` rewritten with real assertions on persisted state (signing order, role, sort order, token shape).
- `testGetTemplateSignaturePlacements_integration` rewritten to exercise the pre-decomposed XML fetch + bare-v2-tag → v3 auto-promotion.
- New `testFullSigningPipeline_integration` — placement records → `signPlacement` → stamping → asserts final XML contains signed values.

### Validation

- 928 / 928 Apex tests pass.
- 75% org-wide code coverage.
- Code analyzer: 0 High / 0 Critical.
- Upgrade-safety validator: passed.

### Deferred (with rationale documented in CONSOLIDATION_PLAN.md and project memory)

- V1/V2 query parser consolidation — high risk of silent wrong-data bugs without stronger integration test safety net first.
- Document Source mode methods (`createMultiSignerRequest`, `getRelatedDocuments`, `getDocumentSignatureRoles`) — kept as deprecated `global @AuraEnabled` for upgrade safety.
- E2E script overhaul to validate installed packages — they only run in source-deployed dev contexts; making them install-validators is a dedicated future project.

### Coming in v1.47.0

GitHub issue [#25](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/issues/25) — design doc in `RUNNER_UX_PLAN.md`:

- Per-record templates (`Specific_Record_Ids__c` comma-separated Id list)
- Category browsing + explicit sort order
- Output format override at runtime
- Audience visibility via permission set lists

---

## v1.43.0 — Guided signatures, document packets, decline flow, sequential signing

Promoted package: `04tal000006hLTxAAM` (1.43.0-11)

Major signature subsystem overhaul. Full v3 tag syntax (`{@Signature_Role:Order:Type}`), guided per-placement signing UI, multi-template document packets, sequential signing order, decline flow with reason capture, reminder schedulable, OWA-based branded emails with per-signer reply-to, signature audit records, expanded setup validation checklist. See git history `v1.42.0..v1.43.0` for the full diff and `CLAUDE.md` for architectural details.

---

## v1.42.0 — Permission Audit & Signature Flow Action

### Signature Automation from Flow

- **New invocable: `DocGen: Create Signature Request`** — kick off a full DocGen signature request from any Flow. Pass a template Id, a related record Id, and parallel lists of signer names / emails / (optional) roles / (optional) contact Ids. The action returns the signature request Id and one signing URL per signer, in input order.
- **Flow-native notification** — the invocable defaults to `sendEmails = false` from Flow so your Flow owns the notification path (Send Email action, Slack, Teams, etc.). Set `Send Branded Emails = true` to use the package's built-in branded invitation emails instead. The LWC signature sender path is unchanged and still sends the branded emails by default.
- **End-to-end automation** — record-triggered Flow → create signature request → post signing links to your channel of choice → track completion via `signatureRequestId` on the record.

### Permission Set Audit

- **Added missing class grants** across `DocGen_Admin` and `DocGen_User`: `DocGenSignatureFlowAction`, `DocGenGiantQueryFlowAction`, `DocGenGiantQueryAssembler`, and `DocGenAuthenticatorController` (User). The two Flow invocables were previously un-granted, meaning Flows calling them would fail with `INSUFFICIENT_ACCESS`.
- **Added missing field grants** for all 8 `DocGen_Settings__c` fields to Admin (read/write) and User (read-only). Configuring signature email branding, OWA id, experience site URL, and company name no longer requires a system administrator.
- **Added missing audit field grants** to User: `Contact__c`, `Error_Message__c`, `Signer__c`. The signature audit related list on a record page now shows full context.
- **Added missing VF page grants** to both Admin and User: `DocGenGuide` and `DocGenVerify`. Non-sysadmin users can now reach the in-app admin guide and the document verification page.
- **Added missing tabs**: Signer tab for Admin; Signature Request tab for User.
- **Intentional blocks confirmed**: User remains explicitly denied on `DocGen_Signer__c.PIN_Hash__c`, `PIN_Attempts__c`, `PIN_Expires_At__c`, `Secure_Token__c`, and `DocGen_Signature_Request__c.Secure_Token__c`. Only Admin and the token-gated Guest path can read PIN hashes or signing tokens.

### Security Review Pack

- **Four reviewer-ready documents** in `docs/appexchange/` (each in `.md`, `.doc`, and `.pdf`):
    - `DocGen_Solution_Architecture_and_Usage` — security-focused architecture, threat model, sharing model, controls matrix.
    - `DocGen_Architecture_and_Usage` — feature/component inventory and usage walkthroughs.
    - `DocGen_False_Positive_Report` — per-category disposition of the 335 Checkmarx CxSAST findings (Scan `a0OKX000001JEZY2A4`).
    - `DocGen_Code_Analyzer_Report` — Salesforce Code Analyzer run: **0 High, 30 Moderate** (documented false positives).

### Testing

- `scripts/e2e-01-permissions.apex` expanded from 29 to **37 assertions** — covers the new class grants, page accesses, and `DocGenSignatureFlowAction` visibility on both Admin and User permsets.
- Full e2e suite (8 scripts) passes clean: **138/0 PASS**.
- `RunLocalTests` clean (850+ tests, ≥ 75% coverage).
- Code Analyzer Security + AppExchange: **0 High**, same 30 Moderate documented false positives as v1.41.0.

## v1.26.0 — Giant Query Sort, Visual Builder & Image Fix

### Giant Query Sort Order

- **Pre-query sort** — ORDER BY configured on a child relationship now sorts globally across all batch fragments, not just within each batch of 50. Works for both PDF (server-side batch) and DOCX (client-side assembly).
- **V1 flat config support** — flat SOQL query strings (from the visual builder or manual entry) now trigger the Giant Query async path when child records exceed 2,000. Previously only V3 JSON configs were supported.

### PDF Table Continuity

- Single `Blob.toPdf()` call with internal table breaks every 2,000 rows — no visible gap between sections.
- **Column widths preserved** from the template's column definitions across all table break points.

### Visual Query Builder

- **New tree-based builder** — select fields via compact pills, browse parent lookups and child relationships through searchable dropdown pickers. Same UI pattern at every depth level.
- Labels shown prominently with API names in grey below. Global search bar filters across all levels.
- WHERE, ORDER BY, and LIMIT inputs on each child relationship.
- Available on both the Create wizard and Edit modal via "Try our visual builder" toggle.

### Template Images

- Template-embedded images (logos, headers) now appear in Giant Query PDFs. Fixed a timing issue where image ContentVersions were not committed before the pre-baked HTML was generated.

### Mobile

- Runner detects mobile devices and shows only "Save to Record" — download is not available on mobile.

### Quality

- 630 Apex tests, 0 failures, 75.2% code coverage
- 0 security violations in Salesforce Code Analyzer

---

## v1.23.0 — Cover Pages, Security & Simplified Sharing

Cover pages now render clean — no unwanted headers or footers on your title page. Section breaks in your Word template create proper page breaks in the PDF. Simpler permissions model replaces custom sharing UI with standard Salesforce sharing.

### Cover Page & Section Breaks

- **Title page support** — Templates with "Different First Page" enabled in Word (`<w:titlePg/>`) now suppress headers and footers on the first page. Your cover page stays clean.
- **Section breaks** — Mid-document section breaks in your Word template now create proper page breaks in the PDF instead of being silently stripped.

### PDF Rendering Fixes

- **Spaces between merge tags** — `{FirstName} {LastName}` no longer renders as "FirstNameLastName". Whitespace-only runs are preserved.
- **Page number formatting** — Page numbers in headers and footers now honor the font size, color, bold, and other formatting from your Word template.
- **Page counter CSS** — Switched to `::before` pseudo-elements for reliable page numbering in Flying Saucer running elements.
- **Numbered list detection** — `numbering.xml` now included in the pre-decomposed XML path so numbered vs bulleted lists render correctly in PDF output.

### UI Fixes

- **Template selection persists** — Switching between Create Document, Document Packet, and Combine PDFs tabs no longer resets your template selection.

### Simplified Sharing

- Removed custom sharing UI — use standard Salesforce sharing rules and manual sharing for template access control. Simpler, more predictable, no custom code needed.

### Housekeeping

- Removed built-in sample templates — download templates from [portwoodglobalsolutions.com](https://portwoodglobalsolutions.com)
- 623 Apex tests passing, 24/24 E2E tests, 0 security violations

## v1.22.0 — Bug Fixes & Template Cleanup

Patch release with merge tag spacing fixes and page number formatting. Sample templates moved online.

## v1.21.0 — Query Builder 2.0 & User Guide

Replaced the visual query builder with a simpler, faster, more reliable manual-first experience. The old visual builder had persistent bugs — broken save state, empty config on object selection, template creation failures ("Please configure the query" error). Rather than continuing to patch a complex reactive UI, we stripped it back to what works: a text box with smart suggestions.

### Query Builder 2.0

- **Manual-first approach** — Type your query directly in a monospace textarea. No drag-and-drop, no multi-panel visual builder. Admins who know their objects type faster than they click.
- **Inline field autocomplete** — Start typing a field name and suggestions appear from the object schema. Click to insert with auto-comma formatting.
- **Context-aware suggestions** — Type `Owner.` and it loads the User object's fields. Type `(` and it shows child relationships. Inside `(SELECT ... FROM Contacts)` it suggests Contact fields.
- **Sample record preview** — Pick a sample record on step 1. The query structure tree on step 2 shows real values: `Name = Acme Corporation`, child record rows in mini-tables. See exactly what your query returns before uploading a template.
- **Object selection on step 1** — Base object is picked alongside template name and type. By the time you reach step 2, metadata is pre-loaded. No loading spinners, no async rendering bugs.
- **Inline quick reference** — Syntax examples for fields, parent lookups, related list subqueries with WHERE/ORDER BY/LIMIT right below the textarea.
- **Trailing comma cleanup** — Auto-stripped when clicking Next.
- **Query persistence** — Navigate forward to step 3 and back to step 2, your query is exactly as you left it.

### Builder Bug Fix

- Fixed the root cause of "Please configure the query" error — `_notifyChange()` was firing in `_initRootNode()` before fields loaded asynchronously, emitting empty config to the parent component.

### User Guide

- New public `/DocGenGuide` page with full documentation — 28 sections covering every feature from template creation to Flow automation.
- Sticky sidebar navigation with scroll-spy active section highlighting.
- Consistent nav bar (`Home | User Guide | Roadmap | Community | GitHub`) across all 7 site pages.

### Testing

- **629 Apex tests passing, 0 failures**
- **24/24 E2E tests passing**
- **0 Code Analyzer security violations**

## v1.20.0 — Dynamic Page Numbers & Bug Fixes

Feature release: dynamic page numbering in PDF headers/footers, closing all community-reported rendering issues.

### Dynamic Page Numbers (#9)

- **PAGE and NUMPAGES field codes** — Word's `PAGE` and `NUMPAGES` field codes in headers and footers now render as dynamic page numbers in PDF output. Supports both complex field codes (`w:fldChar begin/separate/end`) and simple field wrappers (`w:fldSimple`). Uses CSS `counter(page)` and `counter(pages)` via `::after` pseudo-elements inside Flying Saucer running headers.
- **Works in both headers and footers** — "Page 1 of 5" style numbering works anywhere in header or footer content, alongside other text and formatting.

### Bug Fixes (Since v1.15.0)

- **Headers/footers on all pages (#9)** — PDF headers and footers now repeat on every page via Flying Saucer running elements with `@page` margin boxes.
- **Numbered lists render correctly (#9)** — Replaced odd/even numId heuristic with actual `numbering.xml` lookup (`w:num` → `w:abstractNum` → `w:lvl` → `w:numFmt`).
- **Font colors from theme references (#9)** — Theme colors (`w:themeColor="accent1"`) now resolve to hex via default Office theme palette (all 16 colors).
- **Ampersand rendering (#5)** — Fixed double-encoding where `&amp;` in XML became `&amp;amp;` in HTML. Added `unescapeXmlEntities()` before `escapeHtml4()`.
- **Create Packet button state (#6)** — Template selection persists across mode switches; button no longer requires re-selection.

### Package Chain

- Ancestor: 1.18.0-2 (04tal000006PW4TAAW)
- Chain: 1.15.0 → 1.16.0 → 1.17.0 → 1.18.0 → 1.20.0

### Testing

- **629 Apex tests passing, 0 failures**
- **76% org-wide code coverage**
- **24/24 E2E tests passing**
- **Visual proof PDFs** generated on clean scratch org verifying each fix

## v1.14.0 — PDF Rendering Fixes + Community Channel + Support Page

Bug fix release addressing community-reported PDF rendering issues, Slack community channel migration, and new Support the Project page.

### PDF Rendering Fixes

- **Headers and footers on all pages** — PDF headers and footers now repeat on every page. Previously they only appeared on page one. Switched from CSS absolute positioning to Flying Saucer's running elements with `@page` margin boxes.
- **Numbered lists render correctly** — Numbered lists no longer render as bullet points. Replaced the unreliable odd/even numId heuristic with actual `numbering.xml` lookup. The renderer now parses `w:num` to `w:abstractNum` to `w:lvl` to `w:numFmt` to determine the real list type (decimal, lowerLetter, upperRoman, bullet, etc.).
- **Font colors from theme references** — Font colors defined as Word theme references (`w:themeColor="accent1"`) now render in PDFs. Added default Office theme color palette mapping for all 16 standard theme colors.
- **Ampersand rendering fixed (#5)** — Ampersands (`&`) no longer render as literal `&amp;` in PDF output. Fixed double-encoding where XML entities in `<w:t>` text were escaped twice (once by XML, once by `escapeHtml4()`).

### UI Fixes

- **Create Packet button state (#6)** — The "Create Packet" button no longer stays disabled after navigating away from the Create Document tab and back. Template selection now persists across mode switches.

### Community

- **Slack community channel** — Migrated from workspace invite to Slack Connect channel invite. Users join from their own Slack workspace, no separate account needed. Updated language across all docs, legal pages, and community landing page.
- **Support the Project page** — New `/DocGenSupport` page with the DocGen origin story, pay-what-you-can philosophy, Circles Indy as featured nonprofit, split-your-donation model, and family photo.

### Testing

- **890 Apex tests passing, 0 failures** — Fixed 4 pre-existing test failures (3 Giant Query tests missing DOCX in `@TestSetup`, 1 numbered list test updated for new `numbering.xml` detection).
- **76% org-wide code coverage** (up from 74%)
- **Code Analyzer: 0 violations** across pmd, eslint, retire-js

## v1.13.0 — Community + AppExchange Prep

Community-first release: Slack community, 100% free model, and AppExchange submission readiness.

### Community

- **Slack community channel** — Replaced custom forum with Slack community channel. Join from your own Slack workspace — no separate account needed.
- **Community link in Command Hub** — "Join the Community" link added to the sidebar, above "Made with love."
- **Slack invite URL from MDT** — `Slack_Invite_Url__c` field on `DocGen_Landing_Config__mdt`. Update one record when the link expires — no code deploy needed.

### Website

- **100% free model** — Removed all paid tier references, premium pricing, and freemium language across all pages.
- **Community promotion** — Landing page help form replaced with community section (Discussion Board, Feature Requests, Report Issues).
- **Roadmap rework** — Removed Premium Launch and tier comparison. Single "Full Feature Set" card at $0. Community-driven roadmap.
- **Terms & Privacy updated** — Accurate PackageSubscriber data disclosure, Slack community channel terms, free model pricing, $100 liability cap.

### AppExchange

- **Security review docs** — Solution architecture, submission form, code analyzer summary — all as `.doc` files ready for upload.
- **LISTING.md** — Complete AppExchange listing reference: SEO title, highlights, description, keywords, screenshots, demo script.
- **Code Analyzer** — Clean scan: 0 Critical, 0 High across all 6 engines (pmd, eslint, retire-js, cpd, regex, flow).

### Fixes

- **Giant Query test fix** — Added missing `DocGen_Template_Version__c` to test setup. Created local DOCX helper to avoid cross-class test data dependency.

## v1.12.0 — RTL Support + Giant Query 28K+ + Custom Object Fix

Major release: RTL language support for PDF output, Giant Query scaling to 28K+ rows, custom object query builder fix, V1 object name resolution, Giant Query Flow action, and install tracker improvements.

### RTL Language Support (Hebrew, Arabic)

- **RTL text rendering** — Detects `<w:bidi/>` and `<w:rtl/>` in DOCX XML. Reverses Hebrew/Arabic text for correct right-to-left display in `Blob.toPdf()`. English merge field values are preserved.
- **RTL paragraph alignment** — Right-aligns paragraphs when document default style or paragraph properties specify `<w:bidi/>`.
- **RTL table layout** — Tables with `<w:bidiVisual/>` render columns right-to-left.
- **RTL run ordering** — Multiple runs within an RTL paragraph display in correct right-to-left order.
- **Complex Script font** — Uses Arial Unicode MS (built into `Blob.toPdf()`) for Hebrew/Arabic glyphs. Detects `w:cs` font attribute.
- **Bidi-aware indentation** — Falls back to `w:start`/`w:end` when `w:left`/`w:right` absent.
- **Known limitation**: Long paragraphs that wrap to multiple lines may have continuation lines starting from the left instead of the right. This is a Flying Saucer (PDF engine) limitation — it does not implement the Unicode Bidirectional Algorithm. Will be addressed in a future release.

### Giant Query (from v1.8.0-v1.9.0)

- **28K+ row scaling** — Single-pass fragment assembly, no Queueable chaining.
- **Reduced HTML size** — `td:nth-child(N)` CSS instead of per-cell classes.
- **Parent merge tag fix** — Validates dot-notation fields against base object schema.
- **V1 object name resolution** — Auto-resolves object names to relationship names in subqueries.

### Query Builder (from v1.7.0)

- **Custom object label fix** — Fixed `_createNode` pluralizing API names (`__c` → `__cs`).
- **Schema-based lookup fields** — Report import uses describe instead of hardcoded `parentObj + 'Id'`.
- **Dynamic child discovery** — Report import for custom object report types.

### Other

- **Giant Query Flow Action** — `DocGenGiantQueryFlowAction` invocable: auto-detects large datasets, sync under 2K rows, async batch over 2K. Customer portal ready.
- **Install tracker** — Net-new notifications only, per-row Account actions, fuzzy org name matching.
- **PPTX/XLSX** — Marked as "Coming Soon" on landing page (not battle-tested).

## v1.11.0 — RTL Language Support (Hebrew/Arabic)

(Superseded by v1.12.0)

## v1.10.0 — Giant Query Flow Action

- **feat: Generate Document (Auto Giant Query)** — New `DocGenGiantQueryFlowAction` invocable action. Scouts child counts automatically — under 2,000 rows generates synchronously, over 2,000 launches async Giant Query batch. PDF saved to record when complete. Returns `isGiantQuery` flag and `jobId` for Screen Flow status tracking.
- **Use case: Customer portals** — Screen Flows on Experience Cloud can offer "Download All Transactions" regardless of dataset size.

## v1.9.0 — V1 Object Name Resolution

- **fix: V1 subquery object name fallback** — When a V1 config uses the object API name (e.g., `FROM Short_Code__c`) instead of the relationship name (`FROM Short_Codes__r`), the parser now auto-resolves it by matching against the parent object's child relationships. Fixes configs generated via Manual Query mode with custom objects.

## v1.8.0 — "Giant Query 28K+ & Custom Object Fix" (Portwood DocGen Managed)

Giant Query PDF now scales to 28,000+ rows. Fixed Queueable chain depth limit and reduced HTML size.

- **fix: Giant Query single-pass assembly** — Assembler now loads all HTML fragments in one Queueable execution instead of chaining. Eliminates the 5-deep Queueable chain limit that caused "Maximum stack depth" on large datasets.
- **fix: Drop per-cell CSS classes** — Removed `class="c1"` from every `<td>` in batch HTML output, saving ~2.5MB on 28K rows. Column formatting now uses `td:nth-child(N)` CSS selectors.
- **fix: Giant Query parent merge tags** — Fixed parent field resolution that silently failed when child loop fields (e.g., `Product2.Name`) were included in the parent SOQL query. Now validates dot-notation fields have a valid relationship on the base object.
- **fix: Multi-part PDF rendering** — When row count exceeds 2,000, renders separate PDFs per chunk for client-side merge. Prevents `Blob.toPdf()` stack overflow on very large documents.
- **Tested**: 28,000 PricebookEntries, 6 columns, ~3.2MB HTML → 8MB PDF.
- **Ancestor Chain** — v1.8.0 → v1.7.0 → v1.6.0. Seamless upgrades.

## v1.7.0 — "Custom Object Query Builder Fix" (Portwood DocGen Managed)

Fixed query builder label processing that broke custom objects with `__c` suffix. The label cleanup logic was extracting the API name from the display label and pluralizing it (e.g., `Record_Consolidation__c` → `Record_Consolidation__cs`), causing invalid object references at generation time.

- **fix: Custom object label pluralization** — `_createNode` no longer pluralizes API names extracted from parenthesized labels. Custom objects like `Record_Consolidation__c` now display their friendly label instead of a mangled API name.
- **fix: Lookup field resolution** — Report import and V2 config parsing now use schema describe to find the correct lookup field instead of hardcoding `parentObj + 'Id'`. Custom object lookups (e.g., `Account__c` instead of `AccountId`) resolve correctly.
- **fix: `_guessLookupField` for custom relationships** — Handles `__r` → `__c` and `__cs` → `__c` relationship suffixes. V1/V2 config parsers now pass lookup fields instead of null.
- **fix: Report import for custom objects** — Dynamic child discovery via schema describe when the hardcoded report type map doesn't match. `resolveReportBaseObject` now resolves custom object report types directly.
- **Defensive `__cs` correction** — V3 data retriever auto-corrects `__cs` object names to `__c` at runtime if the object doesn't exist in global describe.
- **Ancestor Chain** — v1.7.0 → v1.6.0 → v1.5.0. Seamless upgrades.

## v1.6.0 — "Sample Flows" (Portwood DocGen Managed)

Sample Flows demonstrating DocGen Flow action integration. Proper upgrade chain from v1.5.0.

- **DocGen: Generate Account Summary** — Screen Flow for Account record page. Resolves default template via `Is_Default__c`, generates PDF, saves to Files. Launch as Quick Action or App Page button.
- **DocGen: Welcome Pack on New Contact** — Record-Triggered Flow (After Save, Create). Auto-generates welcome document and creates follow-up Task for Contact Owner.
- **Flow Entry Criteria** — Record-triggered flow includes entry criteria to satisfy Code Analyzer (0 High).
- **Ancestor Chain** — v1.6.0 → v1.5.0 → v1.4.0. Seamless upgrades.
- **615 Apex tests**, 76% coverage, 24/24 E2E, 0 Critical, 0 High.

## v1.5.0 — "Giant Query PDF" (Portwood DocGen Managed)

Same features as v1.3.0/v1.4.0 with critical fixes and proper package ancestor chain for upgrades.

- **Ancestor Chain Established** — v1.5.0 is the first version with a proper upgrade path. All future versions chain from here. Subscribers can upgrade in-place going forward.
- **fix: Regex too complicated** — `Pattern.compile` on 1MB+ HTML with 10K data rows hit Apex regex limits. Moved parent merge tag resolution to run on the template HTML (~2KB) before row injection. Barcode markers stripped via string ops instead of regex.
- **fix: E2E State/Country Picklists** — New developer orgs with State/Country picklists enabled caused silent DML failures. Now detects picklist fields via Schema and uses code fields when available. (PR #2 by @AtlasCan)
- **Live Install Count** — Landing page hero badge shows "Proudly serving X orgs" via real-time PackageSubscriber query.
- **Competitor Comparison** — "Child Records per Document" row added to comparison table: DocGen 50,000+ vs competitors at ~200-1,000.
- **615 Apex tests**, 76% coverage, 24/24 E2E, 0 Critical, 0 High.

## v1.3.0 — "Giant Query PDF" (Portwood DocGen Managed)

Server-side PDF generation for records with 3,000-50,000+ child records. No external dependencies, no heap limits, no callouts.

- **Giant Query PDF** — Render unlimited-row PDFs entirely server-side. Batch harvests child records in 50-row cursor pages, saves as lightweight HTML fragments. Progressive Queueable chain accumulates fragments into a single HTML document. One `Blob.toPdf()` call renders the final PDF. Saved directly to the record via ContentDocumentLink.
- **Pre-baked HTML Templates** — Template DOCX is converted to HTML at save time and stored as a ContentVersion. At generation time, zero DOCX XML parsing — just load the pre-baked HTML and inject data rows. Eliminates the heaviest heap operation from the render path.
- **Column CSS Formatting** — Bold, italic, font-size, and text alignment extracted once from the template's loop row XML, applied via CSS class selectors (`.c1`, `.c2`). CSS2.1 compatible with Flying Saucer (Blob.toPdf engine). Zero per-cell overhead for 10,000+ rows.
- **Parent Lookup Fields** — Dot-notation parent fields (e.g., `Product2.Name`, `Product2.Description`) now resolve correctly in Giant Query data rows. Fixed nested map structure in `renderLoopBodyForRecords` to match `resolveValue` traversal.
- **Progress Bar UI** — Real-time progress bar with percentage during batch processing. "Do not leave this page" warning during assembly.
- **Lightweight Launch** — `launchGiantQueryPdfBatch` controller accepts scout-resolved child node config, works for V1/V2/V3 query configs. Pre-decomposed XML lookup avoids ZIP decompression in the controller.
- **Barcode Handling** — Barcode markers (`##BARCODE:code128::VALUE##`) stripped to plain text values in Giant Query rows. CSS bar spans too heavy for 3K+ rows; barcodes work normally in standard PDF generation (< 2,000 rows).
- **Known Limitations** — Images in data rows not rendered (template images work). Custom fonts not supported (Blob.toPdf platform limitation). No save-to-record for objects without ContentDocumentLink support (e.g., Pricebook2).
- **615 Apex tests**, 76% coverage, 24/24 E2E, 0 Critical, 0 High. Tested: 3K PricebookEntries, 10K Opportunities.

## v1.2.0 — "Giant Query & AppExchange Ready" (Portwood DocGen Managed)

First managed package release. Giant Query, security review prep, and 615 tests.

- **Giant Query** — Generate documents from records with 15,000+ child records. Client-side DOCX assembly with cursor-based pagination (500 rows/page). Auto-detects large datasets on Generate click. Works with V1, V2, and V3 query configs. Barcode fonts render natively in DOCX.
- **Managed Package** — Switched from Unlocked to Managed 2GP for AppExchange listing. IP-protected Apex, proper upgrade path.
- **TestDataFactory** — Centralized test data creation across all 5 test classes. `createStandardTestData()`, `attachRealDocxToTestTemplate()`, consistent Account/Template names.
- **Security Review Ready** — 0 Critical, 0 High on Code Analyzer. Package-internal queries use `WITH SYSTEM_MODE`; user-facing queries use `WITH USER_MODE`. All classes use `with sharing`. SOQL-in-loop eliminated.
- **V1/V2/V3 Scout** — Giant Query auto-detection works with all query config formats including manual V1 flat strings.
- **Save-to-Record UX** — Save option hidden for non-PDF output (DOCX always downloads). Giant Query sets download-only mode automatically.
- **615 Apex tests**, 79% coverage, 24/24 E2E, 100% pass rate.

## v1.2.0 — "Hello AppExchange" (Portwood DocGen)

- **Security review ready** — 0 Critical, 0 High on Salesforce Code Analyzer (recommended rules). All SOQL queries use `WITH USER_MODE`. All classes use `with sharing`. All DML justified. Zero SOQL-in-loop violations.
- **553 Apex tests, 79% coverage, 24/24 E2E** — every feature tested, every edge case covered.
- **Permission sets audited** — Admin and User permission sets verified against all 4 custom objects and every field. Required fields excluded (Salesforce auto-grants). FLS enforced end-to-end.
- **Bulk runner redesigned** — single Output Mode dropdown (Individual Files / Print-Ready Packet / Combined + Individual). Batch heap analysis with real measured heap deltas.
- **Template import/export** — portable `.docgen.json` files for sharing templates across orgs.
- **Queueable Finalizer** on DocGenMergeJob — marks jobs as Failed on unhandled exceptions.
- **SLDS design tokens** throughout all LWC components. ESLint clean.
- **Mobile support** — DocGen Runner works on Salesforce mobile (Record Page + App Page).

## v1.1.7 — "Runner Mobile Support & Community Hub (Parked)" (Portwood DocGen)

- **DocGen Runner Mobile Support** — Record Page and App Page targets now include mobile form factor support (`Small` + `Large`), enabling the runner on Salesforce mobile.
- **Community Hub (Parked)** — Full VF-based community forum built and committed to `devhub-tools/` — rich text editor, @mentions, reply notifications via Resend, profile pages, org management, category hub with topic cards, breadcrumb navigation, vendor directory. Parked for now to stay focused on core document generation. Code ready to activate when needed.
- **Removed Community Link** — Removed "Join Community" from Command Hub sidebar and landing page nav.

## v1.1.6 — "Template Import/Export & Community Repo Migration" (Portwood DocGen)

- **Template Import/Export** — Export any template as a portable `.docgen.json` file containing all metadata, query config, saved queries, and the template file (DOCX/XLSX/PPTX). Import the JSON into any org to recreate the template with a single click. Pre-decomposed parts and images are auto-regenerated on import. Export via row action menu; Import via toolbar button.
- **Community Repo Migration** — DocGen's official home is now [Portwood-Global-Solutions/Portwood-DocGen](https://github.com/Portwood-Global-Solutions/Portwood-DocGen). GitHub Discussions enabled, issue templates upgraded (bug report, feature request, question), PR template, CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, and custom labels added.
- **Landing Page Links Updated** — All GitHub and install links on portwoodglobalsolutions.com now point to the new org repo and use CMDT-backed install URLs.
- **507/507 Apex tests**, 77% coverage, 0 Critical/High. E2E 24/24.

## v1.1.5 — "Flow Action Visibility, Null Parent Lookup Fix & Landing Page CMDT" (Portwood DocGen)

- **Flow Actions Visible in Subscriber Orgs** — `DocGenFlowAction` and `DocGenBulkFlowAction` changed from `public` to `global`. In namespaced packages, `@InvocableMethod` and `@InvocableVariable` members must be `global` to appear in the subscriber org's Flow Builder. Fixes #49.
- **Null Parent Lookup Fix** — Null parent lookups in child loops (e.g., `{ReportsTo__r.Name}`) no longer incorrectly render the child record's own `Name` field. They now correctly render as blank. The `resolveValue()` base-object-name skip logic now excludes relationship fields ending in `__r`. Fixes #48.
- **Landing Page CMDT** — Install links on the VF landing page are now driven by `DocGen_Landing_Config__mdt` instead of hardcoded constants. Updating install links for a new release only requires deploying an updated CMDT record — no Apex changes needed.
- **507/507 Apex tests**, 79% coverage, 0 Critical/High. E2E 23/23.

## v1.1.4 — "Bulk Runner UX, Community Hub & Batch Heap Analysis" (Portwood DocGen)

- **Bulk Runner Output Mode** — Replaced confusing checkbox toggles with a single dropdown: "Individual Files" (one PDF per record, unlimited scale), "Print-Ready Packet" (single merged PDF), or "Combined + Individual" (both). Clear labels, clear behavior.
- **Batch Heap Analysis** — Pre-generation analysis now shows per-batch heap estimates alongside merge heap. Uses measured heap delta (not just HTML size) to capture query objects, template parsing, and image metadata overhead. Safer batch size recommendations.
- **Join Community Link** — Command Hub sidebar now includes a "Join Community" link to the DocGen Community Hub at portwoodglobalsolutions.com/DocGenCommunity. Passes the org ID for automatic account linking during registration.
- **507/507 Apex tests**, 83% coverage, 0 Critical/High. E2E 22/22.

## v1.1.3 — "Clickable Hyperlinks in Rich Text PDFs" (Portwood DocGen)

- **Clickable Hyperlinks in PDF** — Rich text `<a href="...">` tags now render as real clickable links in PDF output. Previously, hyperlinks from rich text fields were rendered as styled text (blue + underline) but were not clickable. Now they generate proper `<a>` tags in the HTML passed to `Blob.toPdf()`.
- **Anchor Tag Parsing** — New `extractAttribute()` helper parses `href` from rich text anchor tags. Handles quoted and unquoted attributes, `&amp;` decoding.
- **Custom URL Attribute for DOCX→PDF Bridge** — Rich text links embed a `w:docgen-url` attribute on `w:hyperlink` elements during XML processing, which the HTML renderer reads to produce clickable `<a>` tags without needing relationship file lookups.

## v1.1.2 — "Image Sizing, Error Diagnostics & Multiline Text" (Portwood DocGen)

Huge thanks to **@Henk3000** for PR #47 — ImageRenderSpec, ahe() helper, multiline text preservation, error diagnostics for malformed tags, and smart container expansion for numbered lists.

- **ImageRenderSpec** — Percentage-based image sizing (`{%Logo:100%x}`), max constraints (`{%Logo:m100%x}`), intrinsic dimension detection from PNG/JPEG headers, aspect ratio preservation. Credit: @Henk3000 PR #47.
- **Error Diagnostics** — Malformed merge tags and unclosed loop tags now throw `DocGenException` with descriptive messages instead of silently producing broken output.
- **Multiline Text Preservation** — Newlines in Long Text Area and Text Area fields now render as proper Word line breaks (`<w:br/>`) with correct run element handling.
- **Smart Container Expansion** — Loop tags inside numbered/bulleted lists now repeat the list paragraph formatting. Previously only table rows were detected.
- **`ahe()` Helper** — Consistent `AuraHandledException` creation with original exception logging. All 38 throw sites migrated.
- **Universal File Save** — `saveContentVersion()` gracefully handles objects that don't support `FirstPublishLocationId` or `ContentDocumentLink` (e.g., Pricebook2).
- **507/507 Apex tests**, 79% coverage, 0 Critical/High. E2E 22/22.

## v1.1.0 — "Pixel-Perfect PDF" (Portwood DocGen)

Huge thanks to **@josephedwards-png** for PR #46 — his analysis of the relId collision bug and namespacing approach was the key insight that unlocked header/footer image rendering.

- **Header/Footer Rendering in PDF** — Full formatting, borders, merge tags, images. Headers at top, footers pinned to bottom.
- **Namespaced Image RelIds** — `header1_rId1`, `footer1_rId1` prevent collisions. Credit: @josephedwards-png PR #46.
- **Dynamic Style Resolution** — Table borders, cell padding, page size/margins all read from `styles.xml` and `w:sectPr` at render time.
- **PDF Merger Restored** — Generate+merge, merge-only, document packets with client-side PDF merging.
- **Client-Side DOCX Assembly** — Zero heap ZIP. Per-image Apex calls with fresh 6MB heap each.
- **507/507 Apex tests**, 81% coverage, 0 Critical/High. E2E 22/22.
- Templates with headers/footers must be re-saved to pick up the fix.

## v1.0.8 — "Full Release" (Portwood DocGen)

**IMPORTANT: If upgrading from the old unnamespaced "Document Generation" package, you MUST uninstall it first.** The new package uses the `portwoodglobal` namespace — the two cannot coexist. Go to Setup > Installed Packages > Document Generation > Uninstall, then install this version.

- **Website Live** — [portwoodglobalsolutions.com](https://portwoodglobalsolutions.com) — landing page with install links and live demo
- **DocGenDataProvider Interface** — Custom Apex data sources for templates. Implement `getData(Id recordId)` and `getFieldNames()` to supply data from any source — external APIs, computed fields, cross-object aggregations. V4 query config: `{"v":4,"provider":"ClassName"}`
- **Apex Provider in Query Builder** — Toggle between Standard Object and Apex Provider. Searchable class picker finds all `DocGenDataProvider` implementations. Tags preview from `getFieldNames()`
- **Flow Actions Expanded** — Single generation: Save to Record, Document Title override, Content Version ID output. Bulk generation: Combined PDF Only, Keep Individual Files, Batch Size, Job Label
- **Mobile Support** — Responsive CSS, utility bar target, flow screen compatible
- **Bulk Runner UX** — "Combined PDF Only" / "Combined + Individual PDFs" replaces confusing merge toggles
- **Sample Record Picker** — Persistent bar above all tabs in edit modal
- **507 Apex Tests Passing** — 83% code coverage, 0 Critical, 0 High on Code Analyzer
- **E2E: 22/22** — includes V4 provider tests, image rendering, junction stitching, aggregates
- **Package Install Tracker** — DevHub dashboard with version history, install notifications, auto-refresh

## v1.0.4 — "Namespace Release" (Portwood DocGen)

- **Namespaced Package** — DocGen is now distributed as `portwoodglobal` namespaced unlocked 2GP package via Portwood Global Solutions. Existing unnamespaced installs must uninstall and reinstall.
- **Namespace-Aware LWC** — All Lightning Web Components now use `@salesforce/schema` imports for field access, ensuring correct field resolution in namespaced subscriber orgs. Fixes "undefined" and "field does not exist" errors.
- **Visual Query Builder Fixes** — Tag copy now works in all Lightning contexts (clipboard fallback). "Change Object" button added to tree header. Parent field search preserves selections when filtering.
- **Manual Query Mode** — Toggling to Manual now converts V3 JSON to readable V1 SOQL format. Editable and saveable as V1.
- **Sample Templates Fixed** — Sample templates now create proper version snapshots with metadata headers and image extraction. No more "undefined" in template lists.
- **Bulk Runner UX** — "Combined PDF Only" and "Combined + Individual PDFs" replace confusing "Merge PDFs" / "Merge Only" toggles. Combined-only is now the default (saves heap).
- **Sample Record Promoted** — Record picker moved to persistent bar above all tabs in the edit modal. Accessible from any tab.
- **Permission Sets Updated** — All custom fields, Apex classes, VF pages, and tabs audited and corrected for both Admin and User permission sets.
- **Dead Code Removed** — Removed vestigial DocGenVerify VF page (e-signature leftover).
- **Code Quality** — 161 assertion messages added, 64 missing braces fixed, 11 parseInt radix fixes. Code Analyzer: 0 Critical, 0 High.
- **E2E Tests** — 20 tests (added doc generation size check). All 495 Apex tests passing, 83% coverage.
- **Support** — hello@portwoodglobalsolutions.com

## v2.7.0.7 — "Beacon"

- **Header/Footer Images in PDF** — Fixed: images in Word headers and footers now render in PDF output. The template image extraction now parses `word/_rels/header*.xml.rels` and `word/_rels/footer*.xml.rels` in addition to the main document rels. All image relationship IDs are combined so `buildPdfImageMap()` can resolve them. Templates with header/footer images must be re-saved to pick up the fix.
- **Add Related Records UI Refresh** — Fixed: clicking "Add Related Records" now immediately updates the document structure tree and tabs without requiring navigation away and back.
- **All 495 Apex tests passing** (100% pass rate). E2E 19/19. Code Analyzer: 0 Critical, 0 High, 0 Medium.

## v2.7.0.6 — "Beacon"

- **Pre-flight Job Analysis** — The Bulk Runner now runs a comprehensive governor limit analysis on "Validate Filter". Checks SOQL queries per batch, DML statements, record count limits, and heap usage (merge mode). The Run button is disabled until the filter is validated and all checks pass.
- **Dynamic Junction Target ID** — Report import now dynamically resolves the lookup field on junction objects (e.g., `ContactId` on `OpportunityContactRole`) instead of hardcoding. Works for any junction relationship, not just Contact.
- **View Job Button Fix** — The "View Job" button on the batch status card is now clearly visible (uses `variant="inverse"` for white-on-blue).
- **All 495 Apex tests passing** (100% pass rate). E2E 19/19. Code Analyzer: 0 Critical, 0 High, 0 Medium.

## v2.7.0.5 — "Beacon"

- **Default Template Auto-Select** — Fixed: templates marked as "Default Template for this Object" now auto-select in the document runner when opening a record page. Previously the dropdown always started on "Choose a template..." regardless of the default setting.
- **One Default Per Object Enforcement** — Setting a template as default now automatically unsets any other default for the same object. Previously multiple templates could be toggled as default simultaneously.
- **Tab Character Rendering** — Fixed: Word tab characters (`<w:tab/>`) are now correctly rendered as fixed-width spaces in PDF output. A parsing bug caused `<w:tab` to be misidentified as `<w:t>` (text), silently dropping all tab stops.
- **HeapEstimate Null Safety** — `HeapEstimate.isRisk` now initializes to `false` instead of `null`, preventing null-check failures when heap estimation encounters an exception.
- **Test Coverage** — All 491 Apex tests passing (100% pass rate). E2E 19/19. New test for default template enforcement.

## v2.7.0.4 — "Beacon"

- **Proactive Heap Estimator** — The Bulk Runner now automatically estimates the final heap usage before you start a merge job. It simulates a single document generation and projects the total memory requirement, warning you if the job is likely to exceed the 12MB limit.
- **Word Header/Footer Support for PDF** — Content in Word headers and footers (like company addresses and logos) is now correctly included when generating PDFs.
- **Fixed Run Data Loss** — Resolved an issue where text or merge tags in a Docx run were lost if the run also contained a line break (`<w:br/>`).
- **Query Sanitization Graceful Failure** — Invalid clauses in query configurations no longer fail the entire generation.
- **Improved Parent Object Detection** — Fixed self-referential lookup detection.

## v2.6.0 — "Apollo+"

- **Bulk Data Pre-Cache** — All record data queried in a single SOQL with an IN clause during batch `start()`, cached as a JSON ContentVersion on the Job record. Each `execute()` reads from cache instead of re-querying. Eliminates 500+ individual SOQL queries for V3 configs. Graceful fallback to per-record queries for V1/V2 or if cache exceeds 4MB.
- **Template Static Cache** — Template metadata, file content, and pre-decomposed XML parts are cached statically across batch executions. First record queries the template; remaining records reuse it. Zero redundant template SOQL.
- **Merge PDFs Mode** — New "Merge PDFs" checkbox in bulk runner. Generates individual PDFs per record AND produces a single merged PDF at the end. HTML captured as a byproduct of `renderPdf()` — zero extra processing per record.
- **Merge Only Mode** — New "Merge Only" checkbox. Skips `Blob.toPdf()` and ContentVersion saves per record entirely. Only generates HTML snippets, assembles once in a Queueable, renders one merged PDF. ~5-8x faster than individual PDF generation for large batches.
- **Server-Side PDF Assembly** — `DocGenMergeJob` Queueable reads HTML snippets by title prefix, concatenates with page breaks, calls `Blob.toPdf()` once, saves merged PDF linked to the Job record. Accessible anytime via `Merged_PDF_CV__c`.
- **Custom Notifications** — Bell icon + Salesforce mobile push notification on all bulk job completions. Merge jobs notify with page count; normal jobs notify with success/fail count. Tapping navigates to the Job record. Uses `DocGen_Job_Complete` custom notification type.
- **Configurable Batch Size** — New "Batch Size" input in bulk runner UI (1-200, default 1). Simple text-only templates can use 10-50 for faster throughput. Complex templates with images stay at 1 for max heap.
- **lookupField Bug Fix** — Query tree builder now uses the actual lookup field API name from schema describe (`opt.lookupField`) instead of guessing from the parent object name. Fixes incorrect SOQL for custom objects where the lookup field name doesn't match the object name (e.g., `abc__Purchase_Order__c` vs `abc__PurchaseOrder__c`).
- **DateTime Filter Fix** — `getObjectFields()` now returns field type metadata. Filter builder appends `T00:00:00Z` to date-only values on datetime fields. Report filter import applies the same fix for standard datetime fields like CreatedDate.
- **Image Deduplication Confirmed** — Tested `Blob.toPdf()` image handling: same image URL repeated across pages is stored once in the PDF (confirmed via size analysis). Template logos on 500 pages = one embedded image, not 500.
- **New Custom Objects/Fields** — `Data_Cache_CV__c` (bulk data cache), `Merged_PDF_CV__c` (merged PDF link), `Merge_Only__c` (merge-only flag) on DocGen_Job\_\_c. "Merging" status added to Status picklist. `DocGen_Job_Complete` custom notification type.
- **New Apex Classes** — `DocGenMergeJob` (Queueable for server-side PDF assembly).
- **E2E Tests** — 19/19 passing. No regressions from bulk caching or merge changes.

## v2.5.0 — "Apollo+"

- **Child Record PDF Merge** — New "Child Record PDFs" mode in the document generator. Pick a child relationship (e.g., Opportunities from Account), optionally filter with a WHERE clause, browse PDFs attached to each child record with grouped checkboxes and Select All, merge selected PDFs into one document. Download or save to parent record.
- **Bulk Generate + Merge** — After a bulk PDF job completes, merge all generated PDFs into a single downloadable document. Merge icon button on each completed job in the Recent Jobs list for easy access later.
- **Named Bulk Jobs** — Give bulk jobs a custom name (e.g., "March Receipts") for easy identification. Search bar filters the Recent Jobs list by name, template, or status.
- **Aggregate Format Specifiers** — Aggregate tags now support format suffixes: `{SUM:LineItems.TotalPrice:currency}` → $55,000.00. Works with `:currency`, `:percent`, `:number`, and custom patterns like `:#,##0.00`.
- **Aggregate Bug Fix** — Fixed silent failure when format specifiers (`:currency`, etc.) were appended to aggregate tags. The format suffix was being included in the field name lookup, causing the tag to resolve to "0" or disappear.
- **VF Fallback Removed** — Removed `DocGenPdfRenderer` VF page and `DocGenPdfRendererController`. `Blob.toPdf()` with the Spring '26 Release Update handles all PDF rendering. Eliminates the last security scan violation and reduces attack surface.
- **Security Hardening** — Zero PMD security violations. All 22 findings resolved: SOQL injection (validated inputs + NOPMD), CRUD (package-internal objects with permission sets), XSS (ID validation + escaping).
- **Page Breaks in Loops** — README now documents how to use Word page breaks inside child loops for one-page-per-record output (receipts, invoices, certificates).
- **E2E Test Coverage** — 6 new aggregate tests (T14-T19): COUNT, SUM, SUM:currency, AVG, MIN, MAX. Total: 19 tests.

## v2.4.0 — "Apollo+"

- **QR Codes** — `{*Field:qr}` generates QR codes in PDF output. Supports up to 255 characters (full text field). Custom sizing: `{*Field:qr:200}` for 200px square. Version 1-14 with Level M error correction and Reed-Solomon.
- **Barcode Sizing** — `{*Field:code128:300x80}` for custom barcode dimensions.
- **Number & Currency Formatting** — `{Amount:currency}` → $500,000.00. Also `:percent`, `:number`, and custom patterns like `{Price:#,##0.00}`.
- All 13 barcode/QR tests passing, E2E 13/13.

## v2.3.0 — "Apollo+"

- **PDF Merger** — Generate a document and merge it with existing PDFs on the record in one step. Client-side merge engine (`docGenPdfMerger.js`) — pure JS, no external dependencies, zero heap.
- **Merge-Only Mode** — Combine existing PDFs without generating a template. Dual-listbox for reordering. Select 2+ PDFs, merge, download or save.
- **Document Packets** — Select multiple PDF templates, generate each for the same record, merge into one combined document. Optionally append existing PDFs.
- **Aggregate Tags** — `{SUM:QuoteLineItems.TotalPrice}`, `{COUNT:Contacts}`, `{AVG:...}`, `{MIN:...}`, `{MAX:...}`. Computed from child record data already in memory — zero extra SOQL.
- **Barcode Tags** — `{*FieldName}` renders Code 128 barcodes as CSS bars in PDF output. No images, no fonts — pure HTML/CSS rendered by `Blob.toPdf()`.
- **Excel (XLSX) Output** — Upload an Excel template with merge tags in cells. Engine parses shared strings table, inlines references, merges tags, and assembles via client-side ZIP. Same pattern as DOCX.
- **Save to Record for All Formats** — DOCX, XLSX, and PDF can all be saved back to the record. Previously PDF-only.
- **Query Builder Fix** — Selecting fields, changing the search filter, and selecting more fields no longer loses previous selections. Hidden selections are preserved across filter changes.
- **Show Selected Toggle** — New button in the query builder to filter the field list to only selected fields. Works alongside search.
- **Robust PDF Parsing** — Root catalog detection follows `startxref` spec path with nested `<<>>` dictionary handling. Works with PDF 1.5+ cross-reference streams.
- **Page Ordering Fix** — Merged PDFs preserve correct reading order from each document's page tree.

## v2.0.0 — "Apollo"

- **Single-App Experience** — One tab, three cards: Templates, Bulk Generate, How It Works. No more tab sprawl.
- **Bulk Runner Overhaul** — Typeahead template search, inline sample record picker, real PDF preview download, server-loaded job history. All in one view.
- **Zero-Heap PDF Preview** — `generatePdfBlob()` now forces PDF output format, ensuring the pre-decomposed path and relative image URLs are always used. Preview works on templates with dozens of images without hitting heap limits.
- **Query Builder Stability** — Fixed infinite re-parse loop that reset the active tab and wiped field selections on every checkbox toggle. V1 flat configs and V2 JSON configs now load correctly in the visual builder (backward compatible).
- **Self-Contained E2E Tests** — `scripts/e2e-test.apex` creates its own template, DOCX file, template version, test data, generates a real PDF, validates 13 assertions, and cleans up. Zero dependencies on pre-existing org data.
- **Report Filter Auto-Save** — Imported report WHERE clauses automatically saved as bulk queries and loaded when the template is selected.
- **Saved Query Management** — Save, load, and delete named SOQL conditions per template.
- **Recent Jobs Panel** — Completed bulk jobs load from the server with status, counts, template name, and date. Refreshes automatically when a job finishes.

## v1.6.0

- **Multi-Object Query Builder** — Tab-per-object layout with visual relationship tree. Build templates spanning Account → Opportunities → Line Items → Contacts in one view. Each object gets its own tab with field selection, parent field picker, and WHERE/ORDER BY/LIMIT.
- **V3 Query Tree Engine** — New JSON v3 config format. One SOQL query per object node, stitched together in Apex. Supports any depth with zero SOQL nesting limits. Backward compatible with v1/v2 configs.
- **Report Import** — Import field selections from ANY Salesforce Report. Dynamic base object resolution using plural label matching — works for standard, cross-object, and custom report types. Auto-detects parent lookups, child relationships, and junction objects. Report date filters extracted as bulk WHERE clauses.
- **Junction Object Support** — Contact via OpportunityContactRole, Campaign Members, and other junction objects detected and handled automatically. Two-hop queries stitch junction targets into the data map.
- **Click-to-Copy Merge Tags** — Click any tag in the builder to copy it to clipboard with a toast confirmation.
- **Bulk Runner Refresh** — Refresh button on template picker. Report filters auto-populate the WHERE clause when selecting a template built from a report import.
- **Backward-Compatible Upgrade** — Stub methods for removed signature classes allow v1.6.0 to install cleanly over v1.4.0 orgs.
- **E2E Test Suite** — `scripts/e2e-test.apex` validates 13 tests: V3 tree walker, parent fields, grandchild stitching, image CV creation, junction stitching, legacy backward compat, document generation. Self-cleaning. One click.
- **Stress Test** — `scripts/stress-test-data.apex` creates a Quote with 15 products, each with a product image. Validates zero-heap image rendering at scale.
- **Amanda-Friendly Naming** — All labels use plain English: "Opportunity Products" not "OpportunityLineItems", "Your Document Structure" not "Relationship Map", "Include parent fields" not "Add parent above".

## v1.5.0

- **Command Hub** — Single-tab UX replacing 7 tabs. Wizard-first onboarding, embedded bulk generator, contextual help.
- **Deep Grandchild Relationships** — Multi-level query stitching: Account → Opportunities → Line Items → Schedules. One SOQL per level, stitched in Apex. Query builder UI supports "Add Related List" inside child cards.
- **Signature Feature Removed** — E-signatures carry legal requirements a doc gen tool should not implement. Use dedicated providers (DocuSign, Adobe Sign).
- **Custom Font Upload Removed** — `Blob.toPdf()` does not support CSS `@font-face` (confirmed via data URIs, static resources, and ContentVersion URLs). PDF supports Helvetica, Times, Courier, Arial Unicode MS. DOCX preserves template fonts.
- **Font Documentation** — PDF font limitations documented. DOCX recommended for custom fonts.
- **DOCX Download Only** — Save to Record removed for DOCX output (Aura 4MB payload limit). Download works for any size.

## v1.3.4

- **Zero-Heap PDF Images** — `{%ImageField}` tags skip blob loading for PDF; images resolved by URL with zero heap cost
- **Pre-Decomposed Templates** — Template XML stored as ContentVersions on save; PDF generation skips ZIP decompression (~75% heap reduction)
- **PDF Image Fix** — Relative Salesforce URLs for `Blob.toPdf()` compatibility
- **Bold Space Fix** — Preserved whitespace between adjacent bold merge fields
- **Encoding Fix** — `&` no longer double-encoded in PDF output
- **Documentation Overhaul** — Release Update visibility, query builder limits, troubleshooting, known limitations table
- **Rich Text Fields** — Bold, italic, paragraph structure, and embedded images preserved in Word and PDF output

## v1.2.2

- **Admin Guide** — Data Model section with object reference tables
- **Page Layouts** — Added layouts for all custom objects

## v1.2.0

- **Unified PDF Generation** — Single code path for single and bulk PDF. -766 lines of duplicated logic.
- **Spring '26 Blob.toPdf() Compatibility** — Native rendering with Release Update, VF fallback without
- **Page Break Fix** — `page-break-inside: avoid` on paragraphs and list items

## v1.1.1

- **PDF Renderer** — Full DOCX style conversion: headings, lists, line spacing, page breaks, borders, shading, hyperlinks, superscript/subscript, tables
- **Merge Fields** — `{!Field}` Salesforce-style syntax and base object prefix stripping
- **Query Parser** — Auto-splits fields from adjacent subqueries

## v1.1.0

- **Admin Guide** — In-app guide covering all features
- **Version Preview** — Query display, template download, sample generation
- **Security** — `Security.stripInaccessible()`, sanitization hardening, error genericization

## v1.0.0

- **Server-Side PDF** — All generation via `DocGenHtmlRenderer` + `Blob.toPdf()`. Zero client-side JavaScript.
- **Security** — API v66.0, CRUD/FLS enforcement

## v0.9.x

- PKCE Auth Fix, wizard UX improvements, credential provisioning

## v0.8.0

- Fixed package uninstall blockers, updated terminology

## v0.7.0 and earlier

- Bulk PDF generation, transaction finalizers, security hardening, compression API migration, rich text support, 2GP package
