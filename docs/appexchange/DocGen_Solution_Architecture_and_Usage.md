# DocGen — Solution Architecture and Usage Guide

## AppExchange Security Review Documentation

**Package:** Portwood DocGen Managed
**Namespace:** portwoodglobal
**Version:** 1.34.0
**Package ID:** 04tal000006UXkfAAG

---

## 1. Solution Overview

DocGen is a 100% native Salesforce document generation engine with built-in electronic signatures. It generates PDFs, Word documents, Excel spreadsheets, and PowerPoint presentations by merging live Salesforce data into user-uploaded templates. All processing occurs entirely within the Salesforce platform.

**Key Principle:** Zero external callouts. Zero external dependencies. No data leaves the customer's Salesforce org.

---

## 2. Information Flow

### 2.1 Document Generation Flow

```
User clicks "Generate" on Record Page
        |
        v
LWC (docGenRunner) calls @AuraEnabled method
        |
        v
DocGenController.processAndReturnDocument()
        |
        v
DocGenDataRetriever fetches record data via SOQL
(runs with SYSTEM_MODE on package objects,
 USER_MODE on standard objects)
        |
        v
DocGenService.mergeTemplate() processes template:
  - Decompresses DOCX/XLSX/PPTX ZIP
  - Replaces merge tags with record data
  - Processes loops, conditionals, images, barcodes
  - Recompresses modified ZIP
        |
        v
PDF Path: DocGenHtmlRenderer converts OOXML to HTML
          Blob.toPdf() renders PDF (Salesforce engine)
        |
        v
Output returned to browser (download) or saved
as ContentVersion on the record (save to record)
```

**Data touchpoints:**
1. SOQL query to retrieve record data (within org)
2. ContentVersion read to load template file (within org)
3. Apex processing of template merge (within org)
4. ContentVersion write to save generated document (within org)

**No external touchpoints.** All data remains within the Salesforce org boundary.

### 2.2 E-Signature Flow

```
Admin creates Signature Request
        |
        v
DocGenSignatureSenderController creates:
  - DocGen_Signature_Request__c record
  - DocGen_Signer__c record per signer
  - Generates 64-char SHA-256 token per signer
  - Sends branded email via Messaging.SingleEmailMessage
    (using Org-Wide Email Address if configured)
        |
        v
Signer clicks link in email
        |
        v
Public Salesforce Site serves DocGenSignature VF page
(Guest user context, no Salesforce login required)
        |
        v
Token validated via DocGenSignatureController.validateToken()
  - 64-char hex format check
  - Token lookup in DocGen_Signer__c (SYSTEM_MODE)
  - 48-hour expiry check
  - Status validation (not already signed/cancelled)
        |
        v
Email PIN Verification:
  1. Signer enters email address
  2. Server validates email matches signer record
  3. 6-digit PIN generated (Crypto.getRandomInteger)
  4. PIN hashed with SHA-256 (plaintext NEVER stored)
  5. Hash + expiry (10 min) saved on signer record
  6. PIN sent via email (Messaging.SingleEmailMessage)
  7. Signer enters PIN
  8. Server hashes input, compares to stored hash
  9. Max 3 attempts before permanent lockout
        |
        v
Document Preview:
  - Merged template HTML rendered in expandable panel
  - Signer reviews full document before signing
        |
        v
Signature Capture:
  - Signer types full name
  - Checks consent checkbox
  - Clicks "Sign Document"
        |
        v
DocGenSignatureController.saveSignature():
  - Validates PIN was verified
  - Validates consent given
  - Stores typed name on signer record
  - Creates DocGen_Signature_Audit__c with:
    * IP address (server-side via X-Forwarded-For)
    * User agent
    * Consent timestamp
    * PIN verification timestamp
  - Checks if all signers complete
        |
        v
All signers complete:
  - Platform Event (DocGen_Signature_PDF__e) published
  - Trigger routes to TemplateSignaturePdfQueueable
  - Template merged with record data
  - {@Signature_Role} placeholders replaced with typed names
  - Electronic Signature Certificate appended to HTML
  - Blob.toPdf() generates final PDF
  - SHA-256 hash of PDF computed and stored on audit record
  - PDF saved as ContentVersion on related record
```

**Signature data touchpoints:**
1. Token validation query (within org, SYSTEM_MODE)
2. PIN hash storage/comparison (within org, SHA-256)
3. Email delivery (Salesforce Messaging API, no external service)
4. Audit record creation (within org, field history tracking)
5. PDF generation and storage (within org)

**No signature data leaves the Salesforce org.**

---

## 3. Authentication

### 3.1 Internal Users (Admin/User)
- Standard Salesforce authentication (login, SSO, MFA)
- Access controlled by `DocGen Admin` and `DocGen User` permission sets
- All @AuraEnabled methods require authenticated session
- CSRF protection handled by Salesforce Aura/LWC framework

### 3.2 External Signers (Guest Users)
- No Salesforce login required
- Access via public Salesforce Site
- Authentication via cryptographic token:
  - Generated: `Crypto.generateAesKey(256)` + SHA-256 hash (64-char hex)
  - Expiry: 48 hours from creation
  - Single-use: burned after signing
  - Format validated: must match `[a-fA-F0-9]{64}` pattern
- Identity verification via email PIN:
  - 6-digit code sent to signer's email
  - SHA-256 hashed before storage (plaintext never persisted)
  - 10-minute expiry
  - 3 attempts max before permanent lockout
- Guest user profile restricted to:
  - DocGen_Guest_Signature permission set only
  - Read-only on signature objects (via SYSTEM_MODE, token-gated)
  - No access to templates, jobs, or other DocGen data

---

## 4. Encryption

### 4.1 Data at Rest
- All data stored in standard Salesforce objects (encrypted per org's Shield Platform Encryption settings if enabled)
- PIN codes stored as SHA-256 hashes only — plaintext never persisted
- Signature tokens stored as SHA-256 hex strings
- Document integrity hash (SHA-256) stored on audit records

### 4.2 Data in Transit
- All Salesforce platform communication uses TLS 1.2+
- No external API calls — no data leaves the Salesforce TLS boundary
- Email delivery via Salesforce Messaging API (Salesforce's own TLS)

### 4.3 Cryptographic Operations
- Token generation: `Crypto.generateAesKey(256)` (256-bit random key) + `Crypto.generateDigest('SHA-256')`
- PIN generation: `Crypto.getRandomInteger()` (CSPRNG)
- PIN hashing: `Crypto.generateDigest('SHA-256')` — one-way hash, not reversible
- Document hashing: `Crypto.generateDigest('SHA-256')` on final PDF blob

**No custom encryption keys. No key management. No hardcoded secrets.** All cryptographic material generated at runtime using Salesforce's built-in `Crypto` class.

---

## 5. Data Touchpoints Summary

| Touchpoint | Direction | Protocol | Authentication | Data |
|---|---|---|---|---|
| Template upload | User → SF | HTTPS (TLS 1.2+) | SF session | DOCX/XLSX/PPTX file |
| Record data query | Internal SF | SOQL | SF session | Record fields |
| Document generation | Internal SF | Apex processing | SF session | Merged document |
| Document save | Internal SF | DML | SF session | ContentVersion |
| Signature email | SF → Email | SF Messaging API | OWA or running user | Link + branding |
| PIN email | SF → Email | SF Messaging API | OWA | 6-digit code |
| Signing page | Signer → SF | HTTPS (TLS 1.2+) | Token + PIN | Typed name + consent |
| Audit record | Internal SF | DML | SYSTEM_MODE (token-gated) | IP, UA, hash, timestamps |

**External integrations:** None
**External callouts:** None
**Session ID usage:** None
**Data stored outside Salesforce:** None

---

## 6. Basic Usage Instructions

### 6.1 Initial Setup
1. Install the package
2. Assign `DocGen Admin` permission set to admin users
3. Assign `DocGen User` permission set to end users
4. Enable Blob.toPdf() Release Update (Setup > Release Updates)
5. Add the `docGenRunner` LWC component to record page layouts

### 6.2 Creating a Template
1. Open the DocGen app (App Launcher > DocGen)
2. Click "Create New" in the template library
3. Name the template, select the base object (e.g., Account)
4. Build the query using the visual query builder or manual SOQL editor
5. Upload a .docx file containing merge tags (e.g., `{Name}`, `{#Contacts}{FirstName}{/Contacts}`)

### 6.3 Generating a Document
1. Navigate to any record page with the DocGen component
2. Select a template from the dropdown
3. Choose Download or Save to Record
4. Click Generate Document

### 6.4 E-Signatures
1. Configure a Salesforce Site pointing to `DocGenSignature` VF page
2. Assign `DocGen Guest Signature` permission set to the site guest user
3. Set email deliverability to "All Email"
4. Configure branding in Command Hub > Signatures tab
5. Add `{@Signature_Buyer}` placeholders to your Word template
6. Create a signature request from any record page using the Signature Sender component

### 6.5 Document Verification
1. Every signed PDF includes an Electronic Signature Certificate
2. The certificate contains a verification URL
3. Anyone can verify by visiting the URL or uploading the PDF to the verify page
4. The browser computes a SHA-256 hash locally (file never uploaded) and checks against the audit record

---

## 7. Security Compliance

| Check | Status |
|---|---|
| Salesforce Code Analyzer (Security + AppExchange) | 0 Critical, 0 High |
| External callouts | None |
| Session ID usage | None |
| Data exfiltration paths | None |
| SOQL injection | Schema allowlist validation on all dynamic elements |
| XSS | No innerHTML; LWC auto-escaping; ID validation on URL params |
| CSRF | Platform-handled for all @AuraEnabled methods |
| CRUD/FLS | Permission set enforced (package-internal objects) |
| Sharing | `with sharing` on admin classes; `without sharing` on guest classes (token-gated) |
| Apex tests | 850 tests, 75% coverage |

**Full Checkmarx compliance documentation:** See `docs/code-analysis/checkmarx-findings.md` in the source repository.

---

*Portwood Global Solutions — https://portwoodglobalsolutions.com*
