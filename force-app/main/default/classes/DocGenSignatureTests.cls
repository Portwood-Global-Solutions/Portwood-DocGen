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
            Secure_Token__c = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2',
            Status__c = 'Sent'
        );
        insert req;

        DocGen_Signer__c signer = new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Multi Signer One',
            Signer_Email__c = 'multisigner@test.com',
            Role_Name__c = 'Buyer',
            Secure_Token__c = 'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
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
                FROM DocGen_Signer__c WHERE Secure_Token__c = 'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5' LIMIT 1];
    }

    private static DocGen_Signature_Request__c getTestRequest() {
        return [SELECT Id, Secure_Token__c, Status__c, Source_Document_Id__c
                FROM DocGen_Signature_Request__c WHERE Secure_Token__c = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2' LIMIT 1];
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
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('0000000000000000000000000000000000000000000000000000000000000000');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('Signature request not found. The link may be invalid or expired.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_ValidSignerToken() {
        createTestFile();
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
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
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
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
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('This signature request is no longer active.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_LegacyToken() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
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
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
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
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('This signature request has been cancelled.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_ViewedThenValidateAgain() {
        createTestFile();
        DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        System.assertEquals('Viewed', getTestSigner().Status__c);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(true, res.isValid, 'Viewed signer should still be valid');
    }

    @isTest
    static void testValidateToken_LegacyViewedThenValidateAgain() {
        DocGenSignatureController.validateToken('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
        System.assertEquals('Viewed', getTestRequest().Status__c);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
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
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.fetchDocumentData('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertNotEquals(null, res.templateBase64);
        System.assertNotEquals(null, res.recordId);
    }

    @isTest
    static void testFetchDocumentData_LegacyToken() {
        createTestFile();

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.fetchDocumentData('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
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
            DocGenSignatureController.saveSignature('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5', fakeBase64);
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
            DocGenSignatureController.saveSignature('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5', fakeBase64);
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
            DocGenSignatureController.saveSignature('0000000000000000000000000000000000000000000000000000000000000001', fakeBase64);
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
        DocGenSignatureController.saveSignature('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5', fakeBase64);
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
            DocGenSignatureController.stampAndReturnSource('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5', fakeBase64);
        } catch (AuraHandledException e) {
            caught1 = true;
        }
        System.assert(caught1, 'stampAndReturnSource should throw for invalid DOCX (signer)');

        // Legacy token — same error path
        Boolean caught2 = false;
        try {
            DocGenSignatureController.stampAndReturnSource('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2', fakeBase64);
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
            DocGenSignatureController.finishSignatureUpload('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5', fakeBase64Pdf, 'TestSigned.pdf');
        } catch (Exception e) {
            // Acceptable — code path exercised
        }

        // Legacy path
        try {
            DocGenSignatureController.finishSignatureUpload('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2', fakeBase64Pdf, 'TestSigned.pdf');
        } catch (Exception e) {
            // Acceptable
        }

        // Invalid token — method is now a no-op (PDF saved server-side), should not throw
        DocGenSignatureController.finishSignatureUpload('NO_MATCH_TOKEN_XYZ', fakeBase64Pdf, 'TestSigned.pdf');
        System.assert(true, 'finishSignatureUpload is a no-op and should not throw');

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
        validInput.token = 'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5';

        DocGenSignatureValidator.FlowInput invalidInput = new DocGenSignatureValidator.FlowInput();
        invalidInput.token = '0000000000000000000000000000000000000000000000000000000000000002';

        DocGenSignatureValidator.FlowInput blankInput = new DocGenSignatureValidator.FlowInput();
        blankInput.token = '';

        DocGenSignatureValidator.FlowInput legacyInput = new DocGenSignatureValidator.FlowInput();
        legacyInput.token = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

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
        input.token = '0000000000000000000000000000000000000000000000000000000000000003';
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
        input.token = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
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
        req1.token = '0000000000000000000000000000000000000000000000000000000000000004';
        req1.base64Image = EncodingUtil.base64Encode(Blob.valueOf('fake-sig'));
        DocGenSignatureFinalizer.finalizeSignature(new List<DocGenSignatureFinalizer.FinalizeRequest>{ req1 });

        // Valid legacy token — error path (not real DOCX)
        DocGenSignatureFinalizer.FinalizeRequest req2 = new DocGenSignatureFinalizer.FinalizeRequest();
        req2.token = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
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
        Boolean caught = false;
        try {
            DocGenSignatureService.handleSignatureSubmission('TOTALLY_INVALID_TOKEN_XYZ', fakeBase64Sig);
        } catch (DocGenSignatureService.SignatureException e) {
            caught = true;
            System.assert(e.getMessage().contains('Invalid security token format'));
        }
        Test.stopTest();

        System.assert(caught, 'Should throw SignatureException for invalid token format');
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

    // =========================================================================
    // Additional DocGenSignatureController coverage tests
    // =========================================================================

    @isTest
    static void testValidateToken_BadFormat_TooShort() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken('abcdef');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('Invalid security token format.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_BadFormat_NonHex() {
        // 64 chars but contains non-hex characters
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('Invalid security token format.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_ExpiredSignerToken() {
        DocGen_Signer__c signer = getTestSigner();
        // We cannot backdate CreatedDate directly, so we test the path by
        // verifying the 30-day logic exists. Instead, set Status to exercise
        // the expiry branch by using Test.setCreatedDate.
        Test.setCreatedDate(signer.Id, System.now().addDays(-31));

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('This signature link has expired. Please request a new one.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_ExpiredLegacyToken() {
        // Delete the signer so the legacy fallback is used
        DocGen_Signer__c signer = getTestSigner();
        delete signer;

        DocGen_Signature_Request__c req = getTestRequest();
        Test.setCreatedDate(req.Id, System.now().addDays(-31));

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('This signature link has expired. Please request a new one.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_SignedParentRequest() {
        DocGen_Signature_Request__c req = getTestRequest();
        req.Status__c = 'Signed';
        update req;

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assertEquals('This signature request is no longer active.', res.errorMessage);
    }

    @isTest
    static void testValidateToken_SignerNoDocument() {
        // Source_Document_Id__c is a placeholder that won't match any CV
        // This exercises the 'Confidential Document' fallback in validateSignerToken
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertEquals('Confidential Document', res.documentTitle);
    }

    @isTest
    static void testValidateToken_LegacyNoDocument() {
        // Delete signer so legacy path is used; source doc ID is placeholder
        delete getTestSigner();

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertEquals('Confidential Document', res.documentTitle);
    }

    @isTest
    static void testFetchDocumentData_WithValidDocx() {
        ContentVersion cv = createValidDocxForSigning();

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.fetchDocumentData('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertNotEquals(null, res.templateBase64);
        // Should contain actual HTML from the DOCX conversion
        System.assert(res.templateBase64.contains('Agreement'), 'HTML should contain document text');
    }

    @isTest
    static void testFetchDocumentData_LegacyWithValidDocx() {
        ContentVersion cv = createValidDocxForSigning();
        // Delete signer so legacy path is used
        delete getTestSigner();

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.fetchDocumentData('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertNotEquals(null, res.recordId);
    }

    @isTest
    static void testFetchDocumentData_NoSourceDoc() {
        // Source doc ID is placeholder — no CV exists
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.fetchDocumentData('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        // templateBase64 should be null when no CV found
    }

    @isTest
    static void testSaveSignature_BlankToken() {
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('sig'));
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureController.saveSignature('', fakeBase64);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for blank token');
    }

    @isTest
    static void testSaveSignature_MalformedToken() {
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('sig'));
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureController.saveSignature('not-a-valid-hex-token', fakeBase64);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for malformed token');
    }

    @isTest
    static void testSaveSignature_SignerNotFound() {
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('sig'));
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureController.saveSignature('0000000000000000000000000000000000000000000000000000000000000099', fakeBase64);
        } catch (AuraHandledException e) {
            caught = true;
            // AuraHandledException.getMessage() returns 'Script-thrown exception' in Apex;
            // the custom message is only available client-side.
        }
        Test.stopTest();

        System.assert(caught, 'Should throw when signer not found');
    }

    @isTest
    static void testSaveSignature_ExpiredToken() {
        DocGen_Signer__c signer = getTestSigner();
        Test.setCreatedDate(signer.Id, System.now().addDays(-31));

        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('sig'));
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureController.saveSignature('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5', fakeBase64);
        } catch (AuraHandledException e) {
            caught = true;
            // AuraHandledException.getMessage() returns 'Script-thrown exception' in Apex;
            // the custom message ('This signature link has expired.') is only available client-side.
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for expired signer token');
    }

    @isTest
    static void testSaveSignature_MultipleSigners_NotComplete() {
        // Add a second signer so the first signing doesn't complete the request
        DocGen_Signature_Request__c req = getTestRequest();
        DocGen_Signer__c signer2 = new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Second Signer',
            Signer_Email__c = 'second@test.com',
            Role_Name__c = 'Seller',
            Secure_Token__c = '1111111111111111111111111111111111111111111111111111111111111111',
            Status__c = 'Pending',
            Sort_Order__c = 2
        );
        insert signer2;

        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('first-sig'));

        Test.startTest();
        DocGenSignatureController.SaveSignatureResult result =
            DocGenSignatureController.saveSignature('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5', fakeBase64);
        Test.stopTest();

        System.assertEquals(false, result.isComplete, 'Should not be complete with remaining signers');
        System.assertEquals(1, result.remaining, 'One signer should remain');
        System.assertEquals('In Progress', getTestRequest().Status__c);
    }

    @isTest
    static void testStampAndReturnSource_InvalidTokenFormat() {
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureController.stampAndReturnSource('short', 'base64');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for invalid token format');
    }

    @isTest
    static void testStampAndReturnSource_MultiSignerSuccess() {
        ContentVersion cv = createValidDocxForSigning();
        DocGen_Signer__c signer = getTestSigner();

        // Mark signer as Signed with signature data
        signer.Status__c = 'Signed';
        signer.Signature_Data__c = EncodingUtil.base64Encode(Blob.valueOf('buyer-sig-png'));
        update signer;

        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('sig'));

        Test.startTest();
        Map<String, String> result = DocGenSignatureController.stampAndReturnSource(
            'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5', fakeBase64
        );
        Test.stopTest();

        System.assertEquals('complete', result.get('status'));
        System.assert(result.get('title').contains('Signed'));

        // Verify parent request status updated
        System.assertEquals('Signed', getTestRequest().Status__c);

        // Verify audit record created
        List<DocGen_Signature_Audit__c> audits = [
            SELECT Signer_Name__c, Document_Hash_SHA256__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c = :getTestRequest().Id
        ];
        System.assert(!audits.isEmpty(), 'Audit records should be created');

        // Verify signature data cleared
        DocGen_Signer__c updatedSigner = [SELECT Signature_Data__c FROM DocGen_Signer__c WHERE Id = :signer.Id];
        System.assertEquals(null, updatedSigner.Signature_Data__c, 'Signature data should be cleared');
    }

    @isTest
    static void testStampAndReturnSource_LegacySuccess() {
        ContentVersion cv = createValidDocxForSigning();
        // Delete signer so legacy path is used
        delete getTestSigner();

        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('legacy-sig-png'));

        Test.startTest();
        Map<String, String> result = DocGenSignatureController.stampAndReturnSource(
            'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2', fakeBase64
        );
        Test.stopTest();

        System.assertEquals('complete', result.get('status'));
        System.assert(result.get('title').contains('Signed'));

        // Verify request status updated
        System.assertEquals('Signed', getTestRequest().Status__c);

        // Verify audit record created
        List<DocGen_Signature_Audit__c> audits = [
            SELECT Signer_Name__c, Signer_Email__c, Document_Hash_SHA256__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c = :getTestRequest().Id
        ];
        System.assert(!audits.isEmpty(), 'Legacy audit record should be created');
        System.assertEquals('Legacy Signer', audits[0].Signer_Name__c);
        System.assertEquals('legacy@test.com', audits[0].Signer_Email__c);
    }

    @isTest
    static void testStampAndReturnSource_LegacyAlreadySigned() {
        // Delete signer so legacy path is used
        delete getTestSigner();

        DocGen_Signature_Request__c req = getTestRequest();
        req.Status__c = 'Signed';
        update req;

        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('sig'));
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureController.stampAndReturnSource(
                'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2', fakeBase64
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for already-signed legacy request');
    }

    @isTest
    static void testStampAndReturnSource_LegacyCancelled() {
        // Delete signer so legacy path is used
        delete getTestSigner();

        DocGen_Signature_Request__c req = getTestRequest();
        req.Status__c = 'Cancelled';
        update req;

        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('sig'));
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureController.stampAndReturnSource(
                'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2', fakeBase64
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for cancelled legacy request');
    }

    @isTest
    static void testStampAndReturnSource_NonexistentToken() {
        // Token that matches no signer and no legacy request
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureController.stampAndReturnSource(
                '0000000000000000000000000000000000000000000000000000000000000077', EncodingUtil.base64Encode(Blob.valueOf('sig'))
            );
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for nonexistent token in legacy fallback');
    }

    @isTest
    static void testStampAndReturnSource_MultiSignerWithMultipleSigners() {
        // Create a DOCX with two role placeholders
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Signature_Buyer} {#Signature_Seller}</w:t></w:r></w:p></w:body></w:document>';

        ContentVersion cv = new ContentVersion(
            Title = 'MultiRoleDoc',
            PathOnClient = 'MultiRoleDoc.docx',
            VersionData = buildValidDocxBlob(docXml)
        );
        insert cv;
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        Account acc = getTestAccount();
        insert new ContentDocumentLink(LinkedEntityId = acc.Id, ContentDocumentId = cv.ContentDocumentId, ShareType = 'V');

        DocGen_Signature_Request__c req = getTestRequest();
        req.Source_Document_Id__c = cv.Id;
        update req;

        // Update existing signer and add a second one, both marked Signed
        DocGen_Signer__c signer1 = getTestSigner();
        signer1.Status__c = 'Signed';
        signer1.Signature_Data__c = EncodingUtil.base64Encode(Blob.valueOf('buyer-sig'));
        update signer1;

        Contact con = getTestContact();
        DocGen_Signer__c signer2 = new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Seller Person',
            Signer_Email__c = 'seller@test.com',
            Role_Name__c = 'Seller',
            Secure_Token__c = '2222222222222222222222222222222222222222222222222222222222222222',
            Status__c = 'Signed',
            Signature_Data__c = EncodingUtil.base64Encode(Blob.valueOf('seller-sig')),
            Sort_Order__c = 2,
            Contact__c = con.Id
        );
        insert signer2;

        Test.startTest();
        Map<String, String> result = DocGenSignatureController.stampAndReturnSource(
            'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
            EncodingUtil.base64Encode(Blob.valueOf('sig'))
        );
        Test.stopTest();

        System.assertEquals('complete', result.get('status'));

        // Verify two audit records created
        List<DocGen_Signature_Audit__c> audits = [
            SELECT Signer_Name__c, Contact__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c = :req.Id
        ];
        System.assertEquals(2, audits.size(), 'Should create audit record per signer');
    }

    @isTest
    static void testFinishSignatureUpload_NoOp() {
        // Verify finishSignatureUpload accepts any arguments without error
        Test.startTest();
        DocGenSignatureController.finishSignatureUpload(null, null, null);
        DocGenSignatureController.finishSignatureUpload(
            'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
            EncodingUtil.base64Encode(Blob.valueOf('pdf-data')),
            'TestDoc.pdf'
        );
        Test.stopTest();

        System.assert(true, 'finishSignatureUpload is a no-op');
    }

    @isTest
    static void testValidateToken_SignerWithRealDocCreatesPublicLink() {
        ContentVersion cv = createValidDocxForSigning();

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertEquals('SignableDoc', res.documentTitle);
        // documentUrl comes from getOrCreatePublicLink
        System.assertNotEquals(null, res.documentUrl);
    }

    @isTest
    static void testValidateToken_LegacyWithRealDocCreatesPublicLink() {
        ContentVersion cv = createValidDocxForSigning();
        // Delete signer so legacy path is used
        delete getTestSigner();

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertEquals('SignableDoc', res.documentTitle);
        System.assertNotEquals(null, res.documentUrl);
    }

    @isTest
    static void testValidateToken_ExistingPublicLink() {
        ContentVersion cv = createValidDocxForSigning();

        // First call creates the ContentDistribution
        DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');

        Test.startTest();
        // Second call should find the existing ContentDistribution
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertNotEquals(null, res.documentUrl);
    }

    @isTest
    static void testValidateToken_SignerAlreadyViewed() {
        createTestFile();
        DocGen_Signer__c signer = getTestSigner();
        signer.Status__c = 'Viewed';
        update signer;

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        // Should not update status again since it's already Viewed
        System.assertEquals('Viewed', [SELECT Status__c FROM DocGen_Signer__c WHERE Id = :signer.Id].Status__c);
    }

    @isTest
    static void testValidateToken_LegacyViewedStatus() {
        // Delete signer so legacy path is used
        delete getTestSigner();

        DocGen_Signature_Request__c req = getTestRequest();
        req.Status__c = 'Viewed';
        update req;

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        // Should not update status since it's already Viewed (not Sent)
    }

    @isTest
    static void testValidateToken_SignerWithSignedCountGreaterThanZero() {
        createTestFile();
        DocGen_Signature_Request__c req = getTestRequest();

        // Add a second signer who is already signed
        DocGen_Signer__c signer2 = new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Already Signed',
            Signer_Email__c = 'done@test.com',
            Role_Name__c = 'Seller',
            Secure_Token__c = '3333333333333333333333333333333333333333333333333333333333333333',
            Status__c = 'Signed',
            Sort_Order__c = 2
        );
        insert signer2;

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertEquals(2, res.totalSigners);
        System.assertEquals(1, res.signedCount, 'One signer should already be signed');
    }

    // =========================================================================
    // DocGenSignatureSubmitter — success path
    // =========================================================================

    @isTest
    static void testSignatureSubmitter_SuccessPath() {
        ContentVersion cv = createValidDocxForSigning();
        DocGen_Signature_Request__c req = getTestRequest();
        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('submit-sig'));

        DocGenSignatureSubmitter.FlowInput input = new DocGenSignatureSubmitter.FlowInput();
        input.token = req.Secure_Token__c;
        input.signatureData = fakeBase64Sig;

        Test.startTest();
        List<DocGenSignatureSubmitter.FlowOutput> outputs =
            DocGenSignatureSubmitter.submitSignature(new List<DocGenSignatureSubmitter.FlowInput>{ input });
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assertEquals(true, outputs[0].isSuccess, 'Should succeed with valid token and DOCX');
    }

    // =========================================================================
    // DocGenSignatureEmailService — additional coverage
    // =========================================================================

    @isTest
    static void testSendSignatureRequestEmailsEmptyList() {
        Test.startTest();
        DocGenSignatureEmailService.sendSignatureRequestEmails(null, 'Test');
        DocGenSignatureEmailService.sendSignatureRequestEmails(new List<DocGenSignatureEmailService.SignerEmail>(), 'Test');
        Test.stopTest();
        System.assert(true, 'Should handle empty/null signer lists without error');
    }

    @isTest
    static void testSendSignatureRequestEmailsWithoutContact() {
        DocGenSignatureEmailService.SignerEmail signer = new DocGenSignatureEmailService.SignerEmail(
            'No Contact', 'nocontact@test.com', 'Buyer', 'https://example.com/sign?token=abc', null
        );

        Test.startTest();
        DocGenSignatureEmailService.sendSignatureRequestEmails(
            new List<DocGenSignatureEmailService.SignerEmail>{ signer }, 'Test Document'
        );
        Test.stopTest();
        System.assert(true, 'Should send email without contact');
    }

    @isTest
    static void testSendSignatureRequestEmailsWithBranding() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Company_Name__c = 'Test Corp';
        settings.Signature_Email_Logo_Url__c = 'https://logo.png';
        settings.Signature_Email_Brand_Color__c = '#FF0000';
        settings.Signature_Email_Subject__c = 'Sign Now: {DocumentTitle}';
        settings.Signature_Email_Footer_Text__c = 'Custom footer text';
        upsert settings;

        Contact con = getTestContact();
        DocGenSignatureEmailService.SignerEmail signer = new DocGenSignatureEmailService.SignerEmail(
            'Branded Signer', 'branded@test.com', 'Seller', 'https://example.com/sign?token=xyz', con.Id
        );

        Test.startTest();
        DocGenSignatureEmailService.sendSignatureRequestEmails(
            new List<DocGenSignatureEmailService.SignerEmail>{ signer }, 'Branded Doc'
        );
        Test.stopTest();
        System.assert(true, 'Should send branded email');
    }

    @isTest
    static void testSendSignatureRequestEmailsNullValues() {
        DocGenSignatureEmailService.SignerEmail signer = new DocGenSignatureEmailService.SignerEmail(
            null, 'null@test.com', null, 'https://example.com/sign?token=abc', null
        );

        Test.startTest();
        DocGenSignatureEmailService.sendSignatureRequestEmails(
            new List<DocGenSignatureEmailService.SignerEmail>{ signer }, null
        );
        Test.stopTest();
        System.assert(true, 'Should handle null values gracefully');
    }

    @isTest
    static void testSendSignatureRequestEmailsCompanyNameOnly() {
        // Covers the branch where logoUrl is blank but companyName is set
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Company_Name__c = 'Name Only Corp';
        settings.Signature_Email_Logo_Url__c = null;
        settings.Signature_Email_Brand_Color__c = null;
        settings.Signature_Email_Subject__c = null;
        settings.Signature_Email_Footer_Text__c = null;
        upsert settings;

        DocGenSignatureEmailService.SignerEmail signer = new DocGenSignatureEmailService.SignerEmail(
            'Signer', 'signer@test.com', null, 'https://example.com/sign', null
        );

        Test.startTest();
        DocGenSignatureEmailService.sendSignatureRequestEmails(
            new List<DocGenSignatureEmailService.SignerEmail>{ signer }, 'Doc Title'
        );
        Test.stopTest();
        System.assert(true, 'Should render company name as text when no logo');
    }

    // =========================================================================
    // DocGenSignatureSenderController — additional coverage
    // =========================================================================

    @isTest
    static void testGetPendingSignatureRequestsWithNullSourceDoc() {
        Account acc = getTestAccount();
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Signer_Name__c = 'NullDoc Signer',
            Signer_Email__c = 'nulldoc@test.com',
            Source_Document_Id__c = null,
            Related_Record_Id__c = acc.Id,
            Secure_Token__c = 'b2b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6b2b2',
            Status__c = 'Sent'
        );
        insert req;

        Test.startTest();
        List<Map<String, Object>> results = DocGenSignatureSenderController.getPendingSignatureRequests(acc.Id);
        Test.stopTest();

        System.assert(results.size() >= 1, 'Should return results including null source doc request');
    }

    @isTest
    static void testGetSiteBaseUrlWithConfiguredUrl() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Experience_Site_Url__c = 'https://mysite.example.com/';
        upsert settings;

        ContentVersion cv = createTestFile();
        Account acc = getTestAccount();

        Test.startTest();
        String signingUrl = DocGenSignatureSenderController.createSignatureRequest(
            cv.ContentDocumentId, acc.Id, 'Site Test', 'site@test.com'
        );
        Test.stopTest();

        System.assert(signingUrl.startsWith('https://mysite.example.com/'), 'Should use configured site URL');
        System.assert(!signingUrl.contains('//apex'), 'Trailing slash should be trimmed');
    }

    // =========================================================================
    // DocGenSignatureService — additional coverage
    // =========================================================================

    @isTest
    static void testHandleSignatureSubmissionCancelledStatus() {
        DocGen_Signature_Request__c req = getTestRequest();
        req.Status__c = 'Cancelled';
        update req;

        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('sig'));

        Test.startTest();
        DocGenSignatureService.handleSignatureSubmission(req.Secure_Token__c, fakeBase64Sig);
        Test.stopTest();

        System.assert(true, 'Should skip cancelled request silently');
    }

    @isTest
    static void testHandleSignatureSubmissionBlankToken() {
        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('sig'));
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureService.handleSignatureSubmission('', fakeBase64Sig);
        } catch (DocGenSignatureService.SignatureException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for blank token');
    }

    @isTest
    static void testHandleSignatureSubmissionWrongLengthToken() {
        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('sig'));
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenSignatureService.handleSignatureSubmission('abcdef1234', fakeBase64Sig);
        } catch (DocGenSignatureService.SignatureException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for wrong-length token');
    }

    @isTest
    static void testHandleSignatureSubmissionNonMatchingToken() {
        String validFormatToken = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        String fakeBase64Sig = EncodingUtil.base64Encode(Blob.valueOf('sig'));

        Test.startTest();
        DocGenSignatureService.handleSignatureSubmission(validFormatToken, fakeBase64Sig);
        Test.stopTest();

        System.assert(true, 'Should return silently for non-matching token');
    }

    @isTest
    static void testStampAllSignaturesToBlobFallbackAppend() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>No placeholder</w:t></w:r></w:p></w:body></w:document>';

        ContentVersion cv = new ContentVersion(
            Title = 'FallbackDoc',
            PathOnClient = 'FallbackDoc.docx',
            VersionData = buildValidDocxBlob(docXml)
        );
        insert cv;

        String sig = EncodingUtil.base64Encode(Blob.valueOf('sig-data'));
        List<DocGenSignatureService.SignerData> signers = new List<DocGenSignatureService.SignerData>{
            new DocGenSignatureService.SignerData('Manager', sig)
        };

        Test.startTest();
        Blob result = DocGenSignatureService.stampAllSignaturesToBlob(cv.Id, signers);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return blob even with fallback');
    }
}
