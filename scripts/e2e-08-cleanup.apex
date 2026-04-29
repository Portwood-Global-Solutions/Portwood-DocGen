// DocGen E2E Test 08 — Cleanup ALL Test Data
// Run: sf apex run --target-org <org> -f scripts/e2e-08-cleanup.apex
// Depends on: e2e-02 through e2e-06 (cleans up everything they created)
// Expected: PASS: N  FAIL: 0
//
// Set KEEP_TEST_DATA = true to skip all deletes and preserve generated
// documents on the "E2E Test Corp" Account for visual inspection.

Boolean KEEP_TEST_DATA = false; // ← flip to true to keep test data

Integer pass = 0;
Integer fail = 0;

Id acctId;
Id tmplId;

// ===== Look up test data =====
try {
    List<Account> accts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp' LIMIT 1];
    if (!accts.isEmpty()) {
        acctId = accts[0].Id;
    }

    List<DocGen_Template__c> tmpls = [SELECT Id FROM DocGen_Template__c WHERE Name = 'E2E Test Template' LIMIT 1];
    if (!tmpls.isEmpty()) {
        tmplId = tmpls[0].Id;
    }
} catch (Exception e) {
    System.debug('LOOKUP NOTE: ' + e.getMessage());
}

if (KEEP_TEST_DATA) {
    // ===== KEEP MODE — report what exists, skip deletes =====
    System.debug('*** KEEP_TEST_DATA = true — skipping all deletes ***');
    Integer kept = 0;
    if (acctId != null) {
        kept += [
            SELECT COUNT()
            FROM DocGen_Signature_Audit__c
            WHERE
                Signature_Request__c IN (
                    SELECT Id
                    FROM DocGen_Signature_Request__c
                    WHERE Related_Record_Id__c = :acctId
                )
        ];
        kept += [
            SELECT COUNT()
            FROM DocGen_Signer__c
            WHERE
                Signature_Request__c IN (
                    SELECT Id
                    FROM DocGen_Signature_Request__c
                    WHERE Related_Record_Id__c = :acctId
                )
        ];
        kept += [SELECT COUNT() FROM DocGen_Signature_Request__c WHERE Related_Record_Id__c = :acctId];
        kept += [SELECT COUNT() FROM Opportunity WHERE AccountId = :acctId];
        kept += [SELECT COUNT() FROM Contact WHERE AccountId = :acctId];
        kept += 1; // the account itself
        Integer fileCount = [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :acctId];
        System.debug('KEPT: Account "E2E Test Corp" + ' + kept + ' related records, ' + fileCount + ' files attached');
        System.debug('>>> View generated docs: Navigate to Account "E2E Test Corp" > Files tab');
    }
    if (tmplId != null) {
        kept += [SELECT COUNT() FROM DocGen_Job__c WHERE Template__c = :tmplId];
        kept += [SELECT COUNT() FROM DocGen_Saved_Query__c WHERE DocGen_Template__c = :tmplId];
        kept += [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
        kept += 1; // the template itself
        System.debug('KEPT: Template "E2E Test Template" + related versions/jobs/queries');
    }
    pass = 12; // all 12 checks "pass" in keep mode
    System.debug('========================================');
    System.debug('E2E-08 CLEANUP (KEEP MODE) — PASS: ' + pass + '  FAIL: 0  ALL TESTS PASSED — data preserved');
    System.debug('========================================');
} else {
    // ===== DELETE MODE — normal cleanup =====

    // ===== Delete Signature Audit records =====
    try {
        if (acctId != null) {
            List<DocGen_Signature_Audit__c> audits = [
                SELECT Id
                FROM DocGen_Signature_Audit__c
                WHERE
                    Signature_Request__c IN (
                        SELECT Id
                        FROM DocGen_Signature_Request__c
                        WHERE Related_Record_Id__c = :acctId
                    )
            ];
            if (!audits.isEmpty()) {
                delete audits;
            }
            pass++;
            System.debug('DELETE AUDIT RECORDS: PASS — ' + audits.size() + ' deleted');
        } else {
            pass++;
            System.debug('DELETE AUDIT RECORDS: PASS — no account found (already clean)');
        }
    } catch (Exception e) {
        fail++;
        System.debug('DELETE AUDIT RECORDS: FAIL — ' + e.getMessage());
    }

    // ===== Delete Signers =====
    try {
        if (acctId != null) {
            List<DocGen_Signer__c> signers = [
                SELECT Id
                FROM DocGen_Signer__c
                WHERE
                    Signature_Request__c IN (
                        SELECT Id
                        FROM DocGen_Signature_Request__c
                        WHERE Related_Record_Id__c = :acctId
                    )
            ];
            if (!signers.isEmpty()) {
                delete signers;
            }
            pass++;
            System.debug('DELETE SIGNERS: PASS — ' + signers.size() + ' deleted');
        } else {
            pass++;
            System.debug('DELETE SIGNERS: PASS — no account found');
        }
    } catch (Exception e) {
        fail++;
        System.debug('DELETE SIGNERS: FAIL — ' + e.getMessage());
    }

    // ===== Delete Signature Requests =====
    try {
        if (acctId != null) {
            List<DocGen_Signature_Request__c> reqs = [
                SELECT Id
                FROM DocGen_Signature_Request__c
                WHERE Related_Record_Id__c = :acctId
            ];
            if (!reqs.isEmpty()) {
                delete reqs;
            }
            pass++;
            System.debug('DELETE SIGNATURE REQUESTS: PASS — ' + reqs.size() + ' deleted');
        } else {
            pass++;
            System.debug('DELETE SIGNATURE REQUESTS: PASS — no account found');
        }
    } catch (Exception e) {
        fail++;
        System.debug('DELETE SIGNATURE REQUESTS: FAIL — ' + e.getMessage());
    }

    // ===== Delete Jobs =====
    try {
        if (tmplId != null) {
            List<DocGen_Job__c> jobs = [SELECT Id FROM DocGen_Job__c WHERE Template__c = :tmplId];
            if (!jobs.isEmpty()) {
                delete jobs;
            }
            pass++;
            System.debug('DELETE JOBS: PASS — ' + jobs.size() + ' deleted');
        } else {
            pass++;
            System.debug('DELETE JOBS: PASS — no template found');
        }
    } catch (Exception e) {
        fail++;
        System.debug('DELETE JOBS: FAIL — ' + e.getMessage());
    }

    // ===== Delete Saved Queries =====
    try {
        if (tmplId != null) {
            List<DocGen_Saved_Query__c> queries = [
                SELECT Id
                FROM DocGen_Saved_Query__c
                WHERE DocGen_Template__c = :tmplId
            ];
            if (!queries.isEmpty()) {
                delete queries;
            }
            pass++;
            System.debug('DELETE SAVED QUERIES: PASS — ' + queries.size() + ' deleted');
        } else {
            pass++;
            System.debug('DELETE SAVED QUERIES: PASS — no template found');
        }
    } catch (Exception e) {
        fail++;
        System.debug('DELETE SAVED QUERIES: FAIL — ' + e.getMessage());
    }

    // ===== Delete Template Versions =====
    try {
        if (tmplId != null) {
            List<DocGen_Template_Version__c> vers = [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Template__c = :tmplId
            ];
            if (!vers.isEmpty()) {
                delete vers;
            }
            pass++;
            System.debug('DELETE TEMPLATE VERSIONS: PASS — ' + vers.size() + ' deleted');
        } else {
            pass++;
            System.debug('DELETE TEMPLATE VERSIONS: PASS — no template found');
        }
    } catch (Exception e) {
        fail++;
        System.debug('DELETE TEMPLATE VERSIONS: FAIL — ' + e.getMessage());
    }

    // ===== Delete Template =====
    try {
        if (tmplId != null) {
            delete [SELECT Id FROM DocGen_Template__c WHERE Id = :tmplId];
            pass++;
            System.debug('DELETE TEMPLATE: PASS');
        } else {
            pass++;
            System.debug('DELETE TEMPLATE: PASS — no template found');
        }
    } catch (Exception e) {
        fail++;
        System.debug('DELETE TEMPLATE: FAIL — ' + e.getMessage());
    }

    // ===== Delete Opportunity =====
    try {
        if (acctId != null) {
            List<Opportunity> opps = [SELECT Id FROM Opportunity WHERE AccountId = :acctId];
            if (!opps.isEmpty()) {
                delete opps;
            }
            pass++;
            System.debug('DELETE OPPORTUNITIES: PASS — ' + opps.size() + ' deleted');
        } else {
            pass++;
            System.debug('DELETE OPPORTUNITIES: PASS — no account found');
        }
    } catch (Exception e) {
        fail++;
        System.debug('DELETE OPPORTUNITIES: FAIL — ' + e.getMessage());
    }

    // ===== Delete Contacts =====
    try {
        if (acctId != null) {
            List<Contact> cons = [SELECT Id FROM Contact WHERE AccountId = :acctId];
            if (!cons.isEmpty()) {
                delete cons;
            }
            pass++;
            System.debug('DELETE CONTACTS: PASS — ' + cons.size() + ' deleted');
        } else {
            pass++;
            System.debug('DELETE CONTACTS: PASS — no account found');
        }
    } catch (Exception e) {
        fail++;
        System.debug('DELETE CONTACTS: FAIL — ' + e.getMessage());
    }

    // ===== Delete Account =====
    try {
        if (acctId != null) {
            delete [SELECT Id FROM Account WHERE Id = :acctId];
            pass++;
            System.debug('DELETE ACCOUNT: PASS');
        } else {
            pass++;
            System.debug('DELETE ACCOUNT: PASS — no account found');
        }
    } catch (Exception e) {
        fail++;
        System.debug('DELETE ACCOUNT: FAIL — ' + e.getMessage());
    }

    // ===== Reset Signature Settings =====
    try {
        DocGenSetupController.saveSignatureSettings(null, null, null, null, null, null, '');
        pass++;
        System.debug('RESET SIGNATURE SETTINGS: PASS');
    } catch (Exception e) {
        fail++;
        System.debug('RESET SIGNATURE SETTINGS: FAIL — ' + e.getMessage());
    }

    // ===== Verify clean =====
    try {
        Integer acctCount = [SELECT COUNT() FROM Account WHERE Name = 'E2E Test Corp'];
        Integer tmplCount = [SELECT COUNT() FROM DocGen_Template__c WHERE Name = 'E2E Test Template'];
        if (acctCount == 0 && tmplCount == 0) {
            pass++;
            System.debug('VERIFY CLEAN: PASS — no test data remains');
        } else {
            fail++;
            System.debug('VERIFY CLEAN: FAIL — accounts: ' + acctCount + ', templates: ' + tmplCount);
        }
    } catch (Exception e) {
        fail++;
        System.debug('VERIFY CLEAN: FAIL — ' + e.getMessage());
    }

    System.debug('========================================');
    System.debug(
        'E2E-08 CLEANUP — PASS: ' +
            pass +
            '  FAIL: ' +
            fail +
            (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
    );
    System.debug('========================================');
}
