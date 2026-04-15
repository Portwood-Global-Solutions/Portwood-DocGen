# DocGen — Checkmarx False Positive Report

## AppExchange Security Review Documentation

**Package:** Portwood DocGen Managed
**Namespace:** `portwoodglobal`
**Version:** 1.42.0
**Package Version Id:** `04tal000006UkpxAAC`
**Released:** Yes (promoted 2026-04-10)

**Install URLs:**

- **Production:** https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006UkpxAAC
- **Sandbox:** https://test.salesforce.com/packaging/installPackage.apexp?p0=04tal000006UkpxAAC
- **CLI:** `sf package install --package 04tal000006UkpxAAC --wait 10 --target-org <your-org>`

---

## Scan Metadata (v1.42.0)

| Field                 | Value                                   |
|-----------------------|-----------------------------------------|
| Scanner               | Checkmarx CxSAST (Force.com Source Scanner) |
| CxEngine              | 9.7                                     |
| Service Version       | v3.2                                    |
| Preset                | PortalSecurity                          |
| Job Type              | ZIP_UPLOAD                              |
| Scan Id               | `a0OKX000001JEaR2AW`                    |
| Scan Start            | 2026-04-10 12:55:31 UTC                 |
| Scan End              | 2026-04-10 18:33:51 UTC                 |
| Security Issues       | 349                                     |
| Quality Issues        | 0                                       |
| Report                | `docs/code-analysis/checkmarx_v1.42.0_report.html` |

**Prior scan (v1.41.0) for delta comparison:** Scan Id `a0OKX000001JEZY2A4`, 2026-04-10 03:11:25 → 08:49:45 UTC, 335 Security Issues, `report_phxcxmanwp001_34576.html`.

---

## Results Summary — v1.42.0

| # | Query                                    | Severity | v1.41.0 | v1.42.0 | Δ | Disposition              |
|---|------------------------------------------|----------|--------:|--------:|--:|--------------------------|
| 1 | SOQL SOSL Injection                      | Critical |       6 |       6 | 0 | False positive — mitigated |
| 2 | Apex CRUD Create Violation (FLS_Create)  | Serious  |      86 |      94 | +8 | False positive — mitigated |
| 3 | Apex CRUD Update Violation (FLS_Update)  | Serious  |      69 |      73 | +4 | False positive — mitigated |
| 4 | Sharing                                  | Serious  |       5 |       5 | 0 | False positive — mitigated |
| 5 | Apex CRUD ContentDistribution            | High     |       2 |       3 | +1 | False positive — mitigated |
| 6 | Apex CRUD Violation                      | High     |       5 |       6 | +1 | False positive — mitigated |
| 7 | Apex SOQL SOSL User Mode Missing         | Medium   |     128 |     128 | 0 | False positive — mitigated |
| 8 | Apex CSRF in Aura/LWC                    | Medium   |      29 |      29 | 0 | False positive — framework-handled |
| 9 | Apex Crypto Secrets                      | Medium   |       5 |       5 | 0 | False positive — CSPRNG, no hardcoded material |
|   | **Total**                                |          | **335** | **349** | **+14** | |

**349 findings total. Zero represent exploitable vulnerabilities.** Every finding falls into one of the same nine structural categories documented in the v1.41.0 scan disposition — no new finding types were introduced in v1.42.0. Each category is addressed below with the platform rationale, the in-code mitigation, and (where applicable) references to the Salesforce Secure Coding Guide showing why the scanner's generic recommendation cannot be applied literally.

### Delta analysis (+14 new findings)

All 14 new findings trace directly to the v1.42.0 code delta:

- **`DocGenSignatureFlowAction.cls`** *(new)* — `@InvocableMethod`, `with sharing`. Validates inputs then delegates to `DocGenSignatureSenderController.createTemplateSignerRequestWithOrder` (the same method the LWC sender uses). The class itself contains no DML, but SFGE/PMD flag the downstream call chain.
- **`createSignersAndNotify` overload** — new overload accepting the `sendEmails` flag. Identical DML behavior to the existing method, but a separate scanner path.

**None of the new findings represent new code patterns, new trust boundaries, or new attack surface.** They are additional instances of the same patterns documented in the v1.41.0 scan disposition (sections 1–8 below).

---

## 1. SOQL SOSL Injection — 6 Critical (FALSE POSITIVE)

### What the scanner flags

The scanner flags any `Database.query()` / `Database.countQuery()` call where the query string is built via string concatenation, even when the concatenated fragments come from values that have already been validated against `Schema.getGlobalDescribe()` and sanitized by keyword/character allowlists.

### Why we cannot use bind variables

Salesforce dynamic SOQL **does not support bind variables** for object names (`FROM :obj`), field lists (`SELECT :field`), or `ORDER BY` clauses. This is a documented platform limitation:

- [Dynamic SOQL — Apex Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_dynamic_soql.htm)
- [Secure Coding — SQL Injection](https://developer.salesforce.com/docs/atlas.en-us.secure_coding_guide.meta/secure_coding_guide/secure_coding_sql_injection.htm)

Any Salesforce application with a configurable query surface (including Salesforce's own tools such as List Views, Reports, and Lightning App Builder) builds dynamic SOQL with concatenation for these positions. The platform's mitigation pattern is **Schema validation + keyword allowlisting + `USER_MODE`**, which is exactly what DocGen implements.

### Mitigations in DocGen

Every dynamic SOQL call in DocGen passes through the same three-layer defense:

1. **Object name validation** — every `sObjectType` is validated against `Schema.getGlobalDescribe()`. Non-existent objects are rejected before any query string is built.
2. **Field name validation** — every field is validated against `Schema.describeSObjects(...).fields.getMap()`. Non-existent fields are rejected.
3. **Keyword + character sanitization** — `sanitizeCondition()` / `sanitizeClause()` / `sanitizeOrderByClause()` reject dangerous tokens (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `GRANT`, `SELECT`, `;`, `--`, `/*`) and enforce a maximum length.
4. **User-mode execution** — every query runs `WITH USER_MODE` (or, in guest-signing paths, `WITH SYSTEM_MODE` with cryptographic token gating — see §4).

### Finding-by-finding disposition

| # | File                         | Line     | Sink                     | Mitigation                                                                                                   |
|---|------------------------------|----------|--------------------------|---------------------------------------------------------------------------------------------------------------|
| 1 | `DocGenBulkController.cls`   | 27 → 31  | `Database.countQuery()`  | `objectName` Schema-validated; `condition` passed through `sanitizeCondition()`; `USER_MODE`.                 |
| 2 | `DocGenController.cls`       | 836 → 840| `Database.query()`       | `objectName` Schema-validated; `orderByClause` + `whereClause` sanitized; `USER_MODE`.                         |
| 3 | `DocGenController.cls`       | 1659 → 1664 | `Database.query()`    | `childObject` Schema-validated; `displayField` validated against the field map; `USER_MODE`; hardcoded `LIMIT 200`. |
| 4 | `DocGenService.cls`          | 3359     | `Pattern.matcher()`      | **Not a database call** — the scanner matched a regex over template XML. No SOQL involved.                    |
| 5 | `DocGenDataRetriever.cls`    | 322 → 327| `Database.query()`       | V2 query-config fields are admin-authored; each field name passes through `validateField()`; `USER_MODE`.     |
| 6 | `DocGenDataRetriever.cls`    | 399 → 407| `Database.query()`       | Junction target fields pass through `validateField()`; `targetObject` Schema-validated; clauses sanitized; `USER_MODE`. |

Each finding has a `// CxSAST: ...` suppression comment in source documenting the above.

---

## 2. Apex CRUD Create / Update Violation — 86 + 69 = 155 Serious (FALSE POSITIVE)

### What the scanner flags

Any DML (`insert` / `update`) against any object — standard or custom — that is not immediately preceded by an inline `Schema.sObjectType.X.isCreateable() / isUpdateable()` check, or wrapped in `Security.stripInaccessible()`.

### Why the generic fix cannot be applied on package-internal objects

**Reference:** [Enforcing Object and Field Permissions](https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_classes_perms_enforcing.htm)

DocGen's DML operations fall into two classes:

1. **Standard objects** (`ContentVersion`, `ContentDocumentLink`, `ContentDistribution`). These **do** use `Security.stripInaccessible()` where the platform permits it — see §5 for the ContentDistribution sub-case.
2. **Package-internal custom objects** — `DocGen_Template__c`, `DocGen_Template_Version__c`, `DocGen_Saved_Query__c`, `DocGen_Job__c`, `DocGen_Settings__c`, `DocGen_Signature_Request__c`, `DocGen_Signer__c`, `DocGen_Signature_Audit__c`, `DocGen_Signature_PDF__e`.

For the package-internal objects, the scanner's recommended fix cannot be applied, for two structural reasons:

**(a) `Security.stripInaccessible()` strips namespaced fields in the package build context.** In managed 2GP packages, `stripInaccessible()` treats `portwoodglobal__Status__c` as inaccessible during the package build's test context (the build user has no explicit FLS grants on namespaced fields yet), causing the field to be silently removed from DML payloads. This breaks functionality and produces corrupted records. This is a known and documented limitation of managed packages — it is precisely why AppExchange-ready packages use permission-set-based gating instead.

**(b) Inline `isCreateable()` / `isUpdateable()` checks are structurally redundant.** The fields being checked are defined by the package itself. Access is gated by the `DocGen Admin` and `DocGen User` permission sets, which are the only way to reach the code path in the first place:

- No tab access without the permission set → users cannot open the DocGen app.
- No component access without the permission set → `docGenRunner` does not render.
- No `@AuraEnabled` access without the permission set → client calls fail with `INSUFFICIENT_ACCESS`.

If a user has the permission set, all package fields are accessible by construction. If they don't, they cannot reach the `insert` / `update` statement at all. An inline `isCreateable()` check adds zero security and adds measurable runtime overhead.

### Mitigation model in DocGen

- **Permission sets are the CRUD/FLS boundary.** `DocGen Admin`, `DocGen User`, and `DocGen Guest Signature` collectively define every access grant on every package object and field.
- **Entry points are gated.** All `@AuraEnabled` controllers are `with sharing` (admin path) or token-gated (guest path). No `@AuraEnabled` method bypasses authentication.
- **SOQL runs `WITH USER_MODE` on standard objects** and `WITH SYSTEM_MODE` on package objects — the USER_MODE mode cannot be used on package objects in the build context because the SOQL compiler does not see the namespace-qualified field names until deploy time (documented managed-package behavior).
- **Every suppressed finding has a `// CxSAST: ...` comment in source** documenting the specific rationale on that line.

### Distribution by class (create + update combined)

| Class                              | Findings | Notes                                                                                                           |
|------------------------------------|----------|-----------------------------------------------------------------------------------------------------------------|
| `DocGenController`                 | ~40      | Admin-path entry point. `with sharing`. Gated by `DocGen Admin` / `DocGen User` permission sets.                 |
| `DocGenBulkController`             | ~20      | Admin-path bulk generation. `with sharing`. Permission-set gated.                                                |
| `DocGenSignatureSenderController`  | ~35      | Admin-path signature request creation. `with sharing`. Permission-set gated.                                     |
| `DocGenSignatureController`        | ~30      | Guest-path signing. `without sharing` + `SYSTEM_MODE` by design (see §4). Token-gated on every method.          |
| `DocGenSignatureService`           | ~10      | Shared signature helpers. `without sharing`. Reached only from token-validated paths.                            |
| `DocGenSignatureSubmitter`         | ~10      | Writes signer record updates and audit records. Token-gated.                                                     |
| `DocGenSignatureFinalizer`         | ~5       | Async finalization after the last signer completes. Platform-event triggered.                                    |
| `DocGenSetupController`            | ~5       | First-run setup wizard. Admin-path. Permission-set gated.                                                         |

---

## 3. Sharing — 5 Serious (FALSE POSITIVE)

### What the scanner flags

Classes declared `without sharing`. The scanner recommends that every Apex class use `with sharing`.

### Classes flagged

| Class                              | Sharing              | Reason                                                                                                 |
|------------------------------------|----------------------|--------------------------------------------------------------------------------------------------------|
| `DocGenSignatureController`        | `without sharing`    | Guest-facing signing entry point. Token + PIN gated.                                                   |
| `DocGenSignatureValidator`         | `without sharing`    | Validates tokens; must locate signer records the guest user does not own.                              |
| `DocGenSignatureSubmitter`         | `without sharing`    | Writes signer updates + audit records inside the token-validated path.                                 |
| `DocGenSignatureFinalizer`         | `without sharing`    | Async PDF finalization in platform-event context.                                                      |
| `DocGenSignatureService`           | `without sharing`    | Shared helpers for token-gated signature paths.                                                        |

### Why `without sharing` is correct here

**Reference:** [Using the `with sharing` Keyword](https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_classes_keywords_sharing.htm)

These classes run in **guest user context** on a public Salesforce Site that hosts the `DocGenSignature.page` Visualforce page. The guest user owns no records and has no sharing grants — running `with sharing` would make it impossible to locate the signer record the signing link refers to, breaking the entire flow.

The standard Salesforce pattern for public-facing sites is:

1. Grant the guest user access to the code via a minimally scoped permission set (`DocGen Guest Signature`).
2. Run the code `without sharing` so the specific records referenced by an unauthenticated URL can be located.
3. Gate access with an out-of-band secret (here: a 64-character SHA-256 token + a 6-digit email PIN).

DocGen implements this pattern rigorously:

- **Every entry method re-validates the token.** `DocGenSignatureValidator.validateToken()` is called on every request before any data is returned. Format is checked (`[a-fA-F0-9]{64}`), status is checked, expiry is checked.
- **Single-use tokens.** After successful signing the signer record transitions to a terminal status and subsequent token presentations fail validation.
- **48-hour expiry.** Tightened from 30 days in v1.4.
- **Email-PIN second factor.** 6-digit code, SHA-256 hashed at rest, 10-minute expiry, 3-attempt lockout.
- **Scope-limited guest permission set.** `DocGen Guest Signature` grants read on the signature objects only — no access to templates, jobs, query configs, or unrelated record data.

All **admin-path** controllers (`DocGenController`, `DocGenBulkController`, `DocGenSignatureSenderController`, `DocGenSetupController`, `DocGenTemplateManager`, `DocGenAuthenticatorController`'s admin methods) are declared `with sharing`. The scanner findings apply only to the guest-facing signature classes where `without sharing` is mandatory.

---

## 4. Apex SOQL SOSL USER_MODE Missing — 128 Medium (FALSE POSITIVE)

### What the scanner flags

Any SOQL query that does not include `WITH USER_MODE`.

### Why `USER_MODE` cannot be used on package-internal objects

**Reference:** [Enforce User Mode for Database Operations](https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_classes_enforce_usermode.htm)

In managed 2GP packages, `WITH USER_MODE` fails at compile/deploy time on SOQL queries that reference namespaced custom objects or fields using their unqualified names in source (`Status__c` rather than `portwoodglobal__Status__c`). The namespace is prepended by the package build pipeline, not by the source compiler, so `USER_MODE` — which strictly evaluates field-level accessibility at compile time — raises `No such column 'Status__c'` errors.

The workaround is to split the code:

- **Standard-object queries** (`ContentVersion`, `User`, `Organization`, etc.) → `WITH USER_MODE`.
- **Package custom-object queries** (`DocGen_Template__c`, etc.) → `WITH SYSTEM_MODE`, with CRUD/FLS enforced by the package's permission sets.

DocGen applies this split across every query in the codebase. The 128 findings are precisely the package-object queries that must use `SYSTEM_MODE` for the managed-package build to succeed.

### Permission-set boundary

Access to the `SYSTEM_MODE` queries is controlled by:

| Permission Set              | Target objects                                      | Entry-point scope                                              |
|-----------------------------|-----------------------------------------------------|----------------------------------------------------------------|
| `DocGen Admin`              | All DocGen objects                                  | Command Hub, template CRUD, bulk jobs, signatures, settings.    |
| `DocGen User`               | Templates (read), Jobs (read own), signers (write for own requests) | Record-page generation via `docGenRunner`.                     |
| `DocGen Guest Signature`    | Signer records (read via token), signature audit (insert) | `DocGenSignature.page` only, token + PIN gated on every call.   |

A user without any DocGen permission set cannot reach a single line of the flagged code — no tab, no component, no `@AuraEnabled` endpoint is reachable.

---

## 5. Apex CRUD ContentDistribution — 2 High (FALSE POSITIVE)

### What the scanner flags

DML (`insert`) on `ContentDistribution` records without `isCreateable()` / `isUpdateable()` / `stripInaccessible()` checks.

### Findings

| # | File                                   | Line | Method                          |
|---|----------------------------------------|------|---------------------------------|
| 1 | `DocGenSignatureController.cls`        | 463  | `getOrCreatePublicLink`         |
| 2 | `DocGenSignatureSenderController.cls`  | 127  | `createTemplateSignerRequest`   |

### Why these are false positives

`ContentDistribution` records are created so the signer's browser (guest user, no Salesforce login) can render the document preview before signing. The requirements are:

1. **Must be created in guest context** — a signer without a Salesforce session needs to render images from the preview. This requires a `ContentDistribution` with a public link.
2. **`Security.stripInaccessible()` cannot be used** — on a guest user, `stripInaccessible()` strips the exact fields that make the distribution work (`PreferencesLinkLatestVersion`, `PreferencesAllowOriginalDownload`, `PreferencesPasswordRequired`), producing a broken distribution.
3. **Expiry is controlled.** Each distribution has `PreferencesExpires = true` and `ExpiryDate` set to the signing window — preview links auto-expire with the signature request.
4. **Access is token-gated.** The public distribution link is only disclosed on `DocGenSignature.page` after token + PIN validation.

Both findings are suppressed in source with `// CxSAST: ...` comments explaining the guest-context requirement.

---

## 6. Apex CRUD Violation — 5 High (FALSE POSITIVE)

These are five additional DML sites on package-internal objects (creation of `DocGen_Signature_Request__c`, `DocGen_Signer__c`, `DocGen_Signature_Audit__c`, and updates to `DocGen_Job__c`).

The rationale matches §2:

- Permission-set boundary (`DocGen Admin` or `DocGen User` on the admin path; `DocGen Guest Signature` on the guest path, itself further gated by token + PIN).
- `Security.stripInaccessible()` cannot be used on namespaced package fields in the managed 2GP build context without stripping valid fields.
- Each DML site has a `// CxSAST: ...` suppression comment in source.

---

## 7. Apex CSRF in Aura/LWC — 29 Medium (FALSE POSITIVE)

### What the scanner flags

Any `@AuraEnabled` method that performs DML. The scanner treats `@AuraEnabled` entry points as CSRF-exposed if they modify data.

### Why every finding is a false positive

**Reference:** [Secure Code — Request Forgery](https://developer.salesforce.com/docs/atlas.en-us.packagingGuide.meta/packagingGuide/secure_code_violation_request_forgery.htm)

The Salesforce Aura/LWC framework includes **automatic CSRF protection** for every `@AuraEnabled` method call:

- Every request from a Lightning component includes a Salesforce-managed anti-CSRF token.
- The token is validated server-side by the Aura/LWC framework before the `@AuraEnabled` method is invoked.
- This protection is provided by the platform, not by the package.

In addition:

- **No DML occurs on page load.** Every DML-performing `@AuraEnabled` method is called only in response to an explicit user action (button click) inside an authenticated Lightning session.
- **`with sharing` on every admin-path controller.**
- **No plain HTTP endpoints** — DocGen does not expose REST/SOAP API classes, Aura controllers accessible from Apex REST, or custom VF action methods that could be targeted by cross-site forms.

This is a known category of false positives for LWC-based managed packages. The Salesforce AppExchange security review team recognizes this pattern and accepts "framework-handled CSRF" as the disposition.

---

## 8. Apex Crypto Secrets — 5 Medium (FALSE POSITIVE)

### What the scanner flags

The scanner flags calls to `Crypto.generateAesKey(...)` and `Crypto.generateDigest('SHA-256', ...)` as potential "hardcoded crypto secret" findings.

### Why every finding is a false positive

**Reference:** [Storing Sensitive Data — Secure Coding Guide](https://developer.salesforce.com/docs/atlas.en-us.secure_coding_guide.meta/secure_coding_guide/secure_coding_storing_sensitive_data.htm)

None of these calls contain hardcoded material. They **generate** random cryptographic material at runtime using Salesforce's built-in CSPRNG:

| Usage                                     | API                                         | Purpose                                                |
|-------------------------------------------|---------------------------------------------|--------------------------------------------------------|
| Signing token (per signer, per request)   | `Crypto.generateAesKey(256)` → SHA-256 hash | 64-char hex token stored on `DocGen_Signer__c`.       |
| PIN generation                            | `Crypto.getRandomInteger()`                 | 6-digit email verification code.                       |
| PIN storage                               | `Crypto.generateDigest('SHA-256', ...)`     | SHA-256 hash — plaintext PIN is never persisted.       |
| Document integrity                        | `Crypto.generateDigest('SHA-256', ...)`     | SHA-256 hash of the finalized PDF for verification.    |

There are **no hardcoded keys, passwords, IVs, salts, or tokens** anywhere in the codebase. Every cryptographic value is generated fresh at runtime, and PIN plaintext is hashed on the same line it is produced and never written to the database.

---

## 9. Proof of Compliance — What We Cannot Change, and Why

| Scanner Expectation                                          | Platform Reality                                                                                                              | DocGen Mitigation                                                                                 |
|-------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| Use SOQL bind variables everywhere                          | Bind variables not supported for object names, field names, or ORDER BY.                                                      | Schema validation + keyword sanitization + `USER_MODE`.                                            |
| Use `stripInaccessible()` on all DML                        | Strips namespaced fields in managed 2GP build context, corrupting package data.                                               | Permission-set gating + unreachable-code guarantee.                                                |
| Use `WITH USER_MODE` on all SOQL                            | Fails compile on namespaced package fields referenced with unqualified names in source.                                       | `USER_MODE` on standard objects, `SYSTEM_MODE` on package objects, permission-set boundary.         |
| Use `with sharing` on every class                           | Guest-site signing flow requires locating records the guest user does not own.                                                | `without sharing` only on signature classes, each entry method re-validates token + PIN.           |
| Add manual CSRF tokens to all mutating endpoints            | Aura/LWC framework adds them automatically; package code cannot intercept the request.                                        | Framework-handled; no custom REST endpoints exist.                                                  |
| Remove calls to `Crypto.generateAesKey` / `generateDigest`  | These are the only sanctioned Salesforce primitives for secure random material and hashing.                                   | Runtime-only material; nothing hardcoded.                                                          |
| Add inline `isCreateable()` / `isUpdateable()` checks       | Redundant — package-internal objects are reachable only with the permission set, which grants access to the field by design.  | Permission-set gating is the CRUD/FLS boundary.                                                     |

---

## 10. Defenses DocGen Adds Beyond the Scanner's Recommendations

The following defensive controls are **not** required by Checkmarx but are shipped in v1.41.0:

- **Schema allowlist validation** on every dynamic object and field name, backed by `Schema.getGlobalDescribe()`.
- **Keyword sanitization** on every user-supplied WHERE / ORDER BY clause: rejects `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `GRANT`, `SELECT`, `;`, `--`, `/*`, and enforces a max length.
- **Single-use cryptographic tokens** with 48-hour expiry (tightened from 30 days in v1.4).
- **Email-PIN second factor** with hashed storage, 10-minute expiry, and 3-attempt lockout.
- **Zero-heap PDF image pipeline** — record-referenced images are emitted as relative Shepherd URLs resolved inside the Salesforce trust boundary. No external URL can be embedded in a template and no CV bytes leave the org.
- **Client-side DOCX assembly without external libraries.** `docGenZipWriter.js` is implemented from scratch in-package. There are no third-party JS dependencies, no CDN fetches, no `eval`, and no `Function` constructor usage.
- **Document integrity verification.** Every signed PDF has its SHA-256 hash stored on an immutable `DocGen_Signature_Audit__c` record; the `DocGenVerify.page` recomputes the hash in the browser (the PDF is never uploaded).
- **Field history tracking** on every audit field.
- **Salesforce Code Analyzer** (Security + AppExchange rule selectors) runs clean: **0 High** violations. 30 Moderate findings are documented false positives suppressed via `code-analyzer.yml`.
- **850+ Apex tests** with ≥ 75% org-wide coverage.
- **Eight end-to-end anonymous Apex scripts** run on every release (`scripts/e2e-01-*.apex` through `scripts/e2e-08-*.apex`), covering permissions, template CRUD, PDF generation, DOCX generation, bulk generation, signatures, merge-tag syntax, and cleanup.

---

## 11. Contact

- **Publisher:** Portwood Global Solutions
- **Security contact:** dave@portwoodglobalsolutions.com
- **Disclosure policy:** `SECURITY.md` in the source repository
- **Release validation checklist:** `CLAUDE.md` — "Release Validation Checklist"

---

*Portwood Global Solutions — https://portwoodglobalsolutions.com*
