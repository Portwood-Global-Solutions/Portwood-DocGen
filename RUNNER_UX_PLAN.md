# Runner UX Plan — 1.47.0

**Goal:** Reduce template-list noise. Today every user sees every template for the matching object type. We add (1) per-record specificity, (2) category/sort visibility controls, (3) output-format override, and (4) audience visibility (executives see X, reps see Y).

**Non-goals:** Rewriting the runner. Changing how merge works. Changing the merge tag syntax.

---

## Feature 1 — Per-record templates

**Use case:** Company A has its own contract templates ("Company A — No signature", "Company A — Signature"). Should only appear when running on Company A.

**Schema add on `DocGen_Template__c`:**

- `Specific_Record_Ids__c` — LongTextArea(32k). Comma-separated 18-char Ids. Empty = applies to all records of the base object. Non-empty = appears only when runner is on one of the listed records.

**Runner filter logic in `getTemplatesForObject(objectApiName, recordId)`:**

```
WHERE Base_Object_API__c = :objectApiName
  AND (Specific_Record_Ids__c = null OR Specific_Record_Ids__c LIKE :('%' + recordId18 + '%'))
```

Always normalize the incoming `recordId` to its 18-char form before the LIKE. 18-char Salesforce Ids don't substring-match each other in practice — case-sensitive, full-entropy chars — so the `LIKE '%id%'` is safe across a comma-sep list.

**Admin UX for the field:** plain LongTextArea entry, one Id per comma. Future polish: a custom LWC editor on the template manager that resolves Ids to record names + lets admins pick from a lookup. Out of scope for v1.

**Why comma-separated text, not junction:**

- One field, one DML, no new object.
- Many records per template without the relational overhead.
- Acceptable cost: no foreign-key cascade on record delete (orphaned Ids sit in the field; harmless — they just don't match anything).

**Bulk runner caveat:** template selection happens once, before iteration. Filter at template-pick time using the bulk job's source record (the saved-query owner / bulk parent), NOT per-row at runtime. Per-row filtering would silently skip records — confusing.

**Edge case:** if `Specific_Record_Id__c` points to a deleted record, the template becomes invisible. Silent for v1; admins clean up via the template manager. Future enhancement: surface a "broken link" badge.

---

## Feature 2 — Category browsing + explicit sort

**Use case:** Long template lists are hard to scan. `Category__c` field exists today but is unused at runtime.

**Schema add on `DocGen_Template__c`:**

- `Sort_Order__c` — Number(18, 0). Lower = higher in list. Null = falls back to existing `Is_Default__c` DESC, `Name` ASC.

**Runner UI in `docGenRunner`:**

- New "Category" dropdown above the template picker. Auto-populates from distinct `Category__c` values on the visible templates. Defaults to "All".
- "All" view groups templates by Category visually (sections with counts: "Quotes (3)", "Onboarding (2)").
- Selecting a specific category filters to flat list.
- `Is_Default__c=true` templates get a star icon and float to top within their group.

**Auto-populated vs. picklist:**

- Start auto-populated. Free-text `Category__c`. Risk: typos create lookalikes ("Quote" vs. "Quotes"). Mitigation: convert to picklist in 1.48 if it gets messy. Picklist later is non-breaking.

**SOQL ORDER:**

```
ORDER BY Sort_Order__c ASC NULLS LAST, Is_Default__c DESC, Name ASC
```

---

## Feature 3 — Output format override at runtime

**Use case:** Today `Output_Format__c` is locked to the template. To support both DOCX and PDF for one logical template, admins clone the template — duplication.

**Schema add on `DocGen_Template__c`:**

- `Lock_Output_Format__c` — Checkbox, default `false`. If `true`, runner hides the format picker and forces template's `Output_Format__c`. For compliance cases where the format is contractually fixed.

**Runner UI:**

- New "Output as" radio. Defaults to template's `Output_Format__c`. Allowed values constrained by template type:
    - Word template → Word DOCX, PDF
    - PowerPoint template → PPTX only (radio greyed out)
- Hidden when `Lock_Output_Format__c = true` or in the signature sender flow (signatures always PDF).

**API change:**

- `DocGenController.processAndReturnDocument(tmplId, recordId)` → add optional `String outputFormatOverride` parameter, defaulting to null (use template setting). Validates compatibility — throws `DocGenException` for PowerPoint→PDF.
- `generatePdf(tmplId, recordId, save)` stays as a convenience wrapper.
- `DocGenFlowAction.generateDocument` invocable: add optional `Output Format Override` input.
- `DocGenBulkController.submitJob` and `DocGenBulkFlowAction`: add optional override.

**Backward compatibility:** all existing callers omit the new parameter; behavior unchanged. Signature flow ignores it (always PDF).

---

## Feature 4 — Audience visibility

**Use case:** "Executives see X templates only, sales reps see Y. Don't show sales reps the executive contract templates."

**Schema add on `DocGen_Template__c`:**

- `Required_Permission_Sets__c` — LongTextArea(32k). Comma-separated permission set API names. Empty = visible to all DocGen users. Non-empty = visible to users assigned to ANY of the listed permission sets (OR semantics).

**Runner filter logic:**

1. At start of `getTemplatesForObject`, query the running user's permission set names once: `[SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE AssigneeId = :UserInfo.getUserId()]` → `Set<String> userPermSets`.
2. SOQL pre-filter: pull all templates matching object/record filter regardless of perm set.
3. In-memory filter: keep template if `Required_Permission_Sets__c == null` OR any name in the comma-split list is contained in `userPermSets`.

In-memory filter (vs. dynamic SOQL with chained `LIKE`s) keeps the SOQL simple and predictable, and the result set is bounded by the object/record filter so the in-memory step is cheap.

**Admin workflow:**

1. Create one or more permission sets (e.g., `DocGen_Executive_Templates`, `DocGen_Finance_Templates`). They need no specific permissions — purely "audience tags".
2. Assign perm sets to the right users.
3. On each restricted template, set `Required_Permission_Sets__c = 'DocGen_Executive_Templates,DocGen_Finance_Templates'` (any-of) — or just one for single-audience templates.
4. Sales reps without any matching perm set won't see those templates anywhere — runner, bulk, signature sender, Flow.

**Why comma-separated, not junction:**

- Same rationale as `Specific_Record_Ids__c`: one field, no new object.
- Any-of semantics covers the realistic "executives or finance" case.
- All-of semantics ("must have BOTH") deferred — vanishingly rare ask. If needed later, add `Required_Permission_Sets_All__c` as a sibling field. Non-breaking.

**Why permission set, not profile:**

- Profiles are 1:1 with users. Permission sets are N:M. Real orgs use permission sets to layer access — fits Salesforce-native patterns.
- Permission set names are unique per org, stable, and don't change when users move teams.
- Composes with existing `DocGen_Admin` / `DocGen_User` perm sets.
- Subscribers create their own perm sets — package ships no opinionated audience perm sets.

**Why not OWD/sharing:**

- Switching to `USER_MODE` everywhere is a big behavior shift. Existing customers' templates would suddenly become invisible to anyone not the owner.
- Sharing rules can't be packaged — every subscriber would have to set up rules manually.
- Permission-set-based filter is fully self-contained in the package.

**Required_Permission_Set\_\_c does NOT enforce CRUD/FLS** — that's still gated by the existing DocGen perm sets. This is purely a runtime visibility filter for template selection. Anyone with raw DocGen object access could still see them in a SOQL query — but that's true of any record visibility built on a field filter (Design D / native sharing is the only "hard" enforcement). For the asked use case (UX noise reduction + role-appropriate template menus) this is sufficient.

**Bulk + Flow:** same filter applies. Templates the running user can't see don't appear as options.

---

## Schema summary — new fields on `DocGen_Template__c`

| API name                      | Type              | Purpose                                                      |
| ----------------------------- | ----------------- | ------------------------------------------------------------ |
| `Specific_Record_Ids__c`      | LongTextArea(32k) | Comma-sep 18-char Ids — per-record template binding (any-of) |
| `Sort_Order__c`               | Number(18,0)      | Explicit sort position                                       |
| `Lock_Output_Format__c`       | Checkbox          | Force template's format, hide picker                         |
| `Required_Permission_Sets__c` | LongTextArea(32k) | Comma-sep perm set names — audience visibility (any-of)      |

**Permission set updates:** all four fields added to `DocGen_Admin` (CRUD), `DocGen_User` (Read/Edit on non-required ones, Read-only on `Required_Permission_Set__c`), `DocGen_Guest_Signature` (no access — guests don't manage templates).

---

## Apex changes

### `DocGenController`

1. `getTemplatesForObject(String objectApiName)` → `getTemplatesForObject(String objectApiName, Id recordId)`. Old signature kept as overload calling new with `recordId=null` (no per-record filter applied).
2. New helper `private static Set<String> getCurrentUserPermSetNames()` — single SOQL on `PermissionSetAssignment WHERE AssigneeId = :UserInfo.getUserId()`.
3. `processAndReturnDocument(tmplId, recordId)` → add optional `outputFormatOverride` param. Validates compatibility before delegating to `DocGenService.generateDocument`.

### `DocGenService`

1. `generateDocument(Id templateId, Id recordId)` → `generateDocument(Id templateId, Id recordId, String outputFormatOverride)`. Old signature stays as overload.
2. `mergeTemplate` reads template's `Output_Format__c`. Use `outputFormatOverride` if non-null and valid; else template's value.

### `DocGenSignatureSenderController`

1. `getDocGenTemplates()` → apply audience filter + per-record filter (using `relatedRecordId`). New signature: `getDocGenTemplates(Id relatedRecordId)`. Old kept for any callers that pass null.
2. Output format override: not exposed (signatures always PDF).

### `DocGenBulkController.getBulkTemplates()`

1. Apply audience filter only (per-record doesn't apply — bulk has no single record).
2. Output format override: pass through `submitJob` to per-row generation.

### `DocGenFlowAction.generateDocument`

1. Add `Output Format Override` input variable, optional.
2. Per-record filtering: applied from the input record Id. Audience filter from the running Flow user.

---

## UX changes — `docGenRunner` LWC

- New section above template list:
    - "Category" dropdown (auto-populated, defaults to "All")
- Template list:
    - Group-by-category headers when "All"
    - Star icon on `Is_Default__c=true`
    - Templates sorted per new ORDER
- Below selected template, before Generate button:
    - "Output as" radio (PDF / DOCX / PPTX as appropriate)
    - Hidden if `Lock_Output_Format__c = true`
- Empty-state text:
    - "No templates available for this record. Check Permission Set assignments or Specific Record Id on your templates." — when filtering produces zero results.

---

## Test plan

**New unit tests in `DocGenControllerTests`:**

- `getTemplatesForObject_perRecordFilter` — template with `Specific_Record_Ids__c='id1,id2,id3'` appears for `id2` but not `id4`; null shows for all
- `getTemplatesForObject_permSetFilter` — user assigned PermSet A sees templates with `Required_Permission_Sets__c='PermSetA'` AND `'PermSetB,PermSetA'` AND null; user without any sees only null
- `getTemplatesForObject_recordIdSubstring_safety` — verify two unrelated 18-char Ids don't substring-match
- `getTemplatesForObject_sortOrder` — Sort_Order**c ASC NULLS LAST honored before Is_Default**c
- `processAndReturnDocument_outputOverride_wordToPdf` — Word template + override='PDF' → PDF blob
- `processAndReturnDocument_outputOverride_powerpointToPdf_throws` — PPT + override='PDF' → DocGenException
- `processAndReturnDocument_outputOverride_lockedTemplate_throws` — Lock_Output_Format\_\_c=true + override given → DocGenException

**New integration test:**

- `runnerEndToEnd_filteredAndOverridden` — set up 4 templates (specific/general × locked/unlocked), simulate runner load for a user with one perm set, verify only the right 2 appear, override one's format, verify generated blob matches.

**Existing tests:** all 928 must continue passing. Sender/bulk/flow tests get new param defaulting to null.

---

## Migration & backward compat

- All four new fields are nullable / default-falsy. Existing templates show identical behavior at runtime — no admin action required.
- Old `getTemplatesForObject(String objectApiName)` overload is kept (delegates to new with `recordId=null` → no per-record filtering). Subscriber custom code continues to compile.
- Old `processAndReturnDocument(tmplId, recordId)` overload kept.
- Permission set delta: NEW field permissions added to all three sets. Subscribers receive them on upgrade.

---

## Risks & open questions

1. **`Specific_Record_Ids__c` LIKE-on-LongTextArea performance.** SOQL `LIKE` on a LongTextArea is a non-indexed scan. Acceptable for typical org template counts (dozens to low hundreds). If a real customer pushes past ~5k templates, revisit (junction object or formula-based index field).
2. **`Required_Permission_Sets__c` enforcement is soft.** Runtime UI filter, not native sharing. Anyone with raw object access could still query a "hidden" template via SOQL. Acceptable for use case (noise reduction). If a customer needs hard enforcement, they need native Salesforce sharing (separate future item).
3. **Category typo drift.** Auto-populated dropdown means "Quote" + "Quotes" appear as two categories. Mitigation: monitor; if it gets messy in real orgs, promote to picklist in 1.48.
4. **Bulk + Flow per-record filter semantics.** Bulk picks one template up front; per-row record-binding doesn't apply. Flow with record context: filter applies based on input record. Documented above; revisit if testers hit confusion.
5. **Output override + signatures.** Signatures need PDF for stamping. Override hidden in signature flows, ignored in Apex API for signature-related entry points. Documented above.

---

## Order of operations

```
1. Schema — add 4 fields + permission set updates
2. Apex — getTemplatesForObject(objectApiName, recordId), getDocGenTemplates(relatedRecordId), getCurrentUserPermSetNames helper
3. Apex — processAndReturnDocument outputFormatOverride param, generateDocument override param
4. Apex tests — 6 new unit tests + 1 integration test
5. LWC — docGenRunner: category dropdown, sort, output picker, empty state
6. LWC — docGenSignatureSender: pass relatedRecordId to getDocGenTemplates
7. Flow invocables — add Output Format Override input
8. Manual smoke — full runner UX in scratch
9. Apex test gate (RunLocalTests) — must pass at ≥75%
10. Code analyzer gate — 0 High/Critical
11. Package 1.47.0 + promote
12. Push install URL to ElFuma + Matt
```

Estimated: half day to full day of focused work depending on LWC polish.
