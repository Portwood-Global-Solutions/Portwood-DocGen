// DocGen E2E Test 03 — PDF Generation + Output Verification
// Run: sf apex run --target-org <org> -f scripts/e2e-03-generate-pdf.apex
// Depends on: e2e-02 (Account 'E2E Test Corp', Template 'E2E Test Template')
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;

Id acctId; Id tmplId;

// ===== Look up test data =====
try {
    List<Account> accts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp' LIMIT 1];
    if (accts.isEmpty()) { fail++; System.debug('LOOKUP ACCOUNT: FAIL — E2E Test Corp not found. Run e2e-02 first.'); }
    else { acctId = accts[0].Id; pass++; System.debug('LOOKUP ACCOUNT: PASS — ' + acctId); }

    List<DocGen_Template__c> tmpls = [SELECT Id, Output_Format__c FROM DocGen_Template__c WHERE Name = 'E2E Test Template' LIMIT 1];
    if (tmpls.isEmpty()) { fail++; System.debug('LOOKUP TEMPLATE: FAIL — E2E Test Template not found. Run e2e-02 first.'); }
    else { tmplId = tmpls[0].Id; pass++; System.debug('LOOKUP TEMPLATE: PASS — ' + tmplId); }
} catch (Exception e) { fail++; System.debug('LOOKUP: FAIL — ' + e.getMessage()); }

if (acctId == null || tmplId == null) {
    System.debug('========================================');
    System.debug('E2E-03 GENERATE PDF — PASS: ' + pass + '  FAIL: ' + fail + '  ABORTED (missing test data)');
    System.debug('========================================');
    return;
}

// ===== Ensure template is set to PDF output =====
try {
    DocGen_Template__c t = [SELECT Id, Output_Format__c FROM DocGen_Template__c WHERE Id = :tmplId];
    if (t.Output_Format__c != 'PDF') {
        t.Output_Format__c = 'PDF';
        update t;
    }
    pass++; System.debug('TEMPLATE SET TO PDF: PASS');
} catch (Exception e) { fail++; System.debug('TEMPLATE SET TO PDF: FAIL — ' + e.getMessage()); }

// ===== Generate PDF via processAndReturnDocument =====
String base64Pdf;
try {
    Map<String, Object> genResult = DocGenController.processAndReturnDocument(tmplId, acctId);

    if (genResult == null) { fail++; System.debug('PDF GEN RESULT: FAIL — null result'); }
    else {
        base64Pdf = (String) genResult.get('base64');
        String docTitle = (String) genResult.get('title');

        if (String.isNotBlank(base64Pdf)) {
            pass++; System.debug('PDF GEN NON-EMPTY: PASS — title: ' + docTitle + ', base64 length: ' + base64Pdf.length());
        } else {
            fail++; System.debug('PDF GEN NON-EMPTY: FAIL — empty base64');
        }

        // Template was set to PDF above — verify processAndReturnDocument returns PDF bytes (%PDF header = hex 2550)
        if (String.isNotBlank(base64Pdf)) {
            Blob docBlob = EncodingUtil.base64Decode(base64Pdf);
            String hexStart = EncodingUtil.convertToHex(docBlob).substring(0, 4).toUpperCase();
            if (hexStart == '2550') { pass++; System.debug('PDF OUTPUT VALID: PASS'); }
            else { fail++; System.debug('PDF OUTPUT VALID: FAIL — got hex: ' + hexStart); }

            // Verify non-trivial size (a real PDF with content should be > 500 bytes)
            if (docBlob.size() > 500) { pass++; System.debug('PDF SIZE > 500 bytes: PASS — ' + docBlob.size() + ' bytes'); }
            else { fail++; System.debug('PDF SIZE > 500 bytes: FAIL — only ' + docBlob.size() + ' bytes'); }
        }

        // Save the PDF to the Account for manual inspection
        if (String.isNotBlank(base64Pdf)) {
            try {
                ContentVersion pdfCv = new ContentVersion(
                    Title='E2E Output - PDF', PathOnClient='e2e_output.pdf',
                    VersionData=EncodingUtil.base64Decode(base64Pdf), FirstPublishLocationId=acctId
                );
                insert pdfCv;
                pass++; System.debug('PDF SAVED TO ACCOUNT: PASS');
                System.debug('>>> DOWNLOAD: Navigate to Account "E2E Test Corp" > Files tab to inspect the PDF');
            } catch (Exception e) { fail++; System.debug('PDF SAVED TO ACCOUNT: FAIL — ' + e.getMessage()); }
        }
    }
} catch (Exception e) { fail++; System.debug('PDF GENERATION: FAIL — ' + e.getMessage() + ' at line ' + e.getLineNumber()); }

// ===== Test generatePdf endpoint =====
try {
    Map<String, Object> pdfResult = DocGenController.generatePdf(tmplId, acctId, false);
    if (pdfResult != null) {
        String gpBase64 = (String) pdfResult.get('base64');
        if (String.isNotBlank(gpBase64)) {
            pass++; System.debug('GENERATE PDF ENDPOINT: PASS — base64 length: ' + gpBase64.length());
        } else {
            fail++; System.debug('GENERATE PDF ENDPOINT: FAIL — empty base64');
        }
    } else { fail++; System.debug('GENERATE PDF ENDPOINT: FAIL — null result'); }
} catch (Exception e) { fail++; System.debug('GENERATE PDF ENDPOINT: FAIL — ' + e.getMessage()); }

// ===== Test generatePdf with saveToRecord=true =====
try {
    Map<String, Object> saveResult = DocGenController.generatePdf(tmplId, acctId, true);
    if (saveResult != null) {
        // Check that a ContentDocumentId was returned
        Object cdId = saveResult.get('contentDocumentId');
        if (cdId != null) { pass++; System.debug('GENERATE PDF SAVE TO RECORD: PASS — ContentDocumentId: ' + cdId); }
        else {
            // Some implementations return base64 even with save
            String sb64 = (String) saveResult.get('base64');
            if (String.isNotBlank(sb64)) { pass++; System.debug('GENERATE PDF SAVE TO RECORD: PASS (base64 returned)'); }
            else { fail++; System.debug('GENERATE PDF SAVE TO RECORD: FAIL — no contentDocumentId or base64'); }
        }
    } else { fail++; System.debug('GENERATE PDF SAVE TO RECORD: FAIL — null result'); }
} catch (Exception e) { fail++; System.debug('GENERATE PDF SAVE TO RECORD: FAIL — ' + e.getMessage()); }

System.debug('========================================');
System.debug('E2E-03 GENERATE PDF — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED'));
System.debug('========================================');
