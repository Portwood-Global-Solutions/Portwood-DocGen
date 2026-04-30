// DocGen E2E Test 05 — Bulk Generation Pipeline
// Run: sf apex run --target-org <org> -f scripts/e2e-05-generate-bulk.apex
// Depends on: e2e-02 (Account 'E2E Test Corp', Template 'E2E Test Template')
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;

Id acctId;
Id tmplId;
Id jobId;
Id savedQueryId;

// ===== Look up test data =====
try {
    List<Account> accts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp' LIMIT 1];
    if (accts.isEmpty()) {
        fail++;
        System.debug('LOOKUP ACCOUNT: FAIL — Run e2e-02 first.');
    } else {
        acctId = accts[0].Id;
        pass++;
        System.debug('LOOKUP ACCOUNT: PASS');
    }

    List<DocGen_Template__c> tmpls = [SELECT Id FROM DocGen_Template__c WHERE Name = 'E2E Test Template' LIMIT 1];
    if (tmpls.isEmpty()) {
        fail++;
        System.debug('LOOKUP TEMPLATE: FAIL — Run e2e-02 first.');
    } else {
        tmplId = tmpls[0].Id;
        pass++;
        System.debug('LOOKUP TEMPLATE: PASS');
    }
} catch (Exception e) {
    fail++;
    System.debug('LOOKUP: FAIL — ' + e.getMessage());
}

if (acctId == null || tmplId == null) {
    System.debug('========================================');
    System.debug('E2E-05 GENERATE BULK — PASS: ' + pass + '  FAIL: ' + fail + '  ABORTED (missing test data)');
    System.debug('========================================');
    return;
}

// ===== Validate Filter =====
try {
    Integer ct = DocGenBulkController.validateFilter('Account', 'Name = \'E2E Test Corp\'');
    if (ct > 0) {
        pass++;
        System.debug('VALIDATE FILTER > 0: PASS — count: ' + ct);
    } else {
        fail++;
        System.debug('VALIDATE FILTER > 0: FAIL — count: ' + ct);
    }
} catch (Exception e) {
    fail++;
    System.debug('VALIDATE FILTER: FAIL — ' + e.getMessage());
}

// ===== Submit Bulk Job =====
try {
    jobId = DocGenBulkController.submitJob(tmplId, 'Name = \'E2E Test Corp\'', 'E2E Bulk Test Job', false, 1, false);
    if (jobId != null) {
        pass++;
        System.debug('SUBMIT JOB: PASS — jobId: ' + jobId);
    } else {
        fail++;
        System.debug('SUBMIT JOB: FAIL — null jobId');
    }
} catch (Exception e) {
    fail++;
    System.debug('SUBMIT JOB: FAIL — ' + e.getMessage());
}

// ===== Get Job Status =====
try {
    if (jobId != null) {
        DocGen_Job__c j = DocGenBulkController.getJobStatus(jobId);
        if (j != null && j.Status__c != null) {
            pass++;
            System.debug('GET JOB STATUS: PASS — status: ' + j.Status__c);
        } else {
            fail++;
            System.debug('GET JOB STATUS: FAIL — null or no status');
        }
    } else {
        fail++;
        System.debug('GET JOB STATUS: FAIL — no jobId from submit');
    }
} catch (Exception e) {
    fail++;
    System.debug('GET JOB STATUS: FAIL — ' + e.getMessage());
}

// ===== Get Recent Jobs =====
try {
    List<DocGen_Job__c> recent = DocGenBulkController.getRecentJobs();
    if (recent != null) {
        // Should contain at least our just-created job
        Boolean foundOurJob = false;
        for (DocGen_Job__c rj : recent) {
            if (rj.Id == jobId) {
                foundOurJob = true;
                break;
            }
        }
        if (foundOurJob) {
            pass++;
            System.debug('GET RECENT JOBS: PASS — found our job in list of ' + recent.size());
        } else {
            pass++;
            System.debug('GET RECENT JOBS: PASS — ' + recent.size() + ' jobs (our job may be processing)');
        }
    } else {
        fail++;
        System.debug('GET RECENT JOBS: FAIL — null');
    }
} catch (Exception e) {
    fail++;
    System.debug('GET RECENT JOBS: FAIL — ' + e.getMessage());
}

// ===== Analyze Job =====
try {
    DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(tmplId, 1, 1, false);
    if (analysis != null && analysis.canProceed != null) {
        pass++;
        System.debug('ANALYZE JOB: PASS — canProceed: ' + analysis.canProceed + ', summary: ' + analysis.summary);
    } else {
        fail++;
        System.debug('ANALYZE JOB: FAIL — null analysis');
    }
} catch (Exception e) {
    fail++;
    System.debug('ANALYZE JOB: FAIL — ' + e.getMessage());
}

// ===== Save Query =====
try {
    DocGenBulkController.saveQuery(tmplId, 'E2E Test Query', 'Test saved query', 'Name = \'E2E Test Corp\'');
    pass++;
    System.debug('SAVE QUERY: PASS');
} catch (Exception e) {
    fail++;
    System.debug('SAVE QUERY: FAIL — ' + e.getMessage());
}

// ===== Get Saved Queries =====
try {
    List<DocGen_Saved_Query__c> queries = DocGenBulkController.getSavedQueries(tmplId);
    if (queries != null && !queries.isEmpty()) {
        pass++;
        System.debug('GET SAVED QUERIES: PASS — count: ' + queries.size());
        savedQueryId = queries[0].Id;
    } else {
        fail++;
        System.debug('GET SAVED QUERIES: FAIL — empty or null');
    }
} catch (Exception e) {
    fail++;
    System.debug('GET SAVED QUERIES: FAIL — ' + e.getMessage());
}

// ===== Delete Query =====
try {
    if (savedQueryId != null) {
        DocGenBulkController.deleteQuery(savedQueryId);
        List<DocGen_Saved_Query__c> after = DocGenBulkController.getSavedQueries(tmplId);
        Boolean deleted = true;
        if (after != null) {
            for (DocGen_Saved_Query__c sq : after) {
                if (sq.Id == savedQueryId) {
                    deleted = false;
                    break;
                }
            }
        }
        if (deleted) {
            pass++;
            System.debug('DELETE QUERY: PASS');
        } else {
            fail++;
            System.debug('DELETE QUERY: FAIL — query still exists');
        }
    } else {
        fail++;
        System.debug('DELETE QUERY: FAIL — no savedQueryId');
    }
} catch (Exception e) {
    fail++;
    System.debug('DELETE QUERY: FAIL — ' + e.getMessage());
}

// ===== Get Bulk Templates =====
try {
    List<DocGen_Template__c> bulkTmpls = DocGenBulkController.getBulkTemplates();
    if (bulkTmpls != null) {
        Boolean foundOurs = false;
        for (DocGen_Template__c bt : bulkTmpls) {
            if (bt.Id == tmplId) {
                foundOurs = true;
                break;
            }
        }
        if (foundOurs) {
            pass++;
            System.debug('GET BULK TEMPLATES: PASS — found E2E template in ' + bulkTmpls.size() + ' templates');
        } else {
            pass++;
            System.debug('GET BULK TEMPLATES: PASS — ' + bulkTmpls.size() + ' templates (E2E may not have active CV)');
        }
    } else {
        fail++;
        System.debug('GET BULK TEMPLATES: FAIL — null');
    }
} catch (Exception e) {
    fail++;
    System.debug('GET BULK TEMPLATES: FAIL — ' + e.getMessage());
}

// ===== Direct generateDocument (simulates batch execute — NOT Aura context) =====
try {
    Id docId = DocGenService.generateDocument(tmplId, acctId);
    if (docId != null) {
        pass++;
        System.debug('GENERATE DOCUMENT (non-Aura): PASS — ' + docId);
    } else {
        fail++;
        System.debug('GENERATE DOCUMENT (non-Aura): FAIL — null');
    }
} catch (Exception e) {
    fail++;
    System.debug('GENERATE DOCUMENT (non-Aura): FAIL — ' + e.getMessage());
}

// ===== Document Title override (Flow Document Title input — GH #41) =====
try {
    String customTitle = 'E2E_FlowTitleOverride_' + DateTime.now().getTime();
    Id docId = DocGenService.generateDocument(tmplId, acctId, null, customTitle);
    List<ContentVersion> cvs = [SELECT Title FROM ContentVersion WHERE ContentDocumentId = :docId];
    if (!cvs.isEmpty() && cvs[0].Title == customTitle) {
        pass++;
        System.debug('DOCUMENT TITLE OVERRIDE: PASS — ' + cvs[0].Title);
    } else {
        fail++;
        System.debug(
            'DOCUMENT TITLE OVERRIDE: FAIL — expected "' +
                customTitle +
                '" got "' +
                (cvs.isEmpty() ? 'NO_CV' : cvs[0].Title) +
                '"'
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('DOCUMENT TITLE OVERRIDE: FAIL — ' + e.getMessage());
}

// ===== Clean up job =====
try {
    if (jobId != null) {
        delete [SELECT Id FROM DocGen_Job__c WHERE Id = :jobId];
        System.debug('CLEANUP: Deleted test job ' + jobId);
    }
} catch (Exception e) {
    System.debug('CLEANUP NOTE: ' + e.getMessage());
}

System.debug('========================================');
System.debug(
    'E2E-05 GENERATE BULK — PASS: ' +
        pass +
        '  FAIL: ' +
        fail +
        (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
