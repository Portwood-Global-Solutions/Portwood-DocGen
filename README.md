# Portwood DocGen — Free Document Generation for Salesforce

Generate PDFs and Word docs from any Salesforce record. Merge PDFs, add barcodes and QR codes, compute totals — 100% native, zero external dependencies, 100% free forever. All features, all users, no paid tiers. PowerPoint and Excel coming soon.

[Join the Community Channel](https://portwoodglobalsolutions.com/DocGenCommunity) | [Website](https://portwoodglobalsolutions.com) | [Roadmap](https://portwoodglobalsolutions.com/DocGenRoadmap)

[![Version](https://img.shields.io/badge/version-1.25.0-blue.svg)](#install)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Salesforce-00A1E0.svg)](https://www.salesforce.com)
[![Namespace](https://img.shields.io/badge/namespace-portwoodglobal-purple.svg)](#install)
[![Apex Tests](https://img.shields.io/badge/Apex_Tests-683%2F683_passing-brightgreen)](#code-quality)
[![E2E](https://img.shields.io/badge/E2E-24%2F24_passing-brightgreen)](#code-quality)
[![Website](https://img.shields.io/badge/website-portwoodglobalsolutions.com-blue)](https://portwoodglobalsolutions.com)

---

## Install

```bash
sf package install --package 04tal000006PhBBAA0 --wait 10 --target-org <your-org>
```

[Install in Production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006PhBBAA0) | [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tal000006PhBBAA0)

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
| `{RichTextField}` | Rich text with formatting and images | `{Description}` renders bold, italic, lists |

### Formatting

| Tag | Output |
|-----|--------|
| `{CloseDate:MM/dd/yyyy}` | 03/18/2026 |
| `{Amount:currency}` | $500,000.00 |
| `{Rate:percent}` | 15.5% |
| `{Quantity:number}` | 1,234 |

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
| E-signatures | Intentionally excluded | Use DocuSign, Adobe Sign after generation |

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

### CRUD/FLS Transparency Report

We run the [Salesforce Code Analyzer](https://developer.salesforce.com/docs/platform/salesforce-code-analyzer/guide/engine-sfge.html) with Security + AppExchange rule selectors on every release. The current scan reports **51 High-severity SFGE `ApexFlsViolation` findings** — all on package-internal custom objects. We believe in full transparency, so here they are:

**Why these exist:** DocGen is a managed package with the `portwoodglobal` namespace. Salesforce's `USER_MODE` keyword (which SFGE requires for compliance) breaks namespace resolution during managed package builds — field names like `Query_Config__c` fail with "No such column" because the SOQL engine requires the fully-qualified `portwoodglobal__Query_Config__c`. Since namespace-qualified field names don't compile in development scratch orgs, `SYSTEM_MODE` is the only viable option for package-internal objects. This is standard practice for managed packages on the Salesforce platform.

Salesforce's own [AppExchange security review guidance](https://developer.salesforce.com/blogs/2023/04/prepare-your-app-to-pass-the-appexchange-security-review) explicitly states that bypassing CRUD/FLS is acceptable for "custom objects or fields like logs or system metadata that shouldn't be directly accessible to the user via CRUD/FLS." All DocGen custom objects fall into this category.

**How access is actually enforced:**
- **Object-level CRUD**: Enforced by `DocGen_Admin` and `DocGen_User` permission sets (platform-level)
- **Field-level security**: Enforced by the same permission sets (platform-level)
- **Record-level sharing**: All Apex classes use `with sharing` (platform-enforced)
- **Standard objects** (ContentVersion, ContentDocumentLink): Use `USER_MODE` + `Security.stripInaccessible()` (code-enforced)

No user can read, create, update, or delete any DocGen data without an explicitly assigned permission set.

<details>
<summary>Full SFGE violation log (51 findings across 3 files)</summary>

**DocGenBulkController.cls** (9 findings):
| Line | Operation | Object | Fields |
|------|-----------|--------|--------|
| 9 | READ | DocGen_Template__c | Base_Object_API__c, Description__c, Name, Output_Format__c, Query_Config__c, Test_Record_Id__c |
| 336 | INSERT | DocGen_Job__c | Label__c, Merge_Only__c, Query_Condition__c, Status__c, Template__c |
| 336 | INSERT | DocGen_Job__c | (duplicate path) |
| 356 | READ | DocGen_Job__c | Error_Count__c, Name, Status__c, Success_Count__c, Total_Records__c |
| 366 | READ | DocGen_Job__c | CreatedDate, Error_Count__c, Label__c, Name, Status__c, Success_Count__c, Total_Records__c |
| 382 | READ | DocGen_Job__c | CreatedDate, Query_Condition__c, Template__c |
| 438 | READ | DocGen_Saved_Query__c | CreatedDate, Description__c, DocGen_Template__c, Name, Query_Condition__c |
| 461 | INSERT | DocGen_Saved_Query__c | Description__c, DocGen_Template__c, Name, Query_Condition__c |

**DocGenController.cls** (41 findings):
| Line | Operation | Object | Fields |
|------|-----------|--------|--------|
| 16 | READ | DocGen_Template__c | Base_Object_API__c, Document_Title_Format__c, Output_Format__c, Query_Config__c, Type__c |
| 448 | READ | DocGen_Job__c | Label__c, Status__c, Success_Count__c, Total_Records__c |
| 637 | READ | DocGen_Template__c | Base_Object_API__c, Query_Config__c |
| 787 | READ | DocGen_Template__c | Base_Object_API__c, Description__c, Is_Default__c, Name, Output_Format__c, Query_Config__c, Type__c |
| 800 | READ | DocGen_Template__c | Base_Object_API__c, Category__c, Description__c, Document_Title_Format__c, Is_Default__c, Name, Output_Format__c, Query_Config__c, Test_Record_Id__c, Type__c |
| 800 | READ | ContentDocumentLinks | ContentDocument.CreatedDate, ContentDocumentId |
| 839 | READ | DocGen_Template__c | Base_Object_API__c, Is_Default__c |
| 848 | UPDATE | DocGen_Template__c | Base_Object_API__c, Is_Default__c |
| 852 | UPDATE | DocGen_Template__c | Base_Object_API__c, Category__c, Description__c, Document_Title_Format__c, Is_Default__c, Name, Output_Format__c, Query_Config__c, Test_Record_Id__c, Type__c |
| 857 | READ | DocGen_Template_Version__c | Is_Active__c, Template__c |
| 864 | UPDATE | DocGen_Template_Version__c | Is_Active__c, Template__c |
| 893 | INSERT | DocGen_Template_Version__c | Base_Object_API__c, Category__c, Content_Version_Id__c, Description__c, Is_Active__c, Query_Config__c, Template__c, Type__c |
| 932 | READ | DocGen_Template_Version__c | Base_Object_API__c, Category__c, Content_Version_Id__c, CreatedBy.Name, CreatedDate, Description__c, Is_Active__c, Name, Query_Config__c, Template__c, Type__c |
| 947 | READ | DocGen_Template_Version__c | Base_Object_API__c, Category__c, Content_Version_Id__c, Description__c, Query_Config__c, Template__c, Type__c |
| 955 | READ | DocGen_Template_Version__c | Is_Active__c, Template__c |
| 962 | UPDATE | DocGen_Template_Version__c | Is_Active__c, Template__c |
| 967 | UPDATE | DocGen_Template_Version__c | Is_Active__c |
| 977 | UPDATE | DocGen_Template__c | Base_Object_API__c, Category__c, Description__c, Query_Config__c, Type__c |
| 3065 | INSERT | DocGen_Template__c | Base_Object_API__c, Category__c, Description__c, Name, Output_Format__c, Query_Config__c, Type__c |
| 3098 | INSERT | DocGen_Template_Version__c | Base_Object_API__c, Category__c, Content_Version_Id__c, Description__c, Is_Active__c, Query_Config__c, Template__c, Type__c |
| 3131 | READ | DocGen_Template__c | Base_Object_API__c, Category__c, Description__c, Document_Title_Format__c, Is_Default__c, Name, Output_Format__c, Query_Config__c, Type__c |
| 3131 | READ | Saved_Queries__r | Description__c, Name, Query_Condition__c |
| 3131 | READ | Versions__r | Base_Object_API__c, Category__c, Content_Version_Id__c, Description__c, Is_Active__c, Query_Config__c, Type__c |
| 3227 | INSERT | DocGen_Template__c | Base_Object_API__c, Category__c, Description__c, Document_Title_Format__c, Is_Default__c, Name, Output_Format__c, Query_Config__c, Type__c |
| 3254 | INSERT | DocGen_Template_Version__c | Base_Object_API__c, Category__c, Content_Version_Id__c, Description__c, Is_Active__c, Query_Config__c, Template__c, Type__c |
| 3277 | INSERT | DocGen_Saved_Query__c | Description__c, DocGen_Template__c, Name, Query_Condition__c |

**DocGenTemplateManager.cls** (1 finding):
| Line | Operation | Object | Fields |
|------|-----------|--------|--------|
| 14 | READ | DocGen_Template_Version__c | Content_Version_Id__c, Is_Active__c, Template__c |

All 51 findings are `sfge:ApexFlsViolation` on package-internal custom objects using `SYSTEM_MODE`. Standard object queries (ContentVersion, ContentDocumentLink) use `USER_MODE` with `Security.stripInaccessible()` and have zero violations.

</details>

Found a vulnerability? See [SECURITY.md](SECURITY.md).

## License

Apache License, Version 2.0. See [LICENSE](LICENSE).

---

Built by [Portwood Global Solutions](https://portwoodglobalsolutions.com)
