# Code Analyzer Violations — Tracking Document

**Scan Date:** 2026-04-08
**Version:** v1.28.0
**Total:** 160 violations (129 High, 31 Moderate)
**Target:** 0

---

## Summary by Class

| Class | High | Moderate | Rule Types |
|---|---|---|---|
| DocGenSignatureController | 52 | 0 | FLS (8), WithSharing (44) |
| DocGenController | 40 | 0 | FLS (26), CRUD (14) |
| DocGenBulkController | 10 | 0 | FLS (8), CRUD (2) |
| DocGenSignatureSenderController | 13 | 1 | FLS (5), CRUD (7), HardcodedCreds (1) |
| DocGenSignatureService | 10 | 0 | FLS (4), CRUD (2), WithSharing (4) |
| DocGenAuthenticatorController | 4 | 0 | FLS (2), WithSharing (2) |
| DocGenSetupController | 1 | 0 | CRUD (1) |
| DocGenTemplateManager | 1 | 0 | FLS (1) |
| docGenTreeNode (LWC) | 0 | 8 | BubblesComposedTrue |
| Field metadata (objects) | 0 | 22 | ProtectSensitiveData |

---

## Rule Categories

### 1. `sfge:DatabaseOperationsMustUseWithSharing` — 52 violations

**Classes affected:** DocGenSignatureController (48), DocGenSignatureService (4), DocGenAuthenticatorController (2)

**Root cause:** These classes are declared `without sharing` because they run in guest user context on the public signing site. Guest users have no record access — `SYSTEM_MODE` bypasses FLS/CRUD, and `without sharing` bypasses record sharing. Without these, the signing flow breaks.

**Fix strategy:** Add `// NOPMD` or `@SuppressWarnings` comments with justification. These are **intentionally** without sharing — the access is gated by cryptographic token validation, not sharing rules.

**Lines (DocGenSignatureController):**
- 92, 114, 151, 200, 231, 275, 296, 363, 375, 393, 420, 429, 441, 456, 458, 599, 628, 643, 646, 663, 682, 720, 745, 756, 760, 777, 787, 799

**Lines (DocGenSignatureService):**
- 290, 309

**Lines (DocGenAuthenticatorController):**
- 9, 44

---

### 2. `sfge:ApexFlsViolation` — 55 violations

**Classes affected:** DocGenController (26), DocGenSignatureController (8), DocGenBulkController (8), DocGenSignatureSenderController (5), DocGenSignatureService (4), DocGenAuthenticatorController (2), DocGenTemplateManager (1), DocGenSetupController (1)

**Root cause:** SOQL queries and DML operations on package-internal custom objects (`DocGen_Template__c`, `DocGen_Template_Version__c`, `DocGen_Job__c`, `DocGen_Saved_Query__c`, `DocGen_Signature_Request__c`, `DocGen_Signer__c`, `DocGen_Signature_Audit__c`) don't use `WITH USER_MODE` or `Security.stripInaccessible()`.

**Fix strategy:** Two approaches:
1. **Switch SOQL to `WITH USER_MODE`** where the running user is an authenticated Salesforce user (DocGenController, DocGenBulkController, DocGenSenderController)
2. **Suppress with justification** where queries must run as `SYSTEM_MODE` (guest user signature flow — DocGenSignatureController, DocGenSignatureService, DocGenAuthenticatorController)

**Why we can't blindly add USER_MODE everywhere:** The signature classes run in guest user context where SYSTEM_MODE is required. The template CRUD classes already have permission set checks — FLS is enforced by the permission set, not inline code.

---

### 3. `pmd:ApexCRUDViolation` — 22 violations

**Classes affected:** DocGenController (14), DocGenSignatureSenderController (7), DocGenSetupController (1)

**Root cause:** DML statements (insert, update) on package-internal objects without `Security.stripInaccessible()` or explicit CRUD checks.

**Fix strategy:** Add NOPMD comments with justification — CRUD is controlled by DocGen Admin/User permission sets. The objects are package-internal and not directly accessible without the permission set. Alternatively, wrap DML in `Security.stripInaccessible(AccessType.CREATABLE, records)`.

**Lines (DocGenController):**
- 409, 589, 949, 953, 965, 994, 1063, 1068, 1078, 3254, 3287, 3416, 3443, 3466

**Lines (DocGenSignatureSenderController):**
- 106, 129, 130, 148, 200, 230, 433

**Lines (DocGenSetupController):**
- 48

---

### 4. `pmd:AvoidHardcodedCredentialsInVarDecls` — 1 violation

**File:** DocGenSignatureSenderController.cls:220
**Variable:** `signatureUrl`
**Issue:** PMD flagged `signatureUrl` because it contains the word "SIGNATURE" which matches its credential pattern.

**Fix:** Rename the variable to `signingPageUrl` or suppress with NOPMD comment. This is a false positive — the variable holds a URL, not a credential.

---

### 5. `pmd:AvoidLwcBubblesComposedTrue` — 8 violations (Moderate)

**File:** docGenTreeNode.js lines 49, 58, 67, 77, 86, 97, 107, 116

**Issue:** Custom events dispatched with both `bubbles: true` and `composed: true`. This allows events to cross shadow DOM boundaries which can cause unexpected behavior.

**Fix:** Evaluate whether `composed: true` is actually needed. The tree node component dispatches events that need to reach parent components — `bubbles: true` alone may suffice if the parent is a direct ancestor (not across shadow DOM).

---

### 6. `pmd:ProtectSensitiveData` — 22 violations (Moderate)

**Files:** Various field metadata files across DocGen_Settings__c, DocGen_Signature_Audit__c, DocGen_Signature_Request__c, DocGen_Signer__c

**Issue:** PMD's pattern-matching flags field names containing "Token", "Signature", "Email", "Hash", "PIN" as potential sensitive data/auth tokens.

**Fix:** These are all false positives for a signature system — the fields ARE sensitive data, but they're protected by:
- Permission sets (DocGen Admin, DocGen User, DocGen Guest Signature)
- Sharing model (ControlledByParent for child objects)
- Field history tracking on audit fields
- SYSTEM_MODE access gated by cryptographic token validation

Suppress with documentation explaining the protection model.

---

## Fix Priority

| Priority | Category | Count | Effort | Approach |
|---|---|---|---|---|
| 1 | FLS on internal objects (admin context) | ~35 | Medium | Switch to `WITH USER_MODE` where possible |
| 2 | CRUD on internal objects | ~22 | Low | Add `Security.stripInaccessible()` or NOPMD |
| 3 | WithSharing (guest context) | ~52 | Low | NOPMD with justification — intentional design |
| 4 | Hardcoded creds false positive | 1 | Low | Rename variable |
| 5 | LWC bubbles+composed | 8 | Low | Remove `composed: true` if not needed |
| 6 | ProtectSensitiveData | 22 | Low | Suppress — false positives for signature fields |
| 7 | FLS on signature objects (guest context) | ~20 | Low | NOPMD — SYSTEM_MODE required for guest access |

---

## Progress Log

| Date | Action | Before | After |
|---|---|---|---|
| 2026-04-08 | Initial scan | 160 | 160 |
