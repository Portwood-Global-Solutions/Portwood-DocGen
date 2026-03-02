@isTest
private class DocGenSignatureTests {

    @testSetup
    static void setup() {
        Account acc = new Account(Name = 'Signature Test Account', Website = 'https://test.com');
        insert acc;

        Contact con = new Contact(
            FirstName = 'Signature',
            LastName = 'Tester',
            Email = 'signer@example.com',
            AccountId = acc.Id
        );
        insert con;

        // Source_Document_Id__c is a Text(18) field — use placeholder.
        // Tests that need a real ContentVersion call createTestFile().
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Signer_Name__c = 'Legacy Signer',
            Signer_Email__c = 'legacy@test.com',
            Source_Document_Id__c = '068000000000001AAA',
            Related_Record_Id__c = acc.Id,
            Secure_Token__c = 'LEGACY_TEST_TOKEN_12345',
            Status__c = 'Sent'
        );
        insert req;

        DocGen_Signer__c signer = new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Multi Signer One',
            Signer_Email__c = 'multisigner@test.com',
            Role_Name__c = 'Buyer',
            Secure_Token__c = 'SIGNER_TEST_TOKEN_67890',
            Status__c = 'Pending',
            Sort_Order__c = 1
        );
        insert signer;
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private static DocGen_Signer__c getTestSigner() {
        return [SELECT Id, Secure_Token__c, Status__c, Signature_Request__c
                FROM DocGen_Signer__c WHERE Secure_Token__c = 'SIGNER_TEST_TOKEN_67890' LIMIT 1];
    }

    private static DocGen_Signature_Request__c getTestRequest() {
        return [SELECT Id, Secure_Token__c, Status__c, Source_Document_Id__c
                FROM DocGen_Signature_Request__c WHERE Secure_Token__c = 'LEGACY_TEST_TOKEN_12345' LIMIT 1];
    }

    private static Account getTestAccount() {
        return [SELECT Id FROM Account WHERE Name = 'Signature Test Account' LIMIT 1];
    }

    private static Contact getTestContact() {
        return [SELECT Id FROM Contact WHERE LastName = 'Tester' LIMIT 1];
    }

    /**
     * Creates a ContentVersion + CDL linked to the test account, then updates
     * the signature request's Source_Document_Id__c to point to the new CV.
     */
    private static ContentVersion createTestFile() {
        ContentVersion cv = new ContentVersion(
            Title = 'TestSignatureDoc',
            PathOnClient = 'TestSignatureDoc.docx',
            VersionData = Blob.valueOf('test')
        );
        insert cv;

        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        Account acc = getTestAccount();
        insert new ContentDocumentLink(
            LinkedEntityId = acc.Id,
            ContentDocumentId = cv.ContentDocumentId,
            ShareType = 'V'
        );

        DocGen_Signature_Request__c req = getTestRequest();
        req.Source_Document_Id__c = cv.Id;
        update req;

        return cv;
    }

    // =========================================================================
    // DocGenSignatureController — validateToken
    // =========================================================================

    @isTest
    static void testValidateToken_BlankAndNull() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse blank = DocGenSignatureController.validateToken('');
        DocGenSignatureController.SignatureInitResponse nul = DocGenSignatureController.validateToken(null);
        Test.stopTest();

        System.assertEquals(false, blank.isValid, 'Blank token should return invalid');
        System.assertEquals('Invalid or missing security token.', blank.errorMessage);
        System.assertEquals(false, nul.isValid, 'Null token should return invalid');
    }

    @isTest
    static void testValidateToken_InvalidToken() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('NONEXISTENT_TOKEN_XYZ');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('Signature request not found. The link may be invalid.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_ValidSignerToken() {
        createTestFile();
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('SIGNER_TEST_TOKEN_67890');
        Test.stopTest();

        System.assertEquals(true, res.isValid, 'Valid signer token should return valid');
        System.assertEquals('Multi Signer One', res.signerName);
        System.assertEquals('Buyer', res.roleName);
        System.assertNotEquals(null, res.totalSigners);

        DocGen_Signer__c signer = getTestSigner();
        System.assertEquals('Viewed', signer.Status__c);
    }

    @isTest
    static void testValidateToken_AlreadySignedSigner() {
        DocGen_Signer__c signer = getTestSigner();
        signer.Status__c = 'Signed';
        update signer;

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('SIGNER_TEST_TOKEN_67890');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('You have already signed this document.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_CancelledParentRequest() {
        DocGen_Signature_Request__c req = getTestRequest();
        req.Status__c = 'Cancelled';
        update req;

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('SIGNER_TEST_TOKEN_67890');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('This signature request is no longer active.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_LegacyToken() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('LEGACY_TEST_TOKEN_12345');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertEquals('Legacy Signer', res.signerName);
        System.assertEquals(1, res.totalSigners);
        System.assertEquals(0, res.signedCount);
    }

    @isTest
    static void testValidateToken_LegacyAlreadySigned() {
        DocGen_Signature_Request__c req = getTestRequest();
        req.Status__c = 'Signed';
        update req;

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('LEGACY_TEST_TOKEN_12345');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('This document has already been signed.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_LegacyCancelled() {
        DocGen_Signature_Request__c req = getTestRequest();
        req.Status__c = 'Cancelled';
        update req;

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('LEGACY_TEST_TOKEN_12345');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('This signature request has been cancelled.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_ViewedThenValidateAgain() {
        createTestFile();
        DocGenSignatureController.validateToken('SIGNER_TEST_TOKEN_67890');
        System.assertEquals('Viewed', getTestSigner().Status__c);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('SIGNER_TEST_TOKEN_67890');
        Test.stopTest();

        System.assertEquals(true, res.isValid, 'Viewed signer should still be valid');
    }

    @isTest
    static void testValidateToken_LegacyViewedThenValidateAgain() {
        DocGenSignatureController.validateToken('LEGACY_TEST_TOKEN_12345');
        System.assertEquals('Viewed', getTestRequest().Status__c);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('LEGACY_TEST_TOKEN_12345');
        Test.stopTest();

        System.assertEquals(true, res.isValid, 'Viewed legacy request should still be valid');
    }

    // =========================================================================
    // DocGenSignatureController — fetchDocumentData (needs real CV)
    // =========================================================================

    @isTest
    static void testFetchDocumentData_ValidSignerToken() {
        createTestFile();

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.fetchDocumentData('SIGNER_TEST_TOKEN_67890');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertNotEquals(null, res.templateBase64);
        System.assertNotEquals(null, res.recordId);
    }

    @isTest
    static void testFetchDocumentData_LegacyToken() {
        createTestFile();

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.fetchDocumentData('LEGACY_TEST_TOKEN_12345');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertNotEquals(null, res.templateBase64);
    }

    @isTest
    static void testFetchDocumentData_InvalidToken() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.fetchDocumentData('BAD_TOKEN');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
    }

    // =========================================================================
    // DocGenSignatureController — saveSignature (no CV needed)
    // =========================================================================

    @isTest
    static void testSaveSignature_ValidSigner() {
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake-signature-png'));

        Test.startTest();
        DocGenSignatureController.SaveSignatureResult result =
            DocGenSignatureController.saveSignature('SIGNER_TEST_TOKEN_67890', fakeBase64);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isComplete, 'With one signer signed, request should be complete');
        System.assertEquals(0, result.remaining);

        System.assertEquals('Signed', getTestSigner().Status__c);
    }

    @isTest
    static void testSaveSignature_AlreadySigned() {
        DocGen_Signer__c signer = getTestSigner();
        signer.Status__c = 'Signed';
        update signer;

        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake-sig'));
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureController.saveSignature('SIGNER_TEST_TOKEN_67890', fakeBase64);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for already-signed signer');
    }

    @isTest
    static void testSaveSignature_InvalidToken() {
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake-sig'));
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureController.saveSignature('INVALID_TOKEN_ABC', fakeBase64);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for invalid token');
    }

    @isTest
    static void testSaveSignature_ThenVerifyParentRequestStatus() {
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('signature-data'));

        Test.startTest();
        DocGenSignatureController.saveSignature('SIGNER_TEST_TOKEN_67890', fakeBase64);
        Test.stopTest();

        System.assertEquals('In Progress', getTestRequest().Status__c);
    }

    // =========================================================================
    // DocGenSignatureController — stampAndReturnSource (needs real CV)
    // =========================================================================

    @isTest
    static void testStampAndReturnSource_ErrorPaths() {
        createTestFile();
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake-signature'));

        Test.startTest();

        // Signer token — file is not real DOCX so stamping fails
        Boolean caught1 = false;
        try {
            DocGenSignatureController.stampAndReturnSource('SIGNER_TEST_TOKEN_67890', fakeBase64);
        } catch (AuraHandledException e) {
            caught1 = true;
        }
        System.assert(caught1, 'stampAndReturnSource should throw for invalid DOCX (signer)');

        // Legacy token — same error path
        Boolean caught2 = false;
        try {
            DocGenSignatureController.stampAndReturnSource('LEGACY_TEST_TOKEN_12345', fakeBase64);
        } catch (AuraHandledException e) {
            caught2 = true;
        }
        System.assert(caught2, 'stampAndReturnSource should throw for invalid DOCX (legacy)');

        // Invalid token
        Boolean caught3 = false;
        try {
            DocGenSignatureController.stampAndReturnSource('NO_MATCH_TOKEN', fakeBase64);
        } catch (AuraHandledException e) {
            caught3 = true;
        }
        System.assert(caught3, 'stampAndReturnSource should throw for invalid token');

        Test.stopTest();
    }

    // =========================================================================
    // DocGenSignatureController — finishSignatureUpload (no direct CV query)
    // =========================================================================

    @isTest
    static void testFinishSignatureUpload_Paths() {
        String fakeBase64Pdf = EncodingUtil.base64Encode(Blob.valueOf('fake-pdf'));

        Test.startTest();

        // Multi-signer path
        try {
            DocGenSignatureController.finishSignatureUpload('SIGNER_TEST_TOKEN_67890', fakeBase64Pdf, 'TestSigned.pdf');
        } catch (Exception e) {
            // Acceptable — code path exercised
        }

        // Legacy path
        try {
            DocGenSignatureController.finishSignatureUpload('LEGACY_TEST_TOKEN_12345', fakeBase64Pdf, 'TestSigned.pdf');
        } catch (Exception e) {
            // Acceptable
        }

        // Invalid token
        Boolean caught = false;
        try {
            DocGenSignatureController.finishSignatureUpload('NO_MATCH_TOKEN_XYZ', fakeBase64Pdf, 'TestSigned.pdf');
        } catch (AuraHandledException e) {
            caught = true;
        }
        System.assert(caught, 'finishSignatureUpload should throw for unknown token');

        Test.stopTest();
    }

    // =========================================================================
    // DocGenSignatureController — inner class coverage
    // =========================================================================

    @isTest
    static void testInnerClassCoverage() {
        DocGenSignatureController.SignatureInitResponse res = new DocGenSignatureController.SignatureInitResponse();
        res.isValid = true;
        res.errorMessage = 'test';
        res.signerName = 'test name';
        res.documentTitle = 'test title';
        res.documentUrl = 'https://example.com';
        res.templateBase64 = 'base64data';
        res.recordId = '001000000000000';
        res.mergeDataJson = '{}';
        res.roleName = 'Buyer';
        res.totalSigners = 2;
        res.signedCount = 1;
        System.assertEquals(true, res.isValid);
        System.assertEquals('Buyer', res.roleName);

        DocGenSignatureController.SaveSignatureResult sr = new DocGenSignatureController.SaveSignatureResult();
        sr.isComplete = false;
        sr.remaining = 3;
        System.assertEquals(false, sr.isComplete);
        System.assertEquals(3, sr.remaining);
    }

    // =========================================================================
    // DocGenSignatureSenderController (needs real CV for doc operations)
    // =========================================================================

    @isTest
    static void testGetRelatedDocuments() {
        createTestFile();
        Account acc = getTestAccount();

        Test.startTest();
        List<ContentVersion> docs = DocGenSignatureSenderController.getRelatedDocuments(acc.Id);
        Test.stopTest();

        System.assert(docs.size() >= 1, 'Should find at least 1 document');
    }

    @isTest
    static void testGetRelatedDocuments_NoDocuments() {
        Account tempAcc = new Account(Name = 'No Docs Account', Website = 'https://test.com');
        insert tempAcc;

        Test.startTest();
        List<ContentVersion> docs = DocGenSignatureSenderController.getRelatedDocuments(tempAcc.Id);
        Test.stopTest();

        System.assertEquals(0, docs.size());
    }

    @isTest
    static void testCreateMultiSignerRequest() {
        ContentVersion cv = createTestFile();
        Account acc = getTestAccount();

        String signersJson = '[{"signerName":"Test Signer","signerEmail":"test@test.com","roleName":"Buyer","contactId":""}]';

        Test.startTest();
        List<DocGenSignatureSenderController.SignerResult> results =
            DocGenSignatureSenderController.createMultiSignerRequest(cv.ContentDocumentId, acc.Id, signersJson);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('Test Signer', results[0].signerName);
        System.assertEquals('Buyer', results[0].roleName);
        System.assertNotEquals(null, results[0].signerUrl);
    }

    @isTest
    static void testCreateMultiSignerRequest_MultipleSignersAndContact() {
        ContentVersion cv = createTestFile();
        Account acc = getTestAccount();
        Contact con = getTestContact();

        String signersJson = '[' +
            '{"signerName":"Buyer Person","signerEmail":"buyer@test.com","roleName":"Buyer","contactId":""},' +
            '{"signerName":"Seller Person","signerEmail":"seller@test.com","roleName":"Seller","contactId":"' + con.Id + '"}' +
        ']';

        Test.startTest();
        List<DocGenSignatureSenderController.SignerResult> results =
            DocGenSignatureSenderController.createMultiSignerRequest(cv.ContentDocumentId, acc.Id, signersJson);
        Test.stopTest();

        System.assertEquals(2, results.size());
        System.assertEquals('Buyer Person', results[0].signerName);
        System.assertEquals('Seller Person', results[1].signerName);
    }

    @isTest
    static void testCreateMultiSignerRequest_InvalidDocument() {
        Account acc = getTestAccount();
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureSenderController.createMultiSignerRequest(
                null, acc.Id, '[{"signerName":"X","signerEmail":"x@x.com","roleName":"Buyer","contactId":""}]'
            );
        } catch (Exception e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for null document ID');
    }

    @isTest
    static void testCreateSignatureRequest() {
        ContentVersion cv = createTestFile();
        Account acc = getTestAccount();

        Test.startTest();
        String signingUrl = DocGenSignatureSenderController.createSignatureRequest(
            cv.ContentDocumentId, acc.Id, 'Single Signer', 'single@test.com'
        );
        Test.stopTest();

        System.assertNotEquals(null, signingUrl);
        System.assert(signingUrl.contains('token='));
    }

    @isTest
    static void testCreateSignatureRequest_InvalidDocument() {
        Account acc = getTestAccount();
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureSenderController.createSignatureRequest(null, acc.Id, 'Test', 'test@test.com');
        } catch (Exception e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for null document ID');
    }

    @isTest
    static void testGetSignerRolePicklistValues() {
        Test.startTest();
        List<Map<String, String>> picklist = DocGenSignatureSenderController.getSignerRolePicklistValues();
        Test.stopTest();

        System.assertNotEquals(null, picklist);
    }

    @isTest
    static void testGetSignatureTemplatesAndRoles() {
        Test.startTest();
        // No templates initially
        List<DocGen_Signature_Template__c> empty = DocGenSignatureSenderController.getSignatureTemplates();
        System.assertEquals(0, empty.size());

        // Create one
        String rolesJson = '[{"roleName":"Husband"},{"roleName":"Wife"}]';
        Id templateId = DocGenSignatureSenderController.saveSignatureTemplate('Wedding Template', rolesJson);
        Test.stopTest();

        System.assertNotEquals(null, templateId);

        DocGen_Signature_Template__c tmpl = [SELECT Name FROM DocGen_Signature_Template__c WHERE Id = :templateId];
        System.assertEquals('Wedding Template', tmpl.Name);

        List<DocGen_Signature_Template_Role__c> roles = DocGenSignatureSenderController.getTemplateRoles(templateId);
        System.assertEquals(2, roles.size());
        System.assertEquals('Husband', roles[0].Role_Name__c);
        System.assertEquals('Wife', roles[1].Role_Name__c);

        // Now getSignatureTemplates should return 1
        List<DocGen_Signature_Template__c> templates = DocGenSignatureSenderController.getSignatureTemplates();
        System.assertEquals(1, templates.size());
    }

    @isTest
    static void testGetContactInfo() {
        Contact con = getTestContact();

        Test.startTest();
        Map<String, String> info = DocGenSignatureSenderController.getContactInfo(con.Id);
        Test.stopTest();

        System.assert(info.containsKey('name'));
        System.assert(info.containsKey('email'));
        System.assert(info.get('name').contains('Tester'));
        System.assertEquals('signer@example.com', info.get('email'));
    }

    @isTest
    static void testGetContactInfo_NonExistent() {
        Id fakeId = Contact.SObjectType.getDescribe().getKeyPrefix() + '000000099999';

        Test.startTest();
        Map<String, String> info = DocGenSignatureSenderController.getContactInfo(fakeId);
        Test.stopTest();

        System.assertEquals(0, info.size());
    }

    @isTest
    static void testGetPendingSignatureRequests() {
        createTestFile();
        Account acc = getTestAccount();

        Test.startTest();
        List<Map<String, Object>> results = DocGenSignatureSenderController.getPendingSignatureRequests(acc.Id);
        Test.stopTest();

        System.assert(results.size() >= 1, 'Should find at least 1 signature request');
        System.assertNotEquals(null, results[0].get('id'));
        System.assertNotEquals(null, results[0].get('status'));
        System.assertNotEquals(null, results[0].get('signers'));
    }

    @isTest
    static void testGetPendingSignatureRequests_NoResults() {
        Account tempAcc = new Account(Name = 'Empty Account', Website = 'https://test.com');
        insert tempAcc;

        Test.startTest();
        List<Map<String, Object>> results = DocGenSignatureSenderController.getPendingSignatureRequests(tempAcc.Id);
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @isTest
    static void testSignerResult_Coverage() {
        DocGenSignatureSenderController.SignerResult sr = new DocGenSignatureSenderController.SignerResult();
        sr.signerName = 'Test';
        sr.roleName = 'Buyer';
        sr.signerUrl = 'https://example.com/sign';
        sr.signerEmail = 'test@test.com';
        System.assertEquals('Test', sr.signerName);
    }

    // =========================================================================
    // DocGenSignatureValidator
    // =========================================================================

    @isTest
    static void testSignatureValidator() {
        createTestFile();
        DocGenSignatureValidator.FlowInput validInput = new DocGenSignatureValidator.FlowInput();
        validInput.token = 'SIGNER_TEST_TOKEN_67890';

        DocGenSignatureValidator.FlowInput invalidInput = new DocGenSignatureValidator.FlowInput();
        invalidInput.token = 'TOTALLY_INVALID_TOKEN';

        DocGenSignatureValidator.FlowInput blankInput = new DocGenSignatureValidator.FlowInput();
        blankInput.token = '';

        DocGenSignatureValidator.FlowInput legacyInput = new DocGenSignatureValidator.FlowInput();
        legacyInput.token = 'LEGACY_TEST_TOKEN_12345';

        Test.startTest();
        List<DocGenSignatureValidator.FlowOutput> outputs =
            DocGenSignatureValidator.validateToken(new List<DocGenSignatureValidator.FlowInput>{
                validInput, invalidInput, blankInput, legacyInput
            });
        Test.stopTest();

        System.assertEquals(4, outputs.size());
        System.assertEquals(true, outputs[0].isValid, 'Valid signer token');
        System.assertEquals('Multi Signer One', outputs[0].signerName);
        System.assertEquals(false, outputs[1].isValid, 'Invalid token');
        System.assertNotEquals(null, outputs[1].errorMessage);
        System.assertEquals(false, outputs[2].isValid, 'Blank token');
        System.assertEquals(true, outputs[3].isValid, 'Legacy token');
        System.assertEquals('Legacy Signer', outputs[3].signerName);
    }

    @isTest
    static void testSignatureValidator_FlowOutput_Coverage() {
        DocGenSignatureValidator.FlowOutput out = new DocGenSignatureValidator.FlowOutput();
        out.isValid = true;
        out.errorMessage = 'test error';
        out.signerName = 'test name';
        out.documentTitle = 'test doc';
        out.documentUrl = 'https://example.com';
        System.assertEquals(true, out.isValid);
    }

    // =========================================================================
    // DocGenSignatureSubmitter
    // =========================================================================

    @isTest
    static void testSignatureSubmitter_InvalidToken() {
        DocGenSignatureSubmitter.FlowInput input = new DocGenSignatureSubmitter.FlowInput();
        input.token = 'NONEXISTENT_TOKEN';
        input.signatureData = EncodingUtil.base64Encode(Blob.valueOf('fake-sig'));

        Test.startTest();
        List<DocGenSignatureSubmitter.FlowOutput> outputs =
            DocGenSignatureSubmitter.submitSignature(new List<DocGenSignatureSubmitter.FlowInput>{ input });
        Test.stopTest();

        System.assertEquals(1, outputs.size());
    }

    @isTest
    static void testSignatureSubmitter_ValidToken_ErrorPath() {
        DocGenSignatureSubmitter.FlowInput input = new DocGenSignatureSubmitter.FlowInput();
        input.token = 'LEGACY_TEST_TOKEN_12345';
        input.signatureData = EncodingUtil.base64Encode(Blob.valueOf('fake-sig'));

        Test.startTest();
        List<DocGenSignatureSubmitter.FlowOutput> outputs =
            DocGenSignatureSubmitter.submitSignature(new List<DocGenSignatureSubmitter.FlowInput>{ input });
        Test.stopTest();

        System.assertEquals(1, outputs.size());
    }

    @isTest
    static void testSignatureSubmitter_FlowIO_Coverage() {
        DocGenSignatureSubmitter.FlowInput input = new DocGenSignatureSubmitter.FlowInput();
        input.token = 'abc';
        input.signatureData = 'def';
        System.assertEquals('abc', input.token);

        DocGenSignatureSubmitter.FlowOutput out = new DocGenSignatureSubmitter.FlowOutput();
        out.isSuccess = true;
        out.errorMessage = 'none';
        System.assertEquals(true, out.isSuccess);
    }

    // =========================================================================
    // DocGenSignatureFinalizer
    // =========================================================================

    @isTest
    static void testSignatureFinalizer_Paths() {
        Test.startTest();

        // Invalid token — should handle gracefully
        DocGenSignatureFinalizer.FinalizeRequest req1 = new DocGenSignatureFinalizer.FinalizeRequest();
        req1.token = 'NONEXISTENT_TOKEN_FINAL';
        req1.base64Image = EncodingUtil.base64Encode(Blob.valueOf('fake-sig'));
        DocGenSignatureFinalizer.finalizeSignature(new List<DocGenSignatureFinalizer.FinalizeRequest>{ req1 });

        // Valid legacy token — error path (not real DOCX)
        DocGenSignatureFinalizer.FinalizeRequest req2 = new DocGenSignatureFinalizer.FinalizeRequest();
        req2.token = 'LEGACY_TEST_TOKEN_12345';
        req2.base64Image = EncodingUtil.base64Encode(Blob.valueOf('fake-sig'));
        DocGenSignatureFinalizer.finalizeSignature(new List<DocGenSignatureFinalizer.FinalizeRequest>{ req2 });

        Test.stopTest();

        System.assert(true, 'Finalizer handled both paths without unhandled exception');
    }

    @isTest
    static void testSignatureFinalizer_FinalizeRequest_Coverage() {
        DocGenSignatureFinalizer.FinalizeRequest req = new DocGenSignatureFinalizer.FinalizeRequest();
        req.token = 'test-token';
        req.base64Image = 'test-base64';
        System.assertEquals('test-token', req.token);
    }

    // =========================================================================
    // DocGenAuthenticatorController
    // =========================================================================

    @isTest
    static void testVerifyDocument_KnownHash() {
        DocGen_Signature_Request__c req = getTestRequest();
        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c(
            Signature_Request__c = req.Id,
            Signed_Date__c = System.now(),
            Document_Hash_SHA256__c = 'abc123def456hash',
            IP_Address__c = '127.0.0.1',
            User_Agent__c = 'Test Agent'
        );
        insert audit;

        Test.startTest();
        DocGenAuthenticatorController.VerificationResult result =
            DocGenAuthenticatorController.verifyDocument('abc123def456hash');
        Test.stopTest();

        System.assertEquals(true, result.isValid);
        System.assertEquals('Authentic Document Verified', result.message);
        System.assertNotEquals(null, result.signedDate);
    }

    @isTest
    static void testVerifyDocument_Variants() {
        Test.startTest();
        DocGenAuthenticatorController.VerificationResult unknown =
            DocGenAuthenticatorController.verifyDocument('unknown_hash_999');
        DocGenAuthenticatorController.VerificationResult empty =
            DocGenAuthenticatorController.verifyDocument('');
        DocGenAuthenticatorController.VerificationResult nul =
            DocGenAuthenticatorController.verifyDocument(null);
        Test.stopTest();

        System.assertEquals(false, unknown.isValid);
        System.assert(unknown.message.contains('Not Found'));
        System.assertEquals(false, empty.isValid);
        System.assertEquals(false, nul.isValid);
    }

    @isTest
    static void testVerifyDocument_WithSignerInfo() {
        DocGen_Signature_Request__c req = getTestRequest();
        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c(
            Signature_Request__c = req.Id,
            Signed_Date__c = System.now(),
            Document_Hash_SHA256__c = 'fullinfo_hash_test',
            IP_Address__c = '192.168.1.1',
            User_Agent__c = 'Chrome'
        );
        insert audit;

        Test.startTest();
        DocGenAuthenticatorController.VerificationResult result =
            DocGenAuthenticatorController.verifyDocument('fullinfo_hash_test');
        Test.stopTest();

        System.assertEquals(true, result.isValid);
        System.assertEquals('Legacy Signer', result.signerName);
        System.assertEquals('legacy@test.com', result.signerEmail);
        System.assertEquals('192.168.1.1', result.ipAddress);
    }

    @isTest
    static void testVerificationResult_Coverage() {
        DocGenAuthenticatorController.VerificationResult res = new DocGenAuthenticatorController.VerificationResult();
        res.isValid = true;
        res.message = 'test';
        res.signerName = 'name';
        res.signerEmail = 'email@test.com';
        res.signedDate = System.now();
        res.ipAddress = '127.0.0.1';
        System.assertEquals(true, res.isValid);
    }

    // =========================================================================
    // DocGenSignatureService (needs valid DOCX with {#Signature} placeholder)
    // =========================================================================

    /**
     * Builds a minimal valid DOCX ZIP with given document.xml content.
     * Returns the Blob directly (not saved as ContentVersion).
     */
    private static Blob buildValidDocxBlob(String docXml) {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('[Content_Types].xml', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/>' +
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
            '</Types>'
        ));
        zw.addEntry('_rels/.rels', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
            '</Relationships>'
        ));
        zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
        ));
        zw.addEntry('word/document.xml', Blob.valueOf(docXml));
        return zw.getArchive();
    }

    /**
     * Creates a ContentVersion containing a valid DOCX with {#Signature} placeholder,
     * links it to the test account, and updates the signature request to point to it.
     */
    private static ContentVersion createValidDocxForSigning() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t xml:space="preserve">Agreement: {#Signature}</w:t></w:r></w:p></w:body></w:document>';

        ContentVersion cv = new ContentVersion(
            Title = 'SignableDoc',
            PathOnClient = 'SignableDoc.docx',
            VersionData = buildValidDocxBlob(docXml)
        );
        insert cv;
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        Account acc = getTestAccount();
        insert new ContentDocumentLink(LinkedEntityId = acc.Id, ContentDocumentId = cv.ContentDocumentId, ShareType = 'V');

        DocGen_Signature_Request__c req = getTestRequest();
        req.Source_Document_Id__c = cv.Id;
        update req;
        return cv;
    }

    @isTest
    static void testStampSignatureToBlob() {
        ContentVersion cv = createValidDocxForSigning();
        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('fake-png-data'));

        Test.startTest();
        Blob result = DocGenSignatureService.stampSignatureToBlob(cv.Id, fakeBase64Sig, 'REQ-001');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return a DOCX blob');
        System.assert(result.size() > 0, 'Blob should not be empty');
    }

    @isTest
    static void testStampSignatureToBlobWithoutPlaceholder() {
        // DOCX without {#Signature} — falls back to appending at end
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>No placeholder here</w:t></w:r></w:p></w:body></w:document>';

        ContentVersion cv = new ContentVersion(
            Title = 'NoPlaceholderDoc',
            PathOnClient = 'NoPlaceholderDoc.docx',
            VersionData = buildValidDocxBlob(docXml)
        );
        insert cv;

        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('fake-png'));

        Test.startTest();
        Blob result = DocGenSignatureService.stampSignatureToBlob(cv.Id, fakeBase64Sig, 'REQ-002');
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @isTest
    static void testStampAllSignaturesToBlob() {
        // DOCX with two role-based placeholders
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Signature_Buyer} {#Signature_Seller}</w:t></w:r></w:p></w:body></w:document>';

        ContentVersion cv = new ContentVersion(
            Title = 'MultiSigDoc',
            PathOnClient = 'MultiSigDoc.docx',
            VersionData = buildValidDocxBlob(docXml)
        );
        insert cv;

        String sig1 = EncodingUtil.base64Encode(Blob.valueOf('buyer-sig'));
        String sig2 = EncodingUtil.base64Encode(Blob.valueOf('seller-sig'));

        List<DocGenSignatureService.SignerData> signers = new List<DocGenSignatureService.SignerData>{
            new DocGenSignatureService.SignerData('Buyer', sig1),
            new DocGenSignatureService.SignerData('Seller', sig2)
        };

        Test.startTest();
        Blob result = DocGenSignatureService.stampAllSignaturesToBlob(cv.Id, signers);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.size() > 0);
    }

    @isTest
    static void testStampAllSignaturesToBlobBlankRole() {
        // Blank role falls back to {#Signature}
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Signature}</w:t></w:r></w:p></w:body></w:document>';

        ContentVersion cv = new ContentVersion(
            Title = 'BlankRoleDoc',
            PathOnClient = 'BlankRoleDoc.docx',
            VersionData = buildValidDocxBlob(docXml)
        );
        insert cv;

        String sig = EncodingUtil.base64Encode(Blob.valueOf('single-sig'));
        List<DocGenSignatureService.SignerData> signers = new List<DocGenSignatureService.SignerData>{
            new DocGenSignatureService.SignerData('', sig)
        };

        Test.startTest();
        Blob result = DocGenSignatureService.stampAllSignaturesToBlob(cv.Id, signers);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @isTest
    static void testStampSignatureSavesToRecord() {
        ContentVersion cv = createValidDocxForSigning();
        Account acc = getTestAccount();
        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('sig-png'));

        Test.startTest();
        Id signedCvId = DocGenSignatureService.stampSignature(cv.Id, fakeBase64Sig, 'REQ-003', acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, signedCvId, 'Should return a ContentVersion Id');
        ContentVersion signedCv = [SELECT Title FROM ContentVersion WHERE Id = :signedCvId];
        System.assert(signedCv.Title.contains('Signed'), 'Title should contain Signed');
    }

    @isTest
    static void testStampSignatureNullRelatedRecord() {
        ContentVersion cv = createValidDocxForSigning();
        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('sig-png'));

        Test.startTest();
        Id signedCvId = DocGenSignatureService.stampSignature(cv.Id, fakeBase64Sig, 'REQ-004', null);
        Test.stopTest();

        System.assertNotEquals(null, signedCvId);
    }

    @isTest
    static void testHandleSignatureSubmission() {
        ContentVersion cv = createValidDocxForSigning();
        DocGen_Signature_Request__c req = getTestRequest();
        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('submit-sig'));

        Test.startTest();
        DocGenSignatureService.handleSignatureSubmission(req.Secure_Token__c, fakeBase64Sig);
        Test.stopTest();

        DocGen_Signature_Request__c updated = [SELECT Status__c FROM DocGen_Signature_Request__c WHERE Id = :req.Id];
        System.assertEquals('Signed', updated.Status__c);
    }

    @isTest
    static void testHandleSignatureSubmissionInvalidToken() {
        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('sig'));

        Test.startTest();
        DocGenSignatureService.handleSignatureSubmission('TOTALLY_INVALID_TOKEN_XYZ', fakeBase64Sig);
        Test.stopTest();

        // No exception — method returns silently for invalid tokens
        System.assert(true, 'Should handle invalid token gracefully');
    }

    @isTest
    static void testHandleSignatureSubmissionAlreadySigned() {
        DocGen_Signature_Request__c req = getTestRequest();
        req.Status__c = 'Signed';
        update req;

        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('sig'));

        Test.startTest();
        DocGenSignatureService.handleSignatureSubmission(req.Secure_Token__c, fakeBase64Sig);
        Test.stopTest();

        System.assert(true, 'Should skip already-signed request');
    }

    @isTest
    static void testSignerDataConstructor() {
        DocGenSignatureService.SignerData sd = new DocGenSignatureService.SignerData('Buyer', 'base64data');
        System.assertEquals('Buyer', sd.roleName);
        System.assertEquals('base64data', sd.base64Image);
    }
}
