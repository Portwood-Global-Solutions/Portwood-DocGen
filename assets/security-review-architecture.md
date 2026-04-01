# Portwood DocGen — Solution Architecture & Usage

## Architecture Overview

Portwood DocGen is a 100% native Salesforce application. All processing occurs within the Salesforce platform boundary. There are no external callouts, no middleware, no external data storage, and no authentication flows beyond the standard Salesforce user session.

```
┌─────────────────────────────────────────────────────────────┐
│                    SALESFORCE PLATFORM                       │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │   Lightning   │───▶│    Apex      │───▶│  Custom      │  │
│  │   Web         │    │  Controllers │    │  Objects     │  │
│  │   Components  │    │  & Services  │    │  (Templates, │  │
│  │   (UI Layer)  │    │  (Logic)     │    │   Jobs, etc) │  │
│  └──────────────┘    └──────┬───────┘    └──────────────┘  │
│         │                   │                               │
│  ┌──────▼──────┐    ┌──────▼───────┐                       │
│  │  Client-Side │    │ ContentVersion│                      │
│  │  JS (ZIP,    │    │ (Documents)   │                      │
│  │   PDF Merge) │    └───────────────┘                      │
│  └─────────────┘                                            │
│                                                             │
│  No external callouts. No data leaves this boundary.        │
└─────────────────────────────────────────────────────────────┘
```

## Information Flow

### Document Generation (Single Record)

1. User clicks "Generate" on a record page (LWC → Apex via @AuraEnabled)
2. `DocGenController.generateDocument()` receives the record ID and template ID
3. `DocGenDataRetriever` queries record data using SOQL with `WITH USER_MODE` — only fields the user has access to are returned
4. `DocGenService.mergeTemplate()` loads the template file from ContentVersion, parses XML, and replaces merge tags with record data
5. For PDF output: merged XML is converted to HTML by `DocGenHtmlRenderer`, then rendered to PDF via `Blob.toPdf()`
6. For DOCX output: merged XML parts are returned to the client; `docGenZipWriter.js` assembles the final DOCX in the browser
7. Generated document is saved as a new ContentVersion linked to the source record via ContentDocumentLink
8. All server-side processing stays within Apex heap/CPU limits — no async callouts, no external processing

### Giant Query (Large Documents)

For records with 2,000+ child records, the Giant Query engine automatically activates:

1. `DocGenGiantQueryBatch` harvests child records in cursor-paginated batches (500 rows/page)
2. For PDF: `DocGenGiantQueryAssembler` runs as a Queueable chain, progressively building HTML and rendering via `Blob.toPdf()`
3. For DOCX: child data is returned to the client in pages; `docGenZipWriter.js` assembles the final document
4. `DocGenGiantQueryStitchJob` handles post-processing and record linking
5. Supports 50,000+ child records per document

### Bulk Generation

1. User configures a bulk job via the Bulk Runner LWC (template, filter condition, batch size, output mode)
2. `DocGenBulkController.submitJob()` creates a `DocGen_Job__c` record and launches `DocGenBatch`
3. `DocGenBatch` processes records in configurable batch sizes (Database.Batchable)
4. Each batch execution generates documents using the same single-record pipeline
5. If merge mode is selected, `DocGenMergeJob` (Queueable) concatenates PDFs after all batches complete
6. Job status is tracked on the `DocGen_Job__c` record — the UI polls for updates
7. All batch processing runs under the initiating user's permissions

### Flow Integration

1. Admins add `DocGenFlowAction`, `DocGenBulkFlowAction`, or `DocGenGiantQueryFlowAction` as a Flow action
2. The Flow passes record ID and template ID as input variables
3. The invocable method calls the same generation pipeline used by the UI
4. Output (ContentVersion ID) is returned to the Flow for downstream use

### PDF Merging

1. User selects PDFs to merge via the DocGen Runner UI (drag-and-drop ordering)
2. Each PDF is fetched in its own Apex call (fresh 6 MB heap per call)
3. `docGenPdfMerger.js` merges PDFs client-side — parsing object graphs, renumbering references, flattening page trees
4. Five merge modes: Generate & Merge, Document Packets, Merge Only, Child Record PDFs, Bulk Merge
5. No server-side size limits on download; save to record up to ~3 MB

## Authentication

The app does not implement any custom authentication. All operations execute in the context of the running Salesforce user's session:

- **UI access:** Standard Lightning session managed by Salesforce
- **Data access:** All SOQL queries use `WITH USER_MODE` or `AccessLevel.USER_MODE`, enforcing the running user's CRUD and FLS permissions
- **Sharing:** All Apex classes declare `with sharing`, enforcing the running user's sharing rules
- **Permission sets:** Two permission sets (DocGen Admin, DocGen User) control object and field access. Users must be assigned one of these to use the app
- **No OAuth:** No OAuth flows, no access tokens, no refresh tokens, no connected apps
- **No API keys:** No external API keys stored or used anywhere in the package

## Encryption & Data Transfer

- **No external data transfer.** All data stays within the Salesforce platform. There are no HTTP callouts, no external API calls, no webhooks, and no external integrations of any kind.
- **Data at rest:** All data is stored in standard Salesforce objects (custom objects and ContentVersion) and inherits Salesforce's platform encryption (Shield Platform Encryption if enabled by the customer).
- **Data in transit:** All communication between the browser and Salesforce uses Salesforce's standard HTTPS/TLS encryption. The app does not implement any custom transport.
- **Template files:** Uploaded as ContentVersion records. Stored using Salesforce's standard file storage. Not transmitted externally.
- **Generated documents:** Saved as ContentVersion records. Subject to the same Salesforce sharing and security model as any other file.

## Data Touchpoints

| Data | Stored Where | Access Control | Notes |
|------|-------------|----------------|-------|
| Templates (DOCX/XLSX/PPTX files) | ContentVersion | Sharing rules + permission set | Uploaded by admins |
| Template metadata | DocGen_Template__c | Sharing rules + permission set | Object, fields, query config |
| Template versions | DocGen_Template_Version__c | Sharing rules + permission set | Version history |
| Generated documents | ContentVersion | Linked to source record via CDL | Inherits record sharing |
| Bulk job records | DocGen_Job__c | Sharing rules + permission set | Status, counts, errors |
| Saved queries | DocGen_Saved_Query__c | Sharing rules + permission set | Reusable filter conditions |
| App settings | DocGen_Settings__c | Hierarchy Custom Setting | Global/user-level config |
| Record data | Standard/custom objects | WITH USER_MODE enforced | Read-only, never modified |

**No customer data is stored in static resources or any location outside of standard Salesforce objects.**

## Subscriber Data

As a managed package publisher, Salesforce automatically provides limited subscriber information through the PackageSubscriber system object. This is a standard Salesforce platform feature for all managed packages. The data includes: org ID, org name, org type, install status, package version installed, and Salesforce instance name. This data is used to track install counts and provide support. It does not include any data from within the subscriber's org.

## Basic Usage Instructions

### Installation
1. Install the package: `sf package install --package 04tal000006PM3VAAW --wait 10 --target-org <your-org>`
2. Assign the **DocGen Admin** permission set to administrators
3. Assign the **DocGen User** permission set to end users
4. Enable the **Blob.toPdf() Release Update** in Setup (required for PDF generation)
5. Open the **DocGen** app from the App Launcher

### Creating a Template
1. Open the DocGen app → Command Hub → Templates section
2. Click **New Template**
3. Select the Salesforce object (e.g., Account, Opportunity)
4. Use the **Visual Query Builder** to select fields, parent lookups, and child relationships
5. Create a Word/Excel/PowerPoint file with merge tags: `{Name}`, `{Account.Name}`, `{#Contacts}{FirstName}{/Contacts}`
6. Upload the template file and save

### Generating a Document
1. Navigate to any record of the configured object type
2. Click the **DocGen** button in the action bar (or add the DocGen Runner component to the page layout)
3. Select a template
4. Click **Generate** — the document is created and attached to the record

### Bulk Generation
1. Open the DocGen app → Bulk Generation tab
2. Select a template and configure filter conditions
3. Choose output mode: Individual Files, Print-Ready Packet, or Combined + Individual
4. Click **Run** — documents are generated asynchronously with real-time status tracking

### Flow Integration
1. In Flow Builder, add an Action element
2. Search for "Generate Document" (DocGenFlowAction) or "Generate Giant Query Document" (DocGenGiantQueryFlowAction)
3. Set the Template ID and Record ID inputs
4. The output includes the generated ContentVersion ID for downstream use

## Community & Support

- **Slack:** https://portwoodglobalsolutions.com/DocGenCommunity — real-time help, feature requests, template sharing
- **GitHub Issues:** https://github.com/Portwood-Global-Solutions/Portwood-DocGen/issues — bug reports, tracked feature requests
- **Professional services:** Implementation, custom templates, and hands-on setup from Portwood Global Solutions
