# Portwood DocGen — Free Document Generation for Salesforce

Generate PDFs and Word docs from any Salesforce record. Merge PDFs, add barcodes and QR codes, compute totals — 100% native, zero external dependencies, 100% free forever. All features, all users, no paid tiers. PowerPoint and Excel coming soon.

[Join the Community Channel](https://portwoodglobalsolutions.com/DocGenCommunity) | [Website](https://portwoodglobalsolutions.com) | [Roadmap](https://portwoodglobalsolutions.com/DocGenRoadmap)

[![Version](https://img.shields.io/badge/version-1.42.0-blue.svg)](#install)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Salesforce-00A1E0.svg)](https://www.salesforce.com)
[![Namespace](https://img.shields.io/badge/namespace-portwoodglobal-purple.svg)](#install)
[![Apex Tests](https://img.shields.io/badge/Apex_Tests-846%2F846_passing-brightgreen)](#code-quality)
[![Security](https://img.shields.io/badge/Code_Analyzer-0_Critical%2C_0_High-brightgreen)](#security)
[![Website](https://img.shields.io/badge/website-portwoodglobalsolutions.com-blue)](https://portwoodglobalsolutions.com)

---

## Install

```bash
sf package install --package 04tal000006UkpxAAC --wait 10 --target-org <your-org>
```

[Install in Production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006UkpxAAC) | [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tal000006UkpxAAC)

**Then:** Assign **DocGen Admin** permission set | Enable **Blob.toPdf() Release Update** | Open the **DocGen** app

---

## Quick Start

1. **Create a template** — pick Word, Excel, or PowerPoint. Choose your Salesforce object.
2. **Select your fields** — use the visual query builder, or paste a full SOQL statement for complex nested relationships.
3. **Add tags and upload** — type `{Name}` where you want data. Upload the file.
4. **Generate** — from any record page, in bulk, or from a Flow.

Download example templates from [portwoodglobalsolutions.com](https://portwoodglobalsolutions.com).

---

## What You Can Do

### Template Formats

| Format | Template | Output Options | Best For |
|--------|----------|---------------|----------|
| **Word** | `.docx` | PDF or DOCX | Contracts, proposals, invoices, letters |
| **Excel** | `.xlsx` | XLSX | Data exports, reports, financial summaries |
| **PowerPoint** | `.pptx` | PPTX | Presentations, slide decks |

Word is the most capable — it's the only format that supports images, barcodes, QR codes, rich text, and PDF output.

### Merge Tags

| Tag | What It Does | Example |
|-----|-------------|---------|
| `{FieldName}` | Insert a field value | `{Name}`, `{Email}`, `{Phone}` |
| `{Parent.Field}` | Pull from a related record | `{Account.Name}`, `{Owner.Email}` |
| `{#ChildList}...{/ChildList}` | Repeat for each child record | `{#Contacts}{FirstName}{/Contacts}` |
| `{#BoolField}...{/BoolField}` | Show/hide based on checkbox | `{#IsActive}Active member{/IsActive}` |
| `{#Field}...{:else}...{/Field}` | Show/hide with fallback | `{#Industry}Sector: {Industry}{:else}No industry{/Industry}` |
| `{^Field}...{/Field}` | Show when field is false/blank | `{^HasDiscount}No discount applied{/HasDiscount}` |
| `{#IF Field op Value}...{/IF}` | Compare field against value | `{#IF Amount > 50000}Premium{:else}Standard{/IF}` |
| `{RichTextField}` | Rich text with formatting and images | `{Description}` renders bold, italic, lists |

### Formatting

| Tag | Output |
|-----|--------|
| `{CloseDate:MM/dd/yyyy}` | 03/18/2026 |
| `{Amount:currency}` | $500,000.00 |
| `{Rate:percent}` | 15.5% |
| `{Quantity:number}` | 1,234 |
| `{IsActive:checkbox}` | [X] or [ ] |

### Aggregates

Place these **outside** the loop to compute totals from child records:

| Tag | Example |
|-----|---------|
| `{SUM:List.Field}` | `{SUM:QuoteLineItems.TotalPrice}` |
| `{COUNT:List}` | `{COUNT:Contacts}` |
| `{AVG:List.Field}` | `{AVG:OpportunityLineItems.UnitPrice}` |
| `{MIN:List.Field}` / `{MAX:List.Field}` | `{MIN:QuoteLineItems.Quantity}` |

### Images

Store a ContentVersion ID (starts with `068`) in a text field, then use `{%FieldName}` in your template:

| Tag | What It Does |
|-----|-------------|
| `{%Logo__c}` | Insert image at original size |
| `{%Logo__c:200x60}` | Fixed size: 200px wide, 60px tall |
| `{%Logo__c:100%x}` | Full page width, keep aspect ratio |
| `{%Logo__c:m100%xm50%}` | Shrink to fit within page width and 50% height |

Images work in both **PDF** and **DOCX** output. You can also embed images directly in your Word template — they render in PDFs automatically.

### Rich Text Fields

Rich text fields render with full formatting (bold, italic, lists, images) in PDF output. Images inside rich text fields work in PDFs. For DOCX output, use `{%FieldName}` image tags instead of rich text images.

### Barcodes & QR Codes

PDF output only. No external services required.

| Tag | What You Get |
|-----|-------------|
| `{*ProductCode}` | Code 128 barcode |
| `{*ProductCode:code128:300x80}` | Barcode at 300px wide, 80px tall |
| `{*Website:qr}` | QR code (150px default) |
| `{*TrackingUrl:qr:200}` | QR code at 200px square |

### Repeating Tables

To repeat rows inside a table (not the whole table), put the loop tags in the data row:

| Name | Title | Email |
|------|-------|-------|
| `{#Contacts}{FirstName} {LastName}` | `{Title}` | `{Email}{/Contacts}` |

The `{#Contacts}` goes in the first cell and `{/Contacts}` goes in the last cell of the same row. The header row stays fixed, and the data row repeats for each record.

### Cover Pages & Section Breaks

- **Title pages** — If your Word template has "Different First Page" enabled, the PDF will suppress headers and footers on page 1. Your cover page stays clean.
- **Section breaks** — Section breaks in your Word template create proper page breaks in the PDF.

### Page Breaks in Loops

Put a page break inside a loop to give each child record its own page:

```
{#Opportunities}
Customer: {Account.Name}
Amount:   {Amount:currency}
                              ← page break here (Insert → Page Break in Word)
{/Opportunities}
```

### PDF Merger

Five ways to combine PDFs:

| Mode | What It Does |
|------|-------------|
| **Generate & Merge** | Generate a doc, then append existing PDFs from the record |
| **Document Packets** | Generate from multiple templates, merge into one PDF |
| **Merge Only** | Combine existing PDFs on the record with drag-and-drop ordering |
| **Child Record PDFs** | Pull PDFs from child records (e.g., all Opportunity PDFs under an Account) |
| **Bulk Merge** | After bulk generation, merge all generated PDFs into one download |

### Giant Query Engine

Records with **2,000 to 50,000+ child records** are detected automatically. Same template, same button — the engine handles pagination and async processing behind the scenes.

### E-Signatures

Collect legally valid electronic signatures directly from DocGen — no third-party tools required. Built-in Simple Electronic Signature (SES) support that's valid under the US ESIGN Act and UETA.

**How it works:**

1. Add `{@Signature_Buyer}` and `{@Signature_Seller}` placeholders to your Word template
2. Create a signature request from any record — each signer gets a branded email with a secure link
3. Signers verify their email with a 6-digit PIN, review the document, type their name, and check the consent box
4. After all signers complete, DocGen generates the signed PDF with an Electronic Signature Certificate

**What's captured for every signature:**

| Data Point | How |
|---|---|
| Signer identity | Email PIN verification (SHA-256 hashed, 10-min expiry, 3 attempts max) |
| Consent | Explicit checkbox — timestamp recorded |
| IP address | Server-side capture via request headers |
| User agent | Browser fingerprint |
| Document integrity | SHA-256 hash of the final PDF |
| Tamper evidence | Field history tracking on all audit fields |

**Verification:** Every signed PDF includes a certificate block with signer details and a verification URL. The verify page lets anyone upload a PDF to check its hash against the audit record — the file never leaves the browser.

**Admin setup:** Configure a Salesforce Site, assign the Guest Signature permission set, set an Org-Wide Email Address, and customize email branding — all from the Signatures tab in the Command Hub. See the [User Guide](https://portwoodglobalsolutions.com/DocGenGuide#sig-admin) for step-by-step instructions.

### Query Builder

The query builder accepts full SOQL statements with unlimited nesting depth. Paste a query like:

```sql
SELECT Name, Industry,
    (SELECT FirstName, LastName, Account.Name FROM Contacts),
    (SELECT Name, Amount,
        (SELECT Quantity, Product2.Name FROM OpportunityLineItems)
    FROM Opportunities WHERE StageName = 'Closed Won')
FROM Account
```

The builder parses the query, displays the field tree with parent lookups highlighted, and generates copy-paste merge tags for your template. Outer `SELECT` / `FROM` clauses are stripped automatically — DocGen always runs against a specific record.

**Tips:**
- Test your query in Developer Console or tools like [Salesforce Inspector](https://chromewebstore.google.com/detail/salesforce-inspector-reloaded/hpijlohoihegkfehhibggnkbjhoemldh) before pasting.
- Use AI to help build complex queries — Agentforce, ChatGPT, Gemini, and Claude can all generate valid SOQL with nested relationships.
- Subqueries support WHERE, ORDER BY, and LIMIT clauses.
- Parent lookups (e.g., `Account.Name`, `Product2.Family`) work at every nesting level.

### Automation

| Action | Inputs | Use In |
|--------|--------|--------|
| `DocGenFlowAction` | templateId, recordId | Record-Triggered Flows, Screen Flows |
| `DocGenBulkFlowAction` | templateId, queryCondition | Scheduled Flows, Bulk Processing |

### Bulk Generation

Generate documents for hundreds of records at once. Enter a filter condition, click Submit. Real-time progress tracking in the app.

---

## What Works in PDF vs DOCX

| Feature | PDF | DOCX |
|---------|-----|------|
| All merge tags and formatting | Yes | Yes |
| Bold, italic, underline, colors, font sizes | Yes | Yes |
| Tables with borders, shading, column widths | Yes | Yes |
| Template-embedded images | Yes | Yes |
| Dynamic images from record fields (`{%Field}`) | Yes | Yes |
| Rich text field formatting | Yes | Yes |
| Rich text images | Yes | No — use `{%Field}` image tags |
| Barcodes and QR codes | Yes | No |
| Page numbers in headers/footers | Yes | N/A (Word handles natively) |
| Cover page (no header on page 1) | Yes | N/A (Word handles natively) |
| Custom fonts (Calibri, branded, etc.) | No — falls back to Helvetica | Yes — preserves original fonts |
| Clickable hyperlinks | No — rendered as styled text | Yes |

---

## PDF Font Support

Salesforce's PDF engine supports these fonts:

| Font | CSS Name | When It's Used |
|------|----------|---------------|
| **Helvetica** | `sans-serif` | Default for all text |
| **Times** | `serif` | If explicitly set in template |
| **Courier** | `monospace` | Fixed-width text |
| **Arial Unicode MS** | (automatic) | Chinese, Japanese, Korean, Thai, Arabic, Hebrew |

Custom fonts from your Word template (Calibri, Cambria, branded typefaces) **fall back to Helvetica** in PDF output. If custom fonts matter, generate as DOCX — Word preserves the original fonts.

Starting with Spring '26, the renderer supports expanded multibyte character rendering for international scripts.

---

## What PDF Can't Do

These are Salesforce platform limitations, not DocGen bugs:

| Not Supported | Why | Workaround |
|--------------|-----|------------|
| Custom fonts | `Blob.toPdf()` only has 4 built-in fonts | Generate as DOCX |
| `@font-face` CSS | Not supported by the PDF renderer | Generate as DOCX |
| Text boxes and shapes | Word drawing objects aren't converted to HTML | Use tables for layout |
| SmartArt and charts | Not rendered in the HTML conversion | Insert as images in your template |
| Clickable hyperlinks | PDF renderer outputs styled text, not links | Links work in DOCX |
| CSS Grid / Flexbox | The PDF renderer supports CSS 2.1 only | Use tables |
| JavaScript | Ignored by the renderer | N/A |
| Even/odd page headers | Not currently supported | Same header on all pages |
| Multiple section headers | One header/footer set per document | Use page breaks, not section-specific headers |
| Multi-column layouts | CSS columns not supported by the PDF engine | Use tables for column layouts |
| E-signatures (QES) | SES signatures are built-in; Qualified Electronic Signatures (EU eIDAS) require a certified provider | Use built-in SES for most use cases |

---

## Governor Limits

| Limit | Details | How DocGen Handles It |
|-------|---------|----------------------|
| **6 MB heap (sync)** | Single document generation | DOCX uses client-side assembly; PDF uses zero-heap image pipeline |
| **12 MB heap (async)** | Bulk batch generation | Batch size 1 = fresh heap per record |
| **~3 MB PDF save** | Saving PDF to a record | Download has no size limit |
| **4 MB Aura payload** | Saving DOCX to a record | Download works for any size |
| **100 SOQL queries** | Per transaction | Multi-level queries use 1 SOQL per relationship depth |
| **50,000+ child records** | Giant datasets | Auto-detected, processed async with cursor pagination |

---

## Architecture

```
Template (.docx/.xlsx/.pptx)
    ↓
Decompress → Merge XML tags → Recompress
    ↓                              ↓
  DOCX/XLSX/PPTX              PDF path:
  (client-side ZIP)     DocGenHtmlRenderer → Blob.toPdf()
```

| Class | Role |
|-------|------|
| `DocGenService` | Core merge engine — tags, loops, images, aggregates, barcodes |
| `DocGenHtmlRenderer` | DOCX XML → HTML for PDF rendering |
| `DocGenDataRetriever` | Multi-level SOQL with query tree stitching |
| `BarcodeGenerator` | Code 128 + QR code generation (pure Apex) |
| `DocGenController` | LWC controller — template CRUD, generation endpoints |
| `DocGenBatch` | Batch Apex for bulk document generation |
| `DocGenSignatureController` | Signing page — token validation, PIN verification, signature capture |
| `DocGenSignatureService` | Typed-name stamping, PDF generation, verification certificate |
| `DocGenSignatureEmailService` | Branded signature request and PIN emails with OWA support |
| `docGenPdfMerger.js` | Client-side PDF merge engine (pure JS) |
| `docGenZipWriter.js` | Client-side DOCX/XLSX assembly (pure JS) |

---

## Releases

DocGen ships on a **biweekly release cycle**. Next release: **April 17, 2026**.

See [CHANGELOG.md](CHANGELOG.md) for full version history.

---

## Community

DocGen is 100% free, open source, and community-driven. Published through [Portwood Global Solutions](https://portwoodglobalsolutions.com).

| Channel | What It's For |
|---------|---------------|
| [Community Channel](https://portwoodglobalsolutions.com/DocGenCommunity) | Real-time help, feature requests, template sharing |
| [GitHub Issues](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/issues) | Bug reports and tracked feature requests |
| [Roadmap](https://portwoodglobalsolutions.com/DocGenRoadmap) | What's shipped and what's coming next |
| [Website](https://portwoodglobalsolutions.com) | Install links, feature overview |

Need dedicated support? Contact us at [hello@portwoodglobalsolutions.com](mailto:hello@portwoodglobalsolutions.com).

## Contributing

We welcome contributions — see [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions.

## Security

### Code Analyzer Results

We run the [Salesforce Code Analyzer](https://developer.salesforce.com/docs/platform/salesforce-code-analyzer/guide/engine-sfge.html) with **Security + AppExchange** rule selectors on every release.

| Severity | Count | Status |
|----------|-------|--------|
| **Critical** | 0 | Clean |
| **High** | 0 | Clean |
| **Moderate** | 30 | All documented false positives |
| **Low** | 0 | Not flagged |

The 30 moderate findings are all PMD false positives that cannot be suppressed inline:
- **22** `ProtectSensitiveData` — PMD flags field names containing "Token", "Email", "Hash", "PIN" in XML metadata. These are signature system fields, intentionally sensitive, protected by permission sets, sharing model, and field history tracking.
- **8** `AvoidLwcBubblesComposedTrue` — Required for recursive tree node event propagation in the visual query builder. Events must cross shadow DOM boundaries in nested components.

See [`code-analyzer.yml`](code-analyzer.yml) for full documentation of each accepted finding.

### How Access Is Enforced

| Layer | Mechanism |
|-------|-----------|
| **Object CRUD** | `DocGen_Admin` and `DocGen_User` permission sets (platform-enforced) |
| **Field-level security** | Same permission sets (platform-enforced) |
| **Record sharing** | Admin-context classes use `with sharing`; signature classes use `without sharing` with access gated by cryptographic token validation |
| **Standard objects** | `USER_MODE` + `Security.stripInaccessible()` (code-enforced) |
| **Signature guest access** | `SYSTEM_MODE` with 64-char SHA-256 token + email PIN verification |

No user can access DocGen data without an explicitly assigned permission set. Signature guest users can only access records matching their validated cryptographic token.

### E-Signature Security

| Control | Implementation |
|---------|---------------|
| Token generation | `Crypto.generateAesKey(256)` + SHA-256 hash (64-char hex) |
| Token expiry | 48 hours from creation |
| PIN verification | 6-digit code, SHA-256 hashed (plaintext never stored), 10-min expiry, 3 attempts max |
| Consent | Explicit checkbox with audit trail entry |
| Document integrity | SHA-256 hash of final PDF stored on audit record |
| Tamper evidence | Field history tracking on all audit fields |
| IP capture | Server-side via `X-Forwarded-For` / `True-Client-IP` headers |

Found a vulnerability? See [SECURITY.md](SECURITY.md).

## Version History

| Version | Channel | Package ID |
|---------|---------|------------|
| v1.42.0 | **Latest (Released)** | `04tal000006UkpxAAC` |
| v1.41.0 | Previous | `04tal000006UiubAAC` |
| v1.40.0 | Previous | `04tal000006UhyXAAS` |
| v1.39.0 | Previous | `04tal000006UhnFAAS` |
| v1.37.0 | Previous | `04tal000006UgBFAA0` |
| v1.36.0 | Previous | `04tal000006Ug9dAAC` |

See [CHANGELOG.md](CHANGELOG.md) for full release notes.

## License

Apache License, Version 2.0. See [LICENSE](LICENSE).

---

Built by [Portwood Global Solutions](https://portwoodglobalsolutions.com)
