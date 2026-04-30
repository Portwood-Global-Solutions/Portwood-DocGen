# Portwood DocGen — User Guide

> **Source of truth.** This file is the canonical reference for every feature DocGen exposes to admins, template authors, end users, and Flow builders. Keep the in-app Learning Center, the public website, and any external docs in sync with this file — never the other way around.
>
> If you ship a new feature: add it here first, then propagate to the Learning Center LWC (`docGenCommandHub`) and the website.
> If you remove/deprecate a feature: mark it in this file, then remove from the Learning Center and website.

**Current release:** v1.77.0 · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rCxFAAU)

---

## Table of contents

1. [What DocGen does](#1-what-docgen-does)
2. [Install & first-run setup](#2-install--first-run-setup)
3. [Permission sets](#3-permission-sets)
4. [Templates](#4-templates)
5. [Query builder](#5-query-builder) — including [Apex Data Provider (V4)](#54-apex-data-provider-v4--class-backed-templates)
6. [Merge tag reference](#6-merge-tag-reference)
7. [Document generation](#7-document-generation)
8. [Bulk generation](#8-bulk-generation)
9. [E-signatures (v3)](#9-e-signatures-v3)
10. [Flow automation](#10-flow-automation)
    10A. [Apex API reference (programmatic access)](#10a-apex-api-reference-programmatic-access)
11. [Heap-aware routing (how big datasets are handled)](#11-heap-aware-routing-how-big-datasets-are-handled)
12. [Admin & settings](#12-admin--settings)
13. [Limits & known constraints](#13-limits--known-constraints)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. What DocGen does

Portwood DocGen is a native Salesforce document generation engine. It merges Salesforce record data into Word and PowerPoint templates to produce PDF, DOCX, PPTX, or XLSX files. It runs 100% inside Salesforce — no external services, no API callouts, no session ID leakage.

**Capabilities at a glance**

- Word, HTML, PowerPoint, Excel templates with `{FieldName}` merge tags
- Multi-object query builder (any depth — Opportunity → Line Items → Product → Pricebook)
- Child record loops (tables, bulleted lists), aggregates (SUM/COUNT/AVG/MIN/MAX), conditionals, comparisons
- Locale-aware currency/number/date formatting (35+ currencies, 25+ locales)
- Dynamic images, barcodes, QR codes, rich text
- E-signatures (typed-name SES with PIN verification, packets, sequential signing, audit trail)
- Bulk generation for mass document runs (hundreds to thousands of records)
- Giant-query mode for templates with 60K+ child rows
- Flow invocable actions for every major operation
- **Automatic heap-aware routing** — the runner silently switches from sync to giant mode if the dataset is too big; customers never see "heap size too large" errors

---

## 2. Install & first-run setup

### Install the package

```bash
sf package install --package 04tal000006rCxFAAU --wait 10 --target-org <your-org>
```

Or: [Install in Production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rCxFAAU) · [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rCxFAAU)

### Post-install checklist

1. **Assign the `DocGen_Admin` permission set** to yourself (see [§3](#3-permission-sets)).
2. **Enable the "Use the Visualforce PDF Rendering Service for `Blob.toPdf()` Invocations" Release Update** in Setup. This is mandatory for PDF output — image resolution and complex layouts require it.
3. **Open the DocGen app** from the App Launcher. You'll land on the Command Hub.
4. For e-signatures only: run through the [signature admin setup](#9-e-signatures-v3) — Site URL, Org-Wide Email Address, guest permission set.

---

## 3. Permission sets

Three permission sets ship with the package. Assign what each user needs.

| Permission set           | Who gets it                              | What they can do                                                                                                                                                                       |
| ------------------------ | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DocGen_Admin`           | Template authors, system admins          | Full CRUD on templates, query configs, signature objects, settings. Can create/edit/delete templates. Can "Sign In Person" bypass for signatures.                                      |
| `DocGen_User`            | End users generating docs                | Read/edit templates (no delete). Generate single + bulk documents. Create signature requests. Can't modify templates or settings.                                                      |
| `DocGen_Guest_Signature` | Salesforce Site guest user (for signing) | Read access to signature requests/signers/placements. Create access on audit records. Access to the signing VF pages. Required for external signers who don't have a Salesforce login. |

**Adding a custom field to DocGen objects? Update all three permission sets.** Missed FLS grants silently break field access for the affected role (signer can't read, generator can't populate, etc.). This is the #1 recurring bug class.

---

## 4. Templates

### 4.1 Creating a template

1. Open the DocGen app → **My Templates** tab → **+ New Template**.
2. Pick a template type: **Word** (`.docx`), **HTML** (`.html` / `.htm` / `.zip`), **PowerPoint** (`.pptx`), or **Excel** (`.xlsx`).
3. Pick a base object (Account, Opportunity, Case, any custom object).
4. Upload your file containing `{FieldName}` merge tags.
5. Configure the query — which fields, which child relationships (see [§5](#5-query-builder)).
6. Choose the default **output format** (PDF or the native format).
7. Save.

**Output formats by template type:**

- Word (`.docx`) template → output PDF **or** DOCX (pick one when you save the template)
- HTML (`.html` / `.htm` / `.zip`) template → output PDF only (see [§4.7](#47-html-templates-google-docs-notion-any-html-source))
- PowerPoint (`.pptx`) template → output PPTX only (PowerPoint→PDF is not supported by the Salesforce platform)
- Excel (`.xlsx`) template → output XLSX only

> **One template → one output format.** As of v1.74 the runtime "Output As"
> override picker is removed — templates render in whatever format they were
> saved with. To offer the same source as both PDF and DOCX, save the template
> twice (one as PDF, one as Native) and let users pick the one they want.
> Cross-format generation produced subtle corruption in either direction and
> the cleanest fix was to make output binding.

> **Max template file size: 10 MB.** The uploader rejects anything larger with
> a clear toast. Almost every 20+ MB template is uncompressed images — in
> Word, right-click any image → **Compress Pictures → Email (96 ppi)** or
> **Web (150 ppi)** — most templates drop to 1–2 MB with no visible quality
> loss. See [§13.8](#138-template--output-size-guidance) for the full
> breakdown of why this limit exists and what generation flows it affects.

### 4.2 Template versions

Each save creates a new `DocGen_Template_Version__c` record. Only the version marked **Active** (`Is_Active__c = true`) is used by the runner.

- Older versions are preserved for rollback.
- When you save a new version, DocGen pre-extracts images from the DOCX/PPTX ZIP and caches them as ContentVersions for fast PDF rendering at generation time.
- It also pre-decomposes the XML parts and caches them — this bypasses ZIP decompression at generation time for ~75% heap savings on PDF output.

### 4.3 Test record

Set `Test_Record_Id__c` on the template to pin a specific record for preview/validation. Useful during template development — you can always preview against a known-good record without picking it each time.

### 4.4 Output format locking

Check `Lock_Output_Format__c` on the template to prevent users from overriding the output format at runtime. If locked, the runner's "output as PDF/Word" toggle is hidden and any attempt to override via the Flow action or API throws a validation error.

Use this for compliance-sensitive documents where only one format is allowed (e.g., signed contracts must always be PDF).

### 4.5 Template visibility (audience control)

Restrict which users see a template in their picker:

- **`Required_Permission_Sets__c`** (comma-separated permission-set names): only users with _all_ of these permission sets see the template.
- **`Specific_Record_Ids__c`** (comma-separated record IDs): only show the template for these specific records.
- **`Record_Filter__c`** (SOQL `WHERE` clause — for example, `StageName = 'Negotiation/Review' AND Amount > 10000`): dynamically show/hide based on the record's field values.

These can be combined. All three must match for the template to appear.

### 4.6 Template sharing

Template access uses **standard Salesforce sharing** — sharing rules, manual sharing, and role hierarchy. Field-level security is enforced on the merged data too. There's no custom sharing UI; if you want to restrict who _sees_ a template in the picker, use the visibility controls in §4.5 instead.

### 4.7 HTML templates (Google Docs, Notion, any HTML source)

Shipped in **v1.61**. HTML templates let you author in any tool that produces HTML — Google Docs is the flagship workflow — and render to PDF. Every merge tag that works in Word templates works identically: `{Name}`, loops, conditionals, aggregates, images, `{Today}`, `{Now}`, `{%Image:N}`, etc.

**Why:** Word templates lock authors into Microsoft Word. HTML templates let content teams design where they already work (Google Docs, Notion, ChatGPT, Apple Pages, any rich-text editor that emits HTML). Merge engine is the same; authoring surface is wide open.

#### 4.7.1 Authoring in Google Docs

1. Design the document in Google Docs. Normal formatting — headings, tables, images, colors, fonts.
2. Add merge tags as plain text: `{Name}`, `{Account.Name}`, `{Amount:currency}`, loops like `{#Contacts}...{/Contacts}`. Full syntax reference in [§6](#6-merge-tag-reference).
3. **File → Download → Web Page (.html, zipped)**. Google Docs produces a `.zip` with your HTML plus an `images/` folder.
4. In the Command Hub, create a template with **Type = HTML** (Output Format is forced to PDF). Upload the `.zip`.
5. DocGen unzips the file in your browser, saves each image as a ContentVersion linked to the template, and rewrites the HTML's `<img src="images/...">` references to `/sfc/servlet.shepherd/version/download/<cvId>` URLs that `Blob.toPdf` resolves natively.
6. Click **Save as New Version** — the template is live.

**Why unzip in the browser?** Salesforce's default File Upload Security blocks `.zip` uploads. DocGen's LWC reads zip bytes with a pure-JavaScript reader (native `DecompressionStream` + manual central-directory parse, zero dependencies), extracts just the HTML + images, and uploads those via Apex. The zip itself never becomes a ContentVersion, so the org setting never sees it. Bonus: unzipping client-side keeps Apex heap flat regardless of template size.

#### 4.7.2 Other authoring tools

- **Notion / Confluence** — export page as HTML
- **ChatGPT / Claude** — ask for HTML, save to a `.html` file
- **Apple Pages** — File → Export To → HTML
- **Hand-written HTML** — any text editor

For single-file uploads (`.html` / `.htm`), DocGen scans for inline `<img src="data:image/...">` URIs — common in Notion / ChatGPT / rich-text paste output — and extracts each to a ContentVersion with the `src` rewritten. `Blob.toPdf` can't decode data URIs directly, so this conversion is what makes those images render.

#### 4.7.3 Header / Footer fields

HTML templates gain two optional fields on a dedicated **Header / Footer** tab in the template edit modal:

- `Header_Html__c` — rendered in the top page margin of every PDF page
- `Footer_Html__c` — rendered in the bottom page margin of every PDF page

Each field has a WYSIWYG rich-text editor with a **Show HTML** / **Show Editor** toggle that flips to a monospace textarea showing the raw HTML (for image widths, inline styles, or any markup the rich editor can't expose). Every merge tag that works in the body works in these fields.

#### 4.7.4 Page numbers

Put `{PageNumber}` and `{TotalPages}` in the Header HTML or Footer HTML field. These compile to Flying Saucer CSS page counters inside the PDF's `@page` margin boxes — "Page 3 of 17" renders correctly on every page automatically.

Example footer HTML:

```html
<div style="text-align:center; font-size:9pt; color:#888;">Page {PageNumber} of {TotalPages}</div>
```

**Flying Saucer limitation:** page counters only resolve inside `@page` rules, not on DOM elements. When a header/footer contains counter tokens, DocGen renders that margin as plain text (no inline images or rich formatting). A header _without_ counters stays rich HTML via CSS running elements. Practical workaround: logo in the header (no counters), page count in the footer (counters only). Both fields can be populated simultaneously.

#### 4.7.5 Images

Three ways to get images into an HTML template:

1. **Google Docs zip** — images inserted in the Google Doc are bundled into the `.zip` and extracted automatically on upload.
2. **Inline data URIs** — `<img src="data:image/png;base64,...">` in the HTML (Notion / ChatGPT / pasted rich text) is scanned on upload; each is saved as its own ContentVersion and the `src` is rewritten.
3. **`{%Image:N}` / `{%FieldName}` merge tags** — same syntax as Word templates. Renders the Nth record-attached image, or a ContentVersion ID stored in a field. Emits `<img src="/sfc/...">` at merge time.

#### 4.7.6 Loops in tables

Loop auto-expansion works the same as Word. Either pattern produces one repeated row per record:

```html
<table>
    <thead>
        <tr>
            <th>Product</th>
            <th>Amount</th>
        </tr>
    </thead>
    <tbody>
        <!-- Pattern A: loop wraps the row -->
        {#OpportunityLineItems}
        <tr>
            <td>{Product2.Name}</td>
            <td>{TotalPrice:currency}</td>
        </tr>
        {/OpportunityLineItems}

        <!-- Pattern B: loop inside the row (DocGen expands to the <tr>) -->
        <tr>
            {#OpportunityLineItems}
            <td>{Product2.Name}</td>
            {/OpportunityLineItems}
        </tr>
    </tbody>
</table>
```

`<li>` list items auto-expand the same way.

#### 4.7.7 Bulk generation + Giant Query

HTML templates work with every generation path: single-record, bulk (individual PDFs or merged), and Giant Query (60K+ row child relationships via batched rendering). Same 12 MB Queueable heap envelope, same 50,000-row batch ceiling, same Flow action.

#### 4.7.8 Known limitations

- **Barcodes / QR codes** — `{*Field:qr}` etc. are Word-only today; in HTML templates the tag falls back to plain text. On the roadmap.
- **DOCX output** — not applicable. HTML templates are PDF-only.
- **Signatures** — `{@Signature_Role}` flows haven't been validated against HTML templates yet. Use Word templates if you need signatures today.
- **Page counters + rich header/footer content** — see §4.7.4. Flying Saucer flattens the margin to text when counters are present.

#### 4.7.9 Troubleshooting

- **"Your company doesn't support the following file types: .zip"** — DocGen's LWC extracts the zip client-side and never uploads the zip itself, so this org-level File Upload Security error shouldn't appear in normal use. If you see it, hard-refresh the page (Cmd+Shift+R / Ctrl+Shift+R) to clear any cached LWC bundle.
- **Images show as broken squares in the PDF** — `Blob.toPdf` can only fetch images via relative `/sfc/` URLs; it can't reach arbitrary HTTPS URLs (no session ID). Make sure the image source is in the zip, a data URI in the HTML, a `{%Image:N}` tag, or a `{%FieldName}` pointing at a real ContentVersion.
- **Page numbers appearing without a configured header/footer** — your template's source HTML already has `@page { @bottom-center { content: counter(page) ... } }`. Google Docs' Web Page export sometimes includes this automatically. Either remove the `@page` block from the HTML body before upload, or accept it (many users actually want page numbers).
- **Bulk merge PDF is blank or cut off** — fixed in v1.62.0. v1.61.0 had a bug concatenating multiple full-HTML snippets that caused Flying Saucer to abandon rendering after the first few records. Upgrade the package.
- **Merge tag shows up literally in the PDF (e.g. the text "{Name}")** — the tag didn't resolve. Check the field name is correct and in your Query Config, and that the WYSIWYG editor didn't HTML-encode the braces (DocGen decodes `&#123;` and `&#125;` automatically, but non-standard editors could still trip this).

---

## 5. Query builder

DocGen supports three query config formats. All three work — pick based on complexity.

### 5.1 V1 — Legacy flat string

Plain SOQL-like string. Single child relationship only.

```
Name, Industry, (SELECT FirstName, LastName FROM Contacts)
```

Detected when the config does NOT start with `{`.

### 5.2 V2 — JSON flat (junction support)

Adds junction-object support for many-to-many (e.g., Account ↔ Contact via AccountContactRelation).

```json
{
    "v": 2,
    "baseObject": "Opportunity",
    "baseFields": ["Name"],
    "parentFields": ["Account.Name"],
    "children": [{ "rel": "OpportunityLineItems", "fields": ["Name"] }],
    "junctions": [
        {
            "junctionRel": "OpportunityContactRoles",
            "targetObject": "Contact",
            "targetIdField": "ContactId",
            "targetFields": ["FirstName"]
        }
    ]
}
```

### 5.3 V3 — Query tree (multi-object, any depth)

Preferred. Tree of nodes — each node is one SOQL query, stitched into the parent's data map via `lookupField`.

```json
{
    "v": 3,
    "root": "Account",
    "nodes": [
        {
            "id": "n0",
            "object": "Account",
            "fields": ["Name"],
            "parentFields": ["Owner.Name"],
            "parentNode": null,
            "lookupField": null,
            "relationshipName": null
        },
        {
            "id": "n1",
            "object": "Contact",
            "fields": ["FirstName"],
            "parentFields": [],
            "parentNode": "n0",
            "lookupField": "AccountId",
            "relationshipName": "Contacts"
        },
        {
            "id": "n2",
            "object": "Opportunity",
            "fields": ["Name", "Amount"],
            "parentFields": [],
            "parentNode": "n0",
            "lookupField": "AccountId",
            "relationshipName": "Opportunities"
        },
        {
            "id": "n3",
            "object": "OpportunityLineItem",
            "fields": ["Quantity"],
            "parentFields": ["Product2.Name"],
            "parentNode": "n2",
            "lookupField": "OpportunityId",
            "relationshipName": "OpportunityLineItems"
        }
    ]
}
```

### 5.4 Using the visual builder

The Command Hub template wizard uses the **`docGenColumnBuilder`** LWC — tab-per-object layout with a tree visualization. Newer templates are V3 by default.

For direct JSON editing or V1 legacy configs, toggle **Manual Query** mode and the older `docGenQueryBuilder` appears.

### 5.5 Per-child filters, order by, limit

Each V3 child node supports:

- `fields`: scalar fields to SELECT
- `parentFields`: dotted lookup fields (e.g., `Product2.Name`)
- `where`: optional `WHERE` clause (sanitized for SOQL injection)
- `orderBy`: optional `ORDER BY` (sanitized)
- `limit`: optional `LIMIT`

Applies to both sync and giant-query paths.

### 5.4 Apex Data Provider (V4 — class-backed templates)

When the data you need to render isn't an SObject — external API responses, computed totals, cross-object aggregations, anything SOQL can't reach — implement the `portwoodglobal.DocGenDataProvider` interface in your org and bind a template to that class. The merge engine calls your class at render time and uses whatever Map you return.

#### Step 1 — write the provider class in your org

```apex
global with sharing class MyAccountBriefProvider implements portwoodglobal.DocGenDataProvider {
    global Map<String, Object> getData(Id recordId) {
        // recordId is whatever the caller passes at generate time (an Account
        // here, but it could be any SObject — or you can ignore it entirely
        // and assemble data from somewhere else).
        Account a = [
            SELECT Id, Name, Industry, AnnualRevenue, Owner.Name
            FROM Account
            WHERE Id = :recordId
            LIMIT 1
        ];

        // Compute / call out / aggregate — anything Apex can do.
        Decimal score = a.AnnualRevenue == null ? 0 : Math.min(100, Math.log(a.AnnualRevenue.doubleValue() + 1) * 6);

        // Pull child collections.
        List<Object> contacts = new List<Object>();
        for (Contact c : [
            SELECT FirstName, LastName, Email, Title
            FROM Contact
            WHERE AccountId = :recordId
        ]) {
            contacts.add(
                new Map<String, Object>{
                    'FullName' => c.FirstName +
                    ' ' +
                    c.LastName,
                    'Title' => c.Title,
                    'Email' => c.Email
                }
            );
        }

        // Return the Map<String, Object> the merge engine consumes.
        // The shape mirrors what every other DocGen path produces.
        return new Map<String, Object>{
            // Simple fields → {Name}, {Industry}, {AnnualRevenue}
            'Name' => a.Name,
            'Industry' => a.Industry,
            'AnnualRevenue' => a.AnnualRevenue,
            // Computed field — no SOQL equivalent → {CustomerScore}
            'CustomerScore' => score,
            // Parent lookup → {Owner.Name}
            'Owner' => new Map<String, Object>{ 'Name' => a.Owner.Name },
            // Child loop → {#Contacts}…{/Contacts} + {COUNT:Contacts}
            'Contacts' => new Map<String, Object>{ 'records' => contacts, 'totalSize' => contacts.size() }
        };
    }

    global List<String> getFieldNames() {
        // Powers the field-pill cheat sheet in the template wizard.
        // Use dot-notation for parent lookups; '#'/'/' wrap loop boundaries.
        return new List<String>{
            'Name',
            'Industry',
            'AnnualRevenue',
            'CustomerScore',
            'Owner.Name',
            '#Contacts',
            'Contacts.FullName',
            'Contacts.Title',
            'Contacts.Email',
            '/Contacts'
        };
    }
}
```

Two methods are required, both `global`. `getData` returns a `Map<String, Object>`; `getFieldNames` returns the list of merge tags shown in the wizard.

The interface lives in the managed package — reference it with the full namespace: `portwoodglobal.DocGenDataProvider`.

#### Step 2 — bind a template to the class

In the DocGen app → New Template:

1. **Step 1 — Data Source**: pick **Apex Class (Data Provider)** instead of Salesforce Record.
2. **Data Provider Class**: search for your class name (e.g., `MyAccountBriefProvider`). The picker filters to classes implementing `portwoodglobal.DocGenDataProvider`. Select yours.
3. The wizard validates the class, calls `getFieldNames()`, and displays the available merge tags.
4. **Step 2** lands directly on the connected-provider view. Compose your template body using the merge tags as you would for any other template.
5. **Step 3** — review and save.

Behind the scenes the template's `Query_Config__c` becomes `{"v":4,"provider":"MyAccountBriefProvider"}`. You can also flip an existing SOQL-backed template to v4 from the **Edit modal → Query Configuration → Use Apex data provider** link.

#### Step 3 — generate

Same as any template. The DocGen app's Generate button, the **Generate Document** Flow action, the Apex `DocGenService.generateDocument()` API — all of them detect the v4 binding automatically and call your class.

```apex
// From Apex — exactly the same call shape as a SOQL-backed template
Id contentDocId = portwoodglobal.DocGenService.generateDocument(templateId, accountId, null);
```

#### Common patterns

- **External callout**: do the callout in `getData`, parse the response, return the parsed Map. Bear in mind callouts subject to governor limits and DML-before-callout rules.
- **Cross-object aggregations**: query whatever you need, build aggregates in Apex, expose them as merge tags.
- **Custom Metadata-driven**: read Custom Metadata Type records to resolve the data shape dynamically.
- **Standalone (no recordId)**: ignore the `recordId` parameter and return data assembled from elsewhere. Useful for "render a report for the current user" templates.

If you don't want template-side binding at all — the data is already in a Flow variable or an Apex wrapper — use **runtime data injection** instead: the **Generate Document** Flow action accepts a `JSON Data` invocable variable, and `DocGenService.generatePdfBlobFromData(templateId, dataMap)` accepts an Apex Map directly. Same merge engine, same tags, no class to write.

---

## 6. Merge tag reference

Every tag DocGen recognizes. Tags are case-insensitive for functions (`{SUM:...}` == `{sum:...}` in processXml; the giant-query assembler's aggregate regex is case-sensitive — use uppercase to be safe).

### 6.1 Field merge

```
{FieldName}
{!FieldName}              Salesforce-style prefix — treated identically to {FieldName}
{Account.Name}            Parent lookup
{Owner.Profile.Name}      Multi-level lookup (any depth)
```

Null/missing fields render as empty string — no error, no placeholder.

### 6.2 Format specifiers

Append `:format` to a field tag.

#### Date formatting

```
{CloseDate:MM/dd/yyyy}          Java SimpleDateFormat pattern
{CloseDate:MMMM d, yyyy}        April 17, 2026
{CloseDate:date}                User's locale default
{CloseDate:date:de_DE}          17.04.2026 (German)
{CloseDate:date:ja_JP}          2026/04/17 (Japanese)
{CloseDate:date:en_GB}          17/04/2026 (British)
```

Locale defaults: `en_US` → `MM/dd/yyyy`; `en_GB/AU/NZ/IE/IN` → `dd/MM/yyyy`; `de_*`, `ru_*`, `pl_*`, `cs_*`, `hu_*`, `tr_*` → `dd.MM.yyyy`; `fr_*`, `es_*`, `it_*`, `pt_*` → `dd/MM/yyyy`; `nl_*` → `dd-MM-yyyy`; `ja_*` → `yyyy/MM/dd`; `zh_*` and Nordic → `yyyy-MM-dd`; `ko_*` → `yyyy. MM. dd`.

#### Currency formatting

```
{Amount:currency}               $500,000.00 (US default)
{Amount:currency:EUR}           €500,000.00
{Amount:currency:EUR:de_DE}     500.000,00 € (German formatting)
{Amount:currency:JPY}           ¥500000 (no decimals)
{Amount:currency:GBP}           £500,000.00
```

Supported currencies: USD, EUR, GBP, JPY, CNY, CHF, CAD, AUD, INR, KRW, BRL, MXN, SEK, NOK, DKK, PLN, CZK, HUF, TRY, ZAR, SGD, HKD, NZD, THB, MYR, PHP, IDR, TWD, ILS, RUB, NGN, KES, AED, SAR, COP, CLP, PEN, ARS, EGP, GHS.

Zero-decimal currencies (JPY, KRW, CLP, VND, HUF, ISK, TWD) format without decimals automatically.

#### Number formatting

```
{Quantity:number}               1,234 (US separators)
{Quantity:number:de_DE}         1.234 (German — dot-as-thousands)
{Quantity:number:fr_FR}         1 234 (French — space-as-thousands)
{Quantity:#,##0}                Custom pattern — always US separators
{Quantity:#,##0.00}             1,234.56
{Quantity:0,000}                Custom pattern with leading zeros
```

#### Percent formatting

```
{Rate:percent}                  15.5%
{Rate:percent:de_DE}            15,5 %
```

#### Checkbox formatting

```
{IsActive:checkbox}             [X] when true, [ ] when false
```

Uses ASCII box-drawing characters — works in any font.

### 6.3 Loops

Repeat a block for each child record.

```
{#Contacts}
  {FirstName} {LastName} — {Email}
{/Contacts}
```

**Container auto-expansion.** If the loop tags sit inside a table row or a bulleted/numbered list paragraph, DocGen detects it and repeats the **entire row/paragraph** instead of just the inner content. This is how invoice line-item tables work — drop `{#OpportunityLineItems}` and `{/OpportunityLineItems}` anywhere inside the row and every line item gets its own row automatically.

Nested loops are supported:

```
{#Opportunities}
  Opp: {Name}
  {#OpportunityLineItems}
    · {Product2.Name} × {Quantity}
  {/OpportunityLineItems}
{/Opportunities}
```

Empty loops (null or empty child list) render nothing — no error.

### 6.4 Conditionals

#### Boolean conditional

```
{#IsActive}
  Account is active.
{/IsActive}

{#IsActive}
  Active.
{:else}
  Inactive.
{/IsActive}
```

Truthy values: Boolean `true`, non-empty lists, any non-null non-false non-empty-string value.

#### Inverse conditional

Show when falsy. Opposite of `{#Field}`.

```
{^Closed__c}
  Still open.
{/Closed__c}

{^IsActive}
  Inactive.
{:else}
  Active.
{/IsActive}
```

#### IF comparison expressions

Supports `>`, `<`, `>=`, `<=`, `=` (or `==`), `!=`. Values can be field refs, quoted strings, or numbers.

```
{#IF Amount > 100000}
  Large deal — requires approval.
{/IF}

{#IF StageName = 'Closed Won'}
  Congratulations!
{:else}
  Keep pushing.
{/IF}

{#IF Priority != 'Low'}
  Escalate this case.
{/IF}
```

String comparisons are case-sensitive.

#### AND / OR / NOT (v1.72+)

Combine comparisons with boolean operators. Both word-form (`AND`, `OR`, `NOT` — case-insensitive) and symbolic form (`&&`, `||`, `!`) work. Parentheses control precedence.

```
{#IF Amount > 100000 AND Stage = 'Negotiation/Review'}
  Large deal in negotiation — escalate.
{/IF}

{#IF Stage = 'Closed Won' OR Stage = 'Closed - Pending Funding'}
  Pipeline closed.
{/IF}

{#IF NOT IsPrivate__c}
  Public record.
{/IF}
```

Default precedence (highest first): `NOT` → comparisons → `AND` → `OR`. Use parens to override:

```
{#IF (Amount > 100000 OR Strategic__c) AND IsClosed = false}
  Large or strategic, still open.
{/IF}
```

Arbitrarily long chains and grouping work:

```
{#IF (Region = 'NA') OR (Region = 'EU' AND Tier__c = 'Gold') OR (Strategic__c)}
  Eligible for premium support.
{/IF}
```

Quoted strings are opaque — `AND` / `OR` inside quotes is treated as part of the string, not as an operator.

#### Live example — Project Status Showcase

Repository ships a complete worked example exercising every IF feature. Three files:

- `dev-only-deploy/main/default/classes/ProjectStatusDemoProvider.cls` — a V4 Apex Data Provider that returns synthetic project data (no SOQL — works without test data setup).
- `scripts/template-project-status.html` — the full HTML template body. Demonstrates nested IF, AND/OR/NOT, parens, comparison, bare-boolean IF, empty-rel `totalSize=0`, inverse loops with `{:else}`.
- `scripts/demo-project-status-template.apex` — anonymous Apex script that creates the DocGen template, links the provider, and renders one PDF attached to a record.

To run it:

```bash
# 1. Deploy the provider class
sf project deploy start --source-dir dev-only-deploy/main/default/classes/ProjectStatusDemoProvider.cls --target-org <your-org>

# 2. Create the template + render a sample PDF
sf apex run --target-org <your-org> -f scripts/demo-project-status-template.apex
```

The script logs a Salesforce URL where the rendered PDF is attached. Open it to see all the IF features rendering against real data — including the empty-rel sections that correctly suppress.

#### Nested IF blocks

`{#IF}…{/IF}` blocks can be nested arbitrarily deep (v1.72+). Common pattern: an outer IF gates a whole section, inner IFs gate sub-sections within it.

```
{#IF Work_Tasks__r.totalSize != 0}
  WORK TASKS
  …table with Work Tasks loop…
  {#IF Work_Task_Step_Count__c != 0}
    …Steps table with Steps loop…
  {/IF}
{/IF}
```

`Rel.totalSize` returns 0 (not null) when the child relationship is empty (v1.72+), so `{#IF Rel.totalSize != 0}` is the canonical "render this section if there are rows" check.

### 6.5 Aggregates

Grand totals across a child relationship. Works in sync and giant-query paths.

```
{COUNT:OpportunityLineItems}                          1000
{COUNT:OpportunityLineItems:number}                   1,000
{SUM:OpportunityLineItems.TotalPrice}                 50000
{SUM:OpportunityLineItems.TotalPrice:currency}        $50,000.00
{SUM:Lines.Amount:currency:EUR:de_DE}                 50.000,00 €
{AVG:OrderItems.UnitPrice:currency}                   $127.50
{MIN:Quotes.Amount:currency}                          $100.00
{MAX:Deals.Amount:currency:GBP}                       £999,999.00
```

All five functions support any format suffix (`currency`, `number`, `percent`, custom patterns).

**Aggregate fields don't need to be rendered columns** — you can aggregate `UnitPrice` even if your loop table only shows `Product2.Name` and `Quantity`. The resolver validates field names against the child object's schema.

### 6.6 Images

**Option 1 — record-attached (easiest, v1.58+).** `{%Image:N}` renders the Nth oldest image attached to the current record. No ContentVersion ID field, no query-builder setup — drag a photo onto the record in Files and the tag picks it up. Filters to PNG/JPG/GIF/BMP/TIFF/SVG automatically (non-image attachments are skipped).

```
{%Image:1}                First image attached to the record, natural size
{%Image:1:200}            Max 200px in either dimension (preserves aspect)
{%Image:1:200x200}        Explicit 200px × 200px
{%Image:1:400x}           400px wide, auto height
{%Image:1:x150}           Auto width, 150px tall
{%Image:2}, {%Image:3}    Second, third, … attached image
```

Inside a `{#Relationship}` loop, `{%Image:N}` scopes to the iterating record's images — ideal for inspection reports, real estate listings, product catalogs. Out-of-range indexes render empty silently.

**Option 2 — image field (advanced).** When you need to pick a specific image that isn't the Nth attachment, store the ContentVersion ID (starts with `068`) in a text field and reference it:

```
{%ImageField}                   Embed an image from a rich text field or Files
{%LogoImage:200x100}            Specify max width × height in pixels
```

Handles multiple sources automatically:

- Rich text HTML `<img src="data:...">` — decoded and embedded
- Raw base64 strings (100+ chars) — decoded and embedded
- ContentVersion IDs (18-char, starts with `068`) — looked up and fetched
- Salesforce file URLs (`/sfc/servlet.shepherd/...`) — resolved to blob
- HTTPS URLs — embedded as URL references for PDF rendering

**PDF path (special behavior).** For ContentVersion IDs, the PDF pipeline skips blob loading entirely — it uses relative Salesforce URLs (`/sfc/servlet.shepherd/version/download/<cvId>`) and `Blob.toPdf()` fetches them natively via the VF rendering engine. This is what enables unlimited images in PDFs without heap pressure.

**Image size limits.** PDFs with attached images are limited to roughly **30MB of total image content** for reliable Save-to-Record. Above that threshold, the save operation will error out (Salesforce platform limits on the ContentVersion insert path). If you need to include more images than this threshold allows, use **Download** instead of Save-to-Record — downloads work at a higher ceiling because they don't go through the same save pipeline. A typical inspection report with 20–30 phone photos fits within the 30MB ceiling; 50+ high-resolution photos may need to be downloaded and attached manually.

### 6.7 Barcodes & QR codes

```
{*OrderNumber}                  Code 128 barcode (default)
{*TrackingId:code128}           Explicit type
{*SKU:code128:300x80}           300×80 px
{*ProductCode:qr}               QR code
{*URL:qr:200}                   200px QR code
```

Barcodes are rendered as images in PDF and DOCX output. Types supported: `code128`, `qr`.

### 6.8 Signatures

See [§9](#9-e-signatures-v3) for the full signature feature. Tag syntax:

```
{@Signature_Buyer}                  v2 — typed full signature (default)
{@Signature_Buyer:1:Full}           v3 — role=Buyer, order=1, type=Full signature
{@Signature_Buyer:1:Initials}       v3 — initials
{@Signature_Buyer:1:Date}           v3 — auto-filled signed date
{@Signature_Buyer:1:DatePick}       v3 — user-chosen date
{@Signature_Loan_Officer:2:Full}    Role names with underscores for multi-word
```

- **Role**: any string (Buyer, Seller, Witness, Loan_Officer, etc.). Underscores become spaces in the UI.
- **Order**: sequence number per-role (optional, defaults to 1). Used for sequential signing and multi-placement per signer.
- **Type**: `Full` | `Initials` | `Date` | `DatePick` (optional, defaults to `Full`).

Pre-signing, tags are preserved in the output (not replaced). Post-signing, they're stamped with the signer's typed name or signed date + a subtle "Electronically signed by X on DATE" verification line.

### 6.9 Rich text fields

When a field value contains HTML (`<p>`, `<div>`, `<br>`, `<b>`, `<i>`, `<u>`, `<strong>`, `<em>`, `<span>`, `<img>`, `<a>`), DocGen converts it to proper OOXML formatting preserving paragraphs, line breaks, bold/italic/underline, hyperlinks, and embedded images. Works in PDF and DOCX. PowerPoint strips HTML to plain text.

**Inline images in DOCX:** Lightning rich text inline images (the kind you paste/insert directly into a Rich Text Area field) now render in DOCX output via the **Document Generator** runner on a record page. The platform stores these as ContentReference records (ID prefix `0EM`) which can't be fetched by Apex callouts or browser code, so DocGen renders a single-image PDF server-side via `Blob.toPdf()` (which has internal resolver privileges), then extracts the image bytes client-side and embeds them in the DOCX ZIP. Zero session ID exposure, zero persistent storage, AppExchange-clean.

Limitations:

- The **Generate Sample** button in the template builder produces server-side ZIP only — rich text inline images appear as broken placeholders there. Test rendering via the runner instead.
- DOCX image quality: `Blob.toPdf()` may re-encode the source image as JPEG (visible quality difference vs. the original PNG). For pixel-perfect images, use the `{%Image:N}` merge tag with an attached File instead of inline rich text.
- Rotation of inline images is not preserved — they render at the original orientation.

### 6.10 Multiline text

Newlines in field values render as Word line breaks (`<w:br/>`) — no manual `<br/>` needed.

### 6.10.1 Watermarks / page backgrounds (PDF output)

Two ways to add a full-page watermark or background image to your PDF output:

**Option A: Upload via the template builder (recommended).** In the template editor, click the **Watermark / Background** tab and upload a pre-sized image. This bypasses Word's Watermark dialog entirely and gives you exact pixel-level control over the output.

**Option B: Insert via Word's Design → Watermark dialog.** Word's built-in watermark works too, with these constraints:

- **Scale must be set to 100%.** Word's "Auto", "50%", etc. scale settings are ignored by the PDF renderer — only the source image's pixel dimensions matter.
- **Washout must be OFF.** Leave the Washout checkbox unchecked. To get a faded look, pre-fade the image in an editor (~15–20% opacity over white) BEFORE inserting in Word.
- **No rotation.** Word's 315° diagonal default isn't honored. If you need a rotated watermark, save the image pre-rotated as a PNG.

Both options use the same rendering pipeline — `@page { background-image: url(...) }` extending edge-to-edge across the full page bleed.

**Pre-resize your watermark image to the page dimensions at 96 DPI** (the resolution Flying Saucer renders at — NOT the standard 72 DPI you might assume from PDF specs):

| Page size            | Pixels at 96 DPI  |
| -------------------- | ----------------- |
| Letter (8.5 × 11 in) | **816 × 1056 px** |
| A4 (8.27 × 11.69 in) | **794 × 1123 px** |
| Legal (8.5 × 14 in)  | **816 × 1344 px** |

Other limitations (apply to both options):

- **Text watermarks** ("DRAFT", "CONFIDENTIAL" via Word's text watermark option) are not supported. Use a picture watermark with the text rendered into a PNG.
- **DOCX output preserves whatever Word would render natively** — these constraints only apply to PDF output.

### 6.11 Built-in date/time tags

Two special merge tags resolve to the current date/time without needing a formula field. They accept the same format suffixes as any date field:

```
{Today}                         2026-04-20 (default ISO format)
{Today:MM/dd/yyyy}              04/20/2026
{Today:MMMM d, yyyy}            April 20, 2026
{Today:date}                    Running user's locale default
{Today:date:de_DE}              20.04.2026 (German)
{Now}                           2026-04-20 14:30:00 (current DateTime)
{Now:yyyy-MM-dd HH:mm}          2026-04-20 14:30
{Now:date:ja_JP}                2026/04/20 (Now formatted as Japanese date)
```

Case-insensitive for the keyword itself (`{today}` works). Works in sync, giant-query, bulk, and signature-stamped documents. All format suffixes from §6.2 apply.

### 6.11a Running user tags (Prepared by:)

`{RunningUser.X}` resolves against the **executing user's** record (whoever clicks Generate, runs the Flow, or owns the bulk job). No configuration — works on every template, every record, every output format.

```
Prepared by: {RunningUser.Name}
Email:       {RunningUser.Email}
Title:       {RunningUser.Title} · {RunningUser.Department}
Phone:       {RunningUser.Phone}
```

**Allowlist** — these are the only User fields exposed (other field names resolve to empty by design, so signed templates can't be edited to leak arbitrary User columns):

| Group     | Fields                                                              |
| --------- | ------------------------------------------------------------------- |
| Identity  | `Id`, `Name`, `FirstName`, `LastName`, `Email`, `Username`, `Alias` |
| Title/org | `Title`, `Department`, `CompanyName`, `EmployeeNumber`              |
| Contact   | `Phone`, `MobilePhone`, `Extension`, `Fax`                          |
| Address   | `Street`, `City`, `State`, `PostalCode`, `Country`                  |
| Locale    | `TimeZoneSidKey`, `LocaleSidKey`, `LanguageLocaleKey`               |

Case-insensitive for the namespace (`{runninguser.name}` works). Format suffixes from §6.2 apply: `{RunningUser.Phone}`, `{RunningUser.Name:!}` (no formatter needed for strings — most useful for date-typed extensions).

Works in sync generation, bulk runs, giant-query PDFs (headers/footers/title blocks), Flow-triggered docs, and HTML templates. The User row is queried **once per transaction** and cached, so a 60K-row PDF with `{RunningUser.Name}` in the header costs one extra SOQL total.

### 6.12 Checkmarks & symbols (PDF-safe)

Salesforce's PDF engine (Flying Saucer) only ships with four fonts (Helvetica, Times, Courier, Arial Unicode MS) and **cannot load Wingdings, Symbol, or any custom font**. Most "decorative" Word symbols (Wingdings checkboxes, custom dingbats) silently render as a blank box.

DocGen handles this for you in two ways:

1. **Word checkbox glyphs** (Insert → Symbol → Wingdings 0xFE / 0xA8, or Word content-control checkboxes) are auto-translated to their Unicode equivalents at PDF render time.
2. **Unicode symbols** typed directly in Word, Google Docs, Notion, or any HTML template are auto-wrapped in an Arial Unicode MS span so they render instead of dropping to tofu.

#### Copy-paste symbol palette

These all render reliably in PDF and DOCX. Highlight + copy any of them into your template:

**Checkboxes**
| Symbol | Name | Codepoint |
|---|---|---|
| ☐ | Empty checkbox | U+2610 |
| ☑ | Checked checkbox | U+2611 |
| ☒ | Crossed checkbox | U+2612 |

**Checks & crosses**
| Symbol | Name | Codepoint |
|---|---|---|
| ✓ | Check mark | U+2713 |
| ✔ | Heavy check mark | U+2714 |
| ✗ | Ballot X | U+2717 |
| ✘ | Heavy ballot X | U+2718 |

**Bullets & arrows**
| Symbol | Name | Codepoint |
|---|---|---|
| • | Bullet | U+2022 |
| ▪ | Black square | U+25AA |
| ▶ | Right-pointing triangle | U+25B6 |
| ► | Right-pointing pointer | U+25BA |
| → | Right arrow | U+2192 |
| ← | Left arrow | U+2190 |
| ↑ | Up arrow | U+2191 |
| ↓ | Down arrow | U+2193 |
| ⇒ | Heavy right arrow | U+21D2 |

**Stars & rating**
| Symbol | Name | Codepoint |
|---|---|---|
| ★ | Filled star | U+2605 |
| ☆ | Empty star | U+2606 |
| ♥ | Heart | U+2665 |
| ♦ | Diamond | U+2666 |

**Punctuation & misc**
| Symbol | Name | Codepoint |
|---|---|---|
| § | Section | U+00A7 |
| ¶ | Pilcrow | U+00B6 |
| † | Dagger | U+2020 |
| ‡ | Double dagger | U+2021 |
| … | Ellipsis | U+2026 |
| — | Em dash | U+2014 |
| – | En dash | U+2013 |
| © | Copyright | U+00A9 |
| ® | Registered | U+00AE |
| ™ | Trademark | U+2122 |
| ° | Degree | U+00B0 |
| ± | Plus-minus | U+00B1 |
| × | Multiplication | U+00D7 |
| ÷ | Division | U+00F7 |

#### Conditional checkbox pattern

Combine the checkbox glyphs with `{Field:checkbox}` or `{#IF}` to render dynamic checked/unchecked state from a Salesforce checkbox field:

```
Approved: {#IF IsApproved}☑{/IF}{#IFNOT IsApproved}☐{/IFNOT}
```

Or in tabular form for surveys / inspection forms:

| Item             | Status                                                                   |
| ---------------- | ------------------------------------------------------------------------ |
| Pre-flight check | {#IF Preflight_Complete**c}☑{/IF}{#IFNOT Preflight_Complete**c}☐{/IFNOT} |
| Safety briefing  | {#IF Safety_Done**c}☑{/IF}{#IFNOT Safety_Done**c}☐{/IFNOT}               |

#### What does NOT work

- **Wingdings / Webdings glyphs** other than checkboxes — Flying Saucer can't render them at all. DocGen translates the common checkbox/check codepoints (Wingdings F0A8, F0FE, F0FD, F0FB, F0FC, F0A2; Wingdings 2 F050–F053, F0A3, F0A4); anything else falls back to a neutral □ placeholder.
- **Emoji** (😀 🎉 etc.) — out of Arial Unicode MS coverage, render as tofu in PDF. Use the Unicode symbols above instead.
- **Custom decorative fonts** (script, brand, etc.) — generate as DOCX and open in Word. See [§13.2](#132-pdf-font-limitations).

### 6.13 Not implemented

- **Custom fonts in PDF** — the Salesforce PDF engine only supports Helvetica, Times, Courier, and Arial Unicode MS. `@font-face` is not supported. See [§13.2](#132-pdf-font-limitations). For custom fonts, generate as DOCX and open in Word — DOCX preserves template fonts.

---

## 7. Document generation

### 7.1 From a record page (single doc)

1. Open any record (Account, Opportunity, Case, etc.).
2. The **DocGen Runner** LWC appears (placed via Lightning App Builder or via the Command Hub's "Generate from Record" flow).
3. Pick a template.
4. Choose **Save to Record** (attaches as ContentDocumentLink) or **Download** (sent to your browser).
5. Optional: override output format if the template isn't locked (§4.4).
6. Click **Generate**.

### 7.2 What happens behind the scenes

- The runner **scouts child record counts** before generating.
- If the dataset is small enough for sync heap, it runs the full in-memory merge and returns a base64 blob (sub-second response for most templates).
- If the dataset is too big, it transparently switches to the giant-query batch path — see [§11](#11-heap-aware-routing-how-big-datasets-are-handled).
- For Word output, the client assembles the DOCX in-browser (bypasses the 4MB Aura payload limit).
- For PDF output, the server renders via `Blob.toPdf()` and returns the base64 (or async fragments for huge datasets).

### 7.3 Output format override

If the template isn't locked (`Lock_Output_Format__c = false`), users see a toggle to switch between native and PDF. Flow actions also support the override via `outputFormatOverride` parameter.

### 7.4 PDF merge (combine with existing PDFs)

When the template output is PDF and the record has PDF ContentVersions attached, the runner shows a "Merge PDFs" option. Selected PDFs are appended to the generated doc into one final PDF. Useful for adding signed contracts, terms attachments, or exhibits.

### 7.5 Document packets

A packet is multiple templates generated in one action and merged (or sent as a signature packet). Select multiple templates in the runner, hit Generate, and they're combined. For signature packets, see [§9.3](#93-packets).

---

## 8. Bulk generation

Mass-generate documents for many records in one batch.

### 8.1 Running a bulk job

1. Command Hub → **Bulk Generation** tab.
2. Pick a template.
3. Supply a **filter** — either:
    - A SOQL `WHERE` clause (e.g., `StageName = 'Closed Won' AND CloseDate = THIS_QUARTER`), or
    - A **saved query** you've built previously.
4. Choose:
    - **Combined PDF** — all records merged into one PDF (memory-efficient, compliance bundles).
    - **Individual files** — one PDF per record saved to that record.
    - **Both** — individual files + a combined bundle.
5. Adjust batch size if needed (1–200; default 10).
6. Submit.

### 8.2 Saved queries

Save a filter as a reusable `DocGen_Saved_Query__c`. Gives non-technical users a drop-down of pre-built filters without writing SOQL. Created and managed in the Bulk Generation UI.

### 8.3 Job history

Command Hub → **Job History** tab. Every bulk job shows:

- Status (Draft, Harvesting, Running, Completed, Failed)
- Record count + success/failure counts
- Generated PDFs (clickable links)
- Start + end time
- Error messages (for failed jobs)

### 8.4 Governor-limit analysis

Before a big bulk job submits, the runner calls `analyzeJob()` which estimates:

- SOQL query count
- DML operation count
- Peak heap usage

If any projection exceeds governor limits, the runner **blocks submission** and suggests mitigations (reduce batch size, split the filter into multiple jobs, switch to async).

### 8.5 Heap estimation for merge mode

Combined-PDF mode is memory-heavy. `estimateHeapUsage()` flags risky jobs ahead of time and suggests individual-files mode for large datasets.

---

## 9. E-signatures (v3)

Typed-name electronic signatures with PIN verification, audit trail, packets, and sequential signing.

### 9.1 Sending a signature request

1. Open any record.
2. The **DocGen Signature Sender** LWC appears on the page layout (if placed).
3. Pick one or more templates (packets).
4. Add signers:
    - **Select from Contacts** (picker shows any Contact on the record).
    - **Manual entry** (name + email + role, for people not yet in Salesforce).
5. For each signer, choose:
    - **Role** (Buyer, Seller, Witness — matches `{@Signature_Role}` in the template)
    - **Order** (1, 2, 3 — for sequential flows, controls send order)
6. Pick signing order: **Parallel** (all get emails simultaneously) or **Sequential** (each signer emailed only after the previous completes).
7. Click **Send**. Each signer receives a branded invitation email.

### 9.2 Signature tag syntax

See [§6.8](#68-signatures).

### 9.3 Packets (multi-template signing)

Send multiple templates in one session. The signer sees all documents and signs them all before completion. One email, one signing session, multiple PDFs generated and attached to the source record.

Useful for contract bundles (MSA + SOW + NDA), onboarding packets, etc.

### 9.4 Sequential vs parallel

- **Parallel**: everyone gets the invite right away. First to sign = first done. Good for lightweight approvals.
- **Sequential**: signers are emailed in order (by `Sort_Order__c`). Next signer is automatically emailed when the previous signs. Good for hierarchical approvals (employee → manager → VP → CFO).

### 9.5 PIN verification

Every signer receives a one-time email PIN before they can view the document. Protects against leaked signing URLs.

- Signer clicks link → lands on the verify-PIN page.
- They request a PIN → it's emailed from your Org-Wide Email Address.
- They enter the PIN → the signing page unlocks.

PIN hashes are stored (not the PIN itself). Timestamps on `PIN_Verified_At__c`.

### 9.6 In-person signing (PIN bypass)

Admins with `DocGen_Admin` permission set see a **Sign In Person** button on the signer row. When clicked:

- Browser confirm dialog asks them to attest they've verified the signer's identity in person.
- The signing URL opens in a new tab without requiring PIN.
- An audit record captures who bypassed, when, and the attestation.

### 9.7 Signing page experience

Guided, mobile-friendly. States: PIN verify → signing → review → submit.

- Full document HTML renders inline.
- A sticky action bar at the bottom shows progress (e.g., "2 of 5 signatures").
- An arrow points to the current placement.
- Tap/click a placement to sign: type full name, initials, or pick a date.
- Signer can leave and resume — progress persists (PIN re-verify required on return).
- Before final submit, a consent checkbox.
- Alternative: **Decline** with optional reason.

### 9.8 Reminders

Enable in signature settings. A scheduled job runs hourly and sends one reminder to any pending signer whose request is older than the configured threshold (`Signature_Reminder_Hours__c`, default 24h).

### 9.9 Audit trail

Every signature action creates an immutable `DocGen_Signature_Audit__c` record with:

- IP address (captured server-side)
- User agent
- Timestamp
- Consent hash
- PIN verification timestamp
- Action type (viewed, signed, declined, PIN_bypassed)

Audit records are read-only and appear on the signature request related list.

### 9.10 Signed PDF

Once all signers complete, the system:

1. Generates the final PDF with all signature tags stamped to "Electronically signed by X on DATE" text.
2. Appends a **verification page** listing each signer, their typed name, IP, timestamp, and a QR code linking to the verify page.
3. Saves the PDF to the source record as ContentDocumentLink.
4. Emails the request creator with a link to the signed doc.

### 9.11 Decline flow

Any signer can decline with an optional reason. On decline:

- The request is marked Declined.
- Pending signers are NOT emailed.
- The creator receives a decline notification with the reason.

### 9.12 Admin setup (one-time)

Before signatures work in production, complete the checklist in **Signature Settings**:

- ✅ Site URL configured (Experience Cloud Site or Salesforce Site)
- ✅ Active Salesforce Site exists
- ✅ Org-Wide Email Address configured + verified (green checkmark)
- ✅ Guest permission set assigned to the Site's guest user
- ✅ Signature VF pages deployed (`DocGenSignature`, `DocGenVerify`, `DocGenSign`)

The Settings panel shows each check as pass/fail with a fix link.

### 9.13 Email branding

Configure in Signature Settings:

- Brand color (hex) — used in email header/buttons
- Logo URL — displayed at top of emails
- Subject line and body (merge-tag aware — `{RecipientName}`, `{DocumentName}`, etc.)
- Company name, footer text
- Reply-to: automatically set to the request creator so signer replies route correctly

Branding applies to all signature emails (invitations, reminders, completion, decline).

---

## 10. Flow automation

Four Flow invocable actions. All available in Record-Triggered, Scheduled, Screen, and Autolaunched Flows.

### 10.1 DocGen — Generate Document

Generate a single document.

- **Inputs**: Template ID, Record ID, optional output format override, save-to-record flag, optional document title.
- **Outputs**: ContentDocumentId, ContentVersionId, error message, success flag.

Use when you want a doc generated as part of a workflow (e.g., "when Opportunity closes won, generate the signed-copy PDF and attach").

### 10.2 DocGen — Generate Bulk Documents

Launch a bulk job from a Flow.

- **Inputs**: Template ID, SOQL `WHERE` clause, job label, combined-PDF flag, individual-files flag, batch size.
- **Outputs**: Job ID, success flag.

Fire-and-forget — Flow continues immediately. Monitor via Job History tab.

### 10.3 DocGen — Send Signature Request

Create a signature request and email signers from a Flow.

- **Inputs**: Template ID, Related Record ID, Signers collection (Name, Email, Role, Contact ID), signing order (Parallel/Sequential), sendEmails flag.
- **Outputs**: Request ID, signer URLs (if `sendEmails=false`), success flag, error message, per-signer email status.

Supports the full v3 pipeline — guided signing, PIN, sequential ordering, branded emails.

### 10.4 DocGen — Giant Query Generator

Auto-detect giant-query mode from a Flow.

- **Inputs**: Template ID, Record ID, save-to-record flag.
- **Outputs**: ContentDocumentId (if sync), Job ID (if giant), `isGiantQuery` flag, success flag.

Use when the dataset size is unknown at Flow-design time (customer portal, screen Flow). The action scouts child counts and routes automatically.

---

## 10A. Apex API reference (programmatic access)

Call DocGen from your own Apex code, triggers, scheduled jobs, or Lightning components. All classes are global in the managed package namespace `portwoodglobal`, so subscribers prefix as `portwoodglobal.DocGenService` from their own code.

> Backwards compatibility: methods below are published as stable global entry points. New optional overloads may be added in future releases; existing signatures will not be removed without a major version bump and a deprecation notice.

### 10A.1 `DocGenService` — synchronous generation

Primary entry point from Apex. Use from triggers, scheduled Apex, or other service classes. All methods listed below are `global` in the managed namespace `portwoodglobal` — call them directly from subscriber Apex.

| Method                                                                                                                   | Returns                                | Purpose                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `generateDocument(Id templateId, Id recordId)`                                                                           | `Id` (ContentDocumentId)               | Generates, saves as File on the record, returns the new ContentDocumentId. Uses the template's default output format.                                                                                                 |
| `generateDocument(Id templateId, Id recordId, String outputFormatOverride)`                                              | `Id`                                   | Same, but `'PDF'` / `'Word'` / `'PowerPoint'` / `'HTML'` override. Throws on lock or incompatible combination.                                                                                                        |
| `generatePdfBlob(Id templateId, Id recordId)`                                                                            | `Map<String,Object>` (`blob`, `title`) | Renders a PDF in-memory without saving. Use when you want to email / attach elsewhere / POST to another system.                                                                                                       |
| `generateDocumentFromData(Id templateId, Id recordId, Map<String,Object> preloadedRecordData)`                           | `Id`                                   | Same as `generateDocument` but skips the per-record data query and uses the supplied map instead. For custom bulk loops or callers that already have the data in hand.                                                |
| `generatePdfBlobFromData(Id templateId, Map<String,Object> dataMap)`                                                     | `Map<String,Object>` (`blob`, `title`) | Renders a PDF straight from a caller-built data map — no SOQL, no recordId required. Lets you assemble external API responses, computed totals, or cross-object aggregations and merge them directly into a template. |
| `generateAndSaveFromData(Id templateId, Id attachmentRecordId, Map<String,Object> dataMap, String outputFormatOverride)` | `Id` (ContentDocumentId)               | Same as `generatePdfBlobFromData`, but also saves the file as a ContentVersion linked to `attachmentRecordId`. One-shot "build wrapper → render → attach".                                                            |

```apex
// Example: trigger PDF generation from an approval process
Id contentDocId = portwoodglobal.DocGenService.generateDocument(
    'a0zXXXXXXXXXXXXX',   // template ID
    accountId,            // record ID
    'PDF'                 // force PDF regardless of template setting
);

// Example: invoice generation referencing a Custom Label for the template Id
Id invoicePdf = portwoodglobal.DocGenService.generateDocument(
    System.Label.Invoice_Document_Template_Id,
    invRecordId
);

// Example: render a PDF in-memory and email it without ever creating a File
Map<String, Object> result = portwoodglobal.DocGenService.generatePdfBlob(templateId, oppId);
Blob pdf = (Blob) result.get('blob');
String title = (String) result.get('title');
// ...attach to a Messaging.SingleEmailMessage, POST to an external system, etc.
```

> **Catching exceptions.** All API methods throw `portwoodglobal.DocGenException` on validation failures (locked output format, missing template, PowerPoint→PDF, null `dataMap`, etc.). Subscriber code can catch by name: `catch (portwoodglobal.DocGenException e) { ... }`.

> **Sharing & FLS.** `DocGenService` runs `with sharing` — record-level access is enforced for the calling user. Field-level security is **not** explicitly checked inside the merge engine; if a user has row access but restricted FLS on a referenced field, that field's value will still appear in the rendered document. The `…FromData` overloads (`generatePdfBlobFromData`, `generateAndSaveFromData`) accept a caller-supplied data map and bypass DocGen's SOQL boundary entirely — the calling code is responsible for any FLS/CRUD enforcement on the values it places in the map. Treat these like any privileged service: gate them in your own code if you expose them to lower-privilege actors.

### 10A.2 `DocGenController` — LWC / Aura endpoints

All methods are `@AuraEnabled` so you can call them from your own LWC / Aura components. Use the full path from LWC:

```js
import generatePdf from '@salesforce/apex/portwoodglobal.DocGenController.generatePdf';
```

| Method                                                                                    | Returns                                                                        | Purpose                                                                                                                            |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `generatePdf(Id templateId, Id recordId, Boolean saveToRecord)`                           | `Map<String,Object>` (`base64`, `contentDocumentId`, `title`)                  | LWC-friendly PDF generation. `saveToRecord=true` attaches, `false` returns base64 only.                                            |
| `generatePdfAsync(Id templateId, Id recordId)`                                            | `Id` (AsyncApexJob Id)                                                         | Enqueues a Queueable for large PDFs (>~15 MB) that exceed the sync Aura timeout. Client polls.                                     |
| `generateDocumentGiantQuery(Id templateId, Id recordId)`                                  | `Map<String,Object>` (`isGiantQuery`, `jobId` OR `docId` + `contentVersionId`) | Auto-routes: small child counts go sync, >2000 rows spawn a batched Giant Query job.                                               |
| `saveTemplate(Map<String,Object> fields, Boolean createVersion, String contentVersionId)` | `void`                                                                         | Programmatic template save. Fields: Id, Name, Type**c, Base_Object_API**c, Query_Config**c, Header_Html**c, Footer_Html\_\_c, etc. |
| `getAllTemplates()`                                                                       | `List<DocGen_Template__c>`                                                     | Every template in the org (cacheable).                                                                                             |
| `getTemplatesForObject(String objectApiName)`                                             | `List<DocGen_Template__c>`                                                     | Audience-filtered list. Applies `Required_Permission_Sets__c` and static `Record_Filter__c`.                                       |
| `getTemplatesForObjectAndRecord(String objectApiName, String recordId)`                   | `List<DocGen_Template__c>`                                                     | Above plus per-record filter evaluation (`Specific_Record_Ids__c`, runtime `Record_Filter__c`).                                    |
| `saveHtmlTemplateImage(Id templateId, String fileName, String base64Content)`             | `Map<String,Object>` (`contentVersionId`, `url`)                               | Stores an inline image from an HTML template upload (v1.61+). Called from the LWC during client-side unzip.                        |
| `saveHtmlTemplateBody(Id templateId, String fileName, String htmlContent)`                | `Map<String,Object>` (`contentVersionId`, `contentDocumentId`)                 | Stores the rewritten HTML body after image extraction.                                                                             |

### 10A.3 `DocGenBulkController` — bulk generation

| Method                                                                                                                | Returns                                                 | Purpose                                                                                                                                                   |
| --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `submitJob(Id templateId, String condition, String jobLabel, Boolean mergePdf, Integer batchSize, Boolean mergeOnly)` | `Id` (DocGen_Job\_\_c Id)                               | Launches a bulk batch. `condition` is a SOQL WHERE on the template's base object. `mergePdf` produces a combined PDF; `mergeOnly` skips per-record files. |
| `analyzeJob(Id templateId, Integer recordCount, Integer batchSize, Boolean mergePdf)`                                 | `JobAnalysis` (SOQL / DML / heap / record-count checks) | Pre-flight estimator. Run before `submitJob` to warn about governor-limit risks.                                                                          |
| `getBulkTemplates()`                                                                                                  | `List<DocGen_Template__c>`                              | Audience-filtered template list for the bulk UI.                                                                                                          |
| `getJobStatus(Id jobId)`                                                                                              | `DocGen_Job__c`                                         | Current status, success count, error count, total records, merged-PDF CV Id.                                                                              |
| `validateFilter(String objectName, String condition)`                                                                 | `Integer` (matching count)                              | Validates a WHERE clause and returns the count. Use to preview scope.                                                                                     |

### 10A.4 Flow invocable actions (full signatures)

Usable from Flow Builder and from Apex via `Invocable.Action.createCustomAction(...)`:

| Action                               | Class                        | Input                                                                                                        | Output                                              |
| ------------------------------------ | ---------------------------- | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------- |
| Generate Document                    | `DocGenFlowAction`           | `templateId`, `recordId`, optional `outputFormatOverride`                                                    | `contentDocumentId`, `contentVersionId`, `fileName` |
| Generate Bulk Documents              | `DocGenBulkFlowAction`       | `templateId`, `whereClause`, `jobLabel`, `mergePdf`, `batchSize`, `mergeOnly`                                | `jobId`                                             |
| Generate Document (Auto Giant Query) | `DocGenGiantQueryFlowAction` | `templateId`, `recordId`                                                                                     | `contentDocumentId` (small) OR `jobId` (giant)      |
| Create Signature Request             | `DocGenSignatureFlowAction`  | `templateId`, `recordId`, `signers` (List<Signer>: `email`, `role`, `firstName`, `lastName`), `signingOrder` | `signatureRequestId`, `status`                      |

### 10A.5 `DocGenDataProvider` interface — custom data source

Implement this interface to supply custom data from external APIs, computed fields, or cross-object aggregations. Set the template's **Query Type** to **Apex Provider** and name your class.

```apex
global interface portwoodglobal.DocGenDataProvider {
    Map<String, Object> getData(Id recordId);
}
```

Return a map whose keys match the merge tags in your template. Nested maps → parent-lookup tags (`{Owner.Name}`), lists of maps → child loops (`{#Contacts}`).

Example:

```apex
global class MyCustomProvider implements portwoodglobal.DocGenDataProvider {
    global Map<String, Object> getData(Id recordId) {
        Account a = [SELECT Id, Name, Industry FROM Account WHERE Id = :recordId LIMIT 1];
        Map<String, Object> data = new Map<String, Object>{
            'Name' => a.Name,
            'Industry' => a.Industry,
            'ComputedScore' => calculateRiskScore(a) // your logic
        };
        // Add a child list for {#Contacts}...{/Contacts}
        List<Map<String, Object>> contacts = new List<Map<String, Object>>();
        for (Contact c : [SELECT FirstName, LastName FROM Contact WHERE AccountId = :recordId]) {
            contacts.add(new Map<String, Object>{ 'FirstName' => c.FirstName, 'LastName' => c.LastName });
        }
        data.put('Contacts', new Map<String, Object>{ 'records' => contacts });
        return data;
    }
}
```

### 10A.6 Namespace prefix

The package installs in the `portwoodglobal` namespace. From subscriber code:

- **Apex**: prefix — `portwoodglobal.DocGenService.generateDocument(...)`
- **LWC**: full import path — `@salesforce/apex/portwoodglobal.DocGenController.generatePdf`
- **Flow**: actions appear in the palette with the package namespace label
- **Merge tags in templates**: field API names as written on the base object — no namespace prefix in tags

---

## 11. Heap-aware routing (how big datasets are handled)

This is the routing logic that decides sync vs giant-query path. **Customers never need to think about it** — it just works.

### 11.1 The problem

Salesforce Apex has a hard heap limit: 6 MB synchronous, 12 MB asynchronous. A template rendering 400 line items with `Blob.toPdf()` can easily blow 6 MB because the PDF renderer holds the entire HTML DOM in memory. Pre-v1.54.0, we used a hardcoded 2000-record threshold to decide when to route to giant mode — which was wrong for PDF templates with fewer but heavier records.

### 11.2 The fix (v1.54.0+)

Three layers of defense:

1. **Pre-flight estimator** (v1.54.0 / refined in v1.55.0). Before generation, `scoutChildCounts` estimates peak heap per child relationship using output-format-aware math:
    - PDF: `baseBytes = 1 MB, bytesPerRow = 10 KB` (accounts for DOM parse overhead in `Blob.toPdf`)
    - DOCX/Excel/PowerPoint: `baseBytes = 200 KB, bytesPerRow = 2 KB`
    - If `baseBytes + (rowCount × bytesPerRow) > 60% × 6 MB`, route to giant mode upfront.
    - Result: PDF giant threshold ≈ 260 records, DOCX ≈ 1700 records. No hardcoded record count.

2. **In-flight safety net** (v1.54.0). During sync merge, `processXml` checks `Limits.getHeapSize()` every 50 loop iterations. If heap crosses 60% of the limit, it throws a typed `HeapPressureException` carrying the offending relationship name.

3. **Try-and-retry fallback** (v1.55.0). The controller wraps generation in a try-catch:
    - Catches `HeapPressureException` (from our in-flight check) → returns `{ heapPressure: true, giantRelationship: ... }` signal.
    - Catches `System.LimitException` from `Blob.toPdf()` itself (not ours to throw — this is the PDF engine running out of heap on its own) → same signal.
    - Runner LWC receives the signal → auto-retries via `_assembleGiantQueryPdf` → user sees a "large dataset — switching modes" toast.
    - If the server couldn't identify the giant relationship (PDF engine OOM), the runner picks the relationship with the highest child count from the scout cache.

### 11.3 What the user experiences

- Small dataset: sync generation, ~1-2 seconds, done.
- Medium dataset: pre-flight estimator routes to giant. User sees "Large dataset — switching to giant-query mode" toast, then progress bar, then PDF download/save.
- Large dataset: same as medium — estimator catches it upfront.
- Edge-case where estimator underestimates: sync starts, hits heap, controller signals, runner auto-retries in giant mode. Slightly slower (sync attempt wasted a few seconds) but customer never sees an error.

### 11.4 When does giant mode run?

- **Giant-query batch** (`DocGenGiantQueryBatch`, `Database.Batchable`): queries child records in pages of 50, renders each page's XML fragment, saves as ContentVersion.
- **Giant-query assembler** (`DocGenGiantQueryAssembler`, Queueable): loads all fragments, injects into the template wrapper, renders the final PDF via `Blob.toPdf()`.
- For DOCX output: fragments are shipped to the client, which assembles the final ZIP in-browser via `docGenZipWriter.js`.
- Peak server heap stays under 12 MB even for 50K+ rows.

### 11.5 Bypass

Admins can force giant mode via the Flow action `DocGenGiantQueryFlowAction` regardless of estimator output. Useful for screen flows where you always want async behavior.

---

## 12. Admin & settings

### 12.1 The Command Hub

The DocGen app has 2 tabs: **DocGen** (Command Hub) and **Job History**.

The Command Hub contains:

- Welcome banner (shown when you have < 10 templates; dismissible)
- Quick action cards (Templates, Bulk Generate, Generate from Record)
- Embedded template manager (`docGenAdmin`)
- Embedded bulk runner (`docGenBulkRunner`, collapsible)
- **Learning Center** (help docs — keep in sync with this file)

### 12.2 Signature Settings

Location: DocGen app → Command Hub → Signature Settings.

Covers:

- Site URL configuration
- OWA (Org-Wide Email Address) selection
- Email branding (color, logo, subject, footer)
- Reminder enable/disable + hour threshold
- Setup validation checklist (pass/fail for each prerequisite)

### 12.3 Blob.toPdf Release Update

Mandatory. Enable: Setup → Release Updates → "Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations". Without this, PDFs don't render relative Salesforce image URLs correctly.

### 12.4 Custom fields on DocGen objects

If you add custom fields to `DocGen_Template__c`, `DocGen_Signature_Request__c`, `DocGen_Signer__c`, or any other package object:

1. Add the field definition in the package.
2. Update all three permission sets (Admin, User, Guest if applicable).
3. Update the e2e-01 permissions script with an FLS assertion.

See [CLAUDE.md](./CLAUDE.md) for the full release-checklist rules.

---

## 13. Limits & known constraints

### 13.1 Apex heap limits

- **Sync (interactive runner)**: 6 MB heap.
- **Async (giant-query batch, queueable, bulk)**: 12 MB heap.
- DocGen auto-routes based on estimator + in-flight check + try-catch fallback (see [§11](#11-heap-aware-routing-how-big-datasets-are-handled)). Users never need to manually select a mode.

### 13.2 PDF font limitations

Salesforce's `Blob.toPdf()` uses Flying Saucer with only four built-in fonts:

- **Helvetica** (sans-serif) — default
- **Times** (serif)
- **Courier** (monospace)
- **Arial Unicode MS** — for CJK / multibyte character scripts

**Custom fonts cannot be loaded into the PDF engine.** CSS `@font-face` is not supported — not via data URIs, static resource URLs, or ContentVersion URLs. Exhaustively tested, confirmed impossible on the Salesforce platform.

Workaround: if you need custom fonts (branded typefaces, barcode fonts, decorative scripts), generate as **DOCX**. DOCX preserves whatever fonts are in the template — they render correctly in Word or any compatible viewer.

### 13.3 PowerPoint → PDF not supported

Salesforce's PDF engine can't render PPTX. PowerPoint templates can only output PPTX.

### 13.4 `{Today}` / `{Now}` (v1.56.0+)

Built-in tags for the current date and datetime. See [§6.11](#611-built-in-datetime-tags). Works with all the usual format suffixes (`:MM/dd/yyyy`, `:date`, `:date:de_DE`, etc.). For older versions (< v1.56.0), use a formula field on the base object with `TODAY()` / `NOW()` instead.

### 13.5 Aura 4 MB payload limit

Server-to-LWC responses are capped at 4 MB by the Aura framework. DocGen works around this via client-side DOCX assembly (the server returns merged XML parts + image maps, the browser assembles the ZIP). For PDF giant output > 4 MB, the assembler saves chunks and the client merges them client-side via `docGenPdfMerger.js`.

### 13.6 Lightning Web Security (LWS)

LWS blocks `fetch()` calls to `/sfc/servlet.shepherd/` URLs from LWCs (CORS redirect to `file.force.com`). All binary data must flow through Apex, not client-side `fetch`. DocGen handles this transparently.

### 13.7 Guest user constraints (signing page)

Guest users can't:

- Send email without an OWA (required)
- Call `Auth.SessionManagement.getCurrentSession()` (uncatchable session error)
- Query the User table
- Access ContentVersion via `/sfc/` URLs in the browser (blocked by browser auth)

DocGen's image proxy (`getImageBase64()`) returns base64 for guest users — signing-page JS replaces `<img src="/sfc/...">` with data URIs. Platform events bridge guest → system context for email sending.

### 13.8 Template & output size guidance

The Salesforce platform imposes hard heap and payload limits at every layer of
the DocGen pipeline. Here's exactly where each limit applies and what to
expect:

#### Template upload (the file you save)

- **Hard cap: 10 MB** for `.docx` and `.pptx` templates.
- The uploader rejects anything larger with a friendly toast pointing to the
  Compress Pictures workaround.
- Why: at save time DocGen unzips the template, extracts each image as its
  own ContentVersion, and caches the merged XML parts so PDF rendering at
  generation time can stay heap-light. That decompression runs in a
  Queueable's 12 MB async heap, and templates above ~10 MB plus
  ZipReader/per-entry blob overhead don't survive.
- HTML templates have no fixed cap because they're plain text + separate
  image files; the picker handles them differently.

#### Generation — PDF output

- **Practical output size: up to ~60 MB.**
- PDF generation runs entirely server-side. The merged HTML uses **relative
  image URLs** (the per-image ContentVersions DocGen pre-cached at upload
  time), so `Blob.toPdf()` fetches images natively — no image bytes pass
  through Apex heap.
- Save to Record for PDF: works for any output size that fits in the 12 MB
  Queueable heap (i.e., the template ceiling, not the output ceiling).

#### Generation — DOCX / XLSX output

- **Output ≤ 5 MB → Save to Record works automatically.** The browser
  assembles the file client-side and sends it back through Aura's inbound
  ~5 MB cap, which then becomes a single ContentVersion.
- **Output > 5 MB → 2-step save flow.**
    1. The file downloads to your computer immediately.
    2. A "Step 2 of 2 — drag the downloaded file here" panel appears below
       the Generate button with a `lightning-file-upload` widget bound to
       this record.
    3. Drag the just-downloaded file into that box. The platform's native
       uploader handles it (up to 2 GB) and attaches it to the record. One
       extra step, no Apex heap involved.
- We can't make this a single click for files this big. The Aura framework
  caps inbound payloads at ~5 MB, and there's no Apex API to write a 10 MB
  binary as a single ContentVersion without first base64-encoding the whole
  thing in heap (which then exceeds the 12 MB async heap). The 2-step flow is
  the cleanest path that uses platform-native machinery instead of fighting
  it.

#### Combine PDFs / Document Packet flows

- **Download only.** No Save to Record option.
- Both flows merge multiple existing PDFs in the browser. Saving the merged
  result back to the same record would round-trip through Aura's inbound cap
  AND duplicate content the user already has on the record — so we expose
  only the Download path.
- If users need the merged PDF on the record, they can drag the downloaded
  file into the record's Files list in the standard Lightning UI.

#### Runtime size signaling

- Save to Record selected, DOCX/XLSX template: a small hint under the Output
  Destination toggle reads
    > "Files under 5 MB save to the record automatically. Larger files will
    > download to your computer and a drag-and-drop upload box will appear so
    > you can attach the file in one extra step."
- PDF templates: no hint shown — the practical ceiling is the template size,
  not the output, so the warning isn't relevant.

#### TL;DR

| Scenario                                      | Limit         | UX                                 |
| --------------------------------------------- | ------------- | ---------------------------------- |
| Template upload                               | 10 MB hard    | Reject with Compress Pictures hint |
| PDF generate (download or save)               | ~60 MB output | One-click                          |
| DOCX/XLSX generate ≤ 5 MB                     | n/a           | One-click                          |
| DOCX/XLSX generate > 5 MB, **Download**       | n/a           | One-click                          |
| DOCX/XLSX generate > 5 MB, **Save to Record** | n/a           | 2-step (download + drag-to-attach) |
| Combine PDFs / Packet                         | Download only | One-click                          |

---

## 14. Troubleshooting

### 14.1 Generation fails with "Error generating document"

1. Check the browser console / Apex log for the actual error.
2. Common causes:
    - Query config references a field that doesn't exist or user has no FLS access.
    - Template has a malformed merge tag (unclosed `{` or missing `{/Rel}` for a loop).
    - `Blob.toPdf` Release Update not enabled (PDF only).

### 14.2 Heap size too large

Should never happen in v1.55.0+. If it does:

1. Check that the runner is v1.55.0+ (badge in the Command Hub header).
2. Upgrade subscribers to v1.55.0 if they're on an older version.
3. If confirmed on v1.55.0, file an issue — this is a bug; the estimator should have caught it or the fallback should have retried.

### 14.3 Merge tags render as literal text (e.g., `{Name}` appears in the output)

Usually:

- The field isn't in the query config — add it.
- The tag has a typo (`{name}` case-sensitive is fine for fields, but aggregate function names must be uppercase in some paths).
- The template isn't the active version — re-save.
- Rich-text or CSS `{...}` blocks in stored template HTML can look like unresolved tags but aren't — they're valid CSS.

### 14.4 Signature emails don't arrive

Check in this order:

1. **Setup → Deliverability** — must be "All Email" (default in scratch orgs is "System Email Only" — emails silently dropped).
2. **OWA settings** — "Allow All Profiles" checked, or the sender's profile is listed.
3. **OWA verification** — green checkmark next to the address.
4. **Daily email limit** — Setup → Company Information shows remaining sends.
5. **DNS/SPF** — your domain's TXT record must include `include:_spf.salesforce.com`.
6. **DMARC** — `p=none` is fine; `p=reject` will block.
7. **DKIM** — Setup → DKIM Keys, create + activate, add CNAME records to DNS.
8. **`Email_Status__c` field** on the signature request — shows the exact per-signer error.

### 14.5 PDF image is broken / doesn't render

For ContentVersion-backed images:

- The image URL must be **relative** (`/sfc/servlet.shepherd/version/download/<id>`) — never absolute (`https://...`). Absolute URLs fail silently.
- Template images must be pre-extracted at save time (happens automatically).
- If the template was saved pre-v1.40 or so, re-save it to trigger extraction.

For rich text images:

- Rich text HTML is pre-resolved to data URIs before merge.
- If the source field has broken images, output will show broken images.

### 14.6 Custom font doesn't render in PDF

See [§13.2](#132-pdf-font-limitations). Generate as DOCX for custom fonts.

### 14.7 Giant-query job stuck in "Harvesting"

- Check the **Job History** tab for error messages.
- Check **Setup → Apex Jobs** for the batch + queueable status.
- Most common cause: a field in the query config was deleted or renamed. Fix the query config and re-run.

### 14.8 Learning Center is out of date

Edit `force-app/main/default/lwc/docGenCommandHub/docGenCommandHub.html` to reflect changes made in this UserGuide.md. Deploy and push via the next release. **Don't edit Learning Center in isolation — this file is the source of truth.**

---

## Appendix — Source of truth checklist

Every time a feature ships or changes, touch these three places:

1. **This file** (`UserGuide.md`) — primary source.
2. **Learning Center** (`force-app/main/default/lwc/docGenCommandHub/docGenCommandHub.html`) — in-app documentation.
3. **Website** (https://portwood.dev) — public marketing + docs pages.

If the three drift, this file wins.
