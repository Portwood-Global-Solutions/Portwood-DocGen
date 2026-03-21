# CLAUDE.md — SalesforceDocGen Project Guidelines

## Critical: Blob.toPdf() Image URL Rules

The Spring '26 `Blob.toPdf()` rendering engine has strict requirements for image URLs in HTML:

- **MUST use relative Salesforce paths**: `/sfc/servlet.shepherd/version/download/<ContentVersionId>`
- **NEVER use absolute URLs**: `https://domain.com/sfc/servlet.shepherd/...` — fails silently (no exception, broken image)
- **NEVER use data URIs**: `data:image/png;base64,...` — not supported, renders broken

In `DocGenService.buildPdfImageMap()`, do NOT prepend `URL.getOrgDomainUrl()` to ContentVersion download URLs. Keep them relative. The `Blob.toPdf()` engine resolves relative Salesforce paths internally.

## Critical: Zero-Heap PDF Image Rendering

For PDF output, `{%ImageField}` tags with ContentVersion IDs MUST skip blob loading. The `currentOutputFormat` static variable is set to `'PDF'` before `processXml()` calls. In `buildImageXml()`, when `currentOutputFormat == 'PDF'` and the field value is a ContentVersion ID (`068xxx`), query only `Id, FileExtension` (NOT `VersionData`) and store the relative URL. This is what enables unlimited images in PDFs without heap limits.

**NEVER** add `VersionData` to the SOQL query in the PDF path. Each image blob would consume 100KB-5MB+ of heap, and with multiple images this immediately exceeds governor limits.

## PDF Image Pipeline

### How template images are prepared (on save)

When an admin saves a template version (via `DocGenController.saveTemplate()`), the system calls `DocGenService.extractAndSaveTemplateImages(templateId, versionId)`. This method:

1. Downloads the DOCX/PPTX ZIP from the template's ContentVersion
2. Reads `word/_rels/document.xml.rels` to find all `<Relationship>` entries with `Type` containing `/image`
3. For each image relationship, extracts the image blob from `word/media/`
4. Saves each image as a new ContentVersion with `Title = docgen_tmpl_img_<versionId>_<relId>` and `FirstPublishLocationId = versionId`

This pre-extraction is essential — it creates committed ContentVersion records that `Blob.toPdf()` can reference by relative URL at generation time.

### How template images are rendered (on generate)

At PDF generation time, `buildPdfImageMap()` queries for these pre-committed CVs:
- Finds the active template version
- Queries `ContentVersion WHERE Title LIKE 'docgen_tmpl_img_<versionId>_%'`
- Builds relative URLs: `/sfc/servlet.shepherd/version/download/<cvId>`
- `DocGenHtmlRenderer.convertToHtml()` embeds these as `<img src="/sfc/...">` in the HTML
- `Blob.toPdf()` resolves the relative paths and renders the images

## Package Info

- Package type: Unlocked 2GP (no namespace)
- DevHub: `namespace-org` (davemoudy398@agentforce.com)
- Default target org: `DevOrg - 398`
- Namespace `docgensig` is registered on `DocGen - DevOrg` but linking to DevHub is blocked (OAuth redirect_uri_mismatch)

## Key Architecture

- PDF rendering has two paths in `mergeTemplate()`:
  1. **Pre-decomposed (preferred)**: Loads XML parts from ContentVersions saved during template version creation. Skips ZIP decompression entirely. ~75% heap savings. Used for PDF output when XML CVs exist.
  2. **ZIP path (fallback)**: Full base64 decode + ZIP decompression. Used for DOCX/PPTX output, or PDF when pre-decomposed parts don't exist (older templates not yet re-saved).
- After merge: `buildPdfImageMap()` → `DocGenHtmlRenderer.convertToHtml()` → `Blob.toPdf()` with VF page fallback
- Signature PDFs use `Blob.toPdf()` exclusively (Automated Process user cannot access VF pages)
- The Spring '26 Release Update "Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations" is REQUIRED

## Client-Side DOCX Assembly (In Progress)

DOCX generation now uses client-side ZIP assembly to avoid Apex heap limits:

### How it works
1. Server calls `generateDocumentParts()` which merges XML using `currentOutputFormat='PDF'` trick (skips blob loading)
2. Server returns: `allXmlParts` (merged XML + passthrough entries), `imageCvIdMap` (mediaPath → CV ID), `imageBase64Map` (template media)
3. Client deduplicates CV IDs and calls `getContentVersionBase64()` for each **unique** CV — each call gets fresh 6MB heap
4. Client builds ZIP from scratch via `buildDocx()` in `docGenZipWriter.js` (pure JS, no dependencies)
5. Download works for unlimited size. Save-to-record blocked by Aura 4MB payload limit (needs chunking or alternative).

### Key files
- `docGenRunner/docGenZipWriter.js` — Pure JS ZIP writer (store mode, CRC-32). Exports `buildDocx(xmlParts, mediaParts)` and `buildDocxFromShell()`
- `DocGenService.generateDocumentParts()` — Returns merged parts without ZIP assembly
- `DocGenController.getContentVersionBase64()` — Returns single CV blob as base64, each call = fresh heap
- `DocGenController.generateDocumentParts()` — AuraEnabled endpoint

### Important: rels XML must include ALL image relationships
In both `mergeTemplate()` (full ZIP path, ~line 174) and `tryMergeFromPreDecomposed()` (~line 293), the pending images loop that adds relationships to rels XML must process ALL images, not just ones with blobs. URL-only images need rels entries too for DOCX.

### LWS Constraints
- Lightning Web Security blocks `fetch()` to `/sfc/servlet.shepherd/` URLs (CORS redirect to `file.force.com`)
- All binary data must be returned via Apex, not client-side fetch
- `Blob` constructor in LWC rejects non-standard MIME types — use `application/octet-stream` for DOCX downloads

## Next Priority: Signature Flow Without DOCX

The signature flow should go: **template → stamp signatures into XML → PDF** without ever creating an intermediate DOCX:

1. Signer completes signature → signature image saved as ContentVersion (already works)
2. Server loads pre-decomposed document.xml from template CVs (already works)
3. **NEW: `stampSignaturesInXml(documentXml, relsXml, contentTypesXml, signers)`** — replaces `{#Signature_Role}` placeholders with DrawingML referencing signature image CVs. Returns stamped XML strings, NOT a ZIP.
4. Render PDF: stamped XML → `DocGenHtmlRenderer.convertToHtml()` → `Blob.toPdf()` with relative CV URLs for signature images (already works)
5. Save signed PDF to record (already works)

This eliminates the DOCX intermediate entirely. No ZIP decompress/recompress. No heap issues. The existing `stampAllSignaturesToBlob()` in `DocGenSignatureService.cls` has the placeholder replacement logic — extract the string operations and skip the ZIP parts.

## Scratch Org for Testing

- Alias: `docgen-stress` (expires ~2026-03-28)
- Account: `001Ff00000MDKqsIAH` ("Stress Test Corp") — 500 Contacts, 1 Opportunity
- Template: "Stress Test - Large PDF" — programmatic DOCX with `{%Description}` image + Contact loop with `{%Title}` images
- Test image CV: `068Ff000006MHefIAG` (1.3MB PNG "Design") — stored in Account.Description and first 15 Contacts' Title field
- Release Update enabled

## AppExchange

DocGen is NOT on the AppExchange. Do not reference AppExchange in user-facing documentation (admin guide, README). Code comments saying "AppExchange safe" (meaning no callouts/session IDs) are fine.
