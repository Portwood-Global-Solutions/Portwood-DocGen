# DocGen Consolidation Plan — Session N+1

**Goal:** Reduce the engine from five sprawling subsystems into one path per feature. Delete more lines than we add. Coverage reaches 90%+ as a *side effect* of having less code to test, not as the goal.

**Non-goal:** Adding features. Adding abstractions. Rewriting anything.

**Mental model:** Every item below is "there are two things, pick one, delete the other." If you find yourself writing new logic, stop — you're doing it wrong.

---

## 🛑 FEATURE PRESERVATION GUARANTEE — RULE ZERO

**Every single customer-facing feature that works today must still work after this session.** Consolidation is about deleting *duplicate implementations*, not deleting *capabilities*.

Before starting ANY item, ask: "If I complete this, is there a user flow that stops working?" If the answer is yes — or even "maybe" — STOP. Either the consolidation approach is wrong, or a migration path is needed before deletion.

### Feature inventory — must all work after consolidation

**Document generation:**
- [ ] Generate PDF from template (all merge tag types)
- [ ] Generate DOCX from template (images preserved, fonts preserved)
- [ ] Generate PPTX from template
- [ ] Bulk generation over a saved query
- [ ] Save generated doc to record as ContentVersion
- [ ] Download generated doc from LWC
- [ ] All 3 query config formats work (V1 string, V2 JSON, V3 tree) — may be migrated internally but customer's existing `Query_Config__c` strings keep producing identical output
- [ ] Conditional sections `{#if}...{/if}`
- [ ] Child loops `{#Contacts}...{/Contacts}`
- [ ] Image fields `{%Logo}`
- [ ] Currency, date, number formatting tags
- [ ] Multi-object/junction queries
- [ ] Unicode (Arabic, Chinese, Hebrew, emoji) in output

**Signatures:**
- [ ] Create signature request from LWC (`docGenSignatureSender`)
- [ ] Create signature request from Flow (`DocGenSignatureFlowAction`)
- [ ] Create signature request with Signer apex type (new Flow path)
- [ ] Create signature request with legacy parallel lists (backward compat)
- [ ] Both v2 tags `{@Signature_Buyer}` AND v3 tags `{@Signature_Buyer:1:Full}` produce correct signed PDFs
- [ ] Initials, Date, DatePick placement types
- [ ] Guided signing flow (step-by-step)
- [ ] Email verification via PIN
- [ ] Parallel signing order
- [ ] Sequential signing order
- [ ] Document packets (multi-template)
- [ ] Decline flow with reason
- [ ] Resume after leaving (PIN re-verify)
- [ ] Sender notifications (signer completed, all completed, declined)
- [ ] Reminder emails via schedulable
- [ ] Email status diagnostics (`Email_Status__c` populated)
- [ ] OWA-based branded emails with reply-to
- [ ] Guest user can sign without errors
- [ ] Signed PDF attached to related record on completion
- [ ] Signature audit records created
- [ ] Setup validation checklist in settings UI

**Admin:**
- [ ] Create template via `docGenCommandHub`
- [ ] Upload DOCX/PPTX to template
- [ ] Activate template version
- [ ] Detect merge tags from uploaded template
- [ ] Test merge on a record
- [ ] Query builder (both tree UI and manual mode)
- [ ] Permission set assignment flow

**Integration:**
- [ ] Flow invocable: `DocGen: Generate Document`
- [ ] Flow invocable: `DocGen: Create Signature Request`
- [ ] All three permission sets grant correct access

### Hard rule on `global @AuraEnabled` methods

**Do NOT delete any `global` `@AuraEnabled` method** unless the user has explicitly confirmed no subscriber is using it. These are the public API of the package — deleting one breaks installs silently. Mark deprecated, leave the body, plan removal for a major version.

### Verification of feature preservation (per phase)

Before moving to the next phase, execute this manual checklist in the scratch org:

1. **Generate a PDF** from a template with all merge tag types → open PDF, eyeball that every value rendered
2. **Generate a DOCX** from a template with images → open in Word, verify images present
3. **Send a signature request** from LWC → full flow: email → PIN → sign all placements → verify PDF attached
4. **Send a signature request** from a test Flow → same full flow
5. **Use a v2 tag template** from before v1.43 → signs successfully
6. **Use a v3 tag template** with Initials + Date types → all stamped correctly
7. **Trigger a decline** → sender gets notification
8. **Trigger sequential signing** → second signer email sent only after first completes

Any failure here = revert the last commit, reassess.

### Before any deletion — prove the code is dead

For each method / LWC / field you want to delete:

```bash
# 1. Search the entire codebase for references
grep -rn "methodName" force-app/ scripts/

# 2. Check if it's called by any metadata (layouts, flows, lightning pages, email templates)
grep -rn "methodName" force-app/main/default/flows/ force-app/main/default/layouts/ force-app/main/default/flexipages/

# 3. For @AuraEnabled: is it referenced from any LWC / Aura component?
grep -rn "methodName" force-app/main/default/lwc/ force-app/main/default/aura/
```

Three clean searches = safe to delete. Any hit = investigate before deleting.

---

## Ground rules for this session

1. **One consolidation at a time.** Finish-commit-verify before starting the next. Do not batch.
2. **After each consolidation:** run the full Apex test suite + the e2e scripts touched by the change. If anything fails, fix or revert — do not proceed.
3. **No `Test.isRunningTest()` bypasses added.** If a test forces one, restructure instead.
4. **No "legacy" methods kept alive unless they are `@AuraEnabled` on a `global` class.** Those are the only ones that break subscriber installs. Everything else goes.
5. **Deletion target per item: net negative LOC.** If a consolidation adds more lines than it removes, the approach is wrong — rethink.
6. **When in doubt, ask the user.** Do not guess on questions like "is anyone using this legacy method?" — ask.

---

## Verification gates (run after EVERY item)

```bash
# 1. All local tests pass, per-class coverage visible
sf apex run test --target-org docgen-test-ux \
  --test-level RunLocalTests --code-coverage --wait 30

# 2. Relevant e2e scripts (pick the one(s) touching the area you changed)
sf apex run --target-org docgen-test-ux -f scripts/e2e-06-signatures.apex
# ...etc

# 3. Security / AppExchange scanner — must stay at 0 High/Critical
sf code-analyzer run --workspace "force-app/" \
  --rule-selector "Security" --rule-selector "AppExchange" --view table
```

**Stop condition:** if any gate fails, do not proceed to the next item. Fix or revert.

---

## Phase 1 — Signature subsystem consolidation (highest value, most risk)

### Item 1.1 — Collapse the two signature creation paths into one

**Current state:**
- `DocGenSignatureSenderController.createTemplateSignerRequestWithOrder()` — called by `docGenSignatureSender` LWC
- `DocGenSignatureSenderController.createTemplateSignatureRequestForFlow()` — called by `DocGenSignatureFlowAction`

Both do essentially the same thing: insert request → merge template → build preview HTML with placement spans → create signers + placements → send emails. They diverge on:
- Signing order handling
- Whether `injectPlacementSpans()` or `convertToHtml()` is called
- Default `sendEmails` value

**Target state:** ONE shared `private static Result createSignatureRequest(SignatureRequestOptions opts)` method. Both entry points become thin adapters that build an `opts` struct and call it.

**Delete candidates:**
- The divergent body of `createTemplateSignatureRequestForFlow` (keep only the signature + adapter)
- Any duplicated HTML-building code

**Test implications:**
- `DocGenSignatureSenderControllerTest` existing tests must still pass unchanged
- `DocGenSignatureFlowActionTest` existing tests must still pass unchanged
- If any test breaks, the consolidation missed a behavioral difference — investigate, don't just patch the test

**Commit message:** `refactor(signatures): consolidate two creation paths into shared private method`

---

### Item 1.2 — Remove `Test.isRunningTest()` bypass in `DocGenSignatureEmailService`

**Current state:** Line ~48 of `DocGenSignatureEmailService.cls`:
```apex
if (String.isBlank(owaId) && !Test.isRunningTest()) {
    // skip send in tests
}
```

This is a code smell. It prevents the "no OWA configured" branch from being tested, and it means tests can't verify OWA wiring works.

**Target state:** Extract OWA resolution into a `@TestVisible private static String resolveOwaId()` helper. Remove the `Test.isRunningTest()` check. Tests that need to exercise the OWA-missing branch set `resolveOwaIdOverride = ''`; tests that need a "successful" OWA set `resolveOwaIdOverride = 'fake-owa-id'`. Real sends in tests still don't happen (Messaging.sendEmail in test context is a no-op that returns success).

**Delete candidates:**
- The `!Test.isRunningTest()` check itself
- Any test that relied on the bypass to "pass" without asserting anything meaningful

**Test implications:**
- Add one test that asserts `Email_Status__c` is populated with the "no OWA configured" message when OWA is blank
- Add one test that asserts emails were "sent" (use `Limits.getEmailInvocations()`) when OWA is set

**Commit message:** `refactor(signatures): remove Test.isRunningTest bypass in email service`

---

### Item 1.3 — Delete the v2 signature tag fallback in stamping

**Current state:** `DocGenSignatureService.stampSignaturesInXml()` has two code paths:
1. v3: query placements, stamp each with its typed value
2. v2 fallback: replace every `{@Signature_Role}` with the signer's typed name

**Ask first:** Are any active customer templates using v2 tag syntax (`{@Signature_Buyer}` without `:Order:Type`)? Check package install analytics or recent customer support threads. If yes, this item is deferred — we need a migration path first.

**If no customers on v2 tags:**
**Target state:** Only the v3 path remains. At template save, any bare `{@Signature_Role}` tag is auto-rewritten to `{@Signature_Role:1:Full}` so it flows through the v3 placement pipeline.

**Delete candidates:**
- The v2 fallback branch in `stampSignaturesInXml()`
- Any "legacy" comments referring to v2 tags

**Test implications:**
- `e2e-06-signatures.apex` — remove any v2-only assertions
- `e2e-07-syntax.apex` — ensure v3 tag assertions still pass

**Commit message:** `refactor(signatures): delete v2 tag fallback, auto-migrate at template save`

---

### Item 1.4 — Delete the "Document Source" mode from sender LWC (dead-code removal)

**Current state:** `docGenSignatureSender` LWC still has code for the "Existing Document" mode per CLAUDE.md (Phase 1E of the zazzy-dazzling-rossum plan mentioned it but didn't finish the kill). The `@AuraEnabled` methods `createMultiSignerRequest`, `getRelatedDocuments`, `getDocumentSignatureRoles` are still on `DocGenSignatureSenderController` marked deprecated.

**Ask first:** Confirm with user that **no customer Flow or external integration** calls these three Apex methods. They're `@AuraEnabled` on a `global` class — deleting them breaks subscribers if anyone's calling them.

**If confirmed unused:**
**Target state:**
- Delete the three methods entirely from `DocGenSignatureSenderController`
- Delete the corresponding handlers/imports from `docGenSignatureSender.js`
- Delete any related template HTML

**Delete candidates:**
- `createMultiSignerRequest`, `getRelatedDocuments`, `getDocumentSignatureRoles` and their tests
- Any LWC state variables: `documentOptions`, `selectedDocId`, handler methods
- Imports of those three methods in the JS

**Test implications:**
- Remove test methods in `DocGenSignatureSenderControllerTest` for the deleted methods
- Coverage should go UP because we deleted more uncovered code than test code

**Commit message:** `refactor(signatures): remove legacy Document Source mode — dead since v3`

---

## Phase 2 — Merge engine consolidation

### Item 2.1 — Collapse V1 and V2 query config into V3 on template save

**Current state:** `DataRetriever` auto-detects and routes between `getRecordData` (V1 flat string), `getRecordDataV2` (JSON flat with junctions), and `getRecordDataV3` (query tree). Three parsers, three sets of tests, three code paths to maintain.

**Target state:** ONE parser — V3 (`getRecordDataV3`). At template save time, `DocGenController.saveTemplate()` converts V1 and V2 configs to V3 format before persisting. Any template saved going forward is V3.

**Migration handling:**
- Don't force-migrate existing `Query_Config__c` values in the DB — leave them alone
- But at READ time (when generating), if we encounter V1 or V2, convert on-the-fly and SAVE BACK the V3 version
- After a week, V1/V2 configs will be rare; after a month, essentially zero

**Delete candidates:**
- `getRecordData` and `getRecordDataV2` methods and their private helpers (but NOT the format detection — we still need that to know what to convert)
- Duplicate parsing logic

**Test implications:**
- Add one test per format ensuring the converter produces equivalent V3 config (same records retrieved, same field values)
- Delete the V1-specific and V2-specific deep tests — they become redundant with V3 tests
- `e2e-05-generate-bulk.apex` should produce identical output before and after

**Commit message:** `refactor(query): migrate V1/V2 configs to V3 on read, delete legacy parsers`

---

### Item 2.2 — Pick client-side DOCX assembly, delete server ZIP path

**Current state:** `DocGenService.mergeTemplate()` still has full server-side ZIP assembly code. `DocGenService.generateDocumentParts()` returns parts for client-side assembly via `docGenZipWriter.js`. Two code paths for the same output.

**Ask first:** Is server-side ZIP still used anywhere? Check callers of `mergeTemplate()` — specifically for DOCX output. (PDF path uses pre-decomposed, that stays.)

**If only client-side is used for DOCX:**
**Target state:** `mergeTemplate()` for DOCX output calls `generateDocumentParts()` internally and assembles via a shared helper, OR the method only exists for PDF. Server-side ZIP writing code is gone.

**If server-side is still used (e.g., bulk generation):**
Keep it but consolidate the image pipeline code (which is duplicated between paths) into one helper.

**Delete candidates:**
- Server-side ZIP writer loops
- Duplicate image map building code

**Test implications:**
- `e2e-04-generate-docx.apex` must produce byte-identical ZIP output
- Manual: open generated DOCX in Word, verify rendering unchanged

**Commit message:** `refactor(merge): pick one DOCX assembly path, delete the other`

---

## Phase 3 — Admin/UX consolidation

### Item 3.1 — Delete `docGenAdminGuide` LWC

**Current state:** `docGenAdminGuide` is already a "DEPRECATED stub redirecting to Command Hub Learning Center" per CLAUDE.md.

**Target state:** Deleted. Any lightning page still referencing it gets pointed at `docGenCommandHub` instead.

**Ask first:** Confirm no subscriber orgs have added `docGenAdminGuide` to custom lightning pages. (Low risk — it's been a stub for weeks.)

**Delete candidates:**
- The entire `force-app/main/default/lwc/docGenAdminGuide/` folder
- Any metadata referencing it (Lightning pages, tabs)

**Test implications:**
- None — it's already a stub with no logic

**Commit message:** `chore(lwc): delete deprecated docGenAdminGuide stub`

---

### Item 3.2 — Consolidate `docGenAdmin` into `docGenCommandHub`

**Current state:** `docGenAdmin` is the template manager. `docGenCommandHub` embeds `docGenAdmin`. Two components, one conceptually.

**Ask first:** Does `docGenAdmin` get embedded on any custom page OUTSIDE of `docGenCommandHub`? If yes, keep both. If no, merge.

**If no external usage:**
**Target state:** Template manager logic lives inside `docGenCommandHub` directly. `docGenAdmin` is deleted.

**If external usage exists:**
Skip this item. It's not worth the risk.

**Commit message:** `refactor(lwc): merge docGenAdmin into docGenCommandHub`

---

## Phase 4 — Test infrastructure hardening

(Only after Phases 1-3 are complete. Now the surface is small enough that good tests are feasible.)

### Item 4.1 — Write ONE integration test per customer-facing feature

Replace fragmented unit tests with end-to-end integration tests. Target: **15-20 total tests**, each covering a real customer scenario. See `TEST_PLAN.md` (to be created alongside this consolidation) for the full list.

Each test:
- Creates real data via `TestDataFactory.createStandardTestData()`
- Uses `attachRealDocxToTestTemplate()` for a real DOCX payload
- Drives the full pipeline (merge → generate / request → PIN → sign → PDF)
- Uses `Test.getEventBus().deliver()` to exercise platform event handlers
- Asserts on the **actual output** (PDF blob size > 0, DOCX unzip + contains merged values, signature placement has Status='Signed' with Signed_Value__c populated, etc.)

**Commit message (per test):** `test(feature-name): integration test for [feature]`

---

### Item 4.2 — Delete tests that only assert `notEquals(null)`

After integration tests land, sweep the test classes for assertions like `System.assertNotEquals(null, result)` with no further assertion. Those tests "pass" without proving anything. Delete them — the integration tests cover the same code paths with real assertions.

**Expected outcome:** Test count drops. Coverage % stays flat or rises. Bug-catching power increases dramatically.

---

## Phase 5 — Package release

Only after Phases 1-4 are complete and all gates pass:

```bash
sf package version create --package "Portwood DocGen Managed" \
  --installation-key-bypass --wait 60 --code-coverage \
  --target-dev-hub "Portwood Global - Production"
```

Expected: coverage ≥ 90% (not 75%), package builds clean.

```bash
sf package version promote --package <new-04t> \
  --target-dev-hub "Portwood Global - Production" --no-prompt
```

Update `sfdx-project.json`, README, create git tag `v1.45.0`, push, create GitHub release.

---

## Order of operations — do not deviate

```
1.1  Collapse signature paths           ← highest value, read CLAUDE.md first
1.2  Remove Test.isRunningTest bypass   ← quick win
1.3  Delete v2 tag fallback             ← ASK USER FIRST
1.4  Delete Document Source mode        ← ASK USER FIRST
---- commit + push — Phase 1 done ----
2.1  Consolidate query parsers
2.2  Pick one DOCX assembly path
---- commit + push — Phase 2 done ----
3.1  Delete docGenAdminGuide
3.2  Merge docGenAdmin (if safe)
---- commit + push — Phase 3 done ----
4.1  Write integration tests (TEST_PLAN.md)
4.2  Delete meaningless assertions
---- commit + push — Phase 4 done ----
5    Package, promote, release 1.45.0
```

---

## What to hand the user at the end

1. **Net LOC delta** — how many lines deleted vs added. Target: -2000+ net.
2. **Coverage report** — per-class, sorted by coverage %. Target: no class below 80%, org-wide 90%+.
3. **Feature matrix** — every customer-facing feature mapped to the integration test(s) that prove it works.
4. **Released package version** — promoted 04t Id + install URL.

---

## Signals the plan is going wrong

Watch for these and stop immediately if you see them:

- **You're adding abstractions instead of deleting code.** A new "Facade" class with 200 lines is not consolidation; it's just more surface area.
- **Tests are being modified to match new behavior.** If a test fails after a consolidation, the behavior changed. Either that change is intentional (document why) or the consolidation is wrong (revert).
- **Coverage numbers are stagnant after Phase 1.** Phase 1 alone should move the needle 5-8%. If it doesn't, the dead code is elsewhere.
- **Net LOC is positive at the end of a phase.** You're adding more than you're deleting. Stop, review, simplify.

---

## Open questions to ask the user at session start

1. Are there active subscriber orgs on v2 signature tag syntax? (Affects Item 1.3)
2. Is anyone calling `createMultiSignerRequest`, `getRelatedDocuments`, or `getDocumentSignatureRoles` from a Flow or external integration? (Affects Item 1.4)
3. Is `docGenAdmin` embedded on any custom lightning page outside the Command Hub? (Affects Item 3.2)
4. Target version number — should the post-consolidation release be 1.45.0 or 2.0.0? (2.0.0 signals the architectural shift; 1.45.0 signals continuity.)
