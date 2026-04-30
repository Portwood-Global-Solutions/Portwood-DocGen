# DocGen — Salesforce Code Analyzer Report

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

## Scan Metadata

| Field                 | Value                                                                                              |
| --------------------- | -------------------------------------------------------------------------------------------------- |
| Scanner               | Salesforce Code Analyzer (`sf code-analyzer`)                                                      |
| Code Analyzer version | 0.45.0                                                                                             |
| Engine versions       | PMD 0.39.0, SFGE 0.19.0, ESLint 0.41.0, RetireJS 0.33.0, Regex 0.34.0, Flow 0.35.0                 |
| Scan date             | 2026-04-10 (re-run against v1.42.0 source)                                                         |
| Workspace             | `force-app/`                                                                                       |
| Rule selectors        | `Security`, `AppExchange`                                                                          |
| Command               | `sf code-analyzer run --workspace force-app/ --rule-selector Security --rule-selector AppExchange` |
| Configuration         | `code-analyzer.yml` (inline suppressions enabled)                                                  |
| Raw outputs           | `docs/code-analysis/code-analyzer-report.html`, `.json`                                            |

---

## Summary

| Severity     | Count  | Disposition                                  |
| ------------ | ------ | -------------------------------------------- |
| 1 — Critical | **0**  | —                                            |
| 2 — High     | **0**  | —                                            |
| 3 — Moderate | 30     | All false positives (pattern-matching rules) |
| 4 — Low      | 0      | —                                            |
| 5 — Info     | 0      | —                                            |
| **Total**    | **30** | 0 exploitable findings                       |

**Additional inline-suppressed findings:** 103 violations are suppressed in source via `@SuppressWarnings` / `// NOPMD` / `// CxSAST` markers, each accompanied by an in-line justification comment. These are the intentional `without sharing`, `SYSTEM_MODE`, and CRUD-on-package-object sites documented in `DocGen_False_Positive_Report.md`.

**Pass criteria:** 0 High severity violations. **Status: PASS.**

---

## Finding Category 1 — `pmd:AvoidLwcBubblesComposedTrue` (8 Moderate, FALSE POSITIVE)

**Rule:** Warns when a Lightning Web Component dispatches a `CustomEvent` with both `bubbles: true` and `composed: true`, because such events cross shadow DOM boundaries.

**Findings:** 8 — all in `lwc/docGenTreeNode/docGenTreeNode.js` at lines 49, 58, 67, 77, 86, 97, 107, 116.

**Context:** `docGenTreeNode` is a **recursive** tree component used by the V3 query-tree builder. Each node renders child nodes as additional `<c-doc-gen-tree-node>` instances. User interactions (add/remove/select/expand) must bubble from any depth back up to the root `docGenTreeBuilder` component — which lives **outside** the recursive tree's shadow DOM.

**Why `composed: true` is required:**

- Without `composed: true`, events are trapped at each node's shadow DOM boundary and never reach the tree builder.
- The alternative — chaining re-dispatch handlers at every level of the tree — would require every intermediate `docGenTreeNode` instance to listen to and re-emit every event from its children. That defeats the entire purpose of a bubbling event and makes the recursive structure unmaintainable.

**Why the findings are not exploitable:**

- The events only carry tree-manipulation metadata (node id, action type, field selection). They do not carry credentials, tokens, or record data.
- All event consumers are in-package LWCs (`docGenTreeBuilder`, `docGenColumnBuilder`). There is no risk of a malicious external component intercepting events, because LWS isolates each root component instance.
- The component never renders user-supplied HTML or evaluates user-supplied strings.

**Disposition:** Retained intentionally. Documented in `code-analyzer.yml` and in the component's JSDoc.

---

## Finding Category 2 — `pmd:ProtectSensitiveData` (22 Moderate, FALSE POSITIVE)

**Rule:** PMD pattern-matches field names containing tokens such as `Token`, `Signature`, `Signer`, `Email`, `Hash`, `PIN` and flags them as "potential auth tokens with public visibility." The rule fires on the field metadata XML file alone, without examining the field's actual sharing, CRUD, FLS, or runtime protection.

**Findings:** 22 field metadata files across 4 objects.

### 2.1 `DocGen_Settings__c` — 6 findings

| Field                            | Finding rationale    | Actual content & protection                                                                                                           |
| -------------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `Signature_Email_Brand_Color__c` | Contains "Signature" | Hex color code for email branding. Not an auth token.                                                                                 |
| `Signature_Email_Footer_Text__c` | Contains "Signature" | Footer text for signature emails. Not an auth token.                                                                                  |
| `Signature_Email_Logo_Url__c`    | Contains "Signature" | Relative Salesforce URL for the email logo. Not an auth token.                                                                        |
| `Signature_Email_Message__c`     | Contains "Signature" | Custom message included in signer emails. Not an auth token.                                                                          |
| `Signature_Email_Subject__c`     | Contains "Signature" | Email subject line template. Not an auth token.                                                                                       |
| `Signature_OWA_Id__c`            | Contains "Signature" | Org-Wide Email Address Id (`0D2...`) used as the `From` address. Not a secret — it's a Salesforce record Id already visible in Setup. |

`DocGen_Settings__c` is a **hierarchy custom setting**. Access is controlled by:

- The `DocGen Admin` permission set (read/write) and `DocGen User` permission set (read).
- Salesforce's standard hierarchy custom setting access model.
- No guest user access — `DocGen Guest Signature` does not grant read on `DocGen_Settings__c`.

### 2.2 `DocGen_Signature_Audit__c` — 7 findings

| Field                     | Actual content                                  | Protection                                                                |
| ------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------- |
| `Document_Hash_SHA256__c` | SHA-256 hash of the finalized PDF (hex string). | Public by design — used for external document verification. Not a secret. |
| `Signature_Request__c`    | Master-detail to `DocGen_Signature_Request__c`. | `ControlledByParent` sharing. Not a token — just a relationship field.    |
| `Signer__c`               | Master-detail to `DocGen_Signer__c`.            | `ControlledByParent` sharing. Not a token.                                |
| `Signed_Date__c`          | Datetime the signer completed the signing flow. | `ControlledByParent` sharing. Not a token.                                |
| `Signer_Email__c`         | Email address the request was delivered to.     | `ControlledByParent` sharing. Field history tracking enabled.             |
| `Signer_Name__c`          | Typed name the signer entered.                  | `ControlledByParent` sharing. Field history tracking enabled.             |

The `DocGen_Signature_Audit__c` object is **immutable by design** — it represents the legal audit record of a signing event. Write access is limited to the token-gated `DocGenSignatureSubmitter` code path; read access requires the `DocGen Admin` permission set.

### 2.3 `DocGen_Signature_Request__c` — 4 findings

| Field               | Actual content                                        | Protection                                                                                                                                                       |
| ------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Secure_Token__c`   | SHA-256 hex digest of the request-level token.        | Token is generated fresh per request via `Crypto.generateAesKey(256)`. Stored as a one-way hash — the plaintext cannot be recovered. Single-use. 48-hour expiry. |
| `Signature_Data__c` | Long text for capture metadata (no image data in v2). | `ControlledByParent` under the parent record's sharing.                                                                                                          |
| `Signer_Email__c`   | Recipient email address for the primary signer.       | `ControlledByParent`.                                                                                                                                            |
| `Signer_Name__c`    | Display name for the primary signer.                  | `ControlledByParent`.                                                                                                                                            |

### 2.4 `DocGen_Signer__c` — 6 findings

| Field                  | Actual content                                  | Protection                                                                        |
| ---------------------- | ----------------------------------------------- | --------------------------------------------------------------------------------- |
| `Secure_Token__c`      | SHA-256 hex digest of the signer-level token.   | 256-bit random key → SHA-256. Plaintext never stored. Single-use. 48-hour expiry. |
| `PIN_Hash__c`          | **SHA-256 hash** of the 6-digit email PIN.      | Plaintext never stored. 10-minute expiry. 3-attempt lockout on `PIN_Attempts__c`. |
| `Signature_Data__c`    | Typed-name SES metadata.                        | `ControlledByParent`.                                                             |
| `Signature_Request__c` | Master-detail to `DocGen_Signature_Request__c`. | `ControlledByParent`.                                                             |
| `Signer_Email__c`      | Delivery address.                               | `ControlledByParent`.                                                             |
| `Signer_Name__c`       | Display name.                                   | `ControlledByParent`.                                                             |

### Why PMD's recommended fix cannot be applied

**PMD recommends:** Mark the field as "Protected" or restrict visibility to a specific profile.

- Field-level "Protected" visibility does not exist as a metadata attribute for custom fields on custom objects. "Protected" visibility exists only for custom settings and custom metadata types at the **object** level in managed packages — not for individual fields.
- DocGen objects already operate under a strict permission-set model. A user without `DocGen Admin`, `DocGen User`, or `DocGen Guest Signature` cannot read a single byte from any of these objects, because:
    - No tab grant → no app visibility.
    - No object-level read → SOQL returns zero rows.
    - No `@AuraEnabled` controller grant → all client calls fail with `INSUFFICIENT_ACCESS`.
- `Secure_Token__c` and `PIN_Hash__c` **are** the protection mechanism for the signing flow — they are cryptographic hashes, not plaintext secrets. Storing a hash is the correct pattern, not a vulnerability.
- For every other flagged field, the value is either (a) not sensitive at all (branding, color, footer text, Salesforce record Ids), or (b) protected by `ControlledByParent` sharing under the signature request, which in turn is protected by the admin permission set.

**Disposition:** All 22 findings are documented false positives. The fields' protection is enforced structurally, not through field-name conventions.

---

## Inline-Suppressed Findings — 103 Total

The Code Analyzer run reported `103 violation(s) were suppressed by inline suppression markers`. Every suppression in source has a justification comment. These fall into the categories documented in `DocGen_False_Positive_Report.md`:

| Category                                    | Approx. count | Location class(es)                                                                               | Justification                                                                                                                                    |
| ------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `sfge:DatabaseOperationsMustUseWithSharing` | ~52           | `DocGenSignatureController`, `DocGenSignatureService`, `DocGenAuthenticatorController`           | Guest-site signing requires `without sharing` + `SYSTEM_MODE`. Access is gated by token + PIN, not by sharing.                                   |
| `sfge:ApexFlsViolation`                     | ~35           | `DocGenController`, `DocGenBulkController`, `DocGenSignatureSenderController`, signature classes | `USER_MODE` cannot be used on namespaced package fields with unqualified source names in the 2GP build. Permission-set is the CRUD/FLS boundary. |
| `pmd:ApexCRUDViolation`                     | ~16           | `DocGenController`, `DocGenSignatureSenderController`, `DocGenSetupController`                   | `Security.stripInaccessible()` strips namespaced package fields in the managed 2GP build context, corrupting records.                            |

Each suppression site has an inline comment explaining the specific rationale. Example patterns from the codebase:

```apex
// NOPMD ApexCRUDViolation — package-internal object, CRUD gated by DocGen Admin permission set
insert newTemplateVersion;
```

```apex
// @SuppressWarnings('PMD.ApexSharingViolations')
// Guest-site signing flow requires without sharing + SYSTEM_MODE.
// Access is gated by 64-char SHA-256 token (48h expiry) + email PIN (10min, 3 attempts).
public without sharing class DocGenSignatureController {
```

```apex
// CxSAST: Schema-validated objectName + sanitized whereClause + USER_MODE.
// Bind variables are not supported for FROM <object> on the Salesforce platform.
List<SObject> rows = Database.query(queryString, AccessLevel.USER_MODE);
```

---

## SFGE Engine Execution Notes

The SFGE (Salesforce Graph Engine) run reported four internal execution warnings during path evaluation:

| Entry point                               | Warning                                                                                                 |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `DocGenSignatureController.cls:927`       | Path evaluation timed out after 30,000 ms                                                               |
| `DocGenSignatureSenderController.cls:90`  | `TodoException: Operator is not handled for conditional clause` (known SFGE bug — negation containment) |
| `DocGenSignatureSenderController.cls:233` | Path evaluation timed out after 30,000 ms                                                               |
| `DocGenSignatureSenderController.cls:506` | Path evaluation timed out after 30,000 ms                                                               |

These are **engine-side limitations**, not violations. SFGE traverses every possible execution path from each `@AuraEnabled` entry point; for methods with deep conditional branching (the signature controllers contain multi-factor validation cascades — token format, expiry, status, PIN verification, consent, attempts-remaining), the evaluation exceeds the default 30-second per-path timeout or hits unhandled AST patterns. This is documented behavior of SFGE 0.19.0 and does not indicate a finding.

The `TodoException: NegationContainmentUtil` is a known SFGE bug (`TodoException` is the engine's explicit "this AST shape is not yet implemented" exception). We report it upstream when it blocks full analysis, but it does not affect the findings count — the rest of the rule set evaluates cleanly.

For completeness, the same code paths are covered by:

- The Checkmarx CxSAST scan (all paths fully evaluated — see `DocGen_False_Positive_Report.md`).
- 850+ Apex tests with ≥ 75% org-wide coverage.
- Eight end-to-end anonymous Apex scripts (`scripts/e2e-01-*.apex` through `scripts/e2e-08-*.apex`) that exercise the exact entry points SFGE timed out on.

---

## Configuration — `code-analyzer.yml`

The repository ships `code-analyzer.yml` at the project root. It preserves all Security and AppExchange rules at their default severity and relies on inline suppression markers rather than blanket rule disabling — every suppression is documented on the line it applies to, with the justification visible in code review and audit.

No rules are downgraded. No rules are disabled globally. No paths are excluded. The 30 Moderate findings reported above are the **complete output** of the default Security + AppExchange rule set against the full `force-app/` tree.

---

## Release Gating

Per `CLAUDE.md` — "Release Validation Checklist":

> **3. Code Analyzer — Security + AppExchange (0 violations)**
>
> ```bash
> sf code-analyzer run --workspace "force-app/" --rule-selector "Security" --rule-selector "AppExchange" --view table
> ```
>
> Expected: `0 High severity violation(s) found.` (30 Moderate false positives are acceptable — see `code-analyzer.yml`)

The v1.42.0 scan on 2026-04-10 meets this gate: **0 High, 30 Moderate (all documented false positives), 103 inline-suppressed (all documented)**. The v1.42.0 delta (new `DocGenSignatureFlowAction` invocable + `DocGenSignatureFlowActionTest` + refactored `DocGenSignatureSenderController` helper) introduced zero new Code Analyzer findings — the new class uses existing sharing and validation patterns and all delegations go through the same `DocGenSignatureSenderController` entry points already covered by the v1.41.0 baseline.

---

## Raw Scan Outputs

The machine-readable scan artifacts are included in the repository under `docs/code-analysis/`:

- `code-analyzer-report.html` — the standard Code Analyzer HTML report (opens directly in a browser).
- `code-analyzer-report.json` — the full JSON output including rule metadata, engine versions, and per-violation locations and messages.
- `violations.md` — historical tracking document covering the progression from 129 High violations in v1.28 down to 0 in v1.31+.
- `checkmarx-findings.md` — companion Checkmarx remediation tracker.

---

## Cross-References

- `DocGen_Solution_Architecture_and_Usage.md` — the security-review architecture doc.
- `DocGen_Architecture_and_Usage.md` — the architecture and usage companion.
- `DocGen_False_Positive_Report.md` — the Checkmarx CxSAST false-positive report.
- `SECURITY.md` — vulnerability disclosure policy.
- `CLAUDE.md` — release validation checklist and engineering invariants.

---

_Portwood Global Solutions — https://portwood.dev_
