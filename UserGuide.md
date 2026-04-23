# Portwood DocGen — User Guide

> **Source of truth.** This file is the canonical reference for every feature DocGen exposes to admins, template authors, end users, and Flow builders. Keep the in-app Learning Center, the public website, and any external docs in sync with this file — never the other way around.
>
> If you ship a new feature: add it here first, then propagate to the Learning Center LWC (`docGenCommandHub`) and the website.
> If you remove/deprecate a feature: mark it in this file, then remove from the Learning Center and website.

**Current release:** v1.58.0 · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006lpoPAAQ)

---

## Table of contents

1. [What DocGen does](#1-what-docgen-does)
2. [Install & first-run setup](#2-install--first-run-setup)
3. [Permission sets](#3-permission-sets)
4. [Templates](#4-templates)
5. [Query builder](#5-query-builder)
6. [Merge tag reference](#6-merge-tag-reference)
7. [Document generation](#7-document-generation)
8. [Bulk generation](#8-bulk-generation)
9. [E-signatures (v3)](#9-e-signatures-v3)
10. [Flow automation](#10-flow-automation)
11. [Heap-aware routing (how big datasets are handled)](#11-heap-aware-routing-how-big-datasets-are-handled)
12. [Admin & settings](#12-admin--settings)
13. [Limits & known constraints](#13-limits--known-constraints)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. What DocGen does

Portwood DocGen is a native Salesforce document generation engine. It merges Salesforce record data into Word and PowerPoint templates to produce PDF, DOCX, PPTX, or XLSX files. It runs 100% inside Salesforce — no external services, no API callouts, no session ID leakage.

**Capabilities at a glance**
- Word/PowerPoint/Excel templates with `{FieldName}` merge tags
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
sf package install --package 04tal000006lpoPAAQ --wait 10 --target-org <your-org>
```

Or: [Install in Production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006lpoPAAQ) · [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tal000006lpoPAAQ)

### Post-install checklist

1. **Assign the `DocGen_Admin` permission set** to yourself (see [§3](#3-permission-sets)).
2. **Enable the "Use the Visualforce PDF Rendering Service for `Blob.toPdf()` Invocations" Release Update** in Setup. This is mandatory for PDF output — image resolution and complex layouts require it.
3. **Open the DocGen app** from the App Launcher. You'll land on the Command Hub.
4. For e-signatures only: run through the [signature admin setup](#9-e-signatures-v3) — Site URL, Org-Wide Email Address, guest permission set.

---

## 3. Permission sets

Three permission sets ship with the package. Assign what each user needs.

| Permission set | Who gets it | What they can do |
|---|---|---|
| `DocGen_Admin` | Template authors, system admins | Full CRUD on templates, query configs, signature objects, settings. Can create/edit/delete templates. Can "Sign In Person" bypass for signatures. |
| `DocGen_User` | End users generating docs | Read/edit templates (no delete). Generate single + bulk documents. Create signature requests. Can't modify templates or settings. |
| `DocGen_Guest_Signature` | Salesforce Site guest user (for signing) | Read access to signature requests/signers/placements. Create access on audit records. Access to the signing VF pages. Required for external signers who don't have a Salesforce login. |

**Adding a custom field to DocGen objects? Update all three permission sets.** Missed FLS grants silently break field access for the affected role (signer can't read, generator can't populate, etc.). This is the #1 recurring bug class.

---

## 4. Templates

### 4.1 Creating a template

1. Open the DocGen app → **My Templates** tab → **+ New Template**.
2. Pick a template type: **Word** (`.docx`), **PowerPoint** (`.pptx`), or **Excel** (`.xlsx`).
3. Pick a base object (Account, Opportunity, Case, any custom object).
4. Upload your Word/PowerPoint/Excel file containing `{FieldName}` merge tags.
5. Configure the query — which fields, which child relationships (see [§5](#5-query-builder)).
6. Choose the default **output format** (PDF or the native format).
7. Save.

**Output formats by template type:**
- Word (`.docx`) template → output PDF or DOCX
- PowerPoint (`.pptx`) template → output PPTX only (PowerPoint→PDF is not supported by the Salesforce platform)
- Excel (`.xlsx`) template → output XLSX only

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

- **`Required_Permission_Sets__c`** (comma-separated permission-set names): only users with *all* of these permission sets see the template.
- **`Specific_Record_Ids__c`** (comma-separated record IDs): only show the template for these specific records.
- **`Record_Filter__c`** (SOQL `WHERE` clause — for example, `StageName = 'Negotiation/Review' AND Amount > 10000`): dynamically show/hide based on the record's field values.

These can be combined. All three must match for the template to appear.

### 4.6 Template sharing

Template access uses **standard Salesforce sharing** — sharing rules, manual sharing, and role hierarchy. Field-level security is enforced on the merged data too. There's no custom sharing UI; if you want to restrict who *sees* a template in the picker, use the visibility controls in §4.5 instead.

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
{"v":2,"baseObject":"Opportunity","baseFields":["Name"],
 "parentFields":["Account.Name"],
 "children":[{"rel":"OpportunityLineItems","fields":["Name"]}],
 "junctions":[{"junctionRel":"OpportunityContactRoles","targetObject":"Contact","targetIdField":"ContactId","targetFields":["FirstName"]}]}
```

### 5.3 V3 — Query tree (multi-object, any depth)

Preferred. Tree of nodes — each node is one SOQL query, stitched into the parent's data map via `lookupField`.

```json
{"v":3,"root":"Account","nodes":[
  {"id":"n0","object":"Account","fields":["Name"],"parentFields":["Owner.Name"],"parentNode":null,"lookupField":null,"relationshipName":null},
  {"id":"n1","object":"Contact","fields":["FirstName"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"},
  {"id":"n2","object":"Opportunity","fields":["Name","Amount"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Opportunities"},
  {"id":"n3","object":"OpportunityLineItem","fields":["Quantity"],"parentFields":["Product2.Name"],"parentNode":"n2","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems"}
]}
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

**Option 1 — record-attached (easiest, v1.58+).** `{%Image:N}` renders the Nth oldest image attached to the current record. No ContentVersion ID field, no query-builder setup — drag a photo onto the record in Files and the tag picks it up. Filters to PNG/JPG/GIF/SVG/WEBP automatically (non-image attachments are skipped).

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

### 6.10 Multiline text

Newlines in field values render as Word line breaks (`<w:br/>`) — no manual `<br/>` needed.

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

### 6.12 Not implemented

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
3. **Website** (https://portwoodglobalsolutions.com) — public marketing + docs pages.

If the three drift, this file wins.
