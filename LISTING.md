# AppExchange Listing — Portwood DocGen

Reference document for the Salesforce AppExchange listing. Copy/paste into the listing form.

---

## App Name

Portwood DocGen

## SEO Title

Portwood DocGen — Free Document Generation for Salesforce | PDF & Word

## Tagline

Free Document Generation for Salesforce

## Highlights (3 required, 250 char each)

**1.** Completely free — every feature, every user, no limits. No paid tiers, no per-user pricing, no upgrade prompts. Generate unlimited documents from unlimited templates across your entire org at zero cost.

**2.** 100% native Salesforce — your data never leaves your org. No external servers, no API callouts, no third-party dependencies. Respects sharing rules, CRUD, and field-level security. Works even when other vendors are down.

**3.** Point-and-click setup, no code required. Upload a Word template with merge tags, use the visual query builder to pick fields and related records, and generate polished PDFs and Word documents in seconds.

## Brief Description (300 char max)

Free document generation for Salesforce. Generate polished PDFs and Word documents from any record using Word templates. Related records, images, barcodes, QR codes, totals — 100% native, zero external dependencies, your data never leaves your org.

## Full Description (4,000 char max)

Portwood DocGen is a completely free, 100% native document generation app for Salesforce. Generate professional PDFs and Word documents from any standard or custom object using familiar Word templates with simple merge tags. No external servers, no callouts, no per-user fees — your data never leaves your Salesforce org.

**How it works:** Design your template in Microsoft Word. Add merge tags like {Name}, {Account.Name}, or {#Contacts}{FirstName}{/Contacts}. Upload the template, click Generate from any record page — done. DocGen handles the rest.

**What sets DocGen apart:**

- Every feature is free. No paid tiers, no per-user pricing, no feature gating. Every user in your org gets full access to everything — forever.

- 100% native to Salesforce. Zero external dependencies. No data leaves your org. No external API calls. Works even when third-party services are down. Respects all sharing rules, CRUD, and field-level security.

- Point-and-click setup. The visual query builder lets admins pick fields, parent lookups, and child record relationships without writing code. Works with any standard or custom object.

- Handles massive documents. The Giant Query engine generates documents from records with 50,000+ child records — invoices with thousands of line items, audit trails, transaction logs, price books. Auto-detects large datasets. Same template, same button.

**Key features:**

- PDF and Word (DOCX) output from Word templates
- Parent field lookups at any depth (Account.Owner.Manager.Name)
- Child record loops with nested relationships
- Many-to-many junction object support
- Images from Salesforce Files (ContentVersion)
- Code 128 barcodes and QR codes in PDFs
- Rich text field rendering with formatting preserved
- Aggregate functions: SUM, COUNT, AVG, MIN, MAX
- Date, currency, number, and percent formatting
- Conditional sections (show/hide based on field values)
- Page breaks in loops (one page per child record)
- Bulk generation from list views and reports
- Flow actions for automation (Record-Triggered, Screen, Subflow)
- PDF merger: combine, reorder, and merge PDFs from related records
- Document packets: generate multiple templates and merge into one PDF
- Template import/export for sharing across orgs
- Excel (XLSX) and PowerPoint (PPTX) template support
- Custom Apex data providers for advanced use cases
- Open source (Apache 2.0)

**Security:** Zero critical or high findings on Salesforce Code Analyzer using the Security Review rule set. CRUD/FLS enforced on all queries. No session IDs stored or transmitted. No external callouts. 615 Apex tests passing with 76% coverage.

**Community:** Join the DocGen Slack community for real-time help, feature requests, template sharing, and to help shape the roadmap. The community drives what gets built next.

**Getting started:** Install the package, assign the DocGen Admin permission set, enable the Blob.toPdf() Release Update, and open the DocGen app. Create your first template in under 5 minutes.

## Key Features (bullet list for sidebar)

- PDF and Word document generation
- Word template merge tags
- Visual point-and-click query builder
- Parent field lookups (unlimited depth)
- Child record loops and nesting
- Many-to-many junction support
- Images from Salesforce Files
- Barcodes (Code 128) and QR codes
- Rich text field rendering
- Aggregate functions (SUM, COUNT, AVG, MIN, MAX)
- Bulk generation from list views
- Flow actions for automation
- PDF merger and document packets
- 50,000+ child records per document
- Excel and PowerPoint templates
- Template import/export
- Open source (Apache 2.0)

## Categories

- Document Generation
- Document Management
- Productivity
- Admin Tools

## Search Keywords

document generation, PDF, Word, DOCX, merge tags, mail merge, template, invoice, contract, proposal, report, barcode, QR code, bulk generation, Flow action, native, free, open source, document automation

## Pricing

Free — all features, all users, no limits.

## Requirements

- Salesforce Enterprise, Unlimited, or Developer Edition
- Spring '26 Release Update: "Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations" (required for PDF output)
- Permission set: DocGen Admin or DocGen User

## Package Details

- Package type: Managed (2GP Unlocked)
- Namespace: portwoodglobal
- License: Apache 2.0
- Current version: 1.12.0

## Support

- Slack community: https://portwoodglobalsolutions.com/DocGenCommunity
- GitHub Issues: https://github.com/Portwood-Global-Solutions/Portwood-DocGen/issues
- Website: https://portwoodglobalsolutions.com
- Email: hello@portwoodglobalsolutions.com

## Terms & Conditions

- Terms of Service: https://portwoodglobalsolutions.com/DocGenTerms
- Privacy Policy: https://portwoodglobalsolutions.com/DocGenPrivacy

## Publisher

Portwood Global Solutions
https://portwoodglobalsolutions.com

## Links

- Website: https://portwoodglobalsolutions.com
- GitHub: https://github.com/Portwood-Global-Solutions/Portwood-DocGen
- Roadmap: https://portwoodglobalsolutions.com/DocGenRoadmap
- Community: https://portwoodglobalsolutions.com/DocGenCommunity
- Documentation: https://github.com/Portwood-Global-Solutions/Portwood-DocGen#readme
- Privacy Policy: https://portwoodglobalsolutions.com/DocGenPrivacy
- Terms of Service: https://portwoodglobalsolutions.com/DocGenTerms

## Screenshots (recommended 5-8)

1. **Command Hub** — Main app interface showing template management, quick actions, and help section
2. **Visual Query Builder** — Point-and-click field selection with tree visualization across related objects
3. **Template with Merge Tags** — Word document showing merge tag syntax in a real invoice template
4. **Generated PDF** — Finished PDF output showing merged data, images, and formatting
5. **Bulk Generation** — Bulk generate interface with real-time progress tracking
6. **PDF Merger** — Drag-and-drop PDF combining with multiple merge modes
7. **Flow Action** — DocGen Flow action configured in a Record-Triggered Flow
8. **Barcode & QR Output** — Generated PDF showing Code 128 barcodes and QR codes

## Demo Video Script (optional, 2-3 min)

1. Open the DocGen app — show the Command Hub (10s)
2. Create a new template — pick Account object, select fields with query builder (20s)
3. Show the Word template with merge tags (10s)
4. Upload and generate from an Account record — show PDF output (15s)
5. Show a complex template with child loops, images, and barcodes (15s)
6. Generate from a Flow — show the Flow action config and trigger (15s)
7. Bulk generate from a list view (10s)
8. Merge multiple PDFs with drag-and-drop (10s)
9. End card: "Free forever. Install today." with Slack community link (5s)
