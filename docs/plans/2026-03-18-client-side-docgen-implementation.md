# Client-Side DOCX Generation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add opt-in client-side DOCX generation to `docGenRunner` that assembles ZIP files in the browser, bypassing Apex heap limits.

**Architecture:** Apex calls existing `mergeTemplate()` and returns processed XML strings + base64-encoded media — but never assembles a ZIP. The LWC receives this payload, fetches no additional images (injected images already resolved via `resolvedImages` map — same pattern as today), and assembles the final DOCX ZIP using a pure JS ZIP writer in store mode (no compression).

**Tech Stack:** Apex (`DocGenService`, `DocGenController`), LWC (`docGenRunner`), pure JS ZIP writer, Jest unit tests, `@salesforce/sfdx-lwc-jest` for LWC tests.

**Worktree:** `.worktrees/client-side-docgen` on branch `feature/client-side-docgen`

---

## Context: How the Existing Code Works

- `DocGenService.mergeTemplate()` (private) — unzips template, processes XML (loops, conditionals, merge tags), returns a `MergeResult` containing:
  - `processedXmlEntries` — Map<String, String>: the XML files that had merge tags (word/document.xml, headers, footers)
  - `passthroughEntries` — Map<String, Blob>: everything else from the template ZIP (styles, numbering, media files, etc.)
  - `contentTypesXml` — String: `[Content_Types].xml`
  - `relsXml` — String: `word/_rels/document.xml.rels`
  - `relsPath`, `mediaPath` — String paths
  - `docTitle` — String: resolved document title
- `DocGenService.assembleZip()` (private) — takes `MergeResult`, uses `Compression.ZipWriter` to build the final Blob. **This is where heap spikes.**
- `DocGenService.processDocument()` (public) — calls `mergeTemplate()` then `assembleZip()`. The existing server-side path.
- `pendingImages` — static List on `DocGenService`: injected images collected during XML processing. Already has blobs fetched by Apex.
- The LWC already resolves rich-text images and passes them as `resolvedImages` map. This same mechanism is used for client-side path.

---

## Task 1: Add `processDocumentForClient()` to `DocGenService`

**Files:**

- Modify: `force-app/main/default/classes/DocGenService.cls`

**Step 1: Write the failing test in `DocGenTests.cls`**

Open `force-app/main/default/classes/DocGenTests.cls` and add this test at the end of the class (before the closing `}`):

```apex
@isTest
static void testProcessDocumentForClient_returnsPreZipPayload() {
    // Arrange: use existing test infrastructure (look at how other tests create templates)
    // Find the setup method pattern used in DocGenTests and reuse it.
    // The test should:
    // 1. Create a DocGen_Template__c with Type__c = 'Word'
    // 2. Attach a minimal valid DOCX ContentVersion to it
    // 3. Create a test Account record
    // 4. Call DocGenService.processDocumentForClient(templateId, recordId, null)
    // 5. Assert result contains 'xmlParts', 'mediaParts', 'fileName', 'templateType'
    // 6. Assert result.get('templateType') == 'Word'

    // Look at how DocGenTests sets up test data (it has a setupMinimalDocx() or similar helper).
    // Mirror that exact pattern here.
    Account acc = [SELECT Id FROM Account LIMIT 1];
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Type__c = 'Word' LIMIT 1];

    Test.startTest();
    Map<String, Object> result = DocGenService.processDocumentForClient(tpl.Id, acc.Id, null);
    Test.stopTest();

    System.assertNotEquals(null, result, 'Result should not be null');
    System.assert(result.containsKey('xmlParts'), 'Should contain xmlParts');
    System.assert(result.containsKey('mediaParts'), 'Should contain mediaParts');
    System.assert(result.containsKey('fileName'), 'Should contain fileName');
    System.assertEquals('Word', result.get('templateType'), 'templateType should be Word');
}
```

> **Note:** Before writing the test, read the top of `DocGenTests.cls` to understand the `@testSetup` method and test data. Mirror the exact setup pattern used there.

**Step 2: Run test to verify it fails**

```bash
# This runs in your Salesforce org — skip to Step 3 if you don't have an org connected.
# The test will fail at compile time since processDocumentForClient doesn't exist yet.
# Proceed to Step 3.
```

**Step 3: Implement `processDocumentForClient()` in `DocGenService.cls`**

Add this new `public static` method to `DocGenService` immediately after the closing `}` of `processDocument(Id templateId, Id recordId, Map<String, String> resolvedImages)` (around line 290):

```apex
/**
 * Processes a template and returns the pre-zip intermediate data for client-side assembly.
 * The LWC receives XML strings and base64-encoded media, then assembles the DOCX ZIP
 * in the browser — avoiding Apex heap consumption during ZIP assembly.
 *
 * @param templateId  The DocGen_Template__c record ID.
 * @param recordId    The record to merge data from.
 * @param resolvedImages  Optional map of originalUrl → base64DataUri for RTF images (same as processDocument).
 * @return Map containing: xmlParts (Map<String,String>), mediaParts (Map<String,String>), fileName (String), templateType (String)
 */
public static Map<String, Object> processDocumentForClient(Id templateId, Id recordId, Map<String, String> resolvedImages) {
    MergeResult mr = mergeTemplate(templateId, recordId, resolvedImages);

    // Collect all XML parts: processed entries + structural entries + passthrough XML
    Map<String, String> xmlParts = new Map<String, String>(mr.processedXmlEntries);
    if (mr.contentTypesXml != null) {
        xmlParts.put('[Content_Types].xml', mr.contentTypesXml);
    }
    if (mr.relsXml != null) {
        xmlParts.put(mr.relsPath, mr.relsXml);
    }

    // Separate passthrough entries into XML (text) and media (binary)
    Map<String, String> mediaParts = new Map<String, String>();
    for (String path : mr.passthroughEntries.keySet()) {
        Blob entryBlob = mr.passthroughEntries.get(path);
        if (path.startsWith(mr.mediaPath) || path.contains('/media/')) {
            mediaParts.put(path, EncodingUtil.base64Encode(entryBlob));
        } else {
            xmlParts.put(path, entryBlob.toString());
        }
    }

    // Add injected images from pendingImages (collected during XML processing)
    for (Map<String, Object> img : pendingImages) {
        if (img.containsKey('blob')) {
            String fName = (String) img.get('fileName');
            Blob imageBlob = (Blob) img.get('blob');
            mediaParts.put(mr.mediaPath + fName, EncodingUtil.base64Encode(imageBlob));
        }
    }

    return new Map<String, Object>{
        'xmlParts'     => xmlParts,
        'mediaParts'   => mediaParts,
        'fileName'     => mr.docTitle,
        'templateType' => mr.templateType
    };
}
```

**Step 4: Commit**

```bash
git add force-app/main/default/classes/DocGenService.cls force-app/main/default/classes/DocGenTests.cls
git commit -m "feat: add DocGenService.processDocumentForClient() for pre-zip payload"
```

---

## Task 2: Add `generateDocumentDataForClient()` to `DocGenController`

**Files:**

- Modify: `force-app/main/default/classes/DocGenController.cls`
- Modify: `force-app/main/default/classes/DocGenControllerTests.cls`

**Step 1: Write the failing test in `DocGenControllerTests.cls`**

Read `DocGenControllerTests.cls` first to understand the test setup pattern (it has `@testSetup` and `createTestFile()` helper). Add this test at the end of the class:

```apex
@isTest
static void testGenerateDocumentDataForClient_returnsPayload() {
    createTestFile(); // attaches a file to the test template
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

    Test.startTest();
    Map<String, Object> result = DocGenController.generateDocumentDataForClient(tpl.Id, acc.Id, null);
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assert(result.containsKey('xmlParts'), 'Should have xmlParts');
    System.assert(result.containsKey('mediaParts'), 'Should have mediaParts');
    System.assert(result.containsKey('fileName'), 'Should have fileName');
}

@isTest
static void testGenerateDocumentDataForClient_nullTemplateThrows() {
    Test.startTest();
    Boolean threw = false;
    try {
        DocGenController.generateDocumentDataForClient(null, null, null);
    } catch (AuraHandledException e) {
        threw = true;
    }
    Test.stopTest();
    System.assert(threw, 'Should throw AuraHandledException for null templateId');
}
```

**Step 2: Implement the method in `DocGenController.cls`**

Add this method after `processAndReturnDocumentWithImages()` (after line ~104):

```apex
/**
 * Returns the pre-zip document payload for client-side DOCX assembly.
 * The LWC receives XML strings + base64 media and builds the ZIP in the browser.
 * Supports the same resolvedImages pattern as processAndReturnDocumentWithImages.
 */
@AuraEnabled
public static Map<String, Object> generateDocumentDataForClient(Id templateId, Id recordId, Map<String, String> resolvedImages) {
    if (templateId == null) throw new AuraHandledException('Template ID is required.');
    try {
        return DocGenService.processDocumentForClient(templateId, recordId, resolvedImages);
    } catch (AuraHandledException e) {
        throw e;
    } catch (Exception e) {
        System.debug(LoggingLevel.ERROR, 'DocGen: Client-side generation error: ' + e.getMessage());
        throw new AuraHandledException('Error preparing document for client-side generation: ' + e.getMessage());
    }
}
```

**Step 3: Commit**

```bash
git add force-app/main/default/classes/DocGenController.cls force-app/main/default/classes/DocGenControllerTests.cls
git commit -m "feat: add DocGenController.generateDocumentDataForClient() AuraEnabled method"
```

---

## Task 3: Write `docGenZipWriter.js` — Pure JS ZIP Utility

**Files:**

- Create: `force-app/main/default/lwc/docGenRunner/docGenZipWriter.js`
- Create: `force-app/main/default/lwc/docGenRunner/__tests__/docGenZipWriter.test.js`

### ZIP Store Mode Format Reference

A DOCX is a valid ZIP file. "Store mode" means files are embedded uncompressed (compression method = 0). This requires:

- A CRC-32 checksum per file
- Local file headers before each file's data
- A central directory at the end
- An end-of-central-directory record

**Step 1: Write the failing test**

Create `force-app/main/default/lwc/docGenRunner/__tests__/docGenZipWriter.test.js`:

```javascript
import { buildDocx } from "../docGenZipWriter";

describe("buildDocx", () => {
  it("returns a Uint8Array", () => {
    const result = buildDocx({ "word/document.xml": "<xml/>" }, {});
    expect(result).toBeInstanceOf(Uint8Array);
  });

  it("starts with PK ZIP signature", () => {
    const result = buildDocx({ "word/document.xml": "<xml/>" }, {});
    // Local file header signature: 0x04034b50 (little-endian: 50 4B 03 04)
    expect(result[0]).toBe(0x50);
    expect(result[1]).toBe(0x4b);
    expect(result[2]).toBe(0x03);
    expect(result[3]).toBe(0x04);
  });

  it("ends with end-of-central-directory signature", () => {
    const result = buildDocx({ "word/document.xml": "<xml/>" }, {});
    // EOCD signature: 0x06054b50 (little-endian: 50 4B 05 06)
    const len = result.length;
    expect(result[len - 22]).toBe(0x50);
    expect(result[len - 21]).toBe(0x4b);
    expect(result[len - 20]).toBe(0x05);
    expect(result[len - 19]).toBe(0x06);
  });

  it("includes xml file content in output", () => {
    const xmlContent = "<root><child>hello</child></root>";
    const result = buildDocx({ "word/document.xml": xmlContent }, {});
    // Convert to string and check content appears somewhere in the output
    const str = new TextDecoder().decode(result);
    expect(str).toContain(xmlContent);
  });

  it("handles media files (base64 input)", () => {
    // A 1x1 pixel PNG in base64
    const tiny1x1png =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    const result = buildDocx(
      { "[Content_Types].xml": "<Types/>" },
      { "word/media/image1.png": tiny1x1png }
    );
    expect(result).toBeInstanceOf(Uint8Array);
    expect(result.length).toBeGreaterThan(100);
  });

  it("includes all provided xml files", () => {
    const xmlParts = {
      "word/document.xml": "<document/>",
      "word/styles.xml": "<styles/>",
      "[Content_Types].xml": "<Types/>"
    };
    const result = buildDocx(xmlParts, {});
    const str = new TextDecoder().decode(result);
    expect(str).toContain("word/document.xml");
    expect(str).toContain("word/styles.xml");
    expect(str).toContain("[Content_Types].xml");
  });

  it("returns empty-ish zip for no files", () => {
    const result = buildDocx({}, {});
    // At minimum: EOCD record (22 bytes)
    expect(result.length).toBeGreaterThanOrEqual(22);
  });
});
```

**Step 2: Run test to verify it fails**

```bash
cd .worktrees/client-side-docgen
npm test -- --testPathPattern="docGenZipWriter"
```

Expected: `Cannot find module '../docGenZipWriter'`

**Step 3: Implement `docGenZipWriter.js`**

Create `force-app/main/default/lwc/docGenRunner/docGenZipWriter.js`:

```javascript
/**
 * Pure JavaScript ZIP writer (store mode — no compression).
 * No external dependencies. Produces valid DOCX/ZIP archives.
 *
 * Public API:
 *   buildDocx(xmlParts, mediaParts) → Uint8Array
 *
 * @param {Object} xmlParts   - { 'path/file.xml': '<string content>', ... }
 * @param {Object} mediaParts - { 'path/image.png': '<base64 string>', ... }
 * @returns {Uint8Array} ZIP archive bytes
 */

// ---------------------------------------------------------------------------
// CRC-32 Table (standard polynomial 0xEDB88320)
// ---------------------------------------------------------------------------
const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let j = 0; j < 8; j++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[i] = c;
  }
  return table;
})();

function crc32(bytes) {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Encode a string as UTF-8 bytes */
function utf8Bytes(str) {
  return new TextEncoder().encode(str);
}

/** Decode a base64 string to Uint8Array */
function base64ToBytes(b64) {
  const binaryStr = atob(b64);
  const bytes = new Uint8Array(binaryStr.length);
  for (let i = 0; i < binaryStr.length; i++) {
    bytes[i] = binaryStr.charCodeAt(i);
  }
  return bytes;
}

/** Write a 16-bit little-endian value into a DataView */
function writeUint16LE(view, offset, value) {
  view.setUint16(offset, value, true);
}

/** Write a 32-bit little-endian value into a DataView */
function writeUint32LE(view, offset, value) {
  view.setUint32(offset, value, true);
}

/** Concatenate an array of Uint8Arrays into one */
function concat(arrays) {
  const totalLength = arrays.reduce((sum, a) => sum + a.length, 0);
  const result = new Uint8Array(totalLength);
  let offset = 0;
  for (const arr of arrays) {
    result.set(arr, offset);
    offset += arr.length;
  }
  return result;
}

// ---------------------------------------------------------------------------
// ZIP Record Builders
// ---------------------------------------------------------------------------

/**
 * Builds a Local File Header + file data block.
 * Returns { bytes: Uint8Array, crc: number, size: number }
 */
function buildLocalEntry(nameBytes, fileBytes) {
  const crc = crc32(fileBytes);
  const size = fileBytes.length;

  // Local file header: 30 bytes fixed + filename
  const header = new Uint8Array(30 + nameBytes.length);
  const view = new DataView(header.buffer);

  writeUint32LE(view, 0, 0x04034b50); // Local file header signature
  writeUint16LE(view, 4, 20); // Version needed: 2.0
  writeUint16LE(view, 6, 0); // General purpose bit flag
  writeUint16LE(view, 8, 0); // Compression method: STORE
  writeUint16LE(view, 10, 0); // Last mod time
  writeUint16LE(view, 12, 0); // Last mod date
  writeUint32LE(view, 14, crc); // CRC-32
  writeUint32LE(view, 18, size); // Compressed size
  writeUint32LE(view, 22, size); // Uncompressed size
  writeUint16LE(view, 26, nameBytes.length); // File name length
  writeUint16LE(view, 28, 0); // Extra field length

  header.set(nameBytes, 30);

  return {
    bytes: concat([header, fileBytes]),
    crc,
    size
  };
}

/**
 * Builds a Central Directory Entry for a given file.
 */
function buildCentralEntry(nameBytes, crc, size, localOffset) {
  // Central directory entry: 46 bytes fixed + filename
  const entry = new Uint8Array(46 + nameBytes.length);
  const view = new DataView(entry.buffer);

  writeUint32LE(view, 0, 0x02014b50); // Central directory signature
  writeUint16LE(view, 4, 20); // Version made by
  writeUint16LE(view, 6, 20); // Version needed
  writeUint16LE(view, 8, 0); // General purpose bit flag
  writeUint16LE(view, 10, 0); // Compression method: STORE
  writeUint16LE(view, 12, 0); // Last mod time
  writeUint16LE(view, 14, 0); // Last mod date
  writeUint32LE(view, 16, crc); // CRC-32
  writeUint32LE(view, 20, size); // Compressed size
  writeUint32LE(view, 24, size); // Uncompressed size
  writeUint16LE(view, 28, nameBytes.length); // File name length
  writeUint16LE(view, 30, 0); // Extra field length
  writeUint16LE(view, 32, 0); // File comment length
  writeUint16LE(view, 34, 0); // Disk number start
  writeUint16LE(view, 36, 0); // Internal file attributes
  writeUint32LE(view, 38, 0); // External file attributes
  writeUint32LE(view, 42, localOffset); // Offset of local header

  entry.set(nameBytes, 46);

  return entry;
}

/**
 * Builds the End of Central Directory record.
 */
function buildEOCD(entryCount, cdSize, cdOffset) {
  const eocd = new Uint8Array(22);
  const view = new DataView(eocd.buffer);

  writeUint32LE(view, 0, 0x06054b50); // EOCD signature
  writeUint16LE(view, 4, 0); // Disk number
  writeUint16LE(view, 6, 0); // Disk with central directory
  writeUint16LE(view, 8, entryCount); // Entries on this disk
  writeUint16LE(view, 10, entryCount); // Total entries
  writeUint32LE(view, 12, cdSize); // Central directory size
  writeUint32LE(view, 16, cdOffset); // Central directory offset
  writeUint16LE(view, 20, 0); // Comment length

  return eocd;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Assembles a DOCX ZIP from processed XML strings and base64-encoded media files.
 *
 * @param {Object} xmlParts   - { 'word/document.xml': '<xml string>', ... }
 * @param {Object} mediaParts - { 'word/media/img.png': '<base64>', ... }
 * @returns {Uint8Array}
 */
export function buildDocx(xmlParts, mediaParts) {
  const localEntries = []; // Uint8Arrays of local header + data
  const centralEntries = []; // Uint8Arrays of central directory entries
  let offset = 0;

  // Process XML files
  for (const [path, content] of Object.entries(xmlParts)) {
    const nameBytes = utf8Bytes(path);
    const fileBytes = utf8Bytes(content);
    const { bytes, crc, size } = buildLocalEntry(nameBytes, fileBytes);

    centralEntries.push(buildCentralEntry(nameBytes, crc, size, offset));
    localEntries.push(bytes);
    offset += bytes.length;
  }

  // Process media files (base64 → binary)
  for (const [path, b64] of Object.entries(mediaParts)) {
    const nameBytes = utf8Bytes(path);
    const fileBytes = base64ToBytes(b64);
    const { bytes, crc, size } = buildLocalEntry(nameBytes, fileBytes);

    centralEntries.push(buildCentralEntry(nameBytes, crc, size, offset));
    localEntries.push(bytes);
    offset += bytes.length;
  }

  const centralDir = concat(centralEntries);
  const eocd = buildEOCD(localEntries.length, centralDir.length, offset);

  return concat([...localEntries, centralDir, eocd]);
}
```

**Step 4: Run tests to verify they pass**

```bash
npm test -- --testPathPattern="docGenZipWriter"
```

Expected: All 7 tests pass.

**Step 5: Commit**

```bash
git add force-app/main/default/lwc/docGenRunner/docGenZipWriter.js \
        force-app/main/default/lwc/docGenRunner/__tests__/docGenZipWriter.test.js
git commit -m "feat: add pure JS ZIP writer utility for client-side DOCX assembly"
```

---

## Task 4: Update `docGenRunner` LWC

**Files:**

- Modify: `force-app/main/default/lwc/docGenRunner/docGenRunner.js`
- Modify: `force-app/main/default/lwc/docGenRunner/docGenRunner.html`
- Modify: `force-app/main/default/lwc/docGenRunner/docGenRunner.js-meta.xml`
- Create: `force-app/main/default/lwc/docGenRunner/__tests__/docGenRunner.test.js`

**Step 1: Write failing tests**

Create `force-app/main/default/lwc/docGenRunner/__tests__/docGenRunner.test.js`:

```javascript
import { createElement } from "@lwc/engine-dom";
import DocGenRunner from "c/docGenRunner";
import getTemplatesForObject from "@salesforce/apex/DocGenController.getTemplatesForObject";
import generateDocumentDataForClient from "@salesforce/apex/DocGenController.generateDocumentDataForClient";

// Mock Apex methods
jest.mock(
  "@salesforce/apex/DocGenController.getTemplatesForObject",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DocGenController.generateDocumentDataForClient",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DocGenController.processAndReturnDocument",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DocGenController.generatePdfAsync",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DocGenController.checkPdfResult",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DocGenController.saveGeneratedDocument",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const MOCK_TEMPLATES = [
  {
    Id: "001",
    Name: "Test Template",
    Type__c: "Word",
    Output_Format__c: "Document",
    Is_Default__c: true
  }
];

describe("c-doc-gen-runner", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  describe("client-side generation disabled (default)", () => {
    it("does not show client-side badge when enableClientSideGeneration is false", async () => {
      getTemplatesForObject.mockResolvedValue(MOCK_TEMPLATES);
      const el = createElement("c-doc-gen-runner", { is: DocGenRunner });
      el.objectApiName = "Account";
      el.recordId = "acc001";
      el.enableClientSideGeneration = false;
      document.body.appendChild(el);
      await Promise.resolve();

      const badge = el.shadowRoot.querySelector(
        '[data-id="client-side-badge"]'
      );
      expect(badge).toBeNull();
    });
  });

  describe("client-side generation enabled", () => {
    it("shows client-side badge when enableClientSideGeneration is true", async () => {
      getTemplatesForObject.mockResolvedValue(MOCK_TEMPLATES);
      const el = createElement("c-doc-gen-runner", { is: DocGenRunner });
      el.objectApiName = "Account";
      el.recordId = "acc001";
      el.enableClientSideGeneration = true;
      document.body.appendChild(el);
      await Promise.resolve();

      const badge = el.shadowRoot.querySelector(
        '[data-id="client-side-badge"]'
      );
      expect(badge).not.toBeNull();
    });

    it("shows PDF not supported message for PDF output in client-side mode", async () => {
      const pdfTemplates = [
        {
          Id: "002",
          Name: "PDF Template",
          Type__c: "Word",
          Output_Format__c: "PDF",
          Is_Default__c: true
        }
      ];
      getTemplatesForObject.mockResolvedValue(pdfTemplates);
      const el = createElement("c-doc-gen-runner", { is: DocGenRunner });
      el.objectApiName = "Account";
      el.recordId = "acc001";
      el.enableClientSideGeneration = true;
      document.body.appendChild(el);
      await Promise.resolve();

      const warning = el.shadowRoot.querySelector(
        '[data-id="client-side-pdf-warning"]'
      );
      expect(warning).not.toBeNull();
    });

    it("shows PPTX not supported message for PowerPoint in client-side mode", async () => {
      const pptTemplates = [
        {
          Id: "003",
          Name: "PPT Template",
          Type__c: "PowerPoint",
          Output_Format__c: "Document",
          Is_Default__c: true
        }
      ];
      getTemplatesForObject.mockResolvedValue(pptTemplates);
      const el = createElement("c-doc-gen-runner", { is: DocGenRunner });
      el.objectApiName = "Account";
      el.recordId = "acc001";
      el.enableClientSideGeneration = true;
      document.body.appendChild(el);
      await Promise.resolve();

      const warning = el.shadowRoot.querySelector(
        '[data-id="client-side-pptx-warning"]'
      );
      expect(warning).not.toBeNull();
    });
  });
});
```

**Step 2: Run tests to verify they fail**

```bash
npm test -- --testPathPattern="docGenRunner"
```

Expected: Failures because `data-id="client-side-badge"` doesn't exist yet.

**Step 3: Update `docGenRunner.js`**

Read the current `docGenRunner.js` then make these additions:

1. **Add import** at the top (after existing imports):

```javascript
import generateDocumentDataForClient from "@salesforce/apex/DocGenController.generateDocumentDataForClient";
import { buildDocx } from "./docGenZipWriter";
```

2. **Add `@api` property** inside the class (after existing `@api` properties):

```javascript
@api enableClientSideGeneration = false;
```

3. **Add `@track` state** for client-side error (after existing `@track` lines):

```javascript
@track clientSideError = null;
```

4. **Add getter** for unsupported format warning (after `get isGenerateDisabled()`):

```javascript
get isClientSideUnsupported() {
    if (!this.enableClientSideGeneration) return false;
    const selected = this._templateData.find(t => t.Id === this.selectedTemplateId);
    if (!selected) return false;
    const isPDF = selected.Output_Format__c === 'PDF';
    const isPPT = selected.Type__c === 'PowerPoint';
    return isPDF || isPPT;
}

get clientSideUnsupportedReason() {
    const selected = this._templateData.find(t => t.Id === this.selectedTemplateId);
    if (!selected) return '';
    if (selected.Output_Format__c === 'PDF') return 'pdf';
    if (selected.Type__c === 'PowerPoint') return 'pptx';
    return '';
}
```

5. **Replace `generateDocument()`** method entirely with this version that adds the client-side path:

```javascript
async generateDocument() {
    this.isLoading = true;
    this.error = null;
    this.clientSideError = null;

    try {
        const selected = this._templateData.find(t => t.Id === this.selectedTemplateId);
        const templateType = selected ? selected.Type__c : 'Word';
        const isPPT = templateType === 'PowerPoint';
        const isPDF = this.templateOutputFormat === 'PDF' && !isPPT;

        // Client-side path: DOCX only, opt-in
        if (this.enableClientSideGeneration && !isPDF && !isPPT) {
            await this._generateClientSide();
            return;
        }

        // Server-side path (unchanged)
        if (isPDF) {
            this.showToast('Info', 'Generating PDF...', 'info');
            const saveToRecord = this.outputMode === 'save';

            const result = await generatePdfAsync({
                templateId: this.selectedTemplateId,
                recordId: this.recordId,
                saveToRecord: saveToRecord
            });

            if (result.saved) {
                this.showToast('Success', 'PDF saved to record.', 'success');
            } else if (result.base64) {
                const docTitle = result.title || 'Document';
                this.downloadBase64(result.base64, docTitle + '.pdf', 'application/pdf');
                this.showToast('Success', 'PDF downloaded.', 'success');
            }
            this.isLoading = false;
        } else {
            const result = await processAndReturnDocument({
                templateId: this.selectedTemplateId,
                recordId: this.recordId
            });

            if (!result || !result.base64) {
                throw new Error('Document generation returned empty result.');
            }

            const ext = isPPT ? 'pptx' : 'docx';
            const docTitle = result.title || 'Document';

            if (this.outputMode === 'save') {
                this.showToast('Info', 'Saving to Record...', 'info');
                await saveGeneratedDocument({
                    recordId: this.recordId,
                    fileName: docTitle,
                    base64Data: result.base64,
                    extension: ext
                });
                this.showToast('Success', `${ext.toUpperCase()} saved to record.`, 'success');
            } else {
                this.downloadBase64(result.base64, docTitle + '.' + ext, 'application/octet-stream');
                this.showToast('Success', `${isPPT ? 'PowerPoint' : 'Word document'} downloaded.`, 'success');
            }
            this.isLoading = false;
        }
    } catch (e) {
        let msg = 'Unknown error during generation';
        if (e.body && e.body.message) {
            msg = e.body.message;
        } else if (e.message) {
            msg = e.message;
        } else if (typeof e === 'string') {
            msg = e;
        }
        this.error = 'Generation Error: ' + msg;
        this.isLoading = false;
    }
}

async _generateClientSide() {
    try {
        const payload = await generateDocumentDataForClient({
            templateId: this.selectedTemplateId,
            recordId: this.recordId,
            resolvedImages: null
        });

        const docxBytes = buildDocx(payload.xmlParts, payload.mediaParts);
        const fileName = (payload.fileName || 'Document') + '.docx';

        if (this.outputMode === 'save') {
            this.showToast('Info', 'Saving to Record...', 'info');
            // Convert Uint8Array to base64 for saveGeneratedDocument
            const base64 = btoa(String.fromCharCode(...docxBytes));
            await saveGeneratedDocument({
                recordId: this.recordId,
                fileName: payload.fileName || 'Document',
                base64Data: base64,
                extension: 'docx'
            });
            this.showToast('Success', 'Document saved to record.', 'success');
        } else {
            const blob = new Blob([docxBytes], { type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = fileName;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
            this.showToast('Success', 'Document downloaded.', 'success');
        }
        this.isLoading = false;
    } catch (e) {
        let msg = e.body ? e.body.message : (e.message || 'Unknown error');
        this.clientSideError = 'Client-side generation failed: ' + msg;
        this.isLoading = false;
    }
}

handleFallbackToServerSide() {
    this.clientSideError = null;
    // Temporarily bypass client-side for this one generation
    this.enableClientSideGeneration = false;
    this.generateDocument().finally(() => {
        this.enableClientSideGeneration = true;
    });
}
```

**Step 4: Update `docGenRunner.html`**

Read the current HTML then add these sections:

1. **After the opening `<div class="slds-var-p-around_medium">` and before the error block**, add the client-side badge:

```html
<template lwc:if="{enableClientSideGeneration}">
  <div
    data-id="client-side-badge"
    class="slds-badge slds-badge_lightest slds-var-m-bottom_small"
  >
    Client-side generation enabled
  </div>
</template>
```

2. **Add client-side error block** (after the existing error block):

```html
<template lwc:if="{clientSideError}">
  <div
    class="slds-notify slds-notify_alert slds-theme_alert-texture slds-theme_warning"
    role="alert"
  >
    <h2>{clientSideError}</h2>
    <lightning-button
      label="Try server-side generation"
      onclick="{handleFallbackToServerSide}"
      class="slds-var-m-top_x-small"
    >
    </lightning-button>
  </div>
</template>
```

3. **Add unsupported format warnings** inside the `lwc:else` block (after the radio group, before the generate button):

```html
<template lwc:if="{isClientSideUnsupported}">
  <template lwc:if="{clientSideUnsupportedReason}">
    <template lwc:if="{isPdfUnsupported}">
      <p
        data-id="client-side-pdf-warning"
        class="slds-text-color_weak slds-var-m-bottom_small"
      >
        Client-side generation does not support PDF output. Use server-side
        generation for PDF.
      </p>
    </template>
    <template lwc:if="{isPptxUnsupported}">
      <p
        data-id="client-side-pptx-warning"
        class="slds-text-color_weak slds-var-m-bottom_small"
      >
        Client-side generation does not support PowerPoint. Use server-side
        generation for PPTX.
      </p>
    </template>
  </template>
</template>
```

> **Note:** You'll need to add `isPdfUnsupported` and `isPptxUnsupported` getters to the JS:

```javascript
get isPdfUnsupported() { return this.clientSideUnsupportedReason === 'pdf'; }
get isPptxUnsupported() { return this.clientSideUnsupportedReason === 'pptx'; }
```

**Step 5: Update `docGenRunner.js-meta.xml`**

Add the new property inside `<targetConfigs>`. For `lightning__RecordPage` and `lightning__AppPage`, add a new `<targetConfig>` block:

```xml
<targetConfigs>
    <targetConfig targets="lightning__RecordPage,lightning__AppPage">
        <property
      name="enableClientSideGeneration"
      type="Boolean"
      label="Enable Client-Side Generation"
      description="When enabled, DOCX files are assembled in the browser to avoid Apex heap limits. Does not support PDF or PowerPoint output."
    />
    </targetConfig>
    <targetConfig targets="lightning__FlowScreen">
        <property name="recordId" type="String" label="Record ID" />
        <property name="objectApiName" type="String" label="Object API Name" />
    </targetConfig>
</targetConfigs>
```

**Step 6: Run tests**

```bash
npm test -- --testPathPattern="docGenRunner"
```

Expected: All tests pass.

**Step 7: Commit**

```bash
git add force-app/main/default/lwc/docGenRunner/
git commit -m "feat: add opt-in client-side DOCX generation to docGenRunner"
```

---

## Task 5: Fix Pre-Existing `docGenSignaturePad` Test Failure

**Files:**

- Modify: `jest.config.js`

**Context:** The `docGenSignaturePad` component imports `lightning/flowSupport`, which has no Jest stub in `@salesforce/sfdx-lwc-jest`. The test fails with "Cannot find module 'lightning/flowSupport'".

**Step 1: Add module mock to `jest.config.js`**

Read `jest.config.js` first, then update it:

```javascript
const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

module.exports = {
  ...jestConfig,
  modulePathIgnorePatterns: ["<rootDir>/.localdevserver"],
  moduleNameMapper: {
    ...jestConfig.moduleNameMapper,
    "^lightning/flowSupport$":
      "<rootDir>/force-app/test/jest-mocks/lightning/flowSupport.js"
  }
};
```

**Step 2: Create the mock file**

Create `force-app/test/jest-mocks/lightning/flowSupport.js`:

```javascript
export const FlowNavigationNextEvent = class extends CustomEvent {
  constructor() {
    super("navigate");
  }
};
export const FlowNavigationBackEvent = class extends CustomEvent {
  constructor() {
    super("navigateback");
  }
};
export const FlowNavigationFinishEvent = class extends CustomEvent {
  constructor() {
    super("finish");
  }
};
export const FlowNavigationPauseEvent = class extends CustomEvent {
  constructor() {
    super("pause");
  }
};
```

**Step 3: Run all tests**

```bash
npm test
```

Expected: All tests pass, 0 failures.

**Step 4: Commit**

```bash
git add jest.config.js force-app/test/jest-mocks/lightning/flowSupport.js
git commit -m "fix: add lightning/flowSupport Jest mock to resolve test failure"
```

---

## Task 6: Final Verification

**Step 1: Run full test suite**

```bash
npm test
```

Expected: All tests pass, 0 failures.

**Step 2: Run lint**

```bash
npm run lint 2>/dev/null || true
```

Fix any lint errors before proceeding.

**Step 3: Use superpowers:finishing-a-development-branch**

Invoke the `superpowers:finishing-a-development-branch` skill to complete the feature.
