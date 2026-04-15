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

## E-Signatures (v3 — Guided Signing, Packets, Sequential)

Major overhaul shipped in v1.43.0 (April 2026). Architecture is sophisticated but the codebase is currently fragile after a 24-hour iteration sprint. See "FRAGILITY NOTES" section below.

### v3 Tag Syntax

Format: `{@Signature_Role:Order:Type}`

- **Role** — signer role (Buyer, Seller, Witness, Loan_Officer with underscores for multi-word)
- **Order** — sequence number per-role (optional, defaults to 1)
- **Type** — Full | Initials | Date | DatePick (optional, defaults to Full)

Backward compatible: `{@Signature_Buyer}` still works (treated as `:1:Full`).

### Data Model
- `DocGen_Signature_Request__c` — parent record. Fields: `Template__c`, `Template_Ids__c` (packet), `Status__c`, `Signing_Order__c` (Parallel/Sequential), `Email_Status__c` (delivery diagnostics), `Signature_Data__c` (cached preview HTML + image map)
- `DocGen_Signer__c` — one per signer. Fields: `Role_Name__c`, `Status__c` (Pending/Viewed/Signed/Cancelled/Declined), `Signature_Data__c` (typed name), `PIN_Hash__c`, `PIN_Verified_At__c`, `Decline_Reason__c`, `Reminder_Sent_At__c`, `Sort_Order__c`
- `DocGen_Signature_Placement__c` — NEW v3 child of Signer. One record per signature/initial/date placement. Fields: `Sequence_Order__c`, `Placement_Type__c`, `Status__c`, `Signed_Value__c`, `Signed_At__c`, `Tag_Text__c`, `Document_Index__c`, `Section_Context__c`
- `DocGen_Signature_Audit__c` — immutable audit. IP, user agent, hash, consent, PIN verified timestamp
- `DocGen_Signature_PDF__e` — platform event for async PDF generation AND notifications

### Critical: Two Code Paths That Need Consolidation

**This is the #1 fragility issue.** There are two methods that do almost-but-not-quite the same thing:

1. `DocGenSignatureSenderController.createTemplateSignerRequestWithOrder()` — called by LWC sender
2. `DocGenSignatureSenderController.createTemplateSignatureRequestForFlow()` — called by Flow action

Both:
- Insert request record
- Call `mergeTemplateForSignature()` for preview
- Build preview HTML with placement spans
- Call `createSignersAndNotify()` which creates signers + placements
- Send branded emails

Differences (each a potential bug):
- LWC version sets `Signing_Order__c`, Flow version doesn't
- LWC version calls `injectPlacementSpans()`, Flow version calls `convertToHtml()` directly
- Default `sendEmails` value differs

**Next session must consolidate these into one shared private method.**

### Signing Page Flow

The VF page `DocGenSignature.page` runs in guest user context and has multiple states:
- `loading` → `error` (token invalid) | `verify` (PIN entry) | `guided` (v3 signing) | `signature` (v2 fallback)
- Guided state: shows full document HTML, sticky action bar at bottom, arrow indicator on current placement
- Each placement signed individually via `signPlacement()` remoting — persists to `DocGen_Signature_Placement__c.Status__c = 'Signed'`
- Signer can leave and resume — PIN re-verification required on return
- After all placements: consent checkbox + final submit → `saveSignature()` publishes platform event

### Critical: Guest User Constraints

Guest users CANNOT:
- Send email without OWA (`setOrgWideEmailAddressId` required)
- Call `Auth.SessionManagement.getCurrentSession()` — throws uncatchable session error
- Query User table
- Access ContentVersion via `/sfc/servlet.shepherd/` URLs (browser auth blocks)

Guest user code paths in `DocGenSignatureController.cls`:
- `validateToken`, `sendPin`, `verifyPin`, `getSignerPlacements`, `signPlacement`, `getImageBase64`, `saveSignature`, `declineSignature`, `stampAndReturnSource`

The image proxy `getImageBase64()` returns base64 for guest users since they can't fetch /sfc/ URLs. Signing page JS replaces `<img src="/sfc/...">` with data URIs.

`captureClientIp()` MUST check `UserInfo.getUserType() != 'Guest'` before calling `Auth.SessionManagement.getCurrentSession()`.

### Platform Event Trigger

`DocGenSignaturePdfTrigger` runs as Automated Process user (system context). Handles:
- All-signers-complete → enqueue `TemplateSignaturePdfQueueable` for PDF generation + send `sendAllSignedNotification`
- Some-signers-pending → send `sendSignerCompletedNotification` for last signer; if Sequential, send next signer's invite email
- Declined → send `sendDeclineNotification`

Guest users publish the event via `EventBus.publish()` from `saveSignature()` and `declineSignature()`. This bridges guest → system context for email sending and User table queries.

### Email Service

`DocGenSignatureEmailService` — handles ALL signature-related emails. Methods:
- `sendSignatureRequestEmails(signers, docTitle, requestId)` — initial branded invitations
- `sendSignerCompletedNotification(requestId, signer)` — sent to creator when one signer completes
- `sendAllSignedNotification(requestId)` — sent to creator when all done
- `sendDeclineNotification(requestId, signer, reason)` — sent to creator on decline

OWA REQUIRED in production. There's a `Test.isRunningTest()` bypass that skips the OWA check — this is a code smell that next session should fix properly.

`Email_Status__c` field on the request shows delivery diagnostics — admins check this when signers report not receiving emails. Common error messages are explained in the field value (no OWA, deliverability disabled, daily limit, etc.).

Reply-to is set to the request creator's email so signer replies go to the actual sender, not the OWA.

### Reminder Schedulable

`DocGenSignatureReminderSchedulable` queries pending signers past `Signature_Reminder_Hours__c` threshold and sends one reminder per signer (tracked via `Reminder_Sent_At__c`). Auto-scheduled hourly when admin enables reminders in settings via `DocGenSetupController.saveReminderSettings()`.

Test note: has `@TestVisible private static DateTime testThresholdOverride` for tests since CreatedDate can't be set in tests.

### Setup Validation

`DocGenSetupController.validateSignatureSetup()` returns a checklist of pass/fail items shown in the signature settings UI:
1. Site URL configured
2. Active Salesforce Site exists
3. OWA configured and valid
4. Guest permission set assigned
5. VF pages deployed

### Namespace Issue (PRODUCTION)

In subscriber orgs, custom field API names come back from SObject `JSON.serialize` with namespace prefix: `portwoodglobal__Signature_OWA_Id__c` not `Signature_OWA_Id__c`. The LWC `getSettings()` wire returned the SObject directly which broke field access in production.

Fix: `DocGenSetupController.getSettingsFresh()` returns a plain `Map<String, Object>` with unqualified field names. `docGenSignatureSettings.js` uses this method instead of the cacheable `getSettings()`.

### v3 Component Map

**LWC components:**
- `docGenSignatureSender` — record-page component for creating requests. Multi-template selection, signer rows with auto-detection, preview modal, signing order toggle
- `docGenSignatureSettings` — admin settings with setup validation checklist, OWA selector, reminder configuration
- `docGenAdmin` — template manager (createTemplate now correctly persists `Test_Record_Id__c`)
- `docGenAdminGuide` — DEPRECATED stub redirecting to Command Hub Learning Center
- `docGenCommandHub` — main app tab with Learning Center containing all v3 docs

**Apex classes:**
- `DocGenSignatureController` — guest user endpoints (validateToken, sendPin, verifyPin, getSignerPlacements, signPlacement, getImageBase64, saveSignature, declineSignature, stampAndReturnSource)
- `DocGenSignatureSenderController` — internal user endpoints (createTemplateSignerRequest*, createPacketSignerRequest, getTemplateSignaturePlacements, getDocumentPreviewHtml, plus lots of legacy)
- `DocGenSignatureService` — stamping logic (`stampSignaturesInXml` with placement awareness), `TemplateSignaturePdfQueueable`, `buildVerificationBlockHtml`
- `DocGenSignatureEmailService` — all email sending
- `DocGenSignatureFlowAction` — Flow invocable with `Signer` apex type
- `DocGenSignatureReminderSchedulable` — reminder cron job
- `DocGenSignaturePdfTrigger` — platform event trigger (notifications, sequential signing, PDF generation enqueue)

### Permission Sets

Three sets, all updated for v3:
- `DocGen_Admin` — full CRUD on all signature objects including new placement object, all new fields
- `DocGen_User` — read/edit on most fields, no delete
- `DocGen_Guest_Signature` — READ on requests/signers/placements; CREATE on audits; access to DocGenSign, DocGenSignature, DocGenVerify VF pages

When adding new fields, update ALL THREE permission sets (this has been a recurring miss).

### FRAGILITY NOTES (post v1.43-1.44 sprint)

After 24 hours of iterative changes, several areas are fragile and need refactoring:

1. **Two signature creation paths** (LWC vs Flow) must be consolidated into one shared method
2. **Test coverage hovers at 74-75%** — adding new code drops it below threshold; we need integration tests that exercise full pipelines, not unit tests that mock around problems
3. **`Test.isRunningTest()` bypass in DocGenSignatureEmailService** — code smell, should restructure to test email assembly without the OWA gate
4. **Test assertions tweaked to pass** rather than fixing root causes — many tests assert `notEquals(null)` instead of meaningful values
5. **Throw-vs-catch pattern in Flow action is split** — validation throws (backward compat), runtime errors return in Result. Inconsistent.
6. **Email status tracking is new** — the `Email_Status__c` field is populated but no UI surfaces it yet on the signature request record page
7. **Signer apex type AND legacy parallel lists** in Flow action — backward compat overhead
8. **Image proxy untested** — `getImageBase64()` works in theory but hasn't been validated with a real template containing template images

### Production Email Diagnosis

When emails don't arrive, check in this order:
1. **Setup > Deliverability** — must be "All Email" (default in scratch is "System Email Only")
2. **OWA "Allow All Profiles"** — in OWA settings, must be checked or specific profiles listed include the sender's profile
3. **OWA verified** — green checkmark next to the address
4. **Daily email limit** — Setup > Company Information shows remaining sends
5. **DNS/SPF** — domain must have `include:_spf.salesforce.com` in TXT record
6. **DMARC** — `p=none` is fine; `p=reject` will block
7. **DKIM** — Setup > DKIM Keys, create + activate, add CNAME records to DNS
8. **`Email_Status__c` field** on the signature request — shows exact error per signer

### Real-World Tester Feedback (April 2026)

- ElFuma + Matt: first external testers, found 4 bugs (all fixed)
- Charset issue: Arabic, Chinese, Japanese, Russian, Turkish characters fail with ISO-8859-1 default. Fix: `<meta charset="utf-8"/>` in HTML output. RTL layout already supported.
- Google Docs DOCX export uses different XML structure than Microsoft Word — not yet supported. Future enhancement.

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

### 1. E2E Test Suite (8 chained scripts)
```bash
sf apex run --target-org <org> -f scripts/e2e-01-permissions.apex
sf apex run --target-org <org> -f scripts/e2e-02-template-crud.apex
sf apex run --target-org <org> -f scripts/e2e-03-generate-pdf.apex
sf apex run --target-org <org> -f scripts/e2e-04-generate-docx.apex
sf apex run --target-org <org> -f scripts/e2e-05-generate-bulk.apex
sf apex run --target-org <org> -f scripts/e2e-06-signatures.apex
sf apex run --target-org <org> -f scripts/e2e-07-syntax.apex
sf apex run --target-org <org> -f scripts/e2e-08-cleanup.apex
```
Expected: Each script prints `PASS: N  FAIL: 0  ALL TESTS PASSED`

Scripts run in sequence: 01 is standalone, 02 creates test data, 03-06 depend on 02, 07 is standalone (uses processXmlForTest), 08 cleans up everything.

**MANDATORY: When adding ANY feature, field, merge tag, or configuration:**
1. Add assertions to the appropriate e2e script FIRST — before or alongside the feature code
2. Script domain mapping:
   - `e2e-01-permissions` — new Apex classes, VF pages, custom objects, field permissions
   - `e2e-02-template-crud` — template creation, version management, data retrieval
   - `e2e-03-generate-pdf` — PDF generation, output verification
   - `e2e-04-generate-docx` — DOCX generation, ZIP validation, client-side assembly
   - `e2e-05-generate-bulk` — bulk jobs, saved queries, job analysis
   - `e2e-06-signatures` — signature requests, PIN flow, settings, verification
   - `e2e-07-syntax` — ALL merge tag types via processXmlForTest()
   - `e2e-08-cleanup` — add delete statements for any new custom objects
3. Every new merge tag syntax must have a processXmlForTest() assertion in e2e-07
4. Every new custom field must be verified in the permission set validation in e2e-01
5. Every new Apex class must be added to the permission set checks in e2e-01
6. Every new VF page must be verified in the guest permission set checks in e2e-01
7. Each script must stay under 18,000 characters (Anonymous Apex limit is 20,000)

### 2. Apex Test Suite (850+ tests, 75% coverage)
```bash
sf apex run test --target-org <org> --test-level RunLocalTests --wait 15 --code-coverage
```
Expected: `Outcome: Passed`, `Pass Rate: 100%`, org-wide coverage ≥ 75%

### 3. Code Analyzer — Security + AppExchange (0 violations)
```bash
sf code-analyzer run --workspace "force-app/" --rule-selector "Security" --rule-selector "AppExchange" --view table
```
Expected: `0 High severity violation(s) found.` (30 Moderate false positives are acceptable — see `code-analyzer.yml`)

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
