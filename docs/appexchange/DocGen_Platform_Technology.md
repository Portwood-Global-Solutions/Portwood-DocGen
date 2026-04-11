# Salesforce Platform Technology Details

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

> Response to the security review prompt: *"If your solution contains Salesforce Platform technology, such as Lightning Components and Apex, provide details."*

---

DocGen is built **100% on native Salesforce Platform technology**. There are no external services, no callouts, no third-party JavaScript libraries, and no external hosted assets. All processing occurs inside the customer's Salesforce org.

---

## 1. Apex

**27 non-test Apex classes** plus **19 test classes** (846 Apex tests, **75.00% code coverage**, Code Coverage Met: true at package build time).

### Controllers (`@AuraEnabled`, entry points from LWC / VF)

| Class | Sharing | Purpose |
|---|---|---|
| `DocGenController` | `with sharing` | Primary generation entry point. Called from `docGenRunner` LWC. |
| `DocGenBulkController` | `with sharing` | Bulk job creation, progress polling, analysis. |
| `DocGenTemplateManager` | `with sharing` | Template library CRUD. |
| `DocGenSetupController` | `with sharing` | First-run setup wizard + Command Hub metadata. |
| `DocGenSignatureSenderController` | `with sharing` | Admin-initiated signature request creation. |
| `DocGenSignatureController` | `without sharing` | Guest-facing signing page entry point. Token + PIN gated. |
| `DocGenAuthenticatorController` | `without sharing` | Public document verification by SHA-256 hash (used by `DocGenVerify.page`). |

### Service / Helper Classes

`DocGenService` (merge engine), `DocGenDataRetriever` (V1/V2/V3 SOQL), `DocGenDataProvider`, `DocGenHtmlRenderer` (OOXML → HTML for `Blob.toPdf()`), `BarcodeGenerator` (Code-128 / QR), `DocGenSignatureService`, `DocGenSignatureValidator`, `DocGenSignatureSubmitter`, `DocGenSignatureFinalizer`, `DocGenSignatureEmailService`, `DocGenException`.

### Asynchronous Apex

- **Batchable:** `DocGenBatch`, `DocGenGiantQueryBatch`
- **Queueable:** `DocGenGiantQueryAssembler`, `DocGenGiantQueryStitchJob`, `DocGenMergeJob`
- **Platform Event triggered:** `DocGenSignatureFinalizer` (via `DocGen_Signature_PDF__e`)

### Flow Invocable Actions (`@InvocableMethod`)

- `DocGenFlowAction` — single-record document generation
- `DocGenBulkFlowAction` — bulk generation against a saved query
- `DocGenGiantQueryFlowAction` — multi-million-row query job
- `DocGenSignatureFlowAction` *(new in v1.42.0)* — create a signature request and return per-signer signing URLs for Flow-driven signature automation

### Apex Triggers

- **`DocGenSignaturePdfTrigger`** — fires on `DocGen_Signature_PDF__e` platform event insert; enqueues `TemplateSignaturePdfQueueable` to finalize the signed PDF asynchronously.

### SOQL Execution Mode

- **Standard objects** (`ContentVersion`, `ContentDocumentLink`, `User`, etc.): `WITH USER_MODE` — enforces CRUD/FLS at the platform level.
- **Package-internal objects** (`DocGen_Template__c`, `DocGen_Signer__c`, etc.): `WITH SYSTEM_MODE` — required because managed-package namespace resolution breaks unqualified field references at compile time with `USER_MODE`. Access is gated by the three DocGen permission sets.
- **Guest-signing paths** use `SYSTEM_MODE` inside token-validated entry points only.

---

## 2. Lightning Web Components

**17 Lightning Web Components** (no Aura, no Lightning Component Framework):

**Record-page and app components:**

- `docGenRunner` — document generation button on record pages. Includes two pure-JS modules: `docGenZipWriter.js` (dependency-free ZIP writer, CRC-32 inline, store mode) and `docGenPdfMerger.js`. Used for client-side DOCX/XLSX/PPTX assembly.
- `docGenCommandHub` — DocGen app landing page with quick actions, template library, bulk runner.
- `docGenAdmin` — template CRUD and version management.

**Template builders:**

- `docGenSetupWizard`, `docGenAdminGuide`, `docGenQueryBuilder`, `docGenColumnBuilder`, `docGenTreeBuilder`, `docGenTreeNode`, `docGenFilterBuilder`, `docGenTitleEditor`

**Bulk + signatures:**

- `docGenBulkRunner`, `docGenSignatureSender`, `docGenSignatureSettings`, `docGenSharing`, `docGenAuthenticator`, `docGenUtils`

**LWS compliance:** All components are Lightning Web Security compatible. No `eval`, no `Function` constructor, no dynamic imports, no access to global window APIs beyond standard typed arrays. User-supplied strings are rendered via `{expression}` interpolation (auto-escaped) — no `innerHTML` on user data.

---

## 3. Visualforce Pages

**4 Visualforce pages**, all internal to the package (no Sites or public hosting assumed by the package itself — the customer optionally hosts the signing page on their own Salesforce Site).

| Page | Purpose | Access |
|---|---|---|
| `DocGenGuide.page` | In-app admin guide | Admin + User permission sets |
| `DocGenSign.page` / `DocGenSignature.page` | Public signing page (served via customer's Salesforce Site) | Guest via `DocGen_Guest_Signature` permission set |
| `DocGenVerify.page` | Document integrity verification (SHA-256 hash recomputed locally in browser — file never uploaded) | Guest + Admin + User |

All pages use standard Visualforce auto-escaping on all merge fields. URL parameters are validated before reflection.

---

## 4. Custom Objects

**9 custom objects** (8 sObjects + 1 platform event):

| Object | Purpose |
|---|---|
| `DocGen_Template__c` | Logical template definition |
| `DocGen_Template_Version__c` | Versioned OOXML artifact (master-detail to Template) |
| `DocGen_Saved_Query__c` | Reusable V1/V2/V3 query config |
| `DocGen_Job__c` | Bulk generation job tracking |
| `DocGen_Settings__c` | Hierarchy custom setting for org-wide config (branding, OWA, etc.) |
| `DocGen_Signature_Request__c` | Parent of a signature request |
| `DocGen_Signer__c` | One per signer (token, PIN hash, status) |
| `DocGen_Signature_Audit__c` | Immutable audit record with field history tracking |
| `DocGen_Signature_PDF__e` | Platform event for async PDF finalization |

All relationships between DocGen objects use master-detail (`ControlledByParent` sharing) where appropriate to enforce parent-record-based access.

---

## 5. Permission Sets

**3 permission sets** define the complete CRUD/FLS/tab/page/class access model:

| Permission Set | Target | Scope |
|---|---|---|
| `DocGen_Admin` | Admins | Full CRUD on all DocGen objects; access to all Apex classes, tabs, pages, and the Settings custom setting. |
| `DocGen_User` | End users | Generate documents from record pages, view own jobs, read templates. Explicitly **denied** on `DocGen_Signer__c.PIN_Hash__c`, `Secure_Token__c`, `PIN_Attempts__c`, `PIN_Expires_At__c`, and `DocGen_Signature_Request__c.Secure_Token__c`. |
| `DocGen_Guest_Signature` | Site guest user | Minimal scope: read on signature objects exclusively through token-gated entry points in `DocGenSignatureController`. No access to templates, jobs, or unrelated record data. |

---

## 6. Custom Application and Tabs

- **1 Custom App** — `DocGen` (Lightning App with Command Hub, Template Manager, Bulk Gen, Setup, and Job History tabs)
- **11 Custom Tabs** — Command Hub, Template Manager, Bulk Gen, Setup, Admin Guide, plus object tabs for Job, Template, Template Version, Signature Request, Signer, and Signature Audit

---

## 7. Flows (Sample)

**2 sample Flows** shipped with the package as admin-editable starting points:

- `DocGen_Generate_Account_Summary` — demonstrates `DocGenFlowAction` usage
- `DocGen_Welcome_Pack_New_Contact` — record-triggered Flow on Contact insert

---

## 8. External Technologies Used

**None.** Specifically:

- **External callouts:** None. Zero Remote Site Settings, zero Named Credentials, zero `Http.send()` invocations. Confirmed by Salesforce Code Analyzer.
- **Third-party JS libraries:** None. `docGenZipWriter.js` is implemented from scratch in the package precisely so no external ZIP library is pulled in.
- **External fonts / images / CSS:** None. No CDN fetches, no `@font-face` from external URLs.
- **Session ID usage:** None. The package never calls `UserInfo.getSessionId()`.
- **Cryptographic dependencies:** Only Salesforce's built-in `Crypto` class (`generateAesKey`, `generateDigest`, `getRandomInteger`). No hardcoded secrets, keys, or tokens anywhere in the source.

---

## 9. Test Coverage

- **846 Apex tests**, 100% pass rate
- **Package build coverage:** 75.00% (Code Coverage Met: true)
- **Release gate coverage:** 8 end-to-end anonymous Apex scripts (`scripts/e2e-*.apex`) covering permissions, template CRUD, PDF generation, DOCX generation, bulk, signatures, merge-tag syntax, and cleanup. **138/0 PASS** on the v1.42.0 release validation run.

---

## 10. Salesforce Code Analyzer Results

Run with `sf code-analyzer run --rule-selector Security --rule-selector AppExchange` against the full `force-app/` tree:

- **0 Critical**
- **0 High**
- **0 Low**
- **30 Moderate** — all documented false positives (8 `AvoidLwcBubblesComposedTrue` on a recursive tree component where `composed: true` is structurally required for events to cross nested shadow DOMs; 22 `ProtectSensitiveData` pattern-match false positives on signature field names — the fields are protected structurally by the permission sets and are SHA-256 hashes, not plaintext)

See `docs/appexchange/DocGen_Code_Analyzer_Report.pdf` for the full finding-by-finding disposition.

---

## 11. Related Documentation

- `DocGen_Solution_Architecture_and_Usage.pdf` — security-focused architecture, threat model, sharing model, controls matrix.
- `DocGen_Architecture_and_Usage.pdf` — feature/component inventory and usage walkthroughs.
- `DocGen_False_Positive_Report.pdf` — per-category disposition of the Checkmarx CxSAST findings.
- `DocGen_Code_Analyzer_Report.pdf` — Salesforce Code Analyzer run results.

---

*Portwood Global Solutions — https://portwoodglobalsolutions.com*
