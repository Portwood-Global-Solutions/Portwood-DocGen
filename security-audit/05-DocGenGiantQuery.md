# Security Audit: DocGenGiantQueryAssembler / DocGenGiantQueryBatch / DocGenGiantQueryStitchJob

**Audited**: April 30, 2026
**Scope**: Async giant-query PDF/DOCX pipeline — batch harvester, queueable assembler, stitch job.

## Files

- `force-app/main/default/classes/DocGenGiantQueryAssembler.cls` (Queueable, 1095 lines)
- `force-app/main/default/classes/DocGenGiantQueryBatch.cls` (Database.Batchable + Database.Stateful, 567 lines)
- `force-app/main/default/classes/DocGenGiantQueryStitchJob.cls` (Database.Batchable + Database.Stateful, 318 lines)

## Findings

### 1. Sharing keyword — PASS

All three classes declare `public with sharing`. Inner `DocGenGiantQueryStitchFinalizer` also `with sharing`. No `without sharing` anywhere.

### 2. Execution context — system-level, no per-user FLS persisted (LOG, do not change)

`Database.Batchable` and `Queueable` execute under the user who enqueued (via `Database.executeBatch` from `DocGenController`). However, after enqueue, the job continues even if the original user logs out / loses access — it's the platform Automated-process-style execution.

The classes DO use `WITH USER_MODE` / `AccessLevel.USER_MODE` on most data queries (lines 137, 171, 224, 256 in batch; 879 in assembler). Mixed with `WITH SYSTEM_MODE` for package-internal custom objects (templates, jobs). No "ran-as user Id" is persisted on `DocGen_Job__c`; FLS is checked at SOQL time against whoever runs the batch — which is the enqueuing user.

**This is the same architectural decision as the Flow action audit.** The async transaction does not re-impersonate the original requester at every queueable boundary. Because USER_MODE is in effect for child-record queries, this is mostly safe — a guest or low-permission user cannot escalate via batch — but Dave should confirm whether the design intent is "use the enqueuer's perms forever" vs "snapshot the requester's perms and enforce them across chained jobs." **Logging only — not changing.**

### 3. Heap bounds — PASS

`DocGenGiantQueryAssembler.FRAGS_PER_PASS = 50`. Confirmed against CLAUDE.md ("50 rows per fragment per CLAUDE.md"). `DocGenGiantQueryBatch.batchSize = 50` (line 54). Consistent.

### 4. Dynamic SOQL — relationship name & field list — PARTIAL

- `childObjectName` validated via `Schema.getGlobalDescribe().get(...)` and throws `DocGenException` if missing (line 70).
- `lookupField` previously only `String.escapeSingleQuotes`'d. **Fixed in this audit**: now allowlist-validated against the child schema in both batch constructor and assembler aggregate path.
- `childFields` / `parentFields` (the SELECT list) are NOT schema-validated explicitly. Mitigation: SOQL runs with `AccessLevel.USER_MODE`, so an invalid field name produces a SOQL parse error (no silent bypass) and FLS still enforced. The fields come from admin-curated `Query_Config__c`, never user input — the realistic threat is admin error or upstream injection bug, not external attack.
- `relationshipName` only used as merge-tag matcher (`giantRelationshipName` in `{#Rel}` lookup) — never concatenated into SOQL. Safe.

### 5. Aggregate query — `resolveGiantAggregateTags` — FIXED

Before this audit:

- Regex restricts aggregate field names to `[A-Za-z0-9_]+` and validates against `childFieldMap` (good).
- `childObj` validated by `Schema.getGlobalDescribe()` (good).
- BUT: when V3 fallback runs (4-arg constructor — direct invocation, no batch), `whereCls` was pulled from `Query_Config__c` and concatenated into the aggregate SOQL **without sanitization**. Defense-in-depth gap.

**Fix applied** (assembler line 818-840): the V3 fallback now calls `DocGenDataRetriever.sanitizeWhereClause(whereCls)`. Caught `DocGenException` returns html unmodified rather than running unsafe SOQL.

The 7-arg constructor path (the production batch flow) was already safe because `DocGenGiantQueryBatch.sanitizeWhereClause()` runs on raw config before constructing the assembler.

### 6. Throw-vs-catch consistency — MIXED (LOG)

- Constructor throws `DocGenException` for invalid object/field — backward-compat with existing tests (`testGiantQueryBatchWithInvalidObject`, `testGiantQueryBatchWhereInjectionBlocked`).
- Most runtime errors in `execute()` and `finish()` are caught and update `DocGen_Job__c.Status__c = 'Failed'` with `Label__c = e.getMessage()`.
- `resolveParentMergeTags` and `resolveGiantAggregateTags` swallow exceptions silently and return the html unchanged — tags pass through as literal text. CLAUDE.md acknowledges this ("silent pass-through as literal template text in the PDF").

This is the documented fragility note from CLAUDE.md. Not changing.

### 7. Sequential queueable chaining — replay risk — LOW

`DocGenGiantQueryBatch.finish()` calls `System.enqueueJob(new DocGenGiantQueryAssembler(...))`. If the queueable retries (Salesforce auto-retries on certain platform errors), the assembler would re-process all fragments. Idempotency:

- The assembler queries fragments by `Title LIKE 'docgen_giant_<jobId>_%'` — same set each retry.
- Final PDF insert uses no idempotency key — a retry would create a duplicate PDF CV linked to the record.
- Job status update at end (`Status__c = 'Completed'`) is fine to be applied twice.

**Risk**: minor. A retry creates a duplicate PDF. Mitigation would be to check for existing `_final` CV before inserting. Logging only — Dave's call whether to add idempotency.

### 8. Test.isRunningTest() branches — NONE

Searched both classes — zero `Test.isRunningTest()` branches. Clean.

### 9. Test coverage — STRONG

`DocGenGiantQueryTest.cls` (1283 lines, 38 test methods) covers:

- Batch execution with sorted/unsorted paths
- WHERE clause injection blocked (DML keywords, `;`, `--`, `/*`)
- ORDER BY clause injection blocked
- Invalid object rejection
- Stitch job execution + finalizer
- Assembler invocation via `System.enqueueJob`
- V1 flat config path
- Three-level nested subquery stitch
- Flow action sync/async paths

All 38 tests pass after fixes. Image tag tests (4 assembler invocations) also pass.

## Fixes Applied

### Fix 1: V3 fallback whereCls sanitization in `DocGenGiantQueryAssembler.resolveGiantAggregateTags`

When the 4-arg constructor is used (direct invocation, V3 query config), `whereCls` pulled from `node.get('where')` is now passed through `DocGenDataRetriever.sanitizeWhereClause()` before being concatenated into the aggregate SOQL. Caught `DocGenException` returns `html` unmodified.

### Fix 2: lookupField allowlist validation in `DocGenGiantQueryBatch` constructor

Replaced the bare `Schema.getGlobalDescribe().get(childObjectName)` check with a combined validator that also requires `lookupField` to be a real field on the child object. Throws `DocGenException` on invalid lookupField.

### Fix 3: lookupFld allowlist validation in `DocGenGiantQueryAssembler.resolveGiantAggregateTags`

After child-object Schema lookup, the assembler now rejects any `lookupFld` not present in `childFieldMap`. Returns `html` unmodified rather than running with an unvalidated identifier.

## Test Results

- `DocGenGiantQueryTest`: **38/38 PASS** (29s)
- `DocGenImageTagTests`: **PASS** (4 assembler invocations exercised, 12s)
- `DocGenSignatureTests`: **PASS** (37s) — no regression downstream
- `DocGenMiscTests` (full sync): platform QUERY_TIMEOUT — 327 tests too many for single sync transaction
- `DocGenMiscTests` (targeted giant-query subset, 6 tests): **PASS** (3.3s) — `testGiantQueryAssembler_constructorAndExecuteNoFragments`, `testGiantQueryAssembler_withFragments`, plus 3 Flow-action structure tests

## Blockers / Items For Dave

1. **System-vs-user context decision** (finding #2) — should the async pipeline persist a "ran-as user Id" on `DocGen_Job__c` and re-impersonate at each queueable boundary, or is the current "use enqueuer's perms with USER_MODE" model the intended security posture? Same question as the Flow action audit.
2. **Queueable replay idempotency** (finding #7) — minor risk of duplicate final PDFs on platform retry. Add idempotency check before insert?
3. **Throw-vs-catch consistency** (finding #6) — already in CLAUDE.md fragility list. Cross-cutting cleanup, not in scope here.
