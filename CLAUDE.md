# CLAUDE.md — SalesforceDocGen Project Guidelines

## Critical: Blob.toPdf() Image URL Rules

The Spring '26 `Blob.toPdf()` rendering engine has strict requirements for image URLs in HTML:

- **MUST use relative Salesforce paths**: `/sfc/servlet.shepherd/version/download/<ContentVersionId>`
- **NEVER use absolute URLs**: `https://domain.com/sfc/servlet.shepherd/...` — fails silently (no exception, broken image)
- **NEVER use data URIs**: `data:image/png;base64,...` — not supported, renders broken

In `DocGenService.buildPdfImageMap()`, do NOT prepend `URL.getOrgDomainUrl()` to ContentVersion download URLs. Keep them relative. The `Blob.toPdf()` engine resolves relative Salesforce paths internally.

## Critical: Zero-Heap PDF Image Rendering

For PDF output, `{%ImageField}` tags with ContentVersion IDs MUST skip blob loading. The `currentOutputFormat` static variable is set to `'PDF'` before `processXml()` calls. In `buildImageXml()`, when `currentOutputFormat == 'PDF'` and the field value is a ContentVersion ID (`068xxx`), query only `Id, FileExtension` (NOT `VersionData`) and store the relative URL. This is what enables unlimited images in PDFs without heap limits.

**NEVER** add `VersionData` to the SOQL query in the PDF path. Each image blob would consume 100KB-5MB+ of heap, and with multiple images this immediately exceeds governor limits.

## PDF Image Pipeline

### How template images are prepared (on save)

When an admin saves a template version (via `DocGenController.saveTemplate()`), the system calls `DocGenService.extractAndSaveTemplateImages(templateId, versionId)`. This method:

1. Downloads the DOCX/PPTX ZIP from the template's ContentVersion
2. Reads `word/_rels/document.xml.rels` to find all `<Relationship>` entries with `Type` containing `/image`
3. For each image relationship, extracts the image blob from `word/media/`
4. Saves each image as a new ContentVersion with `Title = docgen_tmpl_img_<versionId>_<relId>` and `FirstPublishLocationId = versionId`

This pre-extraction is essential — it creates committed ContentVersion records that `Blob.toPdf()` can reference by relative URL at generation time.

### How template images are rendered (on generate)

At PDF generation time, `buildPdfImageMap()` queries for these pre-committed CVs:
- Finds the active template version
- Queries `ContentVersion WHERE Title LIKE 'docgen_tmpl_img_<versionId>_%'`
- Builds relative URLs: `/sfc/servlet.shepherd/version/download/<cvId>`
- `DocGenHtmlRenderer.convertToHtml()` embeds these as `<img src="/sfc/...">` in the HTML
- `Blob.toPdf()` resolves the relative paths and renders the images

## Package Info

- Package type: Unlocked 2GP with namespace `portwoodglobal`
- Package name: Portwood DocGen
- DevHub: `Portwood Global - Production` (dave@portwoodglobalsolutions.com)
- Dev scratch org: `docgen-test-ux`
- Demo scratch org: `docgen-demo-v2`
- Website: https://portwoodglobalsolutions.com

## Key Architecture

- PDF rendering has two paths in `mergeTemplate()`:
  1. **Pre-decomposed (preferred)**: Loads XML parts from ContentVersions saved during template version creation. Skips ZIP decompression entirely. ~75% heap savings. Used for PDF output when XML CVs exist.
  2. **ZIP path (fallback)**: Full base64 decode + ZIP decompression. Used for DOCX/PPTX output, or PDF when pre-decomposed parts don't exist (older templates not yet re-saved).
- After merge: `buildPdfImageMap()` → `DocGenHtmlRenderer.convertToHtml()` → `Blob.toPdf()` with VF page fallback
- The Spring '26 Release Update "Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations" is REQUIRED

## Client-Side DOCX Assembly (In Progress)

DOCX generation now uses client-side ZIP assembly to avoid Apex heap limits:

### How it works
1. Server calls `generateDocumentParts()` which merges XML using `currentOutputFormat='PDF'` trick (skips blob loading)
2. Server returns: `allXmlParts` (merged XML + passthrough entries), `imageCvIdMap` (mediaPath → CV ID), `imageBase64Map` (template media)
3. Client deduplicates CV IDs and calls `getContentVersionBase64()` for each **unique** CV — each call gets fresh 6MB heap
4. Client builds ZIP from scratch via `buildDocx()` in `docGenZipWriter.js` (pure JS, no dependencies)
5. Download works for unlimited size. Save-to-record blocked by Aura 4MB payload limit (needs chunking or alternative).

### Key files
- `docGenRunner/docGenZipWriter.js` — Pure JS ZIP writer (store mode, CRC-32). Exports `buildDocx(xmlParts, mediaParts)` and `buildDocxFromShell()`
- `DocGenService.generateDocumentParts()` — Returns merged parts without ZIP assembly
- `DocGenController.getContentVersionBase64()` — Returns single CV blob as base64, each call = fresh heap
- `DocGenController.generateDocumentParts()` — AuraEnabled endpoint

### Important: rels XML must include ALL image relationships
In both `mergeTemplate()` (full ZIP path, ~line 174) and `tryMergeFromPreDecomposed()` (~line 293), the pending images loop that adds relationships to rels XML must process ALL images, not just ones with blobs. URL-only images need rels entries too for DOCX.

### LWS Constraints
- Lightning Web Security blocks `fetch()` to `/sfc/servlet.shepherd/` URLs (CORS redirect to `file.force.com`)
- All binary data must be returned via Apex, not client-side fetch
- `Blob` constructor in LWC rejects non-standard MIME types — use `application/octet-stream` for DOCX downloads

## E-Signatures (v2 — Restored)

E-signatures were removed in v1.5 and restored in v2 with a completely reworked architecture:

### Signature Architecture
- **Typed name** instead of canvas-drawn signatures — same SES legal weight, zero heap for images
- **Email PIN verification** — 6-digit code, SHA-256 hashed, 10-min expiry, 3 attempts max
- **Consent checkbox** with explicit audit trail entry
- **48-hour token expiry** (was 30 days in v1.4)
- **`{@Signature_Role}` placeholder syntax** — uses `@` prefix to avoid conflict with `{#Loop}` tags
- **Electronic Signature Certificate** — appended to every signed PDF with signer details and verify URL
- **Document verification page** — `DocGenVerify.page` supports request ID lookup and file hash verification
- **Server-side IP capture** — via `X-Forwarded-For` / `True-Client-IP` headers
- **Field history tracking** on all audit fields
- **Org-Wide Email Address** support for branded sender

### Signature Objects
- `DocGen_Signature_Request__c` — parent record, links to template + related record
- `DocGen_Signer__c` — one per signer, tracks PIN verification, consent, typed name
- `DocGen_Signature_Audit__c` — immutable audit record with SHA-256 hash, IP, user agent, field history
- `DocGen_Signature_PDF__e` — platform event triggers async PDF generation

### Key Implementation Notes
- `{@...}` tags are preserved by `processXml()` (line ~1709 in DocGenService) — it skips any tag starting with `@`
- `mergeTemplateForSignature()` in DocGenService is the entry point for signature PDF generation (was a stub that threw in v1.5, now restored)
- Typed names replace placeholders as plain text inside `<w:t>` elements — no DrawingML, no image blobs
- The `TemplateSignaturePdfQueueable` handles template-based signature PDF generation asynchronously via platform event
- Verification block HTML is built by `DocGenSignatureService.buildVerificationBlockHtml()` and injected before `</body>` in the HTML before `Blob.toPdf()`
- Guest user email sending requires an Org-Wide Email Address to be configured in Signature Settings

## Font Support

### PDF output
`Blob.toPdf()` uses Salesforce's Flying Saucer rendering engine which only supports 4 built-in font families:
- **Helvetica** (`sans-serif`) — the default
- **Times** (`serif`)
- **Courier** (`monospace`)
- **Arial Unicode MS** — for CJK/multibyte characters

Custom fonts **cannot** be loaded into the PDF engine. CSS `@font-face` is not supported — not via data URIs, static resource URLs, or ContentVersion URLs. This is a Salesforce platform limitation, not a DocGen limitation. Paid tools like Nintex and Conga work around this by using their own rendering engines outside of Salesforce.

**Do NOT re-add custom font upload for PDF.** It was built, tested exhaustively (base64 data URIs, static resource URLs, ContentVersion URLs), and confirmed not possible.

### DOCX output
DOCX output preserves whatever fonts are in the template file. If users need custom fonts (branded typefaces, barcode fonts, decorative scripts), they should generate as DOCX. The fonts render correctly when opened in Word or any compatible viewer.

## Scratch Orgs

- **docgen-test-ux**: Development and testing scratch org
- **docgen-demo-v2**: Public demo org (SSO via landing page, 30-day expiry)
- Create new scratch orgs from `Portwood Global - Production` DevHub

## Release Validation Checklist

**All three checks MUST pass before every release. No exceptions.**

### 1. E2E Test Script (24 tests)
```bash
sf apex run --target-org <org> -f scripts/e2e-test.apex
```
Expected: `PASS: 24  FAIL: 0  ALL TESTS PASSED`

Self-contained — creates all test data, runs full document generation pipeline, validates output, cleans up. Zero dependencies on pre-existing org data.

**When adding features:** Add assertions to `scripts/e2e-test.apex` first.

### 2. Apex Test Suite (629 tests, 76% coverage)
```bash
sf apex run test --target-org <org> --test-level RunLocalTests --wait 15 --code-coverage
```
Expected: `Outcome: Passed`, `Pass Rate: 100%`, org-wide coverage ≥ 75%

### 3. Code Analyzer — Security + AppExchange (0 violations)
```bash
sf code-analyzer run --workspace "force-app/" --rule-selector "Security" --rule-selector "AppExchange" --view table
```
Expected: `Found 0 violations.`

Runs PMD security rules, AppExchange-specific rules, and Salesforce Graph Engine (SFGE) taint analysis. SFGE timeouts on complex methods are normal — only violations count.

**If any check fails, the change doesn't ship.**

## Query Config Formats

Three formats, all stored in `Query_Config__c` (32KB LongTextArea):

### V1 — Legacy flat string
```
Name, Industry, (SELECT FirstName, LastName FROM Contacts)
```
Detected by: does NOT start with `{`. Parsed by the original `getRecordData()` method.

### V2 — JSON flat (junction support)
```json
{"v":2,"baseObject":"Opportunity","baseFields":["Name"],"parentFields":["Account.Name"],
 "children":[{"rel":"OpportunityLineItems","fields":["Name"]}],
 "junctions":[{"junctionRel":"OpportunityContactRoles","targetObject":"Contact","targetIdField":"ContactId","targetFields":["FirstName"]}]}
```
Detected by: starts with `{`, `"v":2`. Parsed by `getRecordDataV2()`.

### V3 — Query tree (multi-object, any depth)
```json
{"v":3,"root":"Account","nodes":[
  {"id":"n0","object":"Account","fields":["Name"],"parentFields":["Owner.Name"],"parentNode":null,"lookupField":null,"relationshipName":null},
  {"id":"n1","object":"Contact","fields":["FirstName"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"},
  {"id":"n2","object":"Opportunity","fields":["Name","Amount"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Opportunities"},
  {"id":"n3","object":"OpportunityLineItem","fields":["Quantity"],"parentFields":["Product2.Name"],"parentNode":"n2","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems"}
]}
```
Detected by: starts with `{`, `"v":3`. Parsed by `getRecordDataV3()` tree walker. Each node is one SOQL query, stitched into parent's data map via `lookupField`.

**Backward compat:** All three formats work. The DataRetriever auto-detects the format and routes to the correct parser.

## Command Hub Architecture

The DocGen app has 2 tabs: "DocGen" (Command Hub) and "Job History".

The Command Hub (`docGenCommandHub` LWC) contains:
- Welcome banner (< 10 templates, dismissible)
- Quick action cards (Templates, Bulk Generate, How It Works)
- Embedded template manager (`docGenAdmin`)
- Embedded bulk runner (`docGenBulkRunner`, collapsible)
- Help section with merge tag cheat sheet, heap architecture explanation, Flow integration

The template wizard uses `docGenColumnBuilder` for the query builder step (tab-per-object layout with tree visualization). The old `docGenQueryBuilder` is still available via Manual Query toggle for legacy configs.

## Font Support

### PDF output
`Blob.toPdf()` only supports 4 built-in fonts: Helvetica (`sans-serif`), Times (`serif`), Courier (`monospace`), Arial Unicode MS. CSS `@font-face` is NOT supported. **Do NOT re-add custom font upload for PDF.**

### DOCX output
Preserves whatever fonts are in the template file.

## AppExchange

DocGen is NOT on the AppExchange. Do not reference AppExchange in user-facing documentation (admin guide, README). Code comments saying "AppExchange safe" (meaning no callouts/session IDs) are fine.
