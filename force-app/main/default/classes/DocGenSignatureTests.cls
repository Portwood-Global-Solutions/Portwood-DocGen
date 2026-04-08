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
        return [SELECT Id, Secure_Token__c, Status__c, Signature_Request__c,
                       PIN_Hash__c, PIN_Expires_At__c, PIN_Attempts__c, PIN_Verified_At__c
                FROM DocGen_Signer__c WHERE Secure_Token__c = 'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5' LIMIT 1];
    }

    private static DocGen_Signature_Request__c getTestRequest() {
        return [SELECT Id, Status__c, Secure_Token__c FROM DocGen_Signature_Request__c LIMIT 1];
    }

    // =========================================================================
    // Token Validation
    // =========================================================================

    @isTest
    static void testValidateToken_validMultiSigner() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(true, res.isValid, 'Token should be valid');
        System.assertEquals('Multi Signer One', res.signerName);
        System.assertEquals('multisigner@test.com', res.signerEmail);
        System.assertEquals('Buyer', res.roleName);
        System.assertEquals(true, res.requiresPin, 'PIN should be required for new signer');
    }

    @isTest
    static void testValidateToken_blank() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assert(res.errorMessage.contains('Invalid'));
    }

    @isTest
    static void testValidateToken_badFormat() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('not-a-hex-token');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assert(res.errorMessage.contains('Invalid'));
    }

    @isTest
    static void testValidateToken_notFound() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('0000000000000000000000000000000000000000000000000000000000000099');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assert(res.errorMessage.contains('not found'));
    }

    @isTest
    static void testValidateToken_legacyRequest() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
        Test.stopTest();

        System.assertEquals(true, res.isValid, 'Legacy token should be valid');
        System.assertEquals('Legacy Signer', res.signerName);
        System.assertEquals(false, res.isSignerToken);
    }

    @isTest
    static void testValidateToken_alreadySigned() {
        DocGen_Signer__c signer = getTestSigner();
        signer.Status__c = 'Signed';
        update signer;

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.validateToken('f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
        System.assert(res.errorMessage.contains('already signed'));
    }

    // =========================================================================
    // PIN Verification
    // =========================================================================

    @isTest
    static void testSendPin_success() {
        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.sendPin(
            'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
            'multisigner@test.com'
        );
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'PIN send should succeed');

        DocGen_Signer__c signer = getTestSigner();
        System.assertNotEquals(null, signer.PIN_Hash__c, 'PIN hash should be set');
        System.assertNotEquals(null, signer.PIN_Expires_At__c, 'PIN expiry should be set');
    }

    @isTest
    static void testSendPin_wrongEmail() {
        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.sendPin(
            'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
            'wrong@example.com'
        );
        Test.stopTest();

        System.assertEquals(false, result.get('success'));
        System.assert(((String)result.get('message')).contains('does not match'));
    }

    @isTest
    static void testSendPin_invalidToken() {
        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.sendPin('bad', 'test@test.com');
        Test.stopTest();

        System.assertEquals(false, result.get('success'));
    }

    @isTest
    static void testVerifyPin_success() {
        // First send a PIN
        DocGen_Signer__c signer = getTestSigner();
        String testPin = '123456';
        String pinHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(testPin))
        );
        signer.PIN_Hash__c = pinHash;
        signer.PIN_Expires_At__c = System.now().addMinutes(10);
        signer.PIN_Attempts__c = 0;
        update signer;

        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.verifyPin(
            'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
            '123456'
        );
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'PIN verification should succeed');

        signer = getTestSigner();
        System.assertNotEquals(null, signer.PIN_Verified_At__c, 'PIN_Verified_At should be set');
        System.assertEquals(null, signer.PIN_Hash__c, 'PIN hash should be cleared');
    }

    @isTest
    static void testVerifyPin_wrongPin() {
        DocGen_Signer__c signer = getTestSigner();
        String pinHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf('123456'))
        );
        signer.PIN_Hash__c = pinHash;
        signer.PIN_Expires_At__c = System.now().addMinutes(10);
        signer.PIN_Attempts__c = 0;
        update signer;

        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.verifyPin(
            'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
            '999999'
        );
        Test.stopTest();

        System.assertEquals(false, result.get('success'));
        signer = getTestSigner();
        System.assertEquals(1, signer.PIN_Attempts__c, 'Attempt counter should increment');
    }

    @isTest
    static void testVerifyPin_expired() {
        DocGen_Signer__c signer = getTestSigner();
        String pinHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf('123456'))
        );
        signer.PIN_Hash__c = pinHash;
        signer.PIN_Expires_At__c = System.now().addMinutes(-1); // expired
        signer.PIN_Attempts__c = 0;
        update signer;

        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.verifyPin(
            'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
            '123456'
        );
        Test.stopTest();

        System.assertEquals(false, result.get('success'));
        System.assert(((String)result.get('message')).contains('expired'));
    }

    @isTest
    static void testVerifyPin_lockedOut() {
        DocGen_Signer__c signer = getTestSigner();
        signer.PIN_Attempts__c = 3;
        update signer;

        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.verifyPin(
            'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
            '123456'
        );
        Test.stopTest();

        System.assertEquals(false, result.get('success'));
        System.assert(((String)result.get('message')).contains('Too many'));
    }

    // =========================================================================
    // Save Signature (Typed Name)
    // =========================================================================

    @isTest
    static void testSaveSignature_success() {
        // Set up PIN-verified signer
        DocGen_Signer__c signer = getTestSigner();
        signer.PIN_Verified_At__c = System.now();
        signer.Status__c = 'Viewed';
        update signer;

        Test.startTest();
        DocGenSignatureController.SaveSignatureResult result =
            DocGenSignatureController.saveSignature(
                'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
                'John Smith',
                true,
                '192.168.1.1',
                'Mozilla/5.0'
            );
        Test.stopTest();

        System.assertEquals(true, result.isComplete, 'Should be complete (only 1 signer)');
        System.assertEquals(0, result.remaining);

        signer = [SELECT Status__c, Signature_Data__c, Consent_Captured__c, Signature_Request__c FROM DocGen_Signer__c WHERE Id = :signer.Id];
        System.assertEquals('Signed', signer.Status__c);
        System.assertEquals('John Smith', signer.Signature_Data__c);
        System.assertEquals(true, signer.Consent_Captured__c);

        // Verify audit record created
        List<DocGen_Signature_Audit__c> audits = [
            SELECT Signer_Name__c, IP_Address__c, Consent_Captured__c, PIN_Verified_At__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c = :signer.Signature_Request__c
        ];
        System.assertEquals(1, audits.size(), 'Audit record should be created');
        System.assertEquals('Multi Signer One', audits[0].Signer_Name__c);
        System.assertNotEquals(null, audits[0].IP_Address__c);
        System.assertEquals(true, audits[0].Consent_Captured__c);
        System.assertNotEquals(null, audits[0].PIN_Verified_At__c);
    }

    @isTest
    static void testSaveSignature_noConsent() {
        DocGen_Signer__c signer = getTestSigner();
        signer.PIN_Verified_At__c = System.now();
        update signer;

        Test.startTest();
        try {
            DocGenSignatureController.saveSignature(
                'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
                'John Smith',
                false,
                '1.2.3.4',
                'Test'
            );
            System.assert(false, 'Should have thrown');
        } catch (Exception e) {
            // AuraHandledException — message not accessible in test context
        }
        Test.stopTest();
    }

    @isTest
    static void testSaveSignature_noPinVerification() {
        Test.startTest();
        try {
            DocGenSignatureController.saveSignature(
                'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
                'John Smith',
                true,
                '1.2.3.4',
                'Test'
            );
            System.assert(false, 'Should have thrown');
        } catch (Exception e) {
            // AuraHandledException — message not accessible in test context
        }
        Test.stopTest();
    }

    @isTest
    static void testSaveSignature_blankName() {
        DocGen_Signer__c signer = getTestSigner();
        signer.PIN_Verified_At__c = System.now();
        update signer;

        Test.startTest();
        try {
            DocGenSignatureController.saveSignature(
                'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
                '',
                true,
                '1.2.3.4',
                'Test'
            );
            System.assert(false, 'Should have thrown');
        } catch (Exception e) {
            // AuraHandledException — message not accessible in test context
        }
        Test.stopTest();
    }

    @isTest
    static void testSaveSignature_invalidToken() {
        Test.startTest();
        try {
            DocGenSignatureController.saveSignature('bad-token', 'Name', true, '1.1.1.1', 'UA');
            System.assert(false, 'Should have thrown');
        } catch (Exception e) {
            // AuraHandledException — message not accessible in test context
        }
        Test.stopTest();
    }

    // =========================================================================
    // Signature Service — Typed Name Stamping
    // =========================================================================

    @isTest
    static void testSignerData_constructor() {
        DocGenSignatureService.SignerData sd = new DocGenSignatureService.SignerData('Buyer', 'John Smith');
        System.assertEquals('Buyer', sd.roleName);
        System.assertEquals('John Smith', sd.typedName);
        System.assertNotEquals(null, sd.signedDate);
    }

    @isTest
    static void testSignerData_constructorWithDate() {
        Datetime dt = System.now();
        DocGenSignatureService.SignerData sd = new DocGenSignatureService.SignerData('Seller', 'Jane Doe', dt);
        System.assertEquals('Seller', sd.roleName);
        System.assertEquals('Jane Doe', sd.typedName);
        System.assertEquals(dt, sd.signedDate);
    }

    @isTest
    static void testStampSignaturesInXml() {
        String docXml = '<w:body><w:p><w:r><w:t>{@Signature_Buyer}</w:t></w:r></w:p></w:body>';
        String relsXml = '<Relationships></Relationships>';
        String ctXml = '<Types></Types>';

        List<DocGenSignatureService.SignerImageData> signers = new List<DocGenSignatureService.SignerImageData>();
        signers.add(new DocGenSignatureService.SignerImageData('Buyer', 'John Smith', System.now()));

        Test.startTest();
        DocGenSignatureService.StampResult result = DocGenSignatureService.stampSignaturesInXml(
            docXml, relsXml, ctXml, signers
        );
        Test.stopTest();

        System.assert(result.documentXml != null);
        System.assert(!result.documentXml.contains('{@Signature_Buyer}'), 'Placeholder should be replaced');
    }

    // =========================================================================
    // Email Service
    // =========================================================================

    @isTest
    static void testSendSignatureEmails() {
        List<DocGenSignatureEmailService.SignerEmail> signers = new List<DocGenSignatureEmailService.SignerEmail>();
        signers.add(new DocGenSignatureEmailService.SignerEmail(
            'Test Signer', 'test@test.com', 'Buyer', 'https://example.com/sign?token=abc', null
        ));

        Test.startTest();
        DocGenSignatureEmailService.sendSignatureRequestEmails(signers, 'Test Document');
        Test.stopTest();
        // No assertions needed — just verifying no exceptions
    }

    // =========================================================================
    // Authenticator Controller (Document Verification)
    // =========================================================================

    @isTest
    static void testVerifyDocument_notFound() {
        Test.startTest();
        DocGenAuthenticatorController.VerificationResult res =
            DocGenAuthenticatorController.verifyDocument('0000000000000000000000000000000000000000000000000000000000000000');
        Test.stopTest();

        System.assertEquals(false, res.isValid);
    }

    @isTest
    static void testVerifyDocument_found() {
        DocGen_Signature_Request__c req = getTestRequest();
        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Test',
            Signer_Email__c = 'test@test.com',
            Signed_Date__c = System.now(),
            Document_Hash_SHA256__c = 'abc123hash',
            IP_Address__c = '1.2.3.4'
        );
        insert audit;

        Test.startTest();
        DocGenAuthenticatorController.VerificationResult res =
            DocGenAuthenticatorController.verifyDocument('abc123hash');
        Test.stopTest();

        System.assertEquals(true, res.isValid);
        System.assertEquals('Test', res.signerName);
    }

    // =========================================================================
    // Sender Controller
    // =========================================================================

    @isTest
    static void testGetSignerRolePicklistValues() {
        Test.startTest();
        List<Map<String, String>> options = DocGenSignatureSenderController.getSignerRolePicklistValues();
        Test.stopTest();
        System.assertNotEquals(null, options);
    }

    @isTest
    static void testGetContactInfo() {
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        Test.startTest();
        Map<String, String> info = DocGenSignatureSenderController.getContactInfo(con.Id);
        Test.stopTest();
        System.assertEquals('Signature Tester', info.get('name'));
    }

    @isTest
    static void testGetPendingSignatureRequests() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        List<Map<String, Object>> results = DocGenSignatureSenderController.getPendingSignatureRequests(acc.Id);
        Test.stopTest();
        System.assert(results.size() >= 1);
    }

    @isTest
    static void testGetDocGenTemplates() {
        Test.startTest();
        List<DocGen_Template__c> templates = DocGenSignatureSenderController.getDocGenTemplates();
        Test.stopTest();
        System.assertNotEquals(null, templates);
    }

    // =========================================================================
    // Setup Controller — Signature Settings
    // =========================================================================

    @isTest
    static void testSaveSignatureSettings() {
        Test.startTest();
        DocGenSetupController.saveSignatureSettings(
            '#FF0000', 'https://logo.png', 'Sign {DocumentTitle}',
            'Please sign', 'Footer text', 'Test Corp', ''
        );
        Test.stopTest();

        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        System.assertEquals('#FF0000', settings.Signature_Email_Brand_Color__c);
        System.assertEquals('Test Corp', settings.Company_Name__c);
    }

    // =========================================================================
    // Queueable constructors (coverage)
    // =========================================================================

    @isTest
    static void testSignaturePdfQueueableConstructor() {
        DocGen_Signature_Request__c req = getTestRequest();
        DocGenSignatureService.SignaturePdfQueueable q = new DocGenSignatureService.SignaturePdfQueueable(req.Id);
        System.assertNotEquals(null, q);
    }

    @isTest
    static void testTemplateSignaturePdfQueueableConstructor() {
        DocGen_Signature_Request__c req = getTestRequest();
        DocGenSignatureService.TemplateSignaturePdfQueueable q = new DocGenSignatureService.TemplateSignaturePdfQueueable(req.Id);
        System.assertNotEquals(null, q);
    }

    // =========================================================================
    // Multi-signer flow
    // =========================================================================

    @isTest
    static void testMultiSignerFlow_twoSigners() {
        DocGen_Signature_Request__c req = getTestRequest();

        // Add a second signer
        DocGen_Signer__c signer2 = new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Multi Signer Two',
            Signer_Email__c = 'signer2@test.com',
            Role_Name__c = 'Seller',
            Secure_Token__c = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            Status__c = 'Pending',
            Sort_Order__c = 2
        );
        insert signer2;

        // Verify PIN and sign first signer
        DocGen_Signer__c signer1 = getTestSigner();
        signer1.PIN_Verified_At__c = System.now();
        signer1.Status__c = 'Viewed';
        update signer1;

        Test.startTest();
        DocGenSignatureController.SaveSignatureResult result1 =
            DocGenSignatureController.saveSignature(
                'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5',
                'Signer One Name',
                true,
                '1.1.1.1',
                'Browser 1'
            );
        Test.stopTest();

        System.assertEquals(false, result1.isComplete, 'Should not be complete — signer 2 pending');
        System.assertEquals(1, result1.remaining);
    }

    // =========================================================================
    // Fetch document data
    // =========================================================================

    @isTest
    static void testFetchDocumentData() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res =
            DocGenSignatureController.fetchDocumentData('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2');
        Test.stopTest();
        // Legacy request with fake Source_Document_Id — preview will be unavailable but shouldn't throw
        System.assertNotEquals(null, res);
    }

    // =========================================================================
    // Stamp and return source
    // =========================================================================

    @isTest
    static void testStampAndReturnSource_invalidToken() {
        Test.startTest();
        try {
            DocGenSignatureController.stampAndReturnSource('bad', 'name');
            System.assert(false, 'Should have thrown');
        } catch (Exception e) {
            // AuraHandledException — message not accessible in test context
        }
        Test.stopTest();
    }
}
