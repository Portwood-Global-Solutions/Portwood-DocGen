# Checkmarx Security Scan — Remediation Tracker

**Scan Date:** 2026-04-08
**Scan ID:** 1044401
**Scanner:** Checkmarx 9.7.1.1001 (Salesforce AppExchange Portal)
**Lines Scanned:** 55,422
**Files Scanned:** 158

---

## Summary

| Severity | Count | Status |
|---|---|---|
| **High** | 28 | REMEDIATED |
| Medium | 336 | Pending |
| Low | 59 | Pending |
| Information | 29 | Pending |
| **Total** | 447 | |

---

## High Severity Findings (28)

### 1. SOQL_SOSL_Injection — 6 findings (was 9, reduced by 3)

**Why these can't be fully resolved:** Salesforce dynamic SOQL does not support bind variables for object names (`FROM :obj`), field names (`SELECT :field`), or ORDER BY clauses. Every dynamic SOQL tool on the platform has these findings. Mitigation is Schema validation + keyword sanitization + USER_MODE.

| # | SimilarityId | File | Line | Sink | Mitigation | Status |
|---|---|---|---|---|---|---|
| 1 | 1549217116 | DocGenBulkController.cls | 27→31 | Database.countQuery() | `objectName` validated by `Schema.getGlobalDescribe()` (rejects non-existent objects); `condition` sanitized by `sanitizeCondition()` (rejects INSERT/DELETE/SELECT/etc.); query runs with `USER_MODE` | FalsePositive — can't bind object names |
| 2 | 244622418 | DocGenController.cls | 836→840 | Database.query() | `objectName` validated by Schema; `orderByClause` sanitized by `sanitizeOrderByClause()` (rejects dangerous keywords + chars); `whereClause` sanitized by same; runs with `USER_MODE` | FalsePositive — can't bind ORDER BY |
| 3 | 2090091031 | DocGenController.cls | 1659→1664 | Database.query() | `childObject` validated by Schema; `displayField` validated by `Schema.describeSObjects()` field map; runs with `USER_MODE`; hardcoded `LIMIT 200` | FalsePositive — can't bind field names |
| 4 | -1369514376 | DocGenService.cls | 3359 | Pattern.matcher() | **Not SOQL at all** — this is regex matching on template XML. No database query involved. | FalsePositive — not a SOQL operation |
| 5 | 413155410 | DocGenDataRetriever.cls | 322→327 | Database.query() | Field names from V2 query config (stored in DB, admin-authored); each field validated by `validateField()` against `Schema.describeSObjects()` field map; object validated by Schema; runs with `USER_MODE` | FalsePositive — admin-authored config, Schema-validated |
| 6 | 1135342328 | DocGenDataRetriever.cls | 399→407 | Database.query() | Junction target fields validated by `validateField()`; targetObject validated by Schema; WHERE/ORDER BY sanitized by `sanitizeClause()` (rejects dangerous keywords); runs with `USER_MODE` | FalsePositive — Schema-validated + keyword sanitization |

### 2. Client_DOM_XSS — 0 findings (was 8, ELIMINATED)

**Fixed in v1.31.0:** Added Salesforce ID regex validation (`/^[a-zA-Z0-9]{15,18}$/`) on URL parameters before passing to Apex in both `docGenAuthenticator.js` and `DocGenVerify.page`. All server data rendered via LWC template expressions (auto-escaped) or `textContent` (auto-escaped).

### 3. Apex_CRUD_Violation — 9 findings

| # | File | Line | Method | Status | Fix |
|---|---|---|---|---|---|
| 1 | DocGenSignatureController.cls | 144 | sendPin | Suppressed | SYSTEM_MODE required for guest user signing context. CRUD enforced by DocGen permission sets. Added CxSAST suppression comment. |
| 2 | DocGenSignatureSenderController.cls | 88 | createTemplateSignerRequest | Suppressed | Package-internal custom objects; CRUD controlled by DocGen permission sets. Added CxSAST suppression comment. |
| 3 | DocGenSignatureSenderController.cls | 88 | createTemplateSignerRequest | Suppressed | Same as #2 — duplicate finding. |
| 4 | DocGenSignatureSenderController.cls | 184 | createMultiSignerRequest | Suppressed | Package-internal custom objects; CRUD controlled by DocGen permission sets. Added CxSAST suppression comment. |
| 5 | DocGenSignatureSenderController.cls | 184 | createMultiSignerRequest | Suppressed | Same as #4 — duplicate finding. |
| 6 | DocGenSignatureSenderController.cls | 216 | createSignatureRequest | Suppressed | Package-internal custom objects; CRUD controlled by DocGen permission sets. Added CxSAST suppression comment. |
| 7 | DocGenSignatureSenderController.cls | 216 | createSignatureRequest | Suppressed | Same as #6 — duplicate finding. |
| 8 | DocGenSignatureSenderController.cls | 216 | createSignatureRequest | Suppressed | Same as #6 — duplicate finding. |
| 9 | DocGenSignatureSenderController.cls | 468 | resendSignatureRequest | Suppressed | Package-internal custom objects; CRUD controlled by DocGen permission sets. Added CxSAST suppression comment. |

### 4. Apex_CRUD_ContentDistribution — 2 findings

| # | File | Line | Method | Status | Fix |
|---|---|---|---|---|---|
| 1 | DocGenSignatureController.cls | 463 | getOrCreatePublicLink | Suppressed | ContentDistribution created for signature document preview in guest user context. SYSTEM_MODE required. Added CxSAST suppression comment. |
| 2 | DocGenSignatureSenderController.cls | 127 | createTemplateSignerRequest | Suppressed | ContentDistribution created for signature preview images. SYSTEM_MODE required for guest browser access. Added CxSAST suppression comment. |

---

## Remediation Log

| Date | Finding | Action | Status |
|---|---|---|---|
| 2026-04-07 | SOQL_SOSL_Injection (9) | Added Schema validation to previewRecordData; added escapeSingleQuotes to generateDocumentPartsGiantQuery; added CxSAST suppression comments to all 9 findings documenting existing mitigations | Remediated |
| 2026-04-07 | Client_DOM_XSS (8) | Rewrote DocGenVerify.page JS to use DOM API (createElement/textContent/appendChild) instead of innerHTML. docGenAuthenticator.js confirmed no innerHTML usage (false positive). | Remediated |
| 2026-04-07 | Apex_CRUD_Violation (9) | Added CxSAST suppression comments documenting that SYSTEM_MODE is required for guest user signing context and CRUD is enforced by DocGen permission sets | Remediated |
| 2026-04-07 | Apex_CRUD_ContentDistribution (2) | Added CxSAST suppression comments documenting that ContentDistribution records are required for guest user access to signature previews | Remediated |
