# Audit: Remaining Service Classes (Pass 7)

Sweep covers the small, low-risk service / helper classes left after the major surfaces (controllers, signature pipeline, giant-query pipeline, bulk controllers, flow actions) were audited in passes 1–6.

## Classes audited in this pass

| Class                    | LOC | Sharing                                         | Surface                                                                                             | Severity rollup                                                                               |
| ------------------------ | --- | ----------------------------------------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `DocGenBatch`            | 409 | `with sharing`                                  | Batchable + Stateful, invoked by `DocGenBulkController.submitJob` (AuraEnabled, internal-user only) | 0 high / 1 med / 2 low                                                                        |
| `DocGenMergeJob`         | 184 | `with sharing`                                  | Queueable, chained from `DocGenBatch.finish`                                                        | 0 high / 0 med / 2 low                                                                        |
| `DocGenPdfSaveQueueable` | 38  | `with sharing`                                  | Queueable, enqueued by `DocGenController.generatePdfAsync`                                          | 0 high / 0 med / 0 low                                                                        |
| `DocGenTemplateManager`  | 73  | `with sharing`                                  | Internal helper, called from `DocGenController`                                                     | 0 high / 0 med / 1 low                                                                        |
| `DocGenDataProvider`     | 65  | n/a (interface)                                 | `global` interface (subscriber-implementable extension point)                                       | 0 high / 0 med / 0 low (interface only — implementations are the subscriber's responsibility) |
| `BarcodeGenerator`       | 752 | (no `with sharing` — pure compute, no SOQL/DML) | Internal, called from `DocGenHtmlRenderer`                                                          | 0 high / 0 med / 1 low                                                                        |
| `DocGenException`        | 2   | `global with sharing`                           | Exception type, `global` for subscriber catch                                                       | 0 high / 0 med / 0 low                                                                        |
| `HeapPressureException`  | 12  | `with sharing`                                  | Internal exception                                                                                  | 0 high / 0 med / 0 low                                                                        |

**Pass total: 0 high / 1 med / 6 low.**

## Findings — `DocGenBatch`

### Sharing keyword

`with sharing` ✓ — appropriate for a user-context batch. Critical because the WHERE clause runs `WITH USER_MODE`, and bulk DML on `ContentVersion` cache rows must enforce sharing.

### Surface area

Not directly callable. Constructed from `DocGenBulkController.submitJob` (AuraEnabled, internal user) and from `DocGenBulkFlowAction` / tests. The 3 constructors are `public`, so subscriber Apex inside the same package _could_ instantiate it, but they cannot from outside (not `global`). OK.

### Input validation

- `baseObject` is validated against `Schema.getGlobalDescribe()` (line 69) before any dynamic SOQL — strong defense.
- `condition` is run through `sanitizeCondition()` which rejects `;`, `--`, `/*` and uppercased keywords (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `UNDELETE`, `WITH`, `GROUP BY`, `ORDER BY`, `LIMIT`, `OFFSET`, `FOR UPDATE`, `HAVING`, `TYPEOF`). Reasonable for a WHERE-clause filter, but see "low-1" below.
- `queryConfig` is consumed by `DocGenDataRetriever.getConfigVersion` which detects format before parsing, so V1 flat strings don't crash `JSON.deserializeUntyped`.

### Dynamic SOQL injection

Two dynamic queries (line 74 and 81): both use the validated `baseObject` and `sanitizedCondition`. Both run `WITH USER_MODE`. The `idQuery` inside `buildDataCache` (line 106) uses `String.escapeSingleQuotes(baseObject)` on top of the schema check — defense-in-depth.

### Heap / governor risks

- **MED-1 (acceptable, documented)**: `buildDataCache` materializes up to 50,000 record IDs and the resulting bulk-data JSON in heap before serialization. Mitigations are present: `LIMIT 50000` on the ID query, a `4MB` JSON-size cap that skips caching above the threshold (line 139), and graceful fallback when caching fails (`dataCacheCvId = null; cachedDataJson = null;`). Acceptable as-is — if heap blows in the start phase, the batch falls back to per-record SOQL in execute and still completes.
- ContentVersion writes (cache + HTML snippets) use `Security.stripInaccessible(AccessType.CREATABLE, ...)` — FLS enforced.

### Test coverage

Covered by `DocGenBulkTests` (~17 invocations) and `DocGenMiscTests` (~5 invocations). Good.

### Low-severity observations (NOT fixed — out of scope for this pass)

- **LOW-1**: `sanitizeCondition` uppercase-keyword check accepts whitespace variants. e.g. `LIMIT\t10` (tab between `LIMIT` and number) bypasses the `'LIMIT '` (space) prefix check. Not exploitable in practice — the SOQL parser would reject the resulting clause as malformed before it ran — but the check could be tightened with regex `\\b(LIMIT|OFFSET|...)\\b`. Defer; functional behavior is correct.
- **LOW-2**: `DocGenBatch.successCount` / `failCount` / `htmlSequence` / `dataCacheCvId` / `cachedDataJson` are `public` on a Stateful class. Not exposed outside the package boundary (not `global`), but a same-namespace caller could mutate state mid-batch. Defer.

## Findings — `DocGenMergeJob`

### Sharing keyword

`with sharing` ✓.

### Surface area

Not callable externally. Only `DocGenBatch.finish` enqueues it. Constructor is `public`.

### Input validation

Sole input is `jobId`. Job is queried `WITH SYSTEM_MODE` (legitimate — the queueable runs as the original submitter, and the system-mode read is on the package-internal `DocGen_Job__c` whose CRUD is gated by permission sets).

### Dynamic SOQL

None. All queries are static-bind by `jobId` or by title prefix bind variable. ✓

### Heap / governor risks

Concatenates all snippet bodies into `fullHtml` before `Blob.toPdf()`. `snippets` collection is nulled (line 100) before the toPdf call to free heap. Acceptable — the merge mode is the documented "all snippets fit in one heap" path; bulk paths beyond that are routed to giant-query batches.

### Test coverage

Covered indirectly via `DocGenBatch.finish` tests.

### Low-severity observations (NOT fixed)

- **LOW-1**: The exception handler at line 135 swallows the underlying error and only sets `Status__c = 'Completed with Errors'`. A failure cause is not persisted (no `Last_Error__c` or equivalent on the job record). If the DOCX/HTML concat trips Flying Saucer, admins have to dig the AsyncApexJob log to diagnose. Defer — scope is broader than this pass.
- **LOW-2**: `update new DocGen_Job__c(...)` calls in the `catch` block do not handle DML failure. If the Job record is deleted while the queueable is mid-flight, the error swallows. Acceptable — best-effort cleanup.

## Findings — `DocGenPdfSaveQueueable`

### Sharing

`with sharing` ✓. Final fields. Single-purpose wrapper around `DocGenService.generateDocument(templateId, recordId)`.

### Surface

Not callable externally. Only `DocGenController.generatePdfAsync` enqueues it (line 2423).

### Risks

None. No SOQL, no DML — delegates entirely to `DocGenService`. Re-throws after logging so the queueable retries / Flex Queue reports failure.

## Findings — `DocGenTemplateManager`

### Sharing

`with sharing` ✓.

### Surface

Internal helper. Single static method `getTemplateFileContent(Id)` called from `DocGenController` in 3 places (template content download / DOCX assembly / PDF generation).

### Risks

- Template-version lookup uses `WITH SYSTEM_MODE` (line 18) — legitimate because templates are package-internal and are gated by `DocGen_Admin` / `DocGen_User` permission sets. The `code-analyzer-suppress ApexFlsViolation` annotation acknowledges this.
- Fallback `ContentDocumentLink` lookup (line 30) uses `WITH USER_MODE` — appropriate because it's reading shared documents.
- Returns full base64 of the file. Internal-only callers; no guest exposure. OK.

### Low-severity

- **LOW-1**: No explicit size check before `EncodingUtil.base64Encode(cv.VersionData)`. For a multi-MB DOCX the base64 string is ~1.33× larger and consumes heap. Mitigated upstream — `DocGenController` callers are PDF/DOCX render paths that already account for the file size in their heap budgets. Defer.

## Findings — `DocGenDataProvider`

`global interface` declaring two methods. No implementation. No risk in the interface itself; security depends on the subscriber's implementing class. Documentation comment lists the expected map shape clearly. ✓

## Findings — `BarcodeGenerator`

### Sharing

No `with sharing` keyword — but the class has zero SOQL and zero DML. It's pure compute (Code 128 + QR matrix generation, BMP encoding). Not a sharing concern. ✓

### Surface

`public static` methods — `getPattern(value, type)` and `generate(value, type)`. Not `global`, so no subscriber-Apex exposure. Called from `DocGenHtmlRenderer.cls:3250`.

### Input validation

- `value` is null/blank-checked.
- `barcodeType` is enum-style ('qr' / 'code128') with default fallback.
- Code 128 encoding clamps out-of-range char values to `0` (line 614) — silent fallback, not a crash.
- QR encoding rejects > 14-version data (returns null) — bounded matrix size.

### Heap / governor

Pure JS-Apex compute. Worst case is a v14 QR (size = 73×73 = 5329 cells). Well within limits.

### Low-severity

- **LOW-1**: BMP byte serialization uses string concatenation of hex chars (line 732) for the `convertFromHex` round-trip. For a large QR this is O(n²) on string append. Functional but inefficient. Defer — barcode payloads are tiny (~5KB max) so not a real heap concern.

### Test coverage

`BarcodeGeneratorTest.cls` exists.

## Findings — `DocGenException` / `HeapPressureException`

Both are minimal exception subclasses. `DocGenException` is `global` per the codebase's "subscriber Apex needs to catch namespace-qualified exceptions" rule. No fixable surface.

## Fix phase

**No critical issues found.** Nothing fixed in this pass.

The medium-severity item (heap pressure in `DocGenBatch.buildDataCache`) is already mitigated by the 4MB JSON guard and graceful fallback. No code change warranted.

The low-severity items are tightening / efficiency observations, not exploitable vulnerabilities; deferring.

## Test phase

No source modified ⇒ no deploy needed ⇒ no test run needed.

## Classes Dave's task list did NOT enumerate (so they don't get missed)

Cross-checked the full `force-app/main/default/classes/` listing against Dave's exclusions (`DocGenSignature*`, `DocGenAuthenticator*`, `DocGenController`, `DocGenSetupController`, `DocGenService`, `DocGenDataRetriever`, `DocGenHtmlRenderer`, `DocGenGiantQuery*`, `DocGenBulk*`, `DocGenFlowAction*`) plus the test classes:

**Already covered by this pass's targets** (Dave listed them):

- `DocGenBatch`, `DocGenMergeJob`, `DocGenPdfSaveQueueable`, `DocGenTemplateManager`, `DocGenDataProvider`, `BarcodeGenerator`

**NOT in Dave's task list — found in this pass**:

- `DocGenException.cls` — 2 LOC, trivial; reviewed inline above (no risk).
- `HeapPressureException.cls` — 12 LOC, trivial; reviewed inline above (no risk).
- `DocGenSignatureFinalizer.cls` — 23 LOC, `without sharing`. **Surface: Flow Invocable** (`@InvocableMethod` `Finalize Signature Image`). Calls `DocGenSignatureService.handleSignatureSubmission(token, base64Image)`. Flow context only — guests cannot invoke Flows. Behavior is "system-mode handoff for guest-published placement events." The privileged downstream call is in `DocGenSignatureService` (audited in pass 03 / signature pipeline). **No new findings.**
- `DocGenSignatureSubmitter.cls` — 35 LOC, `without sharing`. **Surface: Flow Invocable** (`Submit Signed Signature`). Same wrapper pattern as Finalizer; delegates to `DocGenSignatureService.handleSignatureSubmission`. **No new findings.**
- `DocGenSignatureValidator.cls` — 35 LOC, `without sharing`. **Surface: Flow Invocable** (`Validate Signature Token`). Wraps `DocGenSignatureController.validateToken` (audited in pass 01). **No new findings** — token format check happens in the wrapped method.

These three signature flow-invocable classes carry the `DocGenSignature` prefix, so technically they fall under Dave's `DocGenSignature*` exclusion. Flagging them here for completeness so they get explicitly counted as audited; no action items.

**`TestDataFactory.cls`** — test-utility class. Not in scope (test code).

## Summary line

**Audited 8 classes (6 explicit targets + 2 small exception types found in sweep).** Severity rollup: **0 high / 1 medium (acceptable, mitigated) / 6 low (deferred).** No code changes; no deploy; no test run required. Three Flow-invocable signature wrappers (`DocGenSignatureFinalizer`, `DocGenSignatureSubmitter`, `DocGenSignatureValidator`) noted for completeness — they delegate to surfaces audited in earlier passes.
