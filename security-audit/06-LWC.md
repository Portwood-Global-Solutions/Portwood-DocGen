# LWC Security Audit (06)

Audit of `force-app/main/default/lwc/` for security-relevant patterns at the Apex-call boundary. 17 LWC bundles inspected via grep + targeted reads.

## Apex methods called from LWC (full list)

Imports collected from `grep -rn "@salesforce/apex/"`. Grouped by Apex class.

### `DocGenController` (called from `docGenAdmin`, `docGenBulkRunner`, `docGenColumnBuilder`, `docGenCommandHub`, `docGenFilterBuilder`, `docGenQueryBuilder`, `docGenRunner`, `docGenTreeBuilder`)

- `getAllTemplates`, `deleteTemplate`, `saveTemplate`, `getTemplateVersions`, `processAndReturnDocument`, `generatePdf`, `generatePdfAsync`, `activateVersion`
- `createSampleTemplates`, `exportTemplate`, `importTemplate`
- `getObjectFields`, `getObjectOptions`, `getChildRelationships`, `getParentRelationships`, `previewRecordData`
- `saveWatermarkImage`, `clearWatermarkImage`
- `searchDataProviders`, `validateDataProvider`
- `testRecordFilter`
- `saveHtmlTemplateImage`, `saveHtmlTemplateBody`
- `getContentVersionSize`, `deleteContentVersionDocument`
- `getOrgId`
- `getAvailableReports`, `importReportConfig`
- `scoutAttachedImageSize`, `getChildRecordPdfs`, `getRecordPdfs`
- `generateDocumentGiantQuery`, `getGiantQueryJobStatus`, `getGiantQueryFragments`, `generateDocumentPartsGiantQuery`, `cleanupGiantQueryFragments`
- `getChildRecordPage`, `scoutChildCounts`, `launchGiantQueryPdfBatch`, `getSortedChildIds`, `getChildRecordsByIds`
- `renderImageAsPdfBase64`
- `getTemplatesForObjectAndRecord`
- `generateDocumentParts`, `getContentVersionBase64`
- `saveGeneratedDocument`

### `DocGenBulkController` (called from `docGenBulkRunner`)

- `getBulkTemplates`, `validateFilter`, `submitJob`, `getJobStatus`
- `getSavedQueries`, `saveQuery`, `deleteQuery`, `getRecentJobs`, `analyzeJob`

### `DocGenAuthenticatorController` (called from `docGenAuthenticator`)

- `verifyDocument`, `verifyByRequestId`

### `DocGenSetupController` (called from `docGenSetupWizard`, `docGenSignatureSettings`)

- `getSettings`, `getSettingsFresh`, `saveSettings`, `saveSignatureSettings`
- `getOrgWideEmailAddresses`, `validateSignatureSetup`, `saveReminderSettings`

### `DocGenSignatureSenderController` (called from `docGenSignatureSender`)

- `getSignerRolePicklistValues`, `createTemplateSignerRequestWithOrder`, `markSignerVerifiedInPerson`, `createPacketSignerRequest`
- `getContactInfo`, `getPendingSignatureRequests`, `getDocGenTemplatesForRecord`
- `getTemplateSignaturePlacements`, `getDocumentPreviewHtml`

### NOT called from any LWC (server-only / Flow / VF / platform-event)

Confirmed not in any LWC import list — these are reached only from VF pages, Flow, triggers, schedulables, or platform events. They still need their own audit passes (and should be on the controller/service audit roster):

- `DocGenSignatureController` (all guest-user endpoints used by `DocGenSignature.page` / `DocGenSign.page`: `validateToken`, `sendPin`, `verifyPin`, `getSignerPlacements`, `signPlacement`, `getImageBase64`, `saveSignature`, `declineSignature`, `stampAndReturnSource`)
- `DocGenSignatureService` / `TemplateSignaturePdfQueueable` (queueables, no direct LWC entry)
- `DocGenSignatureEmailService` (called from triggers/queueables only)
- `DocGenSignatureFlowAction` (Flow invocable)
- `DocGenSignatureReminderSchedulable` (cron)
- `DocGenSignaturePdfTrigger` (platform event trigger)
- `DocGenFlowAction` (Flow invocable)

These should be covered by parallel audit passes — they have a security profile (especially `DocGenSignatureController` which runs in guest-user context).

## innerHTML usages reviewed

Single match found across the entire LWC tree:

### `docGenSignatureSender.js:355` — `container.innerHTML = this.previewHtml`

Used to render server-merged preview HTML in a modal. The preview body comes from `getDocumentPreviewHtml` (Apex), which runs `DocGenHtmlRenderer.convertToHtml` on merged template XML — record field values are XML-escaped server-side. The bundle is necessary because LWC's `lwc:html` directive doesn't support arbitrary HTML rendering for preview content.

**Issue found and FIXED in this audit:** the surrounding code path also concatenated:

1. `tmpl.name` (template Name, admin-controlled but not sanitized by Apex)
2. `err.body.message` / `err.message` (Apex error string) — into HTML strings before `innerHTML` assignment.

Pre-fix, an unusual template name with `<script>` would render as raw HTML in the preview modal. Apex framework errors do not typically echo user input, but the concatenation pattern was unsafe.

**Fix:** added a local `escapeHtml(s)` helper in `handleShowPreview` and applied it to `tmpl.name` (two sites) and the error message before innerHTML assignment. The server-rendered preview HTML itself is left intact (it must contain markup to render). See `force-app/main/default/lwc/docGenSignatureSender/docGenSignatureSender.js` lines ~308-360.

## fetch() patterns

`grep -rn "fetch("` returned **zero hits** across the LWC tree. CLAUDE.md's LWS-blocked-fetch concern is not present in current code. All binary data flows through Apex (`getContentVersionBase64`, `renderImageAsPdfBase64`).

## Other findings

### Blob constructor MIME types — all compliant

All `downloadBase64(...)` calls use the correct MIME type per the CLAUDE.md rule:

- `application/pdf` — for PDFs
- `application/octet-stream` — for DOCX, PPTX (verified `docGenRunner.js` lines 667, 1197, 1219, 1411)
- `application/json` — for template JSON export (`docGenAdmin.js:1900`)

Helper centralized in `docGenUtils/docGenUtils.js:13` (`downloadBase64`). No bespoke `Blob` construction elsewhere except internal compression-stream pipes in `docGenPdfImageExtractor.js` (not user-facing downloads).

### `window.location` redirects — safe

Only one usage: `docGenAuthenticator.js:13` reads `window.location.search` to extract a Salesforce request ID. The value is **regex-validated** against `/^[a-zA-Z0-9]{15,18}$/` before being passed to Apex. Comment already flags this as a CxSAST DOM-XSS mitigation. No redirects of caller-supplied URLs elsewhere.

### `document.write` / `document.cookie` — absent

Zero hits.

### `eval()` / `new Function(...)` / `setTimeout('string',...)` — absent

Zero hits. Multiple `setTimeout(() => ..., n)` callbacks exist (preview render, modal animations) but all use function references, not strings.

### `crossorigin="anonymous"` — absent

Zero hits. The CLAUDE.md broken-canvas-extraction pattern is not present. The PDF-extract trick (Apex-side `Blob.toPdf()` → base64 → client decode in `docGenPdfImageExtractor.js`) is the pattern used instead — server-side fetch privileges, not browser-side CORS.

### Inline event handlers (`onclick="..."`) in templates — absent

All `onclick=` / `onchange=` matches in `.html` files use LWC template binding syntax (`onclick={handlerMethod}`), not inline JS strings. This is the canonical LWC event-binding mechanism — not a CSP violation.

### `outerHTML` / `insertAdjacentHTML` — absent

Zero hits.

### `@wire` data caching — no PII concerns

`@wire(getOrgWideEmailAddresses)` in `docGenSignatureSettings` caches admin-only OWA picklist (no PII). Other wires retrieve template metadata, picklist values, and field describes — all admin-configured metadata. No tokens or session IDs are wired.

## Test phase

`package.json` has only `format` / `format:check` scripts. No `lint` script and no `__tests__/` folder under any LWC bundle. Skipping per audit instructions.

## Summary

- **1 fix applied:** `docGenSignatureSender.js` — added HTML escaping in `handleShowPreview` for template names and error messages before `innerHTML` assignment (defense-in-depth).
- **0 LWS-blocked fetch calls** present.
- **All Blob MIME types compliant** with CLAUDE.md rule.
- **All `window.location` reads validated** before use.
- **No `eval` / `Function` / `document.write` / `crossorigin` patterns** present.
- **Server-side audit gaps:** `DocGenSignatureController` (guest-user), `DocGenSignatureService`, `DocGenSignatureEmailService`, `DocGenSignatureFlowAction`, `DocGenSignatureReminderSchedulable`, `DocGenSignaturePdfTrigger`, `DocGenFlowAction` were not reached via the LWC import list and should be covered by separate audit passes.
