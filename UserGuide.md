# Portwood DocGen — User Guide

Build polished Word and PDF documents from any Salesforce record. Author your template in Word, Google Docs, or any tool that exports HTML — drop in merge tags, and DocGen renders the rest. Everything runs natively inside your Salesforce org, with the same record sharing and field-level security your users already have.

PowerPoint and Excel templates are also supported as **alpha-stage** formats — see [§2](#2-what-docgen-does) for what to expect.

[Install in Production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rKBdAAM) · [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tal000006rKBdAAM) · [Support](https://portwood.dev/support)

---

## Table of contents

1. [Five-minute quick start](#1-five-minute-quick-start) — install → first PDF in five steps
2. [What DocGen does](#2-what-docgen-does)
3. [Install & post-install setup](#3-install--post-install-setup)
4. [Permission sets](#4-permission-sets)
5. [Templates](#5-templates)
6. [Query builder](#6-query-builder) — including [Apex Data Provider (V4)](#66-apex-data-provider-v4--class-backed-templates)
7. [Merge tag reference](#7-merge-tag-reference)
8. [Document generation](#8-document-generation)
9. [Bulk generation](#9-bulk-generation)
10. [E-signatures](#10-e-signatures-v3)
11. [Flow automation cookbook](#11-flow-automation-cookbook)
12. [Apex API reference](#12-apex-api-reference)
13. [Admin & settings](#13-admin--settings)
14. [Limits & known constraints](#14-limits--known-constraints)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Five-minute quick start

The fastest path from a fresh install to your first generated PDF. Every step takes < 1 minute.

### Step 1 — Install

Pick the install link above for your environment. Production for live orgs, Sandbox for sandboxes/scratch orgs. Click **Install for Admins Only**, accept third-party access, and wait for the green checkmark.

### Step 2 — Assign yourself the admin permission set

1. **Setup → Users → Permission Sets**
2. Click **DocGen Admin** → **Manage Assignments** → **Add Assignments**
3. Check the box next to your user → **Next** → **Assign**

You can now create templates and generate documents.

### Step 3 — Enable the PDF rendering release update

DocGen renders PDFs through Salesforce's Visualforce PDF service, which sits behind a release update. Without this, image-heavy PDFs fail silently.

1. **Setup → Release Updates**
2. Find **"Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations"**
3. Click **Get Started** → **Enable**

One-time. Applies to the whole org.

### Step 4 — Make your first template

1. **App Launcher → DocGen** (search "DocGen" if it's not pinned).
2. Click **+ New Template**.
3. Fill in:
    - **Name**: "My First Account Brief"
    - **Type**: Word
    - **Base Object**: Account
    - **Output Format**: PDF
4. Upload a `.docx` file. If you don't have one ready, paste this into a blank Word doc and save as `account-brief.docx`:

    ```
    Account Brief — {Name}

    Industry: {Industry}
    Annual Revenue: {AnnualRevenue:currency}
    Owner: {Owner.Name}

    Prepared by {RunningUser.Name} on {Today:MMMM d, yyyy}.
    ```

5. In the query builder, add `Industry`, `AnnualRevenue`, and `Owner.Name` to the selected fields.
6. Click **Save**.

### Step 5 — Generate

1. Open any Account record.
2. Click the **DocGen Runner** component on the page (placed there automatically by the install). If it's not visible, edit the page in Lightning App Builder and add the **DocGen Runner** component.
3. Pick **My First Account Brief** → click **Generate**.
4. The PDF appears in the record's **Files** related list, and downloads to your browser.

🎉 **You've now done the full lifecycle.** Real templates layer on richer content — child loops for tables (e.g., line items), images, conditional sections, e-signatures — all using the same merge-tag patterns. The rest of this guide covers each capability with worked examples.

> **Stuck?** The most common first-time issue is the runner not showing on the page layout. Edit the page → drag in the **DocGen Runner** component → save. If you see "Insufficient privileges," confirm Step 2 — the perm set assignment.

---

## 2. What DocGen does

A native Salesforce document generation engine that turns merge-tag templates into rendered files.

**Build with:**

- **Word (`.docx`)** templates — the most common authoring tool, fully supported.
- **HTML / Google Docs / Notion / ChatGPT** — any HTML source. Fully supported.
- **PowerPoint (`.pptx`)** for slide decks. _Alpha — see note below._
- **Excel (`.xlsx`)** for spreadsheets. _Alpha — see note below._

**Render to:**

- **PDF** — the universal share format (Word and HTML templates → PDF).
- **DOCX** — keep the native format if you'd rather edit in Word.
- **PPTX, XLSX** — output the native format. _Alpha — see note below._

> **PowerPoint and Excel are alpha-stage.** Core merge mechanics work — `{Field}`, parent lookups, basic loops, format suffixes. We're actively investing in these formats and the surface area will keep growing release over release. Until then, expect rough edges (PowerPoint→PDF isn't supported by the Salesforce platform, complex Excel formulas may not survive merging, advanced PPTX layouts are best-effort). For mission-critical decks and spreadsheets today, render to PDF or DOCX. Hit [portwood.dev/support](https://portwood.dev/support) with what you'd like prioritized.

**Pull data from:**

- Any Salesforce record — Account, Opportunity, Case, custom objects, anything
- Multi-level parent lookups (`{Account.Owner.Manager.Email}`)
- Child relationships at any depth (Opportunity → Line Items → Product → Pricebook)
- Many-to-many junctions
- External APIs / computed values via the [Apex Data Provider](#66-apex-data-provider-v4--class-backed-templates)

**Run from:**

- The record page (one-click Generate)
- The Bulk Generation tab (mass runs across thousands of records)
- Salesforce Flow (every major operation has an invocable action)
- Apex (call `DocGenService.generateDocument` from your own classes)
- Public Salesforce Sites (e-signatures with PIN verification, branded emails, audit trail)

**Built for the platform:**

- 100% native — no external services, no API callouts, no third-party data hand-offs
- Honors the running user's record sharing and field-level security automatically
- Handles small and huge datasets through the same Generate button — no async/sync toggle to think about
- Uses platform-native fonts in PDF; DOCX preserves whatever fonts your template already has

---

## 3. Install & post-install setup

### Install the package

```bash
sf package install --package 04tal000006rKBdAAM --wait 10 --target-org <your-org>
```

Or use the install links at the top of this guide. The install bundles the merge engine, all Lightning components, custom objects, permission sets, and the e-signature Visualforce pages.

### Post-install checklist

1. **Assign the `DocGen_Admin` permission set** to yourself — Setup → Users → Permission Sets → DocGen Admin → Manage Assignments → Add. See [§4](#4-permission-sets) for who needs what.
2. **Enable the Visualforce PDF Rendering Service release update** — Setup → Release Updates → "Use the Visualforce PDF Rendering Service for `Blob.toPdf()` Invocations" → Get Started → Enable. Mandatory for PDF output.
3. **Open the DocGen app** from the App Launcher. The Command Hub is your home base for managing templates, running bulk jobs, and configuring signatures.
4. **For e-signatures only** — run through the [signature admin setup](#1012-admin-setup-one-time) before sending the first signature request: Site URL, Org-Wide Email Address, guest permission set on the site's guest user.

---

## 4. Permission sets

Three permission sets ship with the package. Assign what each user needs.

| Permission set           | Who gets it                                           | What they can do                                                                                                                                                                   |
| ------------------------ | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DocGen_Admin`           | Template authors, system admins                       | Full CRUD on templates, query configs, signature objects, settings. Can create/edit/delete templates. Can "Sign In Person" bypass for signatures.                                  |
| `DocGen_User`            | End users generating docs                             | Read/edit templates (no delete). Generate single + bulk documents. Create signature requests. Can't modify templates or settings.                                                  |
| `DocGen_Guest_Signature` | The Salesforce Site guest user (for external signers) | Read access to signature requests, signers, and placements. Create access on audit records. Access to the signing pages. Required for external signers without a Salesforce login. |

### Assigning a permission set

1. **Setup → Users → Permission Sets**
2. Click the permission-set name (e.g., **DocGen Admin**)
3. Click **Manage Assignments → Add Assignments**
4. Check the box next to each user → **Next** → **Assign**

### Assigning DocGen_Guest_Signature to a Site guest user

Salesforce hides guest users behind several clicks. Full path:

1. **Setup → Sites** → click your e-signature site's name.
2. Click **Public Access Settings** — opens the site profile.
3. From the profile, click **View Users**, then select the e-signature site guest user.
4. On the user record, scroll to **Permission Set Assignments** and add **DocGen Guest Signature**.

### Adding custom fields to DocGen objects?

Update all three permission sets in the same change. Missed FLS grants silently break field access for the affected role (signer can't read it, generator can't populate it).

---

## 5. Templates

### 5.1 Creating a template

1. Open the DocGen app → **My Templates** tab → **+ New Template**.
2. Pick a template type: **Word** (`.docx`), **HTML** (`.html` / `.htm` / `.zip`), **PowerPoint** (`.pptx`, _alpha_), or **Excel** (`.xlsx`, _alpha_).
3. Pick a base object (Account, Opportunity, Case, any custom object). The picker ranks **standard objects first** — when an org has many namespaced custom objects whose names contain `Account`, `Opportunity`, etc. (common with payment processors and managed packages), the standard `Opportunity` always appears at the top of the list with a green **Standard** pill. Up to 50 matches render with a scroll.
4. Upload your file containing `{FieldName}` merge tags.
5. Configure the query — which fields, which child relationships (see [§6](#6-query-builder)).
6. Choose the default **output format** (PDF or the native format).
7. Save.

**Output formats by template type:**

- Word (`.docx`) template → output PDF **or** DOCX (pick one when you save the template)
- HTML (`.html` / `.htm` / `.zip`) template → output PDF only (see [§5.7](#57-html-templates-google-docs-notion-any-html-source))
- PowerPoint (`.pptx`) template → output PPTX only (PowerPoint→PDF is not supported by the Salesforce platform)
- Excel (`.xlsx`) template → output XLSX only

> **One template → one output format.** Templates render in whatever format
> they were saved with — there's no runtime "Output As" picker. To offer the
> same source as both PDF and DOCX, save the template twice (one as PDF, one
> as Native) and let users pick the one they want.

> **Max template file size: 10 MB.** The uploader rejects anything larger with
> a clear toast. Almost every 20+ MB template is uncompressed images — in
> Word, right-click any image → **Compress Pictures → Email (96 ppi)** or
> **Web (150 ppi)** — most templates drop to 1–2 MB with no visible quality
> loss. See [§14.8](#148-template--output-size-guidance) for the full
> breakdown of why this limit exists and what generation flows it affects.

### 5.2 Template versions

Each save creates a new `DocGen_Template_Version__c` record. Only the version marked **Active** (`Is_Active__c = true`) is used by the runner.

- Older versions are preserved for rollback.
- When you save a new version, DocGen pre-extracts images from the DOCX/PPTX ZIP and caches them as ContentVersions for fast PDF rendering at generation time.
- The XML parts are also pre-cached so PDF generation can skip ZIP decompression at runtime.

### 5.3 Test record

Set `Test_Record_Id__c` on the template to pin a specific record for preview/validation. Useful during template development — you can always preview against a known-good record without picking it each time.

### 5.4 Output format locking

Check `Lock_Output_Format__c` on the template to prevent users from overriding the output format at runtime. If locked, the runner's "output as PDF/Word" toggle is hidden and any attempt to override via the Flow action or API throws a validation error.

Use this for compliance-sensitive documents where only one format is allowed (e.g., signed contracts must always be PDF).

### 5.5 Template visibility (audience control)

Restrict which users see a template in their picker:

- **`Required_Permission_Sets__c`** (comma-separated permission-set names): only users with _all_ of these permission sets see the template.
- **`Specific_Record_Ids__c`** (comma-separated record IDs): only show the template for these specific records.
- **`Record_Filter__c`** (SOQL `WHERE` clause — for example, `StageName = 'Negotiation/Review' AND Amount > 10000`): dynamically show/hide based on the record's field values.

These can be combined. All three must match for the template to appear.

### 5.6 Template sharing

Template access uses **standard Salesforce sharing** — sharing rules, manual sharing, and role hierarchy. Field-level security is enforced on the merged data too. There's no custom sharing UI; if you want to restrict who _sees_ a template in the picker, use the visibility controls in §5.5 instead.

### 5.7 HTML templates (Google Docs, Notion, any HTML source)

HTML templates let you author in any tool that produces HTML — Google Docs is the flagship workflow — and render to PDF. Every merge tag that works in Word templates works identically: `{Name}`, loops, conditionals, aggregates, images, `{Today}`, `{Now}`, `{%Image:N}`, etc.

**Why use them?** Word templates lock authors into Microsoft Word. HTML templates let content teams design where they already work (Google Docs, Notion, ChatGPT, Apple Pages, any rich-text editor that emits HTML). Same merge engine, much wider authoring surface.

#### 5.7.1 Authoring in Google Docs

1. Design the document in Google Docs. Normal formatting — headings, tables, images, colors, fonts.
2. Add merge tags as plain text: `{Name}`, `{Account.Name}`, `{Amount:currency}`, loops like `{#Contacts}...{/Contacts}`. Full syntax reference in [§7](#7-merge-tag-reference).
3. **File → Download → Web Page (.html, zipped)**. Google Docs produces a `.zip` with your HTML plus an `images/` folder.
4. In the Command Hub, create a template with **Type = HTML** (Output Format is forced to PDF). Upload the `.zip`.
5. DocGen unzips the file in your browser, saves each image as a ContentVersion linked to the template, and rewrites the HTML's `<img src="images/...">` references to `/sfc/servlet.shepherd/version/download/<cvId>` URLs that `Blob.toPdf` resolves natively.
6. Click **Save as New Version** — the template is live.

**Why unzip in the browser?** Salesforce's default File Upload Security blocks `.zip` uploads. DocGen's LWC reads zip bytes with a pure-JavaScript reader (native `DecompressionStream` + manual central-directory parse, zero dependencies), extracts just the HTML + images, and uploads those via Apex. The zip itself never becomes a ContentVersion, so the org setting never sees it. Bonus: unzipping client-side keeps Apex heap flat regardless of template size.

#### 5.7.2 Other authoring tools

- **Notion / Confluence** — export page as HTML
- **ChatGPT / Claude** — ask for HTML, save to a `.html` file
- **Apple Pages** — File → Export To → HTML
- **Hand-written HTML** — any text editor

For single-file uploads (`.html` / `.htm`), DocGen scans for inline `<img src="data:image/...">` URIs — common in Notion / ChatGPT / rich-text paste output — and extracts each to a ContentVersion with the `src` rewritten. `Blob.toPdf` can't decode data URIs directly, so this conversion is what makes those images render.

#### 5.7.3 Header / Footer fields

HTML templates gain two optional fields on a dedicated **Header / Footer** tab in the template edit modal:

- `Header_Html__c` — rendered in the top page margin of every PDF page
- `Footer_Html__c` — rendered in the bottom page margin of every PDF page

Each field has a WYSIWYG rich-text editor with a **Show HTML** / **Show Editor** toggle that flips to a monospace textarea showing the raw HTML (for image widths, inline styles, or any markup the rich editor can't expose). Every merge tag that works in the body works in these fields.

#### 5.7.4 Page numbers

Put `{PageNumber}` and `{TotalPages}` in the Header HTML or Footer HTML field. These compile to Flying Saucer CSS page counters inside the PDF's `@page` margin boxes — "Page 3 of 17" renders correctly on every page automatically.

Example footer HTML:

```html
<div style="text-align:center; font-size:9pt; color:#888;">Page {PageNumber} of {TotalPages}</div>
```

**Flying Saucer limitation:** page counters only resolve inside `@page` rules, not on DOM elements. When a header/footer contains counter tokens, DocGen renders that margin as plain text (no inline images or rich formatting). A header _without_ counters stays rich HTML via CSS running elements. Practical workaround: logo in the header (no counters), page count in the footer (counters only). Both fields can be populated simultaneously.

#### 5.7.5 Images

Three ways to get images into an HTML template:

1. **Google Docs zip** — images inserted in the Google Doc are bundled into the `.zip` and extracted automatically on upload.
2. **Inline data URIs** — `<img src="data:image/png;base64,...">` in the HTML (Notion / ChatGPT / pasted rich text) is scanned on upload; each is saved as its own ContentVersion and the `src` is rewritten.
3. **`{%Image:N}` / `{%FieldName}` merge tags** — same syntax as Word templates. Renders the Nth record-attached image, or a ContentVersion ID stored in a field. Emits `<img src="/sfc/...">` at merge time.

#### 5.7.6 Loops in tables

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

#### 5.7.7 Bulk generation + Giant Query

HTML templates work with every generation path: single-record, bulk (individual PDFs or merged), and Giant Query (60K+ row child relationships via batched rendering). Same 12 MB Queueable heap envelope, same 50,000-row batch ceiling, same Flow action.

#### 5.7.8 Known limitations

- **Barcodes / QR codes** — `{*Field:qr}` etc. are Word-only today; in HTML templates the tag falls back to plain text. On the roadmap.
- **DOCX output** — not applicable. HTML templates are PDF-only.
- **Signatures** — `{@Signature_Role}` flows haven't been validated against HTML templates yet. Use Word templates if you need signatures today.
- **Page counters + rich header/footer content** — see §5.7.4. Flying Saucer flattens the margin to text when counters are present.

#### 5.7.9 Troubleshooting

- **"Your company doesn't support the following file types: .zip"** — DocGen's LWC extracts the zip client-side and never uploads the zip itself, so this org-level File Upload Security error shouldn't appear in normal use. If you see it, hard-refresh the page (Cmd+Shift+R / Ctrl+Shift+R) to clear any cached LWC bundle.
- **Images show as broken squares in the PDF** — `Blob.toPdf` can only fetch images via relative `/sfc/` URLs; it can't reach arbitrary HTTPS URLs (no session ID). Make sure the image source is in the zip, a data URI in the HTML, a `{%Image:N}` tag, or a `{%FieldName}` pointing at a real ContentVersion.
- **Page numbers appearing without a configured header/footer** — your template's source HTML already has `@page { @bottom-center { content: counter(page) ... } }`. Google Docs' Web Page export sometimes includes this automatically. Either remove the `@page` block from the HTML body before upload, or accept it (many users actually want page numbers).
- **Merge tag shows up literally in the PDF (e.g. the text "{Name}")** — the tag didn't resolve. Check the field name is correct and in your Query Config, and that the WYSIWYG editor didn't HTML-encode the braces (DocGen decodes `&#123;` and `&#125;` automatically, but non-standard editors could still trip this).

---

## 6. Query builder

DocGen supports three query config formats. All three work — pick based on complexity.

### 6.1 V1 — Legacy flat string

Plain SOQL-like string. Single child relationship only.

```
Name, Industry, (SELECT FirstName, LastName FROM Contacts)
```

Detected when the config does NOT start with `{`.

### 6.2 V2 — JSON flat (junction support)

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

### 6.3 V3 — Query tree (multi-object, any depth)

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

### 6.4 Using the visual builder

The Command Hub template wizard uses the **`docGenColumnBuilder`** LWC — tab-per-object layout with a tree visualization. Newer templates are V3 by default.

For direct JSON editing or V1 legacy configs, toggle **Manual Query** mode and the older `docGenQueryBuilder` appears.

### 6.5 Per-child filters, order by, limit

Each V3 child node supports:

- `fields`: scalar fields to SELECT
- `parentFields`: dotted lookup fields (e.g., `Product2.Name`)
- `where`: optional `WHERE` clause (sanitized for SOQL injection)
- `orderBy`: optional `ORDER BY` (sanitized)
- `limit`: optional `LIMIT`

Applies to both sync and giant-query paths.

### 6.6 Apex Data Provider (V4 — class-backed templates)

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

## 7. Merge tag reference

Every tag DocGen recognizes. Tags are case-insensitive for functions (`{SUM:...}` == `{sum:...}` in processXml; the giant-query assembler's aggregate regex is case-sensitive — use uppercase to be safe).

### 7.1 Field merge

```
{FieldName}
{!FieldName}              Salesforce-style prefix — treated identically to {FieldName}
{Account.Name}            Parent lookup
{Owner.Profile.Name}      Multi-level lookup (any depth)
```

Null/missing fields render as empty string — no error, no placeholder.

### 7.2 Format specifiers

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

### 7.3 Loops

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

### 7.4 Conditionals

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

#### AND / OR / NOT

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

`{#IF}…{/IF}` blocks can be nested arbitrarily deep. Common pattern: an outer IF gates a whole section, inner IFs gate sub-sections within it.

```
{#IF Work_Tasks__r.totalSize != 0}
  WORK TASKS
  …table with Work Tasks loop…
  {#IF Work_Task_Step_Count__c != 0}
    …Steps table with Steps loop…
  {/IF}
{/IF}
```

`Rel.totalSize` returns 0 (not null) when the child relationship is empty, so `{#IF Rel.totalSize != 0}` is the canonical "render this section if there are rows" check.

### 7.5 Aggregates

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

### 7.6 Images

**Option 1 — record-attached (easiest).** `{%Image:N}` renders the Nth oldest image attached to the current record. No ContentVersion ID field, no query-builder setup — drag a photo onto the record in Files and the tag picks it up. Filters to PNG/JPG/GIF/BMP/TIFF/SVG automatically (non-image attachments are skipped).

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

### 7.7 Barcodes & QR codes

```
{*OrderNumber}                  Code 128 barcode (default)
{*TrackingId:code128}           Explicit type
{*SKU:code128:300x80}           300×80 px
{*ProductCode:qr}               QR code
{*URL:qr:200}                   200px QR code
```

Barcodes are rendered as images in PDF and DOCX output. Types supported: `code128`, `qr`.

### 7.8 Signatures

See [§10](#10-e-signatures-v3) for the full signature feature. Tag syntax:

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

### 7.9 Rich text fields

When a field value contains HTML (`<p>`, `<div>`, `<br>`, `<b>`, `<i>`, `<u>`, `<strong>`, `<em>`, `<span>`, `<img>`, `<a>`), DocGen converts it to proper OOXML formatting preserving paragraphs, line breaks, bold/italic/underline, hyperlinks, and embedded images. Works in PDF and DOCX. PowerPoint strips HTML to plain text.

**Inline images in rich text** (the kind you paste directly into a Rich Text Area field) render in both PDF and DOCX output when you generate from the runner on a record page.

A few caveats:

- The **Generate Sample** button in the template builder doesn't render inline rich-text images — they show as broken placeholders. Test the real output via the runner instead.
- For pixel-perfect images, use the `{%Image:N}` tag with an attached File rather than inline rich text — DOCX image quality is slightly lossy when sourced from rich-text inline images.
- Inline-image rotation isn't preserved. Rotate the source before pasting.

Plain multiline (long text, textarea) fields work too — newlines in the field value render as proper line breaks in the output. No manual `<br>` needed.

### 7.10 Watermarks / page backgrounds (PDF output)

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

### 7.11 Built-in date/time tags

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

Case-insensitive for the keyword itself (`{today}` works). Works in sync, giant-query, bulk, and signature-stamped documents. All format suffixes from §7.2 apply.

### 7.12 Running user tags (Prepared by:)

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

Case-insensitive for the namespace (`{runninguser.name}` works). Format suffixes from §7.2 apply: `{RunningUser.Phone}`, `{RunningUser.Name:!}` (no formatter needed for strings — most useful for date-typed extensions).

Works in sync generation, bulk runs, giant-query PDFs (headers/footers/title blocks), Flow-triggered docs, and HTML templates. The User row is queried **once per transaction** and cached, so a 60K-row PDF with `{RunningUser.Name}` in the header costs one extra SOQL total.

### 7.13 Checkmarks & symbols (PDF-safe)

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
- **Custom decorative fonts** (script, brand, etc.) — generate as DOCX and open in Word. See [§14.2](#142-pdf-font-limitations).

### 7.14 Not implemented

- **Custom fonts in PDF** — the Salesforce PDF engine only supports Helvetica, Times, Courier, and Arial Unicode MS. `@font-face` is not supported. See [§14.2](#142-pdf-font-limitations). For custom fonts, generate as DOCX and open in Word — DOCX preserves template fonts.

---

## 8. Document generation

### 8.1 From a record page (single doc)

1. Open any record (Account, Opportunity, Case, etc.).
2. The **DocGen Runner** LWC appears (placed via Lightning App Builder or via the Command Hub's "Generate from Record" flow).
3. Pick a template.
4. Choose **Save to Record** (attaches as ContentDocumentLink) or **Download** (sent to your browser).
5. Optional: override output format if the template isn't locked (§5.4).
6. Click **Generate**.

### 8.2 What happens behind the scenes

- The runner **scouts child record counts** before generating.
- If the dataset is small enough for sync heap, it runs the full in-memory merge and returns a base64 blob (sub-second response for most templates).
- If the dataset is too big, it transparently switches to a giant-query batch path. The runner makes that call automatically — you never need to pick "sync vs async."
- For Word output, the client assembles the DOCX in-browser (bypasses the 4MB Aura payload limit).
- For PDF output, the server renders via `Blob.toPdf()` and returns the base64 (or async fragments for huge datasets).

### 8.3 Output format override

If the template isn't locked (`Lock_Output_Format__c = false`), users see a toggle to switch between native and PDF. Flow actions also support the override via `outputFormatOverride` parameter.

### 8.4 PDF merge (combine with existing PDFs)

When the template output is PDF and the record has PDF ContentVersions attached, the runner shows a "Merge PDFs" option. Selected PDFs are appended to the generated doc into one final PDF. Useful for adding signed contracts, terms attachments, or exhibits.

### 8.5 Document packets

A packet is multiple templates generated in one action and merged (or sent as a signature packet). Select multiple templates in the runner, hit Generate, and they're combined. For signature packets, see [§10.3](#103-packets-multi-template-signing).

---

## 9. Bulk generation

Mass-generate documents for many records in one batch.

### 9.1 Running a bulk job

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

### 9.2 Saved queries

Save a filter as a reusable `DocGen_Saved_Query__c`. Gives non-technical users a drop-down of pre-built filters without writing SOQL. Created and managed in the Bulk Generation UI.

### 9.3 Job history

Command Hub → **Job History** tab. Every bulk job shows:

- Status (Draft, Harvesting, Running, Completed, Failed)
- Record count + success/failure counts
- Generated PDFs (clickable links)
- Start + end time
- Error messages (for failed jobs)

### 9.4 Governor-limit analysis

Before a big bulk job submits, the runner calls `analyzeJob()` which estimates:

- SOQL query count
- DML operation count
- Peak heap usage

If any projection exceeds governor limits, the runner **blocks submission** and suggests mitigations (reduce batch size, split the filter into multiple jobs, switch to async).

### 9.5 Heap estimation for merge mode

Combined-PDF mode is memory-heavy. `estimateHeapUsage()` flags risky jobs ahead of time and suggests individual-files mode for large datasets.

---

## 10. E-signatures (v3)

Typed-name electronic signatures with PIN verification, audit trail, packets, and sequential signing.

### 10.1 Sending a signature request

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

### 10.2 Signature tag syntax

See [§7.8](#78-signatures).

### 10.3 Packets (multi-template signing)

Send multiple templates in one session. The signer sees all documents and signs them all before completion. One email, one signing session, **one combined signed PDF** with a **single verification certificate at the very end** of the packet.

Useful for contract bundles (MSA + SOW + NDA), onboarding packets, etc.

### 10.4 Sequential vs parallel

- **Parallel**: everyone gets the invite right away. First to sign = first done. Good for lightweight approvals.
- **Sequential**: signers are emailed in order (by `Sort_Order__c`). Next signer is automatically emailed when the previous signs. Good for hierarchical approvals (employee → manager → VP → CFO).

### 10.5 PIN verification

Every signer receives a one-time email PIN before they can view the document. Protects against leaked signing URLs.

- Signer clicks link → lands on the verify-PIN page.
- They request a PIN → it's emailed from your Org-Wide Email Address.
- They enter the PIN → the signing page unlocks.

PIN hashes are stored (not the PIN itself). Timestamps on `PIN_Verified_At__c`.

### 10.6 In-person signing (PIN bypass)

Admins with `DocGen_Admin` permission set see a **Sign In Person** button on the signer row. When clicked:

- Browser confirm dialog asks them to attest they've verified the signer's identity in person.
- The signing URL opens in a new tab without requiring PIN.
- An audit record captures who bypassed, when, and the attestation.

### 10.7 Signing page experience

Guided, mobile-friendly. States: PIN verify → signing → review → submit.

- Full document HTML renders inline.
- A sticky action bar at the bottom shows progress (e.g., "2 of 5 signatures").
- An arrow points to the current placement.
- Tap/click a placement to sign: type full name, initials, or pick a date.
- Signer can leave and resume — progress persists (PIN re-verify required on return).
- Before final submit, a consent checkbox.
- Alternative: **Decline** with optional reason.

### 10.8 Reminders

Enable in signature settings. A scheduled job runs hourly and sends one reminder to any pending signer whose request is older than the configured threshold (`Signature_Reminder_Hours__c`, default 24h).

### 10.9 Audit trail

Every signature action creates an immutable `DocGen_Signature_Audit__c` record with:

- IP address (captured server-side)
- User agent
- Timestamp
- Consent hash
- PIN verification timestamp
- Action type (viewed, signed, declined, PIN_bypassed)

Audit records are read-only and appear on the signature request related list.

### 10.10 Signed PDF

Once all signers complete, the system:

1. Generates the final PDF with all signature tags stamped to "Electronically signed by X on DATE" text.
2. Appends a **verification page** listing each signer, their typed name, IP, timestamp, and a QR code linking to the verify page.
3. Saves the PDF to the source record as ContentDocumentLink.
4. Emails the request creator with a link to the signed doc.

### 10.11 Decline flow

Any signer can decline with an optional reason. On decline:

- The request is marked Declined.
- Pending signers are NOT emailed.
- The creator receives a decline notification with the reason.

### 10.12 Admin setup (one-time)

Before signatures work in production, complete the checklist in **Signature Settings**:

- ✅ Site URL configured (Experience Cloud Site or Salesforce Site)
- ✅ Active Salesforce Site exists
- ✅ Org-Wide Email Address configured + verified (green checkmark)
- ✅ Guest permission set assigned to the Site's guest user
- ✅ Signature VF pages deployed (`DocGenSignature`, `DocGenVerify`, `DocGenSign`)

The Settings panel shows each check as pass/fail with a fix link.

#### Assigning the guest permission set

Salesforce hides the guest user behind a few clicks. The full path:

1. **Setup → Sites** — click the name of your e-signature site.
2. Click **Public Access Settings**. This opens the site profile.
3. From the profile, click **View Users**, then select the e-signature site guest user.
4. On the user record, scroll to **Permission Set Assignments** and add **DocGen Guest Signature**.

### 10.13 Email branding

Configure in Signature Settings:

- Brand color (hex) — used in email header/buttons
- Logo URL — displayed at top of emails
- Subject line and body (merge-tag aware — `{RecipientName}`, `{DocumentName}`, etc.)
- Company name, footer text
- Reply-to: automatically set to the request creator so signer replies route correctly

Branding applies to all signature emails (invitations, reminders, completion, decline).

---

## 11. Flow automation cookbook

DocGen ships four Flow invocable actions plus two helpers for custom signing UIs. Each one fits a different job-to-be-done. Below: which to pick, plus a worked recipe for each.

### 11.1 Picking the right action

| You want to…                                                                  | Use this action                                   |
| ----------------------------------------------------------------------------- | ------------------------------------------------- |
| Generate a single document for one record (most common)                       | **DocGen — Generate Document**                    |
| Auto-detect "is this dataset big enough to need async?" and route accordingly | **DocGen — Generate Document (Auto Giant Query)** |
| Run a template against many records in one batch                              | **DocGen — Generate Bulk Documents**              |
| Email a document for typed-name signature                                     | **DocGen — Send Signature Request**               |

The first is the workhorse. The other three exist because Flow can't always tell at design time whether a dataset will be small (sync) or huge (async), and bulk + signatures need different inputs.

### 11.2 Recipe — When an Opportunity closes won, generate a PDF and attach it

The bread-and-butter "trigger automation generates a doc" recipe.

**Trigger:** Record-Triggered Flow on Opportunity, **Updated only**, Entry condition: `IsClosed = TRUE AND IsWon = TRUE`.

**Step:** Add an **Action** element → search "DocGen" → pick **Generate Document**.

| Input          | Value                                                                                                                                  |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Template ID    | `{!$Label.OpportunityCloseSummaryTemplateId}` (store template Ids in Custom Labels so you can swap templates without editing the Flow) |
| Record ID      | `{!$Record.Id}`                                                                                                                        |
| Save to Record | `{!$GlobalConstant.True}`                                                                                                              |
| Output Format  | _(leave blank to use the template's default)_                                                                                          |
| Document Title | `{!$Record.Name} — Close Summary`                                                                                                      |

**Output:** `contentDocumentId` — the new file's Id, available downstream if you want to email it or pass it to another action.

**Result:** every closed-won Opportunity gets a generated PDF in its Files related list, automatically.

### 11.3 Recipe — Email a generated PDF without keeping a copy

**Use case:** generate a quote PDF and email it to the customer, but don't store a copy on the record.

1. **DocGen — Generate Document** with **Save to Record = True**. Capture `contentVersionId`.
2. **Send Email** action with `contentVersionId` wired into the attachment input.
3. _(Optional)_ **Delete Records** on the ContentDocument afterward to remove the file.

For a truly storage-less path, drop into Apex: `DocGenService.generatePdfBlob(templateId, recordId)` returns the Blob without persisting anything (see [§12.1](#121-docgenservice--synchronous-generation)).

### 11.4 Recipe — Mass-generate quarterly statements

**Trigger:** Scheduled Flow, runs first day of quarter at 6:00 AM.

**Step:** **DocGen — Generate Bulk Documents**.

| Input                      | Value                                                      |
| -------------------------- | ---------------------------------------------------------- |
| Template ID                | `{!$Label.QuarterlyStatementTemplateId}`                   |
| WHERE Condition            | `Active__c = TRUE AND Status__c = 'Current'`               |
| Job Label                  | `Q{!$Flow.CurrentQuarter} {!$Flow.CurrentYear} Statements` |
| Combined PDF Only          | `{!$GlobalConstant.False}`                                 |
| Also Keep Individual Files | `{!$GlobalConstant.True}`                                  |
| Batch Size                 | `25`                                                       |

**Output:** `jobId` — track in the **Job History** tab in the DocGen Command Hub.

**Result:** every eligible record gets its own statement PDF attached. The job runs async — Flow continues immediately. Failed records are logged on the job record with the specific error.

### 11.5 Recipe — Generate when dataset size is unpredictable

**Use case:** a customer-portal screen Flow generates an invoice. Most invoices have 5–20 line items, but a few customers have 5,000+. You can't know at design time which path is right.

**Step:** **DocGen — Generate Document (Auto Giant Query)**.

| Input          | Value                         |
| -------------- | ----------------------------- |
| Template ID    | `{!$Label.InvoiceTemplateId}` |
| Record ID      | `{!$Record.Id}`               |
| Save to Record | `{!$GlobalConstant.True}`     |

**Outputs:**

- `contentDocumentId` — populated when sync (small dataset)
- `jobId` — populated when async (large dataset)
- `isGiantQuery` — boolean so your Flow can branch

**Pattern:** add a Decision element after the action. If `isGiantQuery = true`, send the user to a "your invoice is being prepared" screen with a polling component that watches the job. If `false`, present the file immediately.

### 11.6 Recipe — Send a contract for signature on Opportunity approval

**Trigger:** Record-Triggered Flow on Opportunity. Entry: `Approval_Status__c → 'Approved'`.

**Step 1 — Get Records:** fetch the primary Contact for the Opportunity.

**Step 2 — Build the signers collection.** Add an **Assignment** element to construct an Apex-defined `DocGenSignatureFlowAction.Signer` record:

```
firstName = {!PrimaryContact.FirstName}
lastName  = {!PrimaryContact.LastName}
email     = {!PrimaryContact.Email}
role      = "Buyer"             // matches {@Signature_Buyer:1:Full} in the template
contactId = {!PrimaryContact.Id}
```

Add it to a `signers` collection variable.

**Step 3 — DocGen — Send Signature Request.**

| Input             | Value                                         |
| ----------------- | --------------------------------------------- |
| Template ID       | `{!$Label.MasterServicesAgreementTemplateId}` |
| Related Record ID | `{!$Record.Id}`                               |
| Signers           | `{!signers}`                                  |
| Signing Order     | `Sequential`                                  |

**Outputs:**

- `signatureRequestId` — the `DocGen_Signature_Request__c` Id; useful for status tracking on the parent Opportunity.
- `status` — `Sent` if everything went through.

**Result:** the signer receives a branded invitation email. They click → enter the PIN → sign → submit. The signed PDF lands on the Opportunity's Files related list with a verification page appended.

For multi-signer flows (parallel: legal + executive sign together; sequential: employee → manager → VP → CFO), add one Signer entry per person and pick **Parallel** or **Sequential** as the signing order.

### 11.7 Recipe — Pass pre-built JSON data instead of querying

The **Generate Document** action accepts an optional **JSON Data** input. When present, DocGen skips its own SOQL retrieval and uses the supplied JSON directly. Use cases:

- External API response that you've already fetched and parsed
- Cross-object data your query config can't express
- Computed values that aren't on any record

```text
{
  "Name": "Acme Corp",
  "Amount": 50000,
  "Items": {
    "records": [
      { "Product": "Widget", "Qty": 2, "Price": 100 },
      { "Product": "Gadget", "Qty": 1, "Price": 250 }
    ]
  }
}
```

Wire this to a Flow Text Variable populated upstream — typically by an Apex action that calls an external API and returns a JSON string. The merge tags in your template (`{Name}`, `{Amount:currency}`, `{#Items}…{/Items}`) resolve against the JSON instead of a Salesforce record.

### 11.8 Recipe — Custom signing UI (advanced)

Two helpers exist for orgs that want to build their own signing experience instead of using the bundled Visualforce pages — for example, an embedded signature pad inside an existing customer portal.

- **`DocGenSignatureValidator.validate`** — validates a secure token from the signing URL and returns signer name, document title, and a preview URL. Call this when your custom page first loads.
- **`DocGenSignatureFinalizer.finalize`** — accepts a base64-encoded PNG of the captured signature and writes the audit record. Call this when the user clicks "Sign and Submit".

A typical custom-screen Flow:

1. Pass `?token=…` into the screen Flow URL.
2. **Action: DocGenSignatureValidator.validate** with `{!token}` — receive name/title/preview.
3. Display the preview. Capture the signature in a Lightning component, base64-encode the PNG.
4. **Action: DocGenSignatureFinalizer.finalize** with `{!token}` and `{!base64Png}` — done.

Most customers don't need this. Use the bundled Visualforce signing pages unless you have a specific reason to embed.

### 11.9 Polling an async job from a screen Flow

Bulk and Giant Query actions return a `jobId`. To poll inside a screen Flow:

1. Add a **Loop** with a manual exit condition.
2. Inside the loop: **Get Records** on `DocGen_Job__c` where `Id = {!jobId}`.
3. Branch on `Status__c`: `Completed` → exit and show the file; `Failed` → exit and show the error; anything else → wait + loop.
4. Add a **Wait** element (5 seconds) between iterations.

Or call `DocGenBulkController.getJobStatus(jobId)` directly from Apex — see [§12.3](#123-docgenbulkcontroller--bulk-generation).

### 11.10 Error handling

Every action returns:

- `success` (Boolean) — `false` if generation failed
- `errorMessage` (String) — user-readable explanation when `success = false`

Always add a Decision element after the action that branches on `success`. The most common failures:

- **Template Id is wrong.** Store template Ids in Custom Labels (`Setup → Custom Labels`) and reference them from Flow as `{!$Label.YourLabelName}` — easier to swap and harder to typo.
- **Record Id is null.** A scheduled trigger fired but the criteria returned nothing. Add an entry condition.
- **Locked output format conflicts with the requested override.** Either unlock the template or stop overriding the format in the Flow.
- **Heap limit exceeded** on a sync action. Switch to **Generate Document (Auto Giant Query)** so the engine routes to async automatically.

---

## 12. Apex API reference

Call DocGen from your own Apex code, triggers, scheduled jobs, or Lightning components. All classes are global in the managed package namespace `portwoodglobal`, so subscribers prefix as `portwoodglobal.DocGenService` from their own code.

> Backwards compatibility: methods below are published as stable global entry points. New optional overloads may be added in future releases; existing signatures will not be removed without a major version bump and a deprecation notice.

### 12.1 `DocGenService` — synchronous generation

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

### 12.2 `DocGenController` — LWC / Aura endpoints

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
| `saveHtmlTemplateImage(Id templateId, String fileName, String base64Content)`             | `Map<String,Object>` (`contentVersionId`, `url`)                               | Stores an inline image from an HTML template upload. Called from the LWC during client-side unzip.                                 |
| `saveHtmlTemplateBody(Id templateId, String fileName, String htmlContent)`                | `Map<String,Object>` (`contentVersionId`, `contentDocumentId`)                 | Stores the rewritten HTML body after image extraction.                                                                             |

### 12.3 `DocGenBulkController` — bulk generation

| Method                                                                                                                | Returns                                                 | Purpose                                                                                                                                                   |
| --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `submitJob(Id templateId, String condition, String jobLabel, Boolean mergePdf, Integer batchSize, Boolean mergeOnly)` | `Id` (DocGen_Job\_\_c Id)                               | Launches a bulk batch. `condition` is a SOQL WHERE on the template's base object. `mergePdf` produces a combined PDF; `mergeOnly` skips per-record files. |
| `analyzeJob(Id templateId, Integer recordCount, Integer batchSize, Boolean mergePdf)`                                 | `JobAnalysis` (SOQL / DML / heap / record-count checks) | Pre-flight estimator. Run before `submitJob` to warn about governor-limit risks.                                                                          |
| `getBulkTemplates()`                                                                                                  | `List<DocGen_Template__c>`                              | Audience-filtered template list for the bulk UI.                                                                                                          |
| `getJobStatus(Id jobId)`                                                                                              | `DocGen_Job__c`                                         | Current status, success count, error count, total records, merged-PDF CV Id.                                                                              |
| `validateFilter(String objectName, String condition)`                                                                 | `Integer` (matching count)                              | Validates a WHERE clause and returns the count. Use to preview scope.                                                                                     |

### 12.4 Flow invocable actions (full signatures)

Usable from Flow Builder and from Apex via `Invocable.Action.createCustomAction(...)`:

| Action                               | Class                        | Input                                                                                                        | Output                                              |
| ------------------------------------ | ---------------------------- | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------- |
| Generate Document                    | `DocGenFlowAction`           | `templateId`, `recordId`, optional `outputFormatOverride`                                                    | `contentDocumentId`, `contentVersionId`, `fileName` |
| Generate Bulk Documents              | `DocGenBulkFlowAction`       | `templateId`, `whereClause`, `jobLabel`, `mergePdf`, `batchSize`, `mergeOnly`                                | `jobId`                                             |
| Generate Document (Auto Giant Query) | `DocGenGiantQueryFlowAction` | `templateId`, `recordId`                                                                                     | `contentDocumentId` (small) OR `jobId` (giant)      |
| Create Signature Request             | `DocGenSignatureFlowAction`  | `templateId`, `recordId`, `signers` (List<Signer>: `email`, `role`, `firstName`, `lastName`), `signingOrder` | `signatureRequestId`, `status`                      |

### 12.5 `DocGenDataProvider` interface — custom data source

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

### 12.6 Namespace prefix

The package installs in the `portwoodglobal` namespace. From subscriber code:

- **Apex**: prefix — `portwoodglobal.DocGenService.generateDocument(...)`
- **LWC**: full import path — `@salesforce/apex/portwoodglobal.DocGenController.generatePdf`
- **Flow**: actions appear in the palette with the package namespace label
- **Merge tags in templates**: field API names as written on the base object — no namespace prefix in tags

---

## 13. Admin & settings

### 13.1 The Command Hub

App Launcher → **DocGen**. The Command Hub is the single entry point for admins:

- **My Templates** — create, edit, version, share.
- **Bulk Generation** — mass-generate against a SOQL filter or saved query.
- **Signatures** — configure email branding, the public Site URL, the OWA sender.
- **Learning Center** — links straight to [portwood.dev/guide](https://portwood.dev/guide) so docs are always current.

### 13.2 Signature Settings

Location: DocGen app → Command Hub → Signature Settings.

Covers:

- Site URL configuration
- OWA (Org-Wide Email Address) selection
- Email branding (color, logo, subject, footer)
- Reminder enable/disable + hour threshold
- Setup validation checklist (pass/fail for each prerequisite)

### 13.3 Blob.toPdf Release Update

Mandatory. Enable: Setup → Release Updates → "Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations". Without this, PDFs don't render relative Salesforce image URLs correctly.

### 13.4 Custom fields on DocGen objects

You can extend `DocGen_Template__c`, `DocGen_Signature_Request__c`, `DocGen_Signer__c`, or any package object with your own custom fields. Just remember to grant FLS to whichever permission sets your users are on (Admin, User, or Guest).

---

## 14. Limits & known constraints

### 14.1 Apex heap limits

- **Sync (interactive runner)**: 6 MB heap.
- **Async (giant-query batch, queueable, bulk)**: 12 MB heap.
- DocGen auto-routes based on dataset size — you never need to manually pick "sync vs async."

### 14.2 PDF font limitations

Salesforce's `Blob.toPdf()` uses Flying Saucer with only four built-in fonts:

- **Helvetica** (sans-serif) — default
- **Times** (serif)
- **Courier** (monospace)
- **Arial Unicode MS** — for CJK / multibyte character scripts

**Custom fonts cannot be loaded into the PDF engine.** CSS `@font-face` is not supported — not via data URIs, static resource URLs, or ContentVersion URLs. Exhaustively tested, confirmed impossible on the Salesforce platform.

Workaround: if you need custom fonts (branded typefaces, barcode fonts, decorative scripts), generate as **DOCX**. DOCX preserves whatever fonts are in the template — they render correctly in Word or any compatible viewer.

### 14.3 PowerPoint → PDF not supported

Salesforce's PDF engine can't render PPTX. PowerPoint templates can only output PPTX.

### 14.4 `{Today}` / `{Now}`

Built-in tags for the current date and datetime. See [§7.11](#711-built-in-datetime-tags). Works with all the usual format suffixes (`:MM/dd/yyyy`, `:date`, `:date:de_DE`, etc.).

### 14.5 Browser payload limit

The Salesforce framework caps individual server-to-browser responses at 4 MB. DocGen works around this for you — large DOCX files are assembled in the browser, large PDFs are streamed in chunks and stitched client-side. You don't have to think about it.

### 14.6 Lightning Web Security (LWS)

If your org has LWS turned on, DocGen still works. We route binary data through Apex rather than direct browser fetches so file URLs never get blocked.

### 14.7 Guest user constraints (signing page)

The signing page runs as a guest user, which the platform restricts pretty heavily. The most visible consequence: **a verified Org-Wide Email Address is required** to send signing emails (Setup → Organization-Wide Email Addresses). Everything else (image rendering, audit logging, platform events) DocGen handles for you.

### 14.8 Template & output size guidance

| Scenario                                        | Limit         | UX                                     |
| ----------------------------------------------- | ------------- | -------------------------------------- |
| Template upload (DOCX / PPTX)                   | 10 MB         | Rejected with a "compress images" hint |
| Template upload (HTML)                          | n/a — text    | One-click                              |
| PDF generate (download or save)                 | ~60 MB output | One-click                              |
| DOCX / XLSX generate ≤ 5 MB                     | n/a           | One-click                              |
| DOCX / XLSX generate > 5 MB, **Download**       | n/a           | One-click                              |
| DOCX / XLSX generate > 5 MB, **Save to Record** | n/a           | 2-step (download, then drag-to-attach) |
| Combine PDFs / Packet                           | Download only | One-click                              |

**Why the 10 MB template cap?** The platform unzips and pre-caches every template at save time, and async heap is bounded at 12 MB. Templates over ~10 MB don't survive that step. Almost every 20 MB+ template is uncompressed images — in Word, right-click any image → **Compress Pictures → Email (96 ppi)** drops most templates to 1–2 MB with no visible quality loss.

**Why the 2-step flow for > 5 MB DOCX / XLSX?** The framework caps inbound browser-to-server payloads at 5 MB. For larger files, DocGen downloads the file to your computer, then shows a drag-to-attach uploader that uses the platform's native (2 GB) uploader. One extra click, no Apex heap involved.

---

## 15. Troubleshooting

### 15.1 Generation fails with "Error generating document"

1. Check the browser console / Apex log for the actual error.
2. Common causes:
    - Query config references a field that doesn't exist or user has no FLS access.
    - Template has a malformed merge tag (unclosed `{` or missing `{/Rel}` for a loop).
    - `Blob.toPdf` Release Update not enabled (PDF only).

### 15.2 Heap size too large

You should almost never see this — DocGen estimates dataset size up front and routes large jobs to the giant-query async path automatically. If you do hit it:

1. Confirm the package is current (Setup → Installed Packages → DocGen version).
2. If you're current, file an issue at portwood.dev/support with the template Id and record Id — this is a routing bug we want to know about.

### 15.3 Merge tags render as literal text (e.g., `{Name}` appears in the output)

Usually:

- The field isn't in the query config — add it.
- The tag has a typo (`{name}` case-sensitive is fine for fields, but aggregate function names must be uppercase in some paths).
- The template isn't the active version — re-save.
- Rich-text or CSS `{...}` blocks in stored template HTML can look like unresolved tags but aren't — they're valid CSS.

### 15.4 Signature emails don't arrive

Check in this order:

1. **Setup → Deliverability** — must be "All Email" (default in scratch orgs is "System Email Only" — emails silently dropped).
2. **OWA settings** — "Allow All Profiles" checked, or the sender's profile is listed.
3. **OWA verification** — green checkmark next to the address.
4. **Daily email limit** — Setup → Company Information shows remaining sends.
5. **DNS/SPF** — your domain's TXT record must include `include:_spf.salesforce.com`.
6. **DMARC** — `p=none` is fine; `p=reject` will block.
7. **DKIM** — Setup → DKIM Keys, create + activate, add CNAME records to DNS.
8. **`Email_Status__c` field** on the signature request — shows the exact per-signer error.

### 15.5 PDF image is broken / doesn't render

For ContentVersion-backed images:

- The image URL must be **relative** (`/sfc/servlet.shepherd/version/download/<id>`) — never absolute (`https://...`). Absolute URLs fail silently.
- Template images must be pre-extracted at save time (happens automatically).
- If the template is older, re-save it to trigger image extraction.

For rich text images:

- Rich text HTML is pre-resolved to data URIs before merge.
- If the source field has broken images, output will show broken images.

### 15.6 Custom font doesn't render in PDF

See [§14.2](#142-pdf-font-limitations). Generate as DOCX for custom fonts.

### 15.7 Giant-query job stuck in "Harvesting"

- Check the **Job History** tab for error messages.
- Check **Setup → Apex Jobs** for the batch + queueable status.
- Most common cause: a field in the query config was deleted or renamed. Fix the query config and re-run.

### 15.8 Still stuck?

The web guide at [portwood.dev/guide](https://portwood.dev/guide) is always current with the latest release. For implementation help or training, visit [portwood.dev/support](https://portwood.dev/support) — we'll walk you through it.
