# Changelog

## v1.46.0 — Signature consolidation, image helper, email status visibility

Promoted package: `04tal000006hQ73AAE` · [Install URL](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006hQ73AAE)
Upgrade-safety validator: passed. v1.43.x subscribers can install directly.

### Signature subsystem consolidation
- Removed dead `createTemplateSignatureRequestForFlow` from `DocGenSignatureSenderController` — Flow path was already routed through the LWC entry point. −73 LOC.
- Removed `Test.isRunningTest()` bypass in `DocGenSignatureEmailService`. The no-OWA branch is now properly tested with assertions on `Email_Status__c` content + zero email invocations.
- Removed v2 signature tag fallback in `stampSignaturesInXml` (+6 obsolete tests). Bare `{@Signature_Role}` tags continue to work via the v3 placement pipeline (`parseSignaturePlacements` already auto-promotes them to `:1:Full`).

### Merge engine
- Extracted `applyPendingImages` helper in `DocGenService` — collapses 3 duplicate call sites (full-ZIP merge, pre-decomposed merge, giant-query parts builder) into one helper.

### Email delivery visibility
- New `Email_Status__c` (LongTextArea, 1000 chars) on `DocGen_Signature_Request__c` surfaces on the page layout in a new "Email Delivery" section. Admins can see per-signer email send status, OWA configuration errors, deliverability problems, and daily-limit hits without leaving the record.
- Field added to `DocGen_Admin` (RW) and `DocGen_User` (R).

### Phase 4-lite integration tests (DocGenSignatureTests)
- `testCreateTemplateSignerRequest_integration` rewritten with real assertions on persisted state (signing order, role, sort order, token shape).
- `testGetTemplateSignaturePlacements_integration` rewritten to exercise the pre-decomposed XML fetch + bare-v2-tag → v3 auto-promotion.
- New `testFullSigningPipeline_integration` — placement records → `signPlacement` → stamping → asserts final XML contains signed values.

### Validation
- 928 / 928 Apex tests pass.
- 75% org-wide code coverage.
- Code analyzer: 0 High / 0 Critical.
- Upgrade-safety validator: passed.

### Deferred (with rationale documented in CONSOLIDATION_PLAN.md and project memory)
- V1/V2 query parser consolidation — high risk of silent wrong-data bugs without stronger integration test safety net first.
- Document Source mode methods (`createMultiSignerRequest`, `getRelatedDocuments`, `getDocumentSignatureRoles`) — kept as deprecated `global @AuraEnabled` for upgrade safety.
- E2E script overhaul to validate installed packages — they only run in source-deployed dev contexts; making them install-validators is a dedicated future project.

### Coming in v1.47.0
GitHub issue [#25](https://github.com/Portwood-Global-Solutions/Portwood-DocGen/issues/25) — design doc in `RUNNER_UX_PLAN.md`:
- Per-record templates (`Specific_Record_Ids__c` comma-separated Id list)
- Category browsing + explicit sort order
- Output format override at runtime
- Audience visibility via permission set lists

---

## v1.43.0 — Guided signatures, document packets, decline flow, sequential signing

Promoted package: `04tal000006hLTxAAM` (1.43.0-11)

Major signature subsystem overhaul. Full v3 tag syntax (`{@Signature_Role:Order:Type}`), guided per-placement signing UI, multi-template document packets, sequential signing order, decline flow with reason capture, reminder schedulable, OWA-based branded emails with per-signer reply-to, signature audit records, expanded setup validation checklist. See git history `v1.42.0..v1.43.0` for the full diff and `CLAUDE.md` for architectural details.

---

## v1.42.0 — Permission Audit & Signature Flow Action

### Signature Automation from Flow
- **New invocable: `DocGen: Create Signature Request`** — kick off a full DocGen signature request from any Flow. Pass a template Id, a related record Id, and parallel lists of signer names / emails / (optional) roles / (optional) contact Ids. The action returns the signature request Id and one signing URL per signer, in input order.
- **Flow-native notification** — the invocable defaults to `sendEmails = false` from Flow so your Flow owns the notification path (Send Email action, Slack, Teams, etc.). Set `Send Branded Emails = true` to use the package's built-in branded invitation emails instead. The LWC signature sender path is unchanged and still sends the branded emails by default.
- **End-to-end automation** — record-triggered Flow → create signature request → post signing links to your channel of choice → track completion via `signatureRequestId` on the record.

### Permission Set Audit
- **Added missing class grants** across `DocGen_Admin` and `DocGen_User`: `DocGenSignatureFlowAction`, `DocGenGiantQueryFlowAction`, `DocGenGiantQueryAssembler`, and `DocGenAuthenticatorController` (User). The two Flow invocables were previously un-granted, meaning Flows calling them would fail with `INSUFFICIENT_ACCESS`.
- **Added missing field grants** for all 8 `DocGen_Settings__c` fields to Admin (read/write) and User (read-only). Configuring signature email branding, OWA id, experience site URL, and company name no longer requires a system administrator.
- **Added missing audit field grants** to User: `Contact__c`, `Error_Message__c`, `Signer__c`. The signature audit related list on a record page now shows full context.
- **Added missing VF page grants** to both Admin and User: `DocGenGuide` and `DocGenVerify`. Non-sysadmin users can now reach the in-app admin guide and the document verification page.
- **Added missing tabs**: Signer tab for Admin; Signature Request tab for User.
- **Intentional blocks confirmed**: User remains explicitly denied on `DocGen_Signer__c.PIN_Hash__c`, `PIN_Attempts__c`, `PIN_Expires_At__c`, `Secure_Token__c`, and `DocGen_Signature_Request__c.Secure_Token__c`. Only Admin and the token-gated Guest path can read PIN hashes or signing tokens.

### Security Review Pack
- **Four reviewer-ready documents** in `docs/appexchange/` (each in `.md`, `.doc`, and `.pdf`):
  - `DocGen_Solution_Architecture_and_Usage` — security-focused architecture, threat model, sharing model, controls matrix.
  - `DocGen_Architecture_and_Usage` — feature/component inventory and usage walkthroughs.
  - `DocGen_False_Positive_Report` — per-category disposition of the 335 Checkmarx CxSAST findings (Scan `a0OKX000001JEZY2A4`).
  - `DocGen_Code_Analyzer_Report` — Salesforce Code Analyzer run: **0 High, 30 Moderate** (documented false positives).

### Testing
- `scripts/e2e-01-permissions.apex` expanded from 29 to **37 assertions** — covers the new class grants, page accesses, and `DocGenSignatureFlowAction` visibility on both Admin and User permsets.
- Full e2e suite (8 scripts) passes clean: **138/0 PASS**.
- `RunLocalTests` clean (850+ tests, ≥ 75% coverage).
- Code Analyzer Security + AppExchange: **0 High**, same 30 Moderate documented false positives as v1.41.0.

## v1.26.0 — Giant Query Sort, Visual Builder & Image Fix

### Giant Query Sort Order
- **Pre-query sort** — ORDER BY configured on a child relationship now sorts globally across all batch fragments, not just within each batch of 50. Works for both PDF (server-side batch) and DOCX (client-side assembly).
- **V1 flat config support** — flat SOQL query strings (from the visual builder or manual entry) now trigger the Giant Query async path when child records exceed 2,000. Previously only V3 JSON configs were supported.

### PDF Table Continuity
- Single `Blob.toPdf()` call with internal table breaks every 2,000 rows — no visible gap between sections.
- **Column widths preserved** from the template's column definitions across all table break points.

### Visual Query Builder
- **New tree-based builder** — select fields via compact pills, browse parent lookups and child relationships through searchable dropdown pickers. Same UI pattern at every depth level.
- Labels shown prominently with API names in grey below. Global search bar filters across all levels.
- WHERE, ORDER BY, and LIMIT inputs on each child relationship.
- Available on both the Create wizard and Edit modal via "Try our visual builder" toggle.

### Template Images
- Template-embedded images (logos, headers) now appear in Giant Query PDFs. Fixed a timing issue where image ContentVersions were not committed before the pre-baked HTML was generated.

### Mobile
- Runner detects mobile devices and shows only "Save to Record" — download is not available on mobile.

### Quality
- 630 Apex tests, 0 failures, 75.2% code coverage
- 0 security violations in Salesforce Code Analyzer

---

## v1.23.0 — Cover Pages, Security & Simplified Sharing

Cover pages now render clean — no unwanted headers or footers on your title page. Section breaks in your Word template create proper page breaks in the PDF. Simpler permissions model replaces custom sharing UI with standard Salesforce sharing.

### Cover Page & Section Breaks
- **Title page support** — Templates with "Different First Page" enabled in Word (`<w:titlePg/>`) now suppress headers and footers on the first page. Your cover page stays clean.
- **Section breaks** — Mid-document section breaks in your Word template now create proper page breaks in the PDF instead of being silently stripped.

### PDF Rendering Fixes
- **Spaces between merge tags** — `{FirstName} {LastName}` no longer renders as "FirstNameLastName". Whitespace-only runs are preserved.
- **Page number formatting** — Page numbers in headers and footers now honor the font size, color, bold, and other formatting from your Word template.
- **Page counter CSS** — Switched to `::before` pseudo-elements for reliable page numbering in Flying Saucer running elements.
- **Numbered list detection** — `numbering.xml` now included in the pre-decomposed XML path so numbered vs bulleted lists render correctly in PDF output.

### UI Fixes
- **Template selection persists** — Switching between Create Document, Document Packet, and Combine PDFs tabs no longer resets your template selection.

### Simplified Sharing
- Removed custom sharing UI — use standard Salesforce sharing rules and manual sharing for template access control. Simpler, more predictable, no custom code needed.

### Housekeeping
- Removed built-in sample templates — download templates from [portwoodglobalsolutions.com](https://portwoodglobalsolutions.com)
- 623 Apex tests passing, 24/24 E2E tests, 0 security violations

## v1.22.0 — Bug Fixes & Template Cleanup

Patch release with merge tag spacing fixes and page number formatting. Sample templates moved online.

## v1.21.0 — Query Builder 2.0 & User Guide

Replaced the visual query builder with a simpler, faster, more reliable manual-first experience. The old visual builder had persistent bugs — broken save state, empty config on object selection, template creation failures ("Please configure the query" error). Rather than continuing to patch a complex reactive UI, we stripped it back to what works: a text box with smart suggestions.

### Query Builder 2.0
- **Manual-first approach** — Type your query directly in a monospace textarea. No drag-and-drop, no multi-panel visual builder. Admins who know their objects type faster than they click.
- **Inline field autocomplete** — Start typing a field name and suggestions appear from the object schema. Click to insert with auto-comma formatting.
- **Context-aware suggestions** — Type `Owner.` and it loads the User object's fields. Type `(` and it shows child relationships. Inside `(SELECT ... FROM Contacts)` it suggests Contact fields.
- **Sample record preview** — Pick a sample record on step 1. The query structure tree on step 2 shows real values: `Name = Acme Corporation`, child record rows in mini-tables. See exactly what your query returns before uploading a template.
- **Object selection on step 1** — Base object is picked alongside template name and type. By the time you reach step 2, metadata is pre-loaded. No loading spinners, no async rendering bugs.
- **Inline quick reference** — Syntax examples for fields, parent lookups, related list subqueries with WHERE/ORDER BY/LIMIT right below the textarea.
- **Trailing comma cleanup** — Auto-stripped when clicking Next.
- **Query persistence** — Navigate forward to step 3 and back to step 2, your query is exactly as you left it.

### Builder Bug Fix
- Fixed the root cause of "Please configure the query" error — `_notifyChange()` was firing in `_initRootNode()` before fields loaded asynchronously, emitting empty config to the parent component.

### User Guide
- New public `/DocGenGuide` page with full documentation — 28 sections covering every feature from template creation to Flow automation.
- Sticky sidebar navigation with scroll-spy active section highlighting.
- Consistent nav bar (`Home | User Guide | Roadmap | Community | GitHub`) across all 7 site pages.

### Testing
- **629 Apex tests passing, 0 failures**
- **24/24 E2E tests passing**
- **0 Code Analyzer security violations**

## v1.20.0 — Dynamic Page Numbers & Bug Fixes

Feature release: dynamic page numbering in PDF headers/footers, closing all community-reported rendering issues.

### Dynamic Page Numbers (#9)
- **PAGE and NUMPAGES field codes** — Word's `PAGE` and `NUMPAGES` field codes in headers and footers now render as dynamic page numbers in PDF output. Supports both complex field codes (`w:fldChar begin/separate/end`) and simple field wrappers (`w:fldSimple`). Uses CSS `counter(page)` and `counter(pages)` via `::after` pseudo-elements inside Flying Saucer running headers.
- **Works in both headers and footers** — "Page 1 of 5" style numbering works anywhere in header or footer content, alongside other text and formatting.

### Bug Fixes (Since v1.15.0)
- **Headers/footers on all pages (#9)** — PDF headers and footers now repeat on every page via Flying Saucer running elements with `@page` margin boxes.
- **Numbered lists render correctly (#9)** — Replaced odd/even numId heuristic with actual `numbering.xml` lookup (`w:num` → `w:abstractNum` → `w:lvl` → `w:numFmt`).
- **Font colors from theme references (#9)** — Theme colors (`w:themeColor="accent1"`) now resolve to hex via default Office theme palette (all 16 colors).
- **Ampersand rendering (#5)** — Fixed double-encoding where `&amp;` in XML became `&amp;amp;` in HTML. Added `unescapeXmlEntities()` before `escapeHtml4()`.
- **Create Packet button state (#6)** — Template selection persists across mode switches; button no longer requires re-selection.

### Package Chain
- Ancestor: 1.18.0-2 (04tal000006PW4TAAW)
- Chain: 1.15.0 → 1.16.0 → 1.17.0 → 1.18.0 → 1.20.0

### Testing
- **629 Apex tests passing, 0 failures**
- **76% org-wide code coverage**
- **24/24 E2E tests passing**
- **Visual proof PDFs** generated on clean scratch org verifying each fix

## v1.14.0 — PDF Rendering Fixes + Community Channel + Support Page

Bug fix release addressing community-reported PDF rendering issues, Slack community channel migration, and new Support the Project page.

### PDF Rendering Fixes
- **Headers and footers on all pages** — PDF headers and footers now repeat on every page. Previously they only appeared on page one. Switched from CSS absolute positioning to Flying Saucer's running elements with `@page` margin boxes.
- **Numbered lists render correctly** — Numbered lists no longer render as bullet points. Replaced the unreliable odd/even numId heuristic with actual `numbering.xml` lookup. The renderer now parses `w:num` to `w:abstractNum` to `w:lvl` to `w:numFmt` to determine the real list type (decimal, lowerLetter, upperRoman, bullet, etc.).
- **Font colors from theme references** — Font colors defined as Word theme references (`w:themeColor="accent1"`) now render in PDFs. Added default Office theme color palette mapping for all 16 standard theme colors.
- **Ampersand rendering fixed (#5)** — Ampersands (`&`) no longer render as literal `&amp;` in PDF output. Fixed double-encoding where XML entities in `<w:t>` text were escaped twice (once by XML, once by `escapeHtml4()`).

### UI Fixes
- **Create Packet button state (#6)** — The "Create Packet" button no longer stays disabled after navigating away from the Create Document tab and back. Template selection now persists across mode switches.

### Community
- **Slack community channel** — Migrated from workspace invite to Slack Connect channel invite. Users join from their own Slack workspace, no separate account needed. Updated language across all docs, legal pages, and community landing page.
- **Support the Project page** — New `/DocGenSupport` page with the DocGen origin story, pay-what-you-can philosophy, Circles Indy as featured nonprofit, split-your-donation model, and family photo.

### Testing
- **890 Apex tests passing, 0 failures** — Fixed 4 pre-existing test failures (3 Giant Query tests missing DOCX in `@TestSetup`, 1 numbered list test updated for new `numbering.xml` detection).
- **76% org-wide code coverage** (up from 74%)
- **Code Analyzer: 0 violations** across pmd, eslint, retire-js

## v1.13.0 — Community + AppExchange Prep

Community-first release: Slack community, 100% free model, and AppExchange submission readiness.

### Community
- **Slack community channel** — Replaced custom forum with Slack community channel. Join from your own Slack workspace — no separate account needed.
- **Community link in Command Hub** — "Join the Community" link added to the sidebar, above "Made with love."
- **Slack invite URL from MDT** — `Slack_Invite_Url__c` field on `DocGen_Landing_Config__mdt`. Update one record when the link expires — no code deploy needed.

### Website
- **100% free model** — Removed all paid tier references, premium pricing, and freemium language across all pages.
- **Community promotion** — Landing page help form replaced with community section (Discussion Board, Feature Requests, Report Issues).
- **Roadmap rework** — Removed Premium Launch and tier comparison. Single "Full Feature Set" card at $0. Community-driven roadmap.
- **Terms & Privacy updated** — Accurate PackageSubscriber data disclosure, Slack community channel terms, free model pricing, $100 liability cap.

### AppExchange
- **Security review docs** — Solution architecture, submission form, code analyzer summary — all as `.doc` files ready for upload.
- **LISTING.md** — Complete AppExchange listing reference: SEO title, highlights, description, keywords, screenshots, demo script.
- **Code Analyzer** — Clean scan: 0 Critical, 0 High across all 6 engines (pmd, eslint, retire-js, cpd, regex, flow).

### Fixes
- **Giant Query test fix** — Added missing `DocGen_Template_Version__c` to test setup. Created local DOCX helper to avoid cross-class test data dependency.

## v1.12.0 — RTL Support + Giant Query 28K+ + Custom Object Fix

Major release: RTL language support for PDF output, Giant Query scaling to 28K+ rows, custom object query builder fix, V1 object name resolution, Giant Query Flow action, and install tracker improvements.

### RTL Language Support (Hebrew, Arabic)
- **RTL text rendering** — Detects `<w:bidi/>` and `<w:rtl/>` in DOCX XML. Reverses Hebrew/Arabic text for correct right-to-left display in `Blob.toPdf()`. English merge field values are preserved.
- **RTL paragraph alignment** — Right-aligns paragraphs when document default style or paragraph properties specify `<w:bidi/>`.
- **RTL table layout** — Tables with `<w:bidiVisual/>` render columns right-to-left.
- **RTL run ordering** — Multiple runs within an RTL paragraph display in correct right-to-left order.
- **Complex Script font** — Uses Arial Unicode MS (built into `Blob.toPdf()`) for Hebrew/Arabic glyphs. Detects `w:cs` font attribute.
- **Bidi-aware indentation** — Falls back to `w:start`/`w:end` when `w:left`/`w:right` absent.
- **Known limitation**: Long paragraphs that wrap to multiple lines may have continuation lines starting from the left instead of the right. This is a Flying Saucer (PDF engine) limitation — it does not implement the Unicode Bidirectional Algorithm. Will be addressed in a future release.

### Giant Query (from v1.8.0-v1.9.0)
- **28K+ row scaling** — Single-pass fragment assembly, no Queueable chaining.
- **Reduced HTML size** — `td:nth-child(N)` CSS instead of per-cell classes.
- **Parent merge tag fix** — Validates dot-notation fields against base object schema.
- **V1 object name resolution** — Auto-resolves object names to relationship names in subqueries.

### Query Builder (from v1.7.0)
- **Custom object label fix** — Fixed `_createNode` pluralizing API names (`__c` → `__cs`).
- **Schema-based lookup fields** — Report import uses describe instead of hardcoded `parentObj + 'Id'`.
- **Dynamic child discovery** — Report import for custom object report types.

### Other
- **Giant Query Flow Action** — `DocGenGiantQueryFlowAction` invocable: auto-detects large datasets, sync under 2K rows, async batch over 2K. Customer portal ready.
- **Install tracker** — Net-new notifications only, per-row Account actions, fuzzy org name matching.
- **PPTX/XLSX** — Marked as "Coming Soon" on landing page (not battle-tested).

## v1.11.0 — RTL Language Support (Hebrew/Arabic)

(Superseded by v1.12.0)

## v1.10.0 — Giant Query Flow Action

- **feat: Generate Document (Auto Giant Query)** — New `DocGenGiantQueryFlowAction` invocable action. Scouts child counts automatically — under 2,000 rows generates synchronously, over 2,000 launches async Giant Query batch. PDF saved to record when complete. Returns `isGiantQuery` flag and `jobId` for Screen Flow status tracking.
- **Use case: Customer portals** — Screen Flows on Experience Cloud can offer "Download All Transactions" regardless of dataset size.

## v1.9.0 — V1 Object Name Resolution

- **fix: V1 subquery object name fallback** — When a V1 config uses the object API name (e.g., `FROM Short_Code__c`) instead of the relationship name (`FROM Short_Codes__r`), the parser now auto-resolves it by matching against the parent object's child relationships. Fixes configs generated via Manual Query mode with custom objects.

## v1.8.0 — "Giant Query 28K+ & Custom Object Fix" (Portwood DocGen Managed)

Giant Query PDF now scales to 28,000+ rows. Fixed Queueable chain depth limit and reduced HTML size.

- **fix: Giant Query single-pass assembly** — Assembler now loads all HTML fragments in one Queueable execution instead of chaining. Eliminates the 5-deep Queueable chain limit that caused "Maximum stack depth" on large datasets.
- **fix: Drop per-cell CSS classes** — Removed `class="c1"` from every `<td>` in batch HTML output, saving ~2.5MB on 28K rows. Column formatting now uses `td:nth-child(N)` CSS selectors.
- **fix: Giant Query parent merge tags** — Fixed parent field resolution that silently failed when child loop fields (e.g., `Product2.Name`) were included in the parent SOQL query. Now validates dot-notation fields have a valid relationship on the base object.
- **fix: Multi-part PDF rendering** — When row count exceeds 2,000, renders separate PDFs per chunk for client-side merge. Prevents `Blob.toPdf()` stack overflow on very large documents.
- **Tested**: 28,000 PricebookEntries, 6 columns, ~3.2MB HTML → 8MB PDF.
- **Ancestor Chain** — v1.8.0 → v1.7.0 → v1.6.0. Seamless upgrades.

## v1.7.0 — "Custom Object Query Builder Fix" (Portwood DocGen Managed)

Fixed query builder label processing that broke custom objects with `__c` suffix. The label cleanup logic was extracting the API name from the display label and pluralizing it (e.g., `Record_Consolidation__c` → `Record_Consolidation__cs`), causing invalid object references at generation time.

- **fix: Custom object label pluralization** — `_createNode` no longer pluralizes API names extracted from parenthesized labels. Custom objects like `Record_Consolidation__c` now display their friendly label instead of a mangled API name.
- **fix: Lookup field resolution** — Report import and V2 config parsing now use schema describe to find the correct lookup field instead of hardcoding `parentObj + 'Id'`. Custom object lookups (e.g., `Account__c` instead of `AccountId`) resolve correctly.
- **fix: `_guessLookupField` for custom relationships** — Handles `__r` → `__c` and `__cs` → `__c` relationship suffixes. V1/V2 config parsers now pass lookup fields instead of null.
- **fix: Report import for custom objects** — Dynamic child discovery via schema describe when the hardcoded report type map doesn't match. `resolveReportBaseObject` now resolves custom object report types directly.
- **Defensive `__cs` correction** — V3 data retriever auto-corrects `__cs` object names to `__c` at runtime if the object doesn't exist in global describe.
- **Ancestor Chain** — v1.7.0 → v1.6.0 → v1.5.0. Seamless upgrades.

## v1.6.0 — "Sample Flows" (Portwood DocGen Managed)

Sample Flows demonstrating DocGen Flow action integration. Proper upgrade chain from v1.5.0.

- **DocGen: Generate Account Summary** — Screen Flow for Account record page. Resolves default template via `Is_Default__c`, generates PDF, saves to Files. Launch as Quick Action or App Page button.
- **DocGen: Welcome Pack on New Contact** — Record-Triggered Flow (After Save, Create). Auto-generates welcome document and creates follow-up Task for Contact Owner.
- **Flow Entry Criteria** — Record-triggered flow includes entry criteria to satisfy Code Analyzer (0 High).
- **Ancestor Chain** — v1.6.0 → v1.5.0 → v1.4.0. Seamless upgrades.
- **615 Apex tests**, 76% coverage, 24/24 E2E, 0 Critical, 0 High.

## v1.5.0 — "Giant Query PDF" (Portwood DocGen Managed)

Same features as v1.3.0/v1.4.0 with critical fixes and proper package ancestor chain for upgrades.

- **Ancestor Chain Established** — v1.5.0 is the first version with a proper upgrade path. All future versions chain from here. Subscribers can upgrade in-place going forward.
- **fix: Regex too complicated** — `Pattern.compile` on 1MB+ HTML with 10K data rows hit Apex regex limits. Moved parent merge tag resolution to run on the template HTML (~2KB) before row injection. Barcode markers stripped via string ops instead of regex.
- **fix: E2E State/Country Picklists** — New developer orgs with State/Country picklists enabled caused silent DML failures. Now detects picklist fields via Schema and uses code fields when available. (PR #2 by @AtlasCan)
- **Live Install Count** — Landing page hero badge shows "Proudly serving X orgs" via real-time PackageSubscriber query.
- **Competitor Comparison** — "Child Records per Document" row added to comparison table: DocGen 50,000+ vs competitors at ~200-1,000.
- **615 Apex tests**, 76% coverage, 24/24 E2E, 0 Critical, 0 High.

## v1.3.0 — "Giant Query PDF" (Portwood DocGen Managed)

Server-side PDF generation for records with 3,000-50,000+ child records. No external dependencies, no heap limits, no callouts.

- **Giant Query PDF** — Render unlimited-row PDFs entirely server-side. Batch harvests child records in 50-row cursor pages, saves as lightweight HTML fragments. Progressive Queueable chain accumulates fragments into a single HTML document. One `Blob.toPdf()` call renders the final PDF. Saved directly to the record via ContentDocumentLink.
- **Pre-baked HTML Templates** — Template DOCX is converted to HTML at save time and stored as a ContentVersion. At generation time, zero DOCX XML parsing — just load the pre-baked HTML and inject data rows. Eliminates the heaviest heap operation from the render path.
- **Column CSS Formatting** — Bold, italic, font-size, and text alignment extracted once from the template's loop row XML, applied via CSS class selectors (`.c1`, `.c2`). CSS2.1 compatible with Flying Saucer (Blob.toPdf engine). Zero per-cell overhead for 10,000+ rows.
- **Parent Lookup Fields** — Dot-notation parent fields (e.g., `Product2.Name`, `Product2.Description`) now resolve correctly in Giant Query data rows. Fixed nested map structure in `renderLoopBodyForRecords` to match `resolveValue` traversal.
- **Progress Bar UI** — Real-time progress bar with percentage during batch processing. "Do not leave this page" warning during assembly.
- **Lightweight Launch** — `launchGiantQueryPdfBatch` controller accepts scout-resolved child node config, works for V1/V2/V3 query configs. Pre-decomposed XML lookup avoids ZIP decompression in the controller.
- **Barcode Handling** — Barcode markers (`##BARCODE:code128::VALUE##`) stripped to plain text values in Giant Query rows. CSS bar spans too heavy for 3K+ rows; barcodes work normally in standard PDF generation (< 2,000 rows).
- **Known Limitations** — Images in data rows not rendered (template images work). Custom fonts not supported (Blob.toPdf platform limitation). No save-to-record for objects without ContentDocumentLink support (e.g., Pricebook2).
- **615 Apex tests**, 76% coverage, 24/24 E2E, 0 Critical, 0 High. Tested: 3K PricebookEntries, 10K Opportunities.

## v1.2.0 — "Giant Query & AppExchange Ready" (Portwood DocGen Managed)

First managed package release. Giant Query, security review prep, and 615 tests.

- **Giant Query** — Generate documents from records with 15,000+ child records. Client-side DOCX assembly with cursor-based pagination (500 rows/page). Auto-detects large datasets on Generate click. Works with V1, V2, and V3 query configs. Barcode fonts render natively in DOCX.
- **Managed Package** — Switched from Unlocked to Managed 2GP for AppExchange listing. IP-protected Apex, proper upgrade path.
- **TestDataFactory** — Centralized test data creation across all 5 test classes. `createStandardTestData()`, `attachRealDocxToTestTemplate()`, consistent Account/Template names.
- **Security Review Ready** — 0 Critical, 0 High on Code Analyzer. Package-internal queries use `WITH SYSTEM_MODE`; user-facing queries use `WITH USER_MODE`. All classes use `with sharing`. SOQL-in-loop eliminated.
- **V1/V2/V3 Scout** — Giant Query auto-detection works with all query config formats including manual V1 flat strings.
- **Save-to-Record UX** — Save option hidden for non-PDF output (DOCX always downloads). Giant Query sets download-only mode automatically.
- **615 Apex tests**, 79% coverage, 24/24 E2E, 100% pass rate.

## v1.2.0 — "Hello AppExchange" (Portwood DocGen)

- **Security review ready** — 0 Critical, 0 High on Salesforce Code Analyzer (recommended rules). All SOQL queries use `WITH USER_MODE`. All classes use `with sharing`. All DML justified. Zero SOQL-in-loop violations.
- **553 Apex tests, 79% coverage, 24/24 E2E** — every feature tested, every edge case covered.
- **Permission sets audited** — Admin and User permission sets verified against all 4 custom objects and every field. Required fields excluded (Salesforce auto-grants). FLS enforced end-to-end.
- **Bulk runner redesigned** — single Output Mode dropdown (Individual Files / Print-Ready Packet / Combined + Individual). Batch heap analysis with real measured heap deltas.
- **Template import/export** — portable `.docgen.json` files for sharing templates across orgs.
- **Queueable Finalizer** on DocGenMergeJob — marks jobs as Failed on unhandled exceptions.
- **SLDS design tokens** throughout all LWC components. ESLint clean.
- **Mobile support** — DocGen Runner works on Salesforce mobile (Record Page + App Page).

## v1.1.7 — "Runner Mobile Support & Community Hub (Parked)" (Portwood DocGen)

- **DocGen Runner Mobile Support** — Record Page and App Page targets now include mobile form factor support (`Small` + `Large`), enabling the runner on Salesforce mobile.
- **Community Hub (Parked)** — Full VF-based community forum built and committed to `devhub-tools/` — rich text editor, @mentions, reply notifications via Resend, profile pages, org management, category hub with topic cards, breadcrumb navigation, vendor directory. Parked for now to stay focused on core document generation. Code ready to activate when needed.
- **Removed Community Link** — Removed "Join Community" from Command Hub sidebar and landing page nav.

## v1.1.6 — "Template Import/Export & Community Repo Migration" (Portwood DocGen)

- **Template Import/Export** — Export any template as a portable `.docgen.json` file containing all metadata, query config, saved queries, and the template file (DOCX/XLSX/PPTX). Import the JSON into any org to recreate the template with a single click. Pre-decomposed parts and images are auto-regenerated on import. Export via row action menu; Import via toolbar button.
- **Community Repo Migration** — DocGen's official home is now [Portwood-Global-Solutions/Portwood-DocGen](https://github.com/Portwood-Global-Solutions/Portwood-DocGen). GitHub Discussions enabled, issue templates upgraded (bug report, feature request, question), PR template, CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, and custom labels added.
- **Landing Page Links Updated** — All GitHub and install links on portwoodglobalsolutions.com now point to the new org repo and use CMDT-backed install URLs.
- **507/507 Apex tests**, 77% coverage, 0 Critical/High. E2E 24/24.

## v1.1.5 — "Flow Action Visibility, Null Parent Lookup Fix & Landing Page CMDT" (Portwood DocGen)

- **Flow Actions Visible in Subscriber Orgs** — `DocGenFlowAction` and `DocGenBulkFlowAction` changed from `public` to `global`. In namespaced packages, `@InvocableMethod` and `@InvocableVariable` members must be `global` to appear in the subscriber org's Flow Builder. Fixes #49.
- **Null Parent Lookup Fix** — Null parent lookups in child loops (e.g., `{ReportsTo__r.Name}`) no longer incorrectly render the child record's own `Name` field. They now correctly render as blank. The `resolveValue()` base-object-name skip logic now excludes relationship fields ending in `__r`. Fixes #48.
- **Landing Page CMDT** — Install links on the VF landing page are now driven by `DocGen_Landing_Config__mdt` instead of hardcoded constants. Updating install links for a new release only requires deploying an updated CMDT record — no Apex changes needed.
- **507/507 Apex tests**, 79% coverage, 0 Critical/High. E2E 23/23.

## v1.1.4 — "Bulk Runner UX, Community Hub & Batch Heap Analysis" (Portwood DocGen)

- **Bulk Runner Output Mode** — Replaced confusing checkbox toggles with a single dropdown: "Individual Files" (one PDF per record, unlimited scale), "Print-Ready Packet" (single merged PDF), or "Combined + Individual" (both). Clear labels, clear behavior.
- **Batch Heap Analysis** — Pre-generation analysis now shows per-batch heap estimates alongside merge heap. Uses measured heap delta (not just HTML size) to capture query objects, template parsing, and image metadata overhead. Safer batch size recommendations.
- **Join Community Link** — Command Hub sidebar now includes a "Join Community" link to the DocGen Community Hub at portwoodglobalsolutions.com/DocGenCommunity. Passes the org ID for automatic account linking during registration.
- **507/507 Apex tests**, 83% coverage, 0 Critical/High. E2E 22/22.

## v1.1.3 — "Clickable Hyperlinks in Rich Text PDFs" (Portwood DocGen)

- **Clickable Hyperlinks in PDF** — Rich text `<a href="...">` tags now render as real clickable links in PDF output. Previously, hyperlinks from rich text fields were rendered as styled text (blue + underline) but were not clickable. Now they generate proper `<a>` tags in the HTML passed to `Blob.toPdf()`.
- **Anchor Tag Parsing** — New `extractAttribute()` helper parses `href` from rich text anchor tags. Handles quoted and unquoted attributes, `&amp;` decoding.
- **Custom URL Attribute for DOCX→PDF Bridge** — Rich text links embed a `w:docgen-url` attribute on `w:hyperlink` elements during XML processing, which the HTML renderer reads to produce clickable `<a>` tags without needing relationship file lookups.

## v1.1.2 — "Image Sizing, Error Diagnostics & Multiline Text" (Portwood DocGen)

Huge thanks to **@Henk3000** for PR #47 — ImageRenderSpec, ahe() helper, multiline text preservation, error diagnostics for malformed tags, and smart container expansion for numbered lists.

- **ImageRenderSpec** — Percentage-based image sizing (`{%Logo:100%x}`), max constraints (`{%Logo:m100%x}`), intrinsic dimension detection from PNG/JPEG headers, aspect ratio preservation. Credit: @Henk3000 PR #47.
- **Error Diagnostics** — Malformed merge tags and unclosed loop tags now throw `DocGenException` with descriptive messages instead of silently producing broken output.
- **Multiline Text Preservation** — Newlines in Long Text Area and Text Area fields now render as proper Word line breaks (`<w:br/>`) with correct run element handling.
- **Smart Container Expansion** — Loop tags inside numbered/bulleted lists now repeat the list paragraph formatting. Previously only table rows were detected.
- **`ahe()` Helper** — Consistent `AuraHandledException` creation with original exception logging. All 38 throw sites migrated.
- **Universal File Save** — `saveContentVersion()` gracefully handles objects that don't support `FirstPublishLocationId` or `ContentDocumentLink` (e.g., Pricebook2).
- **507/507 Apex tests**, 79% coverage, 0 Critical/High. E2E 22/22.

## v1.1.0 — "Pixel-Perfect PDF" (Portwood DocGen)

Huge thanks to **@josephedwards-png** for PR #46 — his analysis of the relId collision bug and namespacing approach was the key insight that unlocked header/footer image rendering.

- **Header/Footer Rendering in PDF** — Full formatting, borders, merge tags, images. Headers at top, footers pinned to bottom.
- **Namespaced Image RelIds** — `header1_rId1`, `footer1_rId1` prevent collisions. Credit: @josephedwards-png PR #46.
- **Dynamic Style Resolution** — Table borders, cell padding, page size/margins all read from `styles.xml` and `w:sectPr` at render time.
- **PDF Merger Restored** — Generate+merge, merge-only, document packets with client-side PDF merging.
- **Client-Side DOCX Assembly** — Zero heap ZIP. Per-image Apex calls with fresh 6MB heap each.
- **507/507 Apex tests**, 81% coverage, 0 Critical/High. E2E 22/22.
- Templates with headers/footers must be re-saved to pick up the fix.

## v1.0.8 — "Full Release" (Portwood DocGen)

**IMPORTANT: If upgrading from the old unnamespaced "Document Generation" package, you MUST uninstall it first.** The new package uses the `portwoodglobal` namespace — the two cannot coexist. Go to Setup > Installed Packages > Document Generation > Uninstall, then install this version.

- **Website Live** — [portwoodglobalsolutions.com](https://portwoodglobalsolutions.com) — landing page with install links and live demo
- **DocGenDataProvider Interface** — Custom Apex data sources for templates. Implement `getData(Id recordId)` and `getFieldNames()` to supply data from any source — external APIs, computed fields, cross-object aggregations. V4 query config: `{"v":4,"provider":"ClassName"}`
- **Apex Provider in Query Builder** — Toggle between Standard Object and Apex Provider. Searchable class picker finds all `DocGenDataProvider` implementations. Tags preview from `getFieldNames()`
- **Flow Actions Expanded** — Single generation: Save to Record, Document Title override, Content Version ID output. Bulk generation: Combined PDF Only, Keep Individual Files, Batch Size, Job Label
- **Mobile Support** — Responsive CSS, utility bar target, flow screen compatible
- **Bulk Runner UX** — "Combined PDF Only" / "Combined + Individual PDFs" replaces confusing merge toggles
- **Sample Record Picker** — Persistent bar above all tabs in edit modal
- **507 Apex Tests Passing** — 83% code coverage, 0 Critical, 0 High on Code Analyzer
- **E2E: 22/22** — includes V4 provider tests, image rendering, junction stitching, aggregates
- **Package Install Tracker** — DevHub dashboard with version history, install notifications, auto-refresh

## v1.0.4 — "Namespace Release" (Portwood DocGen)
- **Namespaced Package** — DocGen is now distributed as `portwoodglobal` namespaced unlocked 2GP package via Portwood Global Solutions. Existing unnamespaced installs must uninstall and reinstall.
- **Namespace-Aware LWC** — All Lightning Web Components now use `@salesforce/schema` imports for field access, ensuring correct field resolution in namespaced subscriber orgs. Fixes "undefined" and "field does not exist" errors.
- **Visual Query Builder Fixes** — Tag copy now works in all Lightning contexts (clipboard fallback). "Change Object" button added to tree header. Parent field search preserves selections when filtering.
- **Manual Query Mode** — Toggling to Manual now converts V3 JSON to readable V1 SOQL format. Editable and saveable as V1.
- **Sample Templates Fixed** — Sample templates now create proper version snapshots with metadata headers and image extraction. No more "undefined" in template lists.
- **Bulk Runner UX** — "Combined PDF Only" and "Combined + Individual PDFs" replace confusing "Merge PDFs" / "Merge Only" toggles. Combined-only is now the default (saves heap).
- **Sample Record Promoted** — Record picker moved to persistent bar above all tabs in the edit modal. Accessible from any tab.
- **Permission Sets Updated** — All custom fields, Apex classes, VF pages, and tabs audited and corrected for both Admin and User permission sets.
- **Dead Code Removed** — Removed vestigial DocGenVerify VF page (e-signature leftover).
- **Code Quality** — 161 assertion messages added, 64 missing braces fixed, 11 parseInt radix fixes. Code Analyzer: 0 Critical, 0 High.
- **E2E Tests** — 20 tests (added doc generation size check). All 495 Apex tests passing, 83% coverage.
- **Support** — hello@portwoodglobalsolutions.com

## v2.7.0.7 — "Beacon"
- **Header/Footer Images in PDF** — Fixed: images in Word headers and footers now render in PDF output. The template image extraction now parses `word/_rels/header*.xml.rels` and `word/_rels/footer*.xml.rels` in addition to the main document rels. All image relationship IDs are combined so `buildPdfImageMap()` can resolve them. Templates with header/footer images must be re-saved to pick up the fix.
- **Add Related Records UI Refresh** — Fixed: clicking "Add Related Records" now immediately updates the document structure tree and tabs without requiring navigation away and back.
- **All 495 Apex tests passing** (100% pass rate). E2E 19/19. Code Analyzer: 0 Critical, 0 High, 0 Medium.

## v2.7.0.6 — "Beacon"
- **Pre-flight Job Analysis** — The Bulk Runner now runs a comprehensive governor limit analysis on "Validate Filter". Checks SOQL queries per batch, DML statements, record count limits, and heap usage (merge mode). The Run button is disabled until the filter is validated and all checks pass.
- **Dynamic Junction Target ID** — Report import now dynamically resolves the lookup field on junction objects (e.g., `ContactId` on `OpportunityContactRole`) instead of hardcoding. Works for any junction relationship, not just Contact.
- **View Job Button Fix** — The "View Job" button on the batch status card is now clearly visible (uses `variant="inverse"` for white-on-blue).
- **All 495 Apex tests passing** (100% pass rate). E2E 19/19. Code Analyzer: 0 Critical, 0 High, 0 Medium.

## v2.7.0.5 — "Beacon"
- **Default Template Auto-Select** — Fixed: templates marked as "Default Template for this Object" now auto-select in the document runner when opening a record page. Previously the dropdown always started on "Choose a template..." regardless of the default setting.
- **One Default Per Object Enforcement** — Setting a template as default now automatically unsets any other default for the same object. Previously multiple templates could be toggled as default simultaneously.
- **Tab Character Rendering** — Fixed: Word tab characters (`<w:tab/>`) are now correctly rendered as fixed-width spaces in PDF output. A parsing bug caused `<w:tab` to be misidentified as `<w:t>` (text), silently dropping all tab stops.
- **HeapEstimate Null Safety** — `HeapEstimate.isRisk` now initializes to `false` instead of `null`, preventing null-check failures when heap estimation encounters an exception.
- **Test Coverage** — All 491 Apex tests passing (100% pass rate). E2E 19/19. New test for default template enforcement.

## v2.7.0.4 — "Beacon"
- **Proactive Heap Estimator** — The Bulk Runner now automatically estimates the final heap usage before you start a merge job. It simulates a single document generation and projects the total memory requirement, warning you if the job is likely to exceed the 12MB limit.
- **Word Header/Footer Support for PDF** — Content in Word headers and footers (like company addresses and logos) is now correctly included when generating PDFs.
- **Fixed Run Data Loss** — Resolved an issue where text or merge tags in a Docx run were lost if the run also contained a line break (`<w:br/>`).
- **Query Sanitization Graceful Failure** — Invalid clauses in query configurations no longer fail the entire generation.
- **Improved Parent Object Detection** — Fixed self-referential lookup detection.

## v2.6.0 — "Apollo+"
- **Bulk Data Pre-Cache** — All record data queried in a single SOQL with an IN clause during batch `start()`, cached as a JSON ContentVersion on the Job record. Each `execute()` reads from cache instead of re-querying. Eliminates 500+ individual SOQL queries for V3 configs. Graceful fallback to per-record queries for V1/V2 or if cache exceeds 4MB.
- **Template Static Cache** — Template metadata, file content, and pre-decomposed XML parts are cached statically across batch executions. First record queries the template; remaining records reuse it. Zero redundant template SOQL.
- **Merge PDFs Mode** — New "Merge PDFs" checkbox in bulk runner. Generates individual PDFs per record AND produces a single merged PDF at the end. HTML captured as a byproduct of `renderPdf()` — zero extra processing per record.
- **Merge Only Mode** — New "Merge Only" checkbox. Skips `Blob.toPdf()` and ContentVersion saves per record entirely. Only generates HTML snippets, assembles once in a Queueable, renders one merged PDF. ~5-8x faster than individual PDF generation for large batches.
- **Server-Side PDF Assembly** — `DocGenMergeJob` Queueable reads HTML snippets by title prefix, concatenates with page breaks, calls `Blob.toPdf()` once, saves merged PDF linked to the Job record. Accessible anytime via `Merged_PDF_CV__c`.
- **Custom Notifications** — Bell icon + Salesforce mobile push notification on all bulk job completions. Merge jobs notify with page count; normal jobs notify with success/fail count. Tapping navigates to the Job record. Uses `DocGen_Job_Complete` custom notification type.
- **Configurable Batch Size** — New "Batch Size" input in bulk runner UI (1-200, default 1). Simple text-only templates can use 10-50 for faster throughput. Complex templates with images stay at 1 for max heap.
- **lookupField Bug Fix** — Query tree builder now uses the actual lookup field API name from schema describe (`opt.lookupField`) instead of guessing from the parent object name. Fixes incorrect SOQL for custom objects where the lookup field name doesn't match the object name (e.g., `abc__Purchase_Order__c` vs `abc__PurchaseOrder__c`).
- **DateTime Filter Fix** — `getObjectFields()` now returns field type metadata. Filter builder appends `T00:00:00Z` to date-only values on datetime fields. Report filter import applies the same fix for standard datetime fields like CreatedDate.
- **Image Deduplication Confirmed** — Tested `Blob.toPdf()` image handling: same image URL repeated across pages is stored once in the PDF (confirmed via size analysis). Template logos on 500 pages = one embedded image, not 500.
- **New Custom Objects/Fields** — `Data_Cache_CV__c` (bulk data cache), `Merged_PDF_CV__c` (merged PDF link), `Merge_Only__c` (merge-only flag) on DocGen_Job__c. "Merging" status added to Status picklist. `DocGen_Job_Complete` custom notification type.
- **New Apex Classes** — `DocGenMergeJob` (Queueable for server-side PDF assembly).
- **E2E Tests** — 19/19 passing. No regressions from bulk caching or merge changes.

## v2.5.0 — "Apollo+"
- **Child Record PDF Merge** — New "Child Record PDFs" mode in the document generator. Pick a child relationship (e.g., Opportunities from Account), optionally filter with a WHERE clause, browse PDFs attached to each child record with grouped checkboxes and Select All, merge selected PDFs into one document. Download or save to parent record.
- **Bulk Generate + Merge** — After a bulk PDF job completes, merge all generated PDFs into a single downloadable document. Merge icon button on each completed job in the Recent Jobs list for easy access later.
- **Named Bulk Jobs** — Give bulk jobs a custom name (e.g., "March Receipts") for easy identification. Search bar filters the Recent Jobs list by name, template, or status.
- **Aggregate Format Specifiers** — Aggregate tags now support format suffixes: `{SUM:LineItems.TotalPrice:currency}` → $55,000.00. Works with `:currency`, `:percent`, `:number`, and custom patterns like `:#,##0.00`.
- **Aggregate Bug Fix** — Fixed silent failure when format specifiers (`:currency`, etc.) were appended to aggregate tags. The format suffix was being included in the field name lookup, causing the tag to resolve to "0" or disappear.
- **VF Fallback Removed** — Removed `DocGenPdfRenderer` VF page and `DocGenPdfRendererController`. `Blob.toPdf()` with the Spring '26 Release Update handles all PDF rendering. Eliminates the last security scan violation and reduces attack surface.
- **Security Hardening** — Zero PMD security violations. All 22 findings resolved: SOQL injection (validated inputs + NOPMD), CRUD (package-internal objects with permission sets), XSS (ID validation + escaping).
- **Page Breaks in Loops** — README now documents how to use Word page breaks inside child loops for one-page-per-record output (receipts, invoices, certificates).
- **E2E Test Coverage** — 6 new aggregate tests (T14-T19): COUNT, SUM, SUM:currency, AVG, MIN, MAX. Total: 19 tests.

## v2.4.0 — "Apollo+"
- **QR Codes** — `{*Field:qr}` generates QR codes in PDF output. Supports up to 255 characters (full text field). Custom sizing: `{*Field:qr:200}` for 200px square. Version 1-14 with Level M error correction and Reed-Solomon.
- **Barcode Sizing** — `{*Field:code128:300x80}` for custom barcode dimensions.
- **Number & Currency Formatting** — `{Amount:currency}` → $500,000.00. Also `:percent`, `:number`, and custom patterns like `{Price:#,##0.00}`.
- All 13 barcode/QR tests passing, E2E 13/13.

## v2.3.0 — "Apollo+"
- **PDF Merger** — Generate a document and merge it with existing PDFs on the record in one step. Client-side merge engine (`docGenPdfMerger.js`) — pure JS, no external dependencies, zero heap.
- **Merge-Only Mode** — Combine existing PDFs without generating a template. Dual-listbox for reordering. Select 2+ PDFs, merge, download or save.
- **Document Packets** — Select multiple PDF templates, generate each for the same record, merge into one combined document. Optionally append existing PDFs.
- **Aggregate Tags** — `{SUM:QuoteLineItems.TotalPrice}`, `{COUNT:Contacts}`, `{AVG:...}`, `{MIN:...}`, `{MAX:...}`. Computed from child record data already in memory — zero extra SOQL.
- **Barcode Tags** — `{*FieldName}` renders Code 128 barcodes as CSS bars in PDF output. No images, no fonts — pure HTML/CSS rendered by `Blob.toPdf()`.
- **Excel (XLSX) Output** — Upload an Excel template with merge tags in cells. Engine parses shared strings table, inlines references, merges tags, and assembles via client-side ZIP. Same pattern as DOCX.
- **Save to Record for All Formats** — DOCX, XLSX, and PDF can all be saved back to the record. Previously PDF-only.
- **Query Builder Fix** — Selecting fields, changing the search filter, and selecting more fields no longer loses previous selections. Hidden selections are preserved across filter changes.
- **Show Selected Toggle** — New button in the query builder to filter the field list to only selected fields. Works alongside search.
- **Robust PDF Parsing** — Root catalog detection follows `startxref` spec path with nested `<<>>` dictionary handling. Works with PDF 1.5+ cross-reference streams.
- **Page Ordering Fix** — Merged PDFs preserve correct reading order from each document's page tree.

## v2.0.0 — "Apollo"
- **Single-App Experience** — One tab, three cards: Templates, Bulk Generate, How It Works. No more tab sprawl.
- **Bulk Runner Overhaul** — Typeahead template search, inline sample record picker, real PDF preview download, server-loaded job history. All in one view.
- **Zero-Heap PDF Preview** — `generatePdfBlob()` now forces PDF output format, ensuring the pre-decomposed path and relative image URLs are always used. Preview works on templates with dozens of images without hitting heap limits.
- **Query Builder Stability** — Fixed infinite re-parse loop that reset the active tab and wiped field selections on every checkbox toggle. V1 flat configs and V2 JSON configs now load correctly in the visual builder (backward compatible).
- **Self-Contained E2E Tests** — `scripts/e2e-test.apex` creates its own template, DOCX file, template version, test data, generates a real PDF, validates 13 assertions, and cleans up. Zero dependencies on pre-existing org data.
- **Report Filter Auto-Save** — Imported report WHERE clauses automatically saved as bulk queries and loaded when the template is selected.
- **Saved Query Management** — Save, load, and delete named SOQL conditions per template.
- **Recent Jobs Panel** — Completed bulk jobs load from the server with status, counts, template name, and date. Refreshes automatically when a job finishes.

## v1.6.0
- **Multi-Object Query Builder** — Tab-per-object layout with visual relationship tree. Build templates spanning Account → Opportunities → Line Items → Contacts in one view. Each object gets its own tab with field selection, parent field picker, and WHERE/ORDER BY/LIMIT.
- **V3 Query Tree Engine** — New JSON v3 config format. One SOQL query per object node, stitched together in Apex. Supports any depth with zero SOQL nesting limits. Backward compatible with v1/v2 configs.
- **Report Import** — Import field selections from ANY Salesforce Report. Dynamic base object resolution using plural label matching — works for standard, cross-object, and custom report types. Auto-detects parent lookups, child relationships, and junction objects. Report date filters extracted as bulk WHERE clauses.
- **Junction Object Support** — Contact via OpportunityContactRole, Campaign Members, and other junction objects detected and handled automatically. Two-hop queries stitch junction targets into the data map.
- **Click-to-Copy Merge Tags** — Click any tag in the builder to copy it to clipboard with a toast confirmation.
- **Bulk Runner Refresh** — Refresh button on template picker. Report filters auto-populate the WHERE clause when selecting a template built from a report import.
- **Backward-Compatible Upgrade** — Stub methods for removed signature classes allow v1.6.0 to install cleanly over v1.4.0 orgs.
- **E2E Test Suite** — `scripts/e2e-test.apex` validates 13 tests: V3 tree walker, parent fields, grandchild stitching, image CV creation, junction stitching, legacy backward compat, document generation. Self-cleaning. One click.
- **Stress Test** — `scripts/stress-test-data.apex` creates a Quote with 15 products, each with a product image. Validates zero-heap image rendering at scale.
- **Amanda-Friendly Naming** — All labels use plain English: "Opportunity Products" not "OpportunityLineItems", "Your Document Structure" not "Relationship Map", "Include parent fields" not "Add parent above".

## v1.5.0
- **Command Hub** — Single-tab UX replacing 7 tabs. Wizard-first onboarding, embedded bulk generator, contextual help.
- **Deep Grandchild Relationships** — Multi-level query stitching: Account → Opportunities → Line Items → Schedules. One SOQL per level, stitched in Apex. Query builder UI supports "Add Related List" inside child cards.
- **Signature Feature Removed** — E-signatures carry legal requirements a doc gen tool should not implement. Use dedicated providers (DocuSign, Adobe Sign).
- **Custom Font Upload Removed** — `Blob.toPdf()` does not support CSS `@font-face` (confirmed via data URIs, static resources, and ContentVersion URLs). PDF supports Helvetica, Times, Courier, Arial Unicode MS. DOCX preserves template fonts.
- **Font Documentation** — PDF font limitations documented. DOCX recommended for custom fonts.
- **DOCX Download Only** — Save to Record removed for DOCX output (Aura 4MB payload limit). Download works for any size.

## v1.3.4
- **Zero-Heap PDF Images** — `{%ImageField}` tags skip blob loading for PDF; images resolved by URL with zero heap cost
- **Pre-Decomposed Templates** — Template XML stored as ContentVersions on save; PDF generation skips ZIP decompression (~75% heap reduction)
- **PDF Image Fix** — Relative Salesforce URLs for `Blob.toPdf()` compatibility
- **Bold Space Fix** — Preserved whitespace between adjacent bold merge fields
- **Encoding Fix** — `&` no longer double-encoded in PDF output
- **Documentation Overhaul** — Release Update visibility, query builder limits, troubleshooting, known limitations table
- **Rich Text Fields** — Bold, italic, paragraph structure, and embedded images preserved in Word and PDF output

## v1.2.2
- **Admin Guide** — Data Model section with object reference tables
- **Page Layouts** — Added layouts for all custom objects

## v1.2.0
- **Unified PDF Generation** — Single code path for single and bulk PDF. -766 lines of duplicated logic.
- **Spring '26 Blob.toPdf() Compatibility** — Native rendering with Release Update, VF fallback without
- **Page Break Fix** — `page-break-inside: avoid` on paragraphs and list items

## v1.1.1
- **PDF Renderer** — Full DOCX style conversion: headings, lists, line spacing, page breaks, borders, shading, hyperlinks, superscript/subscript, tables
- **Merge Fields** — `{!Field}` Salesforce-style syntax and base object prefix stripping
- **Query Parser** — Auto-splits fields from adjacent subqueries

## v1.1.0
- **Admin Guide** — In-app guide covering all features
- **Version Preview** — Query display, template download, sample generation
- **Security** — `Security.stripInaccessible()`, sanitization hardening, error genericization

## v1.0.0
- **Server-Side PDF** — All generation via `DocGenHtmlRenderer` + `Blob.toPdf()`. Zero client-side JavaScript.
- **Security** — API v66.0, CRUD/FLS enforcement

## v0.9.x
- PKCE Auth Fix, wizard UX improvements, credential provisioning

## v0.8.0
- Fixed package uninstall blockers, updated terminology

## v0.7.0 and earlier
- Bulk PDF generation, transaction finalizers, security hardening, compression API migration, rich text support, 2GP package
