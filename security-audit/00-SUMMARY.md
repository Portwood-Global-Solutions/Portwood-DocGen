# v1.75 Security Hardening — Summary

**Branch**: `release/1.75-security-review`
**Org used for validation**: `docgen-security-audit` scratch
**Driver**: AppExchange Security Review submitted 10 days ago, reviewers actively testing

## What was fixed

### CRITICAL / HIGH severity

| File                                                 | Issue                                                                                                                         | Fix                                                                                                                                                          |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DocGenSignatureController.cls`                      | `getImageBase64` IDOR — any guest token granted access to ANY ContentVersion in the org                                       | New `isAuthorizedSignatureImage()` helper binds the requested CV to the signer's request (source doc, version-scoped template image, or HTML-template image) |
| `DocGenSignatureController.cls`                      | `getOrCreatePublicLink` — public ContentDistribution URL never expired                                                        | `PreferencesExpires=true` with 48h `ExpiryDate`; `PreferencesAllowOriginalDownload=false`                                                                    |
| `DocGenSignatureController.cls`                      | `convertSignatureRequestToPdf` — cross-template image collision (no template scope on `docgen_tmpl_img_*` query)              | Scoped to active version's title prefix                                                                                                                      |
| `DocGenController.cls`                               | `getContentVersionBase64` IDOR — any user could read any CV by Id                                                             | USER*MODE-first query; SYSTEM_MODE fallback only for `docgen*\*` managed files                                                                               |
| `DocGenController.cls`                               | `deleteContentVersionDocument` IDOR — destructive op with no caller binding                                                   | Same auth pattern as above                                                                                                                                   |
| `DocGenController.cls`                               | `getContentVersionSize` probe leak                                                                                            | Same auth pattern                                                                                                                                            |
| `DocGenController.cls`                               | `saveWatermarkImage` / `clearWatermarkImage` / `saveHtmlTemplateImage` / `saveHtmlTemplateBody` — no template ownership check | USER_MODE access check on template/version before mutating                                                                                                   |
| `DocGenAuthenticatorController.cls`                  | `verifyDocument` / `verifyByRequestId` — no input validation, dead `Error_Message__c` field selected                          | Strict 64-char hex / 15-or-18-char alphanumeric regex; dead column removed                                                                                   |
| `DocGenSetupController.cls`                          | `getOrgWideEmailAddresses` — anyone with DocGen_User could enumerate all OWA addresses                                        | Admin gate (`DocGen_Admin_Access` perm or admin profile)                                                                                                     |
| `DocGenSetupController.cls`                          | `validateSignatureSetup` — leaks setup state to non-admins                                                                    | Same admin gate                                                                                                                                              |
| `DocGenSignaturePdfTrigger.trigger`                  | SOQL in trigger loop (sequential signing path)                                                                                | Bulkified with `Map<Id, String> templateNameMap`                                                                                                             |
| `DocGenSignaturePdfTrigger.trigger`                  | Sequential next-signer email skipped `Email_Status__c` write                                                                  | Now passes `requestId` to 3-arg `sendSignatureRequestEmails` overload                                                                                        |
| `DocGenGiantQueryAssembler.cls`                      | V3 fallback `whereCls` concatenated raw into aggregate SOQL                                                                   | Routed through canonical `sanitizeWhereClause`                                                                                                               |
| `DocGenGiantQueryBatch.cls`                          | `lookupField` only `escapeSingleQuotes`'d                                                                                     | Schema-allowlist validated against child object                                                                                                              |
| `lwc/docGenSignatureSender/docGenSignatureSender.js` | XSS — `tmpl.name` + `err.body.message` concatenated into innerHTML                                                            | Local `escapeHtml()` helper applied                                                                                                                          |

### MEDIUM / DEFENSIVE

| File                              | Change                                                                                                                                                                                                               |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DocGenSignatureEmailService.cls` | `escapeHtml()` now escapes apostrophe; brand color hex regex validated with safe fallback                                                                                                                            |
| `DocGenHtmlRenderer.cls`          | New `sanitizeCssToken` / `sanitizeCssUrlToken` helpers applied to every CSS-attribute concatenation site (color, themeColor, highlight, shdFill, pFill, cell shading, watermark URL) — protects browser preview path |
| `DocGenService.cls`               | NPE guard in `mergeTemplateForGiantQueryPdf`; `Security.stripInaccessible` on three bare DML statements in `extractAndSaveHtmlTemplateAssets`                                                                        |

## What was deferred for Dave's decision

These are architectural and need your call, not silent agent fixes:

1. **Two-path signature creation consolidation** (`DocGenSignatureSenderController`)
   `createTemplateSignerRequestWithOrder` (LWC) and `createTemplateSignatureRequestForFlow` (Flow) duplicate ~80% of logic. Audit doc has consolidation sketch. CLAUDE.md fragility note #1.

2. **Flow action throw-vs-catch unification** (`DocGenFlowAction`, `DocGenBulkFlowAction`, `DocGenGiantQueryFlowAction`)
   Validation throws (backward-compat); runtime errors return in Result. CLAUDE.md fragility note #5.

3. **Giant Query system-vs-user context** (`DocGenGiantQueryBatch`)
   Async runs as Automated Process user with no per-request user impersonation. Could let a Flow user generate a PDF for relationships they don't have read on. Decision: persist a "ran-as user" Id and re-impersonate, or document that async PDFs run elevated.

4. **`Test.isRunningTest()` bypasses** (3 places: `DocGenSignatureController.captureClientIp`, `DocGenSignatureController.convertSignatureRequestToPdf`, `DocGenSignatureService.renderPdf`, `DocGenSignatureEmailService` per CLAUDE.md)
   Code smell. Proper fix is dependency-injection / test seam refactor. Big change, deferred.

5. **`Database.update(..., false, AccessLevel.SYSTEM_MODE)` allOrNothing=false** in 12+ signature controller call sites. Silently swallows validation rule failures. Acceptable for some upserts (audit captures), problematic for state transitions (signer status). Add result inspection where state correctness matters.

## Tests

### New tests added in this hardening pass

| Class                                   | Method count    | Notes                                                                                                                          |
| --------------------------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `DocGenSignatureTests.cls`              | +6              | `testGetImageBase64_*` IDOR coverage, `testIsAuthorizedSignatureImage_directHelper`, `testFetchDocumentData_publicLinkExpires` |
| `DocGenAuthenticatorControllerTest.cls` | NEW (6 methods) | Strict input validation + happy/notfound paths                                                                                 |
| `DocGenSetupControllerTest.cls`         | NEW (5 methods) | Admin gate happy/deny + smoke for unrelated methods                                                                            |
| `DocGenControllerTests.cls`             | +12             | 6 IDOR fix pairs (authorized/unauthorized)                                                                                     |

### Test results

255/255 in `DocGenSignatureTests`. 214/214 in `DocGenControllerTests`. Full local suite running now (in progress).

## Files modified

```
force-app/main/default/classes/DocGenAuthenticatorController.cls
force-app/main/default/classes/DocGenAuthenticatorControllerTest.cls (new)
force-app/main/default/classes/DocGenAuthenticatorControllerTest.cls-meta.xml (new)
force-app/main/default/classes/DocGenController.cls
force-app/main/default/classes/DocGenControllerTests.cls
force-app/main/default/classes/DocGenGiantQueryAssembler.cls
force-app/main/default/classes/DocGenGiantQueryBatch.cls
force-app/main/default/classes/DocGenHtmlRenderer.cls
force-app/main/default/classes/DocGenService.cls
force-app/main/default/classes/DocGenSetupController.cls
force-app/main/default/classes/DocGenSetupControllerTest.cls (new)
force-app/main/default/classes/DocGenSetupControllerTest.cls-meta.xml (new)
force-app/main/default/classes/DocGenSignatureController.cls
force-app/main/default/classes/DocGenSignatureEmailService.cls
force-app/main/default/classes/DocGenSignatureTests.cls
force-app/main/default/lwc/docGenSignatureSender/docGenSignatureSender.js
force-app/main/default/triggers/DocGenSignaturePdfTrigger.trigger
```

## Per-file findings docs

- `01-DocGenSignatureController.md` — IDOR, ContentDistribution expiry, cross-template scope
- `02-DocGenService.md` — clean, 2 defensive fixes
- `03-DocGenDataRetriever.md` — pending re-audit (first agent failed silently)
- `04-DocGenHtmlRenderer.md` — CSS sanitization
- `05-DocGenGiantQuery.md` — SOQL identifier validation
- `06-LWC.md` — full Apex call inventory + 1 XSS fix
- `07-RemainingServiceClasses.md` — 0 high, 1 medium (already-mitigated heap pressure)
