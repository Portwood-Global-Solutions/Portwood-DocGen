# Audit: DocGenService.cls

**File**: `force-app/main/default/classes/DocGenService.cls`
**Lines**: 6,197 (pre-fix) → 6,213 (post-fix)
**Surface**: Internal package service — globals reachable only by subscriber Apex (no AuraEnabled, no @InvocableMethod, no @RemoteAction, no @HttpGet/Post)
**Class declaration**: `global with sharing class DocGenService`

## Posture summary

This is the largest core class in the package and arguably the most surface-rich, but it audits **clean** at the High-severity level. The class is `global with sharing`, has zero AuraEnabled / Invocable / Http annotations, builds zero dynamic SOQL strings (every query is bound), and routes guest-callable signing helpers through `DocGenSignatureController` which already enforces token + PIN gates upstream. The recurring concerns are smaller: a couple of bare DML statements that should match the rest of the file's `Security.stripInaccessible` posture, and one Test.isRunningTest short-circuit that bypasses the full Word→PDF render path under tests.

## Surface inventory

### `global` API (subscriber-Apex contract — never demote)

| Method                     | Signature                                     | Notes                                                                     |
| -------------------------- | --------------------------------------------- | ------------------------------------------------------------------------- |
| `generatePdfBlob`          | `(Id templateId, Id recordId)`                | Returns PDF Blob + title; subscriber download path.                       |
| `generateDocument`         | `(Id, Id)`                                    | Default template settings → ContentDocumentId.                            |
| `generateDocument`         | `(Id, Id, String outputFormatOverride)`       | Subscriber Flow override.                                                 |
| `generateDocument`         | `(Id, Id, String, String documentTitle)`      | Adds title override (Flow input).                                         |
| `generateDocumentFromData` | `(Id, Id, Map preloaded)`                     | Bypasses SOQL via static override (used by bulk).                         |
| `generatePdfBlobFromData`  | `(Id, Map dataMap)`                           | Subscriber Flow can build wrappers + render to PDF blob without recordId. |
| `generateAndSaveFromData`  | `(Id, Id, Map, String)`                       | Combined render+attach.                                                   |
| `generateAndSaveFromData`  | `(Id, Id, Map, String, String documentTitle)` | + title override.                                                         |

All eight are intentionally global per CLAUDE.md ("subscriber Apex needs `generateDocument*` / `generatePdfBlob*` in installed orgs"). All public methods reviewed; none are presently subscriber-call candidates that warrant promotion. Promoting `enqueueTemplateImageExtraction` was considered but template lifecycle is admin-LWC-driven, not subscriber-Apex-driven — skip.

### Public methods (package-internal contract)

Reachable only from sibling `DocGen*` classes within the package (verified by grep across `force-app/main/default/classes/`). No subscriber-promotion candidates.

### Sharing model

- Outer class: `global with sharing` — correct.
- `PreDecompXmlLoader` inner class: `private without sharing` — **justified**. The signature PDF queueable runs as the Automated Process user, which has no `ContentDocumentLink` rows for package-internal pre-decomposed XML CVs. Without `without sharing`, the queueable returns empty XMLs and signed PDFs render with broken table styles (#28). Loader is scoped tightly: only loads `Title LIKE 'docgen_tmpl_xml_<versionId>_%'` (server-derived prefix, not user-supplied), filters happen via the bind. CVs queried are package-metadata, not user data. **Posture acceptable as-is.**

### Dynamic SOQL surface

**Zero**. Every SOQL statement in the file is a bind-variable query (search confirmed: no `Database.query`, `Database.queryWithBinds`, `Database.getQueryLocator`, `String.escapeSingleQuotes`, or `'SELECT '` string concatenation). All dynamic data retrieval is delegated to `DocGenDataRetriever`, which the original `DocGenSignatureController` audit also covered. CxSAST suppressions in this file are exclusively for FLS / SYSTEM_MODE choices, not injection.

### Test.isRunningTest short-circuits

**One**, in `renderPdf()` (line 1695):

```apex
private static Blob renderPdf(MergeResult mr, Id templateId, Id recordId) {
    if (Test.isRunningTest()) {
        lastRenderedHtml = (mr != null && mr.templateType == 'HTML' && ...)
            ? mr.documentXml
            : '<html><body><p>Test PDF</p></body></html>';
        return Blob.toPdf(lastRenderedHtml);
    }
    ...
}
```

**Effect**: Under tests, Word templates **never** exercise `convertToHtml` + `buildPdfImageMap` + watermark / styles application via this entry point. HTML templates do work (the conditional sets `lastRenderedHtml = mr.documentXml`, which is the already-wrapped HTML produced by `mergeHtmlTemplate`). Tests like `DocGenPageSetupTest` only assert margin/size CSS for HTML templates because of this asymmetry.

**Why not removed**: Removing the bypass for Word templates would require the test harness to handle Flying Saucer's render of synthetic XML containing `r:embed="rIdMissing"` references — image fetches would 404, the renderer would throw, and ~50 existing tests across `DocGenMiscTests` / `DocGenGiantQueryTest` rely on this short-circuit returning a stub Blob. Same code-smell shape as the `DocGenSignatureController` pdf-bypass flagged in audit 01. Recommend a future test-seam refactor (e.g., `@TestVisible` static `htmlRendererStub` that callers can set to bypass `convertToHtml` only — not the entire path).

**Status**: Documented; not fixed in this pass.

## Hardening applied in this pass (v1.75)

### 1. `mergeTemplateForGiantQueryPdf` — empty-list NPE guard (MEDIUM)

**Before**: After querying `DocGen_Template__c WHERE Id = :templateId`, the code accessed `templates[0]` without checking emptiness. An invalid templateId (deleted record, wrong Id type, mismatched namespace) caused `ListException: List index out of bounds: 0` instead of a clear DocGenException.

**After**: Added `if (templates.isEmpty()) throw new DocGenException('Template not found: ' + templateId);` to mirror the pattern used elsewhere in the class (e.g., `mergeTemplate`, `validateOutputFormatOverride`). This path is reachable from `DocGenGiantQueryAssembler.buildHtmlTemplate()` and `DocGenController.launchGiantQueryPdfBatch()` — so the guard surfaces a clean error to the LWC instead of an opaque list-index exception.

### 2. `extractAndSaveHtmlTemplateAssets` — bare DML → stripInaccessible (MEDIUM)

**Before**: Three DML statements (lines 5761, 5802, 5808) used `insert`/`update` directly with `// NOPMD ApexCRUDViolation — package-internal; CRUD via DocGen perm sets`. The rest of the file (and the parallel `extractAndSaveTemplateImages` 100 lines above) consistently uses `Security.stripInaccessible(AccessType.CREATABLE, ...)` for ContentVersion inserts. The inconsistency was a Code Analyzer (PMD `ApexCRUDViolation`) and AppExchange security review concern.

**After**: Routed all three DML calls through `Security.stripInaccessible`:

- `imageCvs` insert → `imgDec` decision + `imgDec.getRecords()` insert.
- `htmlCv` insert → `htmlDec` decision + read assigned ID from the returned record list.
- `DocGen_Template_Version__c` update → `updDec` decision + `updDec.getRecords()` update.

The list ordering / record count is preserved by `stripInaccessible` (it strips fields, not records), so the existing `nameToIndex.get(name) → imageCvs[i]` index alignment in step 2 still holds. NOPMD comments updated to "FLS enforced by stripInaccessible" to match the rest of the file.

## Issues observed but NOT fixed in this pass (deferred)

### Test.isRunningTest bypass in `renderPdf` (Test seam smell)

Detail above. ~50 tests depend on the stub. Refactor would need a separate-PR scope: introduce a `@TestVisible` injection seam for `convertToHtml` calls so tests can assert on the actual XML→HTML pipeline for Word templates.

### `lastRenderedHtml` is `public static` (Test instrumentation surface)

Used by 6 test classes for assertion. Subscriber code that reads this static gets implementation details about the last render. Not a security risk (no PII; cleared on next render), but moving to `@TestVisible private` would be cleaner. Skip until other namespace/visibility work warrants the audit cost.

### `generateDocTitle` does not sanitize filename-hostile chars

Resolves `{Field}` tokens directly into the output title. A record `Name = 'Acme/2026'` produces a title containing `/`, which becomes part of the saved file's `Title` and `PathOnClient`. Salesforce ContentVersion accepts these but they render awkwardly in the file viewer. Not exploitable (no path traversal — `PathOnClient` is metadata, not a filesystem path). Cosmetic.

### Bare DML in `DocGenTemplateDecomposeQueueable.execute` (line 1310)

Uses `update v;` with `code-analyzer-suppress ApexFlsViolation`. This is a single field write (`Pre_Decomposition_Status__c`) on a package-internal custom object during async background work. Wrapping in `Security.stripInaccessible(AccessType.UPDATABLE, ...)` is consistent but the existing suppression is correct for the use case. Skip.

### `applyResolvedImages` does not bound recursion depth

Walks user record data recursively. A pathological data map could blow the Apex stack, but the LWC is the only caller of `processDocument(... resolvedImages)` and it builds the map from real Salesforce data, not user-controlled JSON. Skip.

### `imageBase64Map` heap risk

`mergeTemplate` line 427 calls `EncodingUtil.base64Encode(imgBlob)` for **every** template image to populate `mr.imageBase64ByRelId`. CLAUDE.md flags this in the v1.74 hardening notes. A 9 MB DOCX with 5 images can put 45 MB+ of base64 strings into heap. Currently mitigated by the `outputFormat == 'PDF'` early-return path (which uses `tryMergeFromPreDecomposed` and skips this loop). For DOCX output the heap pressure is real but only matters for templates large enough to exhaust 6 MB sync heap; v1.74's async decomposition queueable + `currentOutputFormat = 'PDF'` static cover the practical cases. Skip — separate optimization, not a security finding.

## Test coverage

The class has substantial existing test coverage across:

- `DocGenMiscTests` — ~50 entry points exercising `processXml`, image rendering, format helpers.
- `DocGenHtmlTemplateTest` — HTML template merge + giant-query HTML pipeline.
- `DocGenPageSetupTest` — orientation/size/margin CSS resolution.
- `DocGenGiantQueryTest` — `extractLoopBody`, `renderLoopBodyForRecords`, `mergeTemplateWithPreRenderedLoops`, `mergeTemplateForGiantQueryPdf`.
- `DocGenSignatureFlowActionTest` — `mergeTemplateForSignature` indirectly.
- `DocGenControllerCoverageTest` — global API surface (`generateDocument*`, `generatePdfBlob*`, `generateAndSaveFromData*`).

No new tests added in this pass — both fixes are defensive (NPE guard + DML hardening) and already exercised by existing tests through the call paths that hit them. The empty-template-list branch is intentionally a thrown exception, which is the same shape as the pre-fix `ListException` so existing negative-path tests already cover it (failure mode is "throws" → "throws").

## Status

✅ Two MEDIUM fixes applied and source-deployed to `docgen-security-audit`.
✅ Regression test run complete — **419 / 419 tests pass, 0 fail** across:

- `DocGenHtmlTemplateTest` + `DocGenPageSetupTest` (26 tests)
- `DocGenMiscTests` + `DocGenSignatureFlowActionTest` + `DocGenGiantQueryTest` + `DocGenControllerCoverageTest` (393 tests)
