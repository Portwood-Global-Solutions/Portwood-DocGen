# Audit: DocGenDataRetriever.cls

**File**: `force-app/main/default/classes/DocGenDataRetriever.cls`
**Lines**: 2137 (pre-fix) → 2154 (post-fix)
**Surface**: Internal — invoked by DocGenController, DocGenBulkController, DocGenSignatureSenderController, DocGenGiantQueryAssembler / Batch
**Class declaration**: `public with sharing class DocGenDataRetriever`

## Audit posture

- **Zero `@AuraEnabled`** methods on this class. All callers are server-side. SOQL injection risk is bounded by the trust level of the upstream `Query_Config__c` (template admin / bulk job creator) — but the JSON / V1 flat string is still treated as semi-trusted user input throughout the class.
- **Zero `Test.isRunningTest()`** branches. No bypass logic.
- **All 12 dynamic SOQL invocations** run with `AccessLevel.USER_MODE`, which enforces sharing + FLS for the calling user. No SYSTEM_MODE in this class.
- **Bind variables** for record IDs (`:recordId`, `:parentIds`, `:targetIds`) are typed `Id` / `Set<Id>` — the Apex runtime guarantees these can never carry SOQL syntax.

## SOQL invocations analyzed

| #   | Line | Method                            | Path                    | Defenses                                                                                                                                             |
| --- | ---- | --------------------------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | 139  | `getRecordData` (V1 flat)         | root SELECT             | object via `validateObjectName` (Schema), fields via `validateField` allowlist, escape on object name, USER_MODE                                     |
| 2   | 369  | `getRecordDataV2`                 | root SELECT             | object via `validateObjectName`, fields via `validateFieldList`, junction rels via `resolveChildSchema`, all clauses via `sanitizeClause`, USER_MODE |
| 3   | 473  | `stitchJunctionTargets`           | junction target lookup  | object + fields via `validateField*`, ORDER BY via `sanitizeClause` w/ allowlist, escape on object, USER_MODE                                        |
| 4   | 655  | `getRecordDataV3`                 | tree root SELECT        | per-node `validateObjectName` + `validateFieldList`, escape on object, USER_MODE                                                                     |
| 5   | 775  | `getRecordDataV3Bulk`             | tree root SELECT (bulk) | same as #4                                                                                                                                           |
| 6   | 886  | `processChildNodes`               | child node SELECT       | `validateObjectName` for child, allowlist for fields + lookupField, `sanitizeClause` for WHERE / ORDER BY / LIMIT, USER_MODE                         |
| 7   | 1022 | `processChildNodesBulk`           | bulk child SELECT       | same as #6                                                                                                                                           |
| 8   | 1137 | `stitchJunctionForTree`           | junction target lookup  | `validateObjectName` + `validateFieldList`, USER_MODE                                                                                                |
| 9   | 1586 | `stitchGrandchildren`             | grandchild SELECT       | `validateObjectName` + per-token `validateField`, `sanitizeClause` for clauses, USER_MODE                                                            |
| 10  | 2031 | `scoutFromFlatConfig`             | `COUNT()` per rel       | `cr.getChildSObject()` + `cr.getField()` come directly from `Schema.ChildRelationship` describe — inherently allowlist-trusted, USER_MODE            |
| 11  | 2073 | `scoutFromJsonConfig` (V2 branch) | `COUNT()` per rel       | same as #10 — uses Schema describe                                                                                                                   |
| 12  | 2129 | `scoutFromJsonConfig` (V3 branch) | `COUNT()` per rel       | **gap pre-fix** — see below                                                                                                                          |

## Hardening applied in this pass (v1.75)

### 1. `scoutFromJsonConfig` V3 branch — `lookupField` allowlist gap (HIGH severity in attacker-controlled-config models, MEDIUM in current threat model)

**Before**: V3 nodes' `lookupField` came from `Query_Config__c` JSON and was concatenated into the count query through `String.escapeSingleQuotes` only. The other V3 paths (`getRecordDataV3` / `getRecordDataV3Bulk`) validate `lookupField` against the child object's field map (lines 597–603 / 731–737), but the scout path skipped that validation. `escapeSingleQuotes` does not stop SOQL keyword smuggling in unquoted identifier positions, so a config with `"lookupField": "Id != null OR Name"` would have produced `SELECT COUNT() FROM Contact WHERE Id != null OR Name = :recordId`, which executes (the `Name = :recordId` portion fails type-check at runtime, but the smuggled `Id != null OR` materially altered the query).

**After (lines 2115–2135)**: Resolve child via `globalDescribe.get(childObject)` → call `validateField(lookupField, childFieldMap)` (the same Schema-allowlist routine the rest of the class uses). Unknown / smuggled `lookupField` values now produce a count of `0` for the relationship and never reach `Database.countQuery`. The `whereClause` was already routed through `sanitizeClause('WHERE')`, so its keyword blocklist is unchanged. Comment updated to call out the threat model explicitly.

## Issues observed but NOT fixed in this pass

- **`stitchJunctionTargets` (line 462)** appends `js.targetWhere` to the WHERE clause via `sanitizeClause`, but `js.targetWhere` is set directly from JSON without an additional Schema field-name check. This is consistent with the rest of the V3 path and matches `getSortedChildIds` policy in `DocGenController` — the `sanitizeClause` keyword blocklist is the documented contract here, not full SOQL parsing. Acceptable.
- **`mapSObject` blob field swallow (line 1809)** is a logged-and-skip pattern. Not a security issue; PMD `EmptyCatchBlock` already silenced.
- **`getRecordDataV4`** dynamically resolves an Apex class by name via `Type.forName(...)` (lines 1929–1937). This is a legitimate plugin extension point — the Apex Type system enforces compile-time deployment of the class, so attacker-supplied class names cannot resolve to arbitrary code. Behavior is gated by `DocGenDataProvider` interface check. Acceptable.

## Test coverage

New `DocGenDataRetrieverSecurityTest.cls` (13 tests) added — all pass:

- `v1WhereClauseRejectsInjection` — V1 flat path rejects `;` / `--` / DML
- `v2InvalidBaseObjectRejected` — `validateObjectName` throws on unknown SObject
- `v2BogusFieldsAreDropped` — silent-drop policy verified
- `v3InvalidObjectRejected` — V3 node object validation
- `v3OrderByRejectsBogusField` — V3 ORDER BY allowlist
- `v3WhereClauseRejectsKeyword` — V3 WHERE keyword blocklist
- `v3LimitNonNumericRejected` — V3 LIMIT must be numeric (no semicolon smuggle)
- **`scoutChildCountsRejectsBogusLookupField`** — covers the v1.75 fix; bogus `lookupField` returns 0, never executes
- `scoutChildCountsHappyPath` — legitimate V3 scout still works
- `sanitizeWhereClauseRejectsDml` — public wrapper rejects `;` + DELETE
- `sanitizeWhereClauseRejectsComment` — `/* */` comments rejected
- `sanitizeWhereClauseAcceptsBenign` — benign clause passes
- `whereClauseRejectsNestedSelect` — `SELECT` in WHERE rejected (V2/V3 protect)

## Test phase results

```
DocGenDataRetrieverSecurityTest:  13 / 13 passed
DocGenSignatureTests + DocGenControllerTests + DocGenMiscTests + DocGenGiantQueryTest:
                                837 / 837 passed (Pass Rate 100%)
```

Org: `docgen-security-audit`, Test Run Id `707Nq00007WRrcm`.

## Status

- [x] Source modifications complete and deployed to `docgen-security-audit`
- [x] New security test class deployed and passing
- [x] Full regression suite passing (837/837)
- [x] No existing tests modified — only `DocGenDataRetrieverSecurityTest.cls` (new) added
