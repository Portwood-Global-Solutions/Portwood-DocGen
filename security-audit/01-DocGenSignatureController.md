# Audit: DocGenSignatureController.cls

**File**: `force-app/main/default/classes/DocGenSignatureController.cls`
**Lines**: 1454 (pre-fix) → 1532 (post-fix)
**Surface**: Guest user (Site / VF) — highest risk
**Class declaration**: `public without sharing class DocGenSignatureController`

## Guest-callable surface (every method here is exposed via @AuraEnabled / @RemoteAction to unauthenticated signers)

| Method                  | Posture              | Notes                                                                  |
| ----------------------- | -------------------- | ---------------------------------------------------------------------- |
| `validateToken`         | OK                   | 64-char hex regex on token before SOQL; status filter; 48hr expiration |
| `sendPin`               | OK                   | Token → email match; rate-limited via PIN_Attempts\_\_c lockout        |
| `verifyPin`             | OK                   | SHA-256 hash compare; 10-min expiry; 3-strike lockout                  |
| `fetchDocumentData`     | OK after fix         | Now creates time-limited public ContentDistribution link               |
| `saveSignature`         | OK                   | Token-driven, consent + PIN gates enforced                             |
| `stampAndReturnSource`  | OK                   | Re-validates token; PIN gate enforced                                  |
| `saveLegacySignature`   | OK                   | Used by legacy single-signer path                                      |
| `declineSignature`      | OK                   | Token-driven                                                           |
| `getSignerPlacements`   | OK                   | Token-driven; throws on bad token                                      |
| `signPlacement`         | OK                   | Validates `Signer__c = signer.Id` before update                        |
| **`getImageBase64`**    | **FIXED (was IDOR)** | Now binds CV to signer's request context                               |
| `finishSignatureUpload` | OK                   | No-op (legacy compat)                                                  |

## Hardening applied in this pass (v1.75)

### 1. `getImageBase64` — IDOR remediation (HIGH)

**Before**: Validated only that `token` was a valid signer token. Then accepted any caller-supplied `contentVersionId` and returned its bytes. A guest with any valid signing token could read arbitrary org files.

**After**: A new `isAuthorizedSignatureImage(cvId, sourceDocId, templateId)` helper enforces that the requested CV is one of:

- The signer's `Signature_Request__r.Source_Document_Id__c`
- A template-version-extracted image whose `Title` starts with `docgen_tmpl_img_<activeVersionId>_`
- An HTML-template image whose `Title` starts with `docgen_html_img_<templateId>_`

Anything else returns `Image not authorized for this signing session` without leaking bytes. Also tightened the CV ID format check (was `startsWith('068')`, now strict 18-char alphanumeric pattern).

### 2. `getOrCreatePublicLink` — never-expiring public link (MEDIUM)

**Before**: Created `ContentDistribution` with `PreferencesExpires = false`, so the public preview URL stayed live forever even after the request was signed/cancelled.

**After**: Sets `PreferencesExpires = true` with `ExpiryDate = now + TOKEN_EXPIRATION_HOURS`, plus disables original/PDF download (`PreferencesAllowOriginalDownload = false`, `PreferencesAllowPDFDownload = false`) so the link is preview-only. Visit notification stays disabled (no signal to creator that a link was visited anonymously — same as before).

### 3. `convertSignatureRequestToPdf` — cross-template image collision (MEDIUM)

**Before**: Looked up `docgen_tmpl_img_*` CVs with `LIMIT 50` and no template scope. With multiple templates active, an `rId1` from template A could shadow `rId1` from template B in the wrong PDF.

**After**: Scopes the lookup to the request's template's active version (`docgen_tmpl_img_<activeVersionId>_%`). Removed the `LIMIT 50` since the result set is now bounded to one version. Added a strict `startsWith` filter post-query as a defense-in-depth check.

### 4. Centralized active-template-version lookup

Added `lookupActiveTemplateVersionId(templateId)` so the `Is_Active__c = TRUE` lookup pattern isn't duplicated in three places. `@TestVisible` for direct test exercise.

## Issues observed but NOT fixed in this pass (deferred to follow-up tasks)

- **`Test.isRunningTest()` short-circuit** in `convertSignatureRequestToPdf` (line 982) and `captureClientIp` (line 76). The PDF-generation bypass means production logic isn't actually exercised by tests for that path. Code smell. Recommend: replace the captureClientIp bypass with a proper `@TestVisible` setter, and replace the convertSignatureRequestToPdf short-circuit with a test seam that injects a stub Blob.
- **`Database.update(..., false, AccessLevel.SYSTEM_MODE)` with `allOrNothing = false`** is used in 12+ places (lines 232, 316, 343, 422, 485, 719, 758, 874, 913, 1217, 1223, 1381). Silently swallows validation rule errors. Acceptable for some optimistic upserts (audit captures) but problematic for state transitions. Recommend: add result inspection where state correctness matters (e.g., signer status updates).
- **No rate limiting on `validateToken`/`sendPin`/`verifyPin`** at the controller layer. Token space is 256-bit so brute force on `validateToken` is infeasible; PIN guess is bounded by `MAX_PIN_ATTEMPTS=3`. Acceptable.

## Test coverage

`DocGenSignatureTests.cls` already had ~90 tests covering the surface. New tests added for the v1.75 hardening:

- `testGetImageBase64_arbitraryCvRejected` — IDOR negative path
- `testGetImageBase64_sourceDocAllowed` — source-doc happy path
- `testGetImageBase64_templateImageAllowed` — version-scoped template image happy path
- `testGetImageBase64_crossTemplateImageRejected` — cross-template collision protection
- `testIsAuthorizedSignatureImage_directHelper` — direct helper contract
- `testFetchDocumentData_publicLinkExpires` — ContentDistribution expiry verification

## Status

✅ Controller modifications complete and source-deployed.
🟡 Test run pending (DocGenSignatureTests with 255 enqueued methods — running against `docgen-security-audit` scratch).
