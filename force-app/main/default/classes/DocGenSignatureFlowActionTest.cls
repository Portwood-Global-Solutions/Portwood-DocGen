// CxSAST: Test class — SOQL/DML findings are test data operations, not production code paths
@isTest
private class DocGenSignatureFlowActionTest {
    @testSetup
    static void setup() {
        TestDataFactory.createStandardTestData();
        TestDataFactory.attachRealDocxToTestTemplate();
    }

    private static DocGenSignatureFlowAction.Request buildRequest() {
        DocGen_Template__c tmpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();
        DocGenSignatureFlowAction.Request r = new DocGenSignatureFlowAction.Request();
        r.templateId = tmpl.Id;
        r.relatedRecordId = acc.Id;
        r.signerNames = new List<String>{ 'Alice Flow', 'Bob Flow' };
        r.signerEmails = new List<String>{ 'alice@flow.test', 'bob@flow.test' };
        r.signerRoles = new List<String>{ 'Buyer', 'Seller' };
        r.signerContactIds = null;
        return r;
    }

    // =========================================================================
    // Happy path — default silent behavior from Flow
    // =========================================================================

    @isTest
    static void testGenerate_defaultSilent() {
        DocGenSignatureFlowAction.Request req = buildRequest();
        // sendEmails left null — should default to false

        Integer emailsBefore = Limits.getEmailInvocations();

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ req }
        );
        Test.stopTest();

        Integer emailsAfter = Limits.getEmailInvocations();
        System.assertEquals(emailsBefore, emailsAfter, 'Flow default must not send emails');

        System.assertEquals(1, results.size(), 'One result per request');
        DocGenSignatureFlowAction.Result r = results[0];
        System.assertNotEquals(null, r.signatureRequestId, 'signatureRequestId populated');
        System.assertEquals(2, r.signerUrls.size(), 'Two signer URLs');
        System.assertEquals(2, r.signerNames.size(), 'Two signer names echoed');
        System.assertEquals(2, r.signerEmails.size(), 'Two signer emails echoed');
        System.assertEquals(2, r.signerRoles.size(), 'Two signer roles echoed');
        System.assertEquals('Alice Flow', r.signerNames[0]);
        System.assertEquals('alice@flow.test', r.signerEmails[0]);
        System.assertEquals('Buyer', r.signerRoles[0]);
        System.assert(r.signerUrls[0].contains('token='), 'URL contains signing token');

        // Verify the signature request + signers were persisted
        DocGen_Signature_Request__c persisted = [
            SELECT Id, Template__c, Status__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :r.signatureRequestId
            LIMIT 1
        ];
        System.assertEquals('Sent', persisted.Status__c);
        List<DocGen_Signer__c> signers = [
            SELECT Id, Role_Name__c, Signer_Email__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :r.signatureRequestId
            ORDER BY Sort_Order__c
        ];
        System.assertEquals(2, signers.size());
        System.assertEquals('Buyer', signers[0].Role_Name__c);
        System.assertEquals('Seller', signers[1].Role_Name__c);
    }

    // =========================================================================
    // Explicit sendEmails = true path
    // =========================================================================

    @isTest
    static void testGenerate_sendEmailsExplicit() {
        DocGenSignatureFlowAction.Request req = buildRequest();
        req.sendEmails = true;

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertNotEquals(null, results[0].signatureRequestId);
        System.assertEquals(2, results[0].signerUrls.size());
    }

    // =========================================================================
    // Multi-request bulk invocation
    // =========================================================================

    @isTest
    static void testGenerate_multipleRequests() {
        DocGenSignatureFlowAction.Request r1 = buildRequest();
        DocGenSignatureFlowAction.Request r2 = buildRequest();
        r2.signerNames = new List<String>{ 'Carol Flow' };
        r2.signerEmails = new List<String>{ 'carol@flow.test' };
        r2.signerRoles = new List<String>{ 'Witness' };

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ r1, r2 }
        );
        Test.stopTest();

        System.assertEquals(2, results.size(), 'One result per request');
        System.assertEquals(2, results[0].signerUrls.size());
        System.assertEquals(1, results[1].signerUrls.size());
        System.assertEquals('Witness', results[1].signerRoles[0]);
    }

    // =========================================================================
    // Role defaulting (empty / short roles list → "Signer")
    // =========================================================================

    @isTest
    static void testGenerate_roleDefaulting() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerRoles = null; // no roles → should default to "Signer"

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ r }
        );
        Test.stopTest();

        System.assertEquals('Signer', results[0].signerRoles[0]);
        System.assertEquals('Signer', results[0].signerRoles[1]);
    }

    @isTest
    static void testGenerate_partialRolesList() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerRoles = new List<String>{ 'Buyer' }; // only one role for two signers

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ r }
        );
        Test.stopTest();

        System.assertEquals('Buyer', results[0].signerRoles[0]);
        System.assertEquals('Signer', results[0].signerRoles[1], 'Missing role defaults to "Signer"');
    }

    // =========================================================================
    // Empty / null input list
    // =========================================================================

    @isTest
    static void testGenerate_emptyInputList() {
        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>()
        );
        Test.stopTest();
        System.assertEquals(0, results.size());
    }

    @isTest
    static void testGenerate_nullInputList() {
        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(null);
        Test.stopTest();
        System.assertEquals(0, results.size());
    }

    // =========================================================================
    // Validation failures
    // =========================================================================

    @isTest
    static void testValidate_nullTemplateId() {
        DocGenSignatureFlowAction.Request r = new DocGenSignatureFlowAction.Request();
        r.relatedRecordId = TestDataFactory.getTestAccount().Id;
        r.signerNames = new List<String>{ 'X' };
        r.signerEmails = new List<String>{ 'x@test.com' };

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('Template Id'));
        }
        Test.stopTest();
        System.assert(caught, 'Missing templateId must throw');
    }

    @isTest
    static void testValidate_nullRelatedRecordId() {
        DocGenSignatureFlowAction.Request r = new DocGenSignatureFlowAction.Request();
        r.templateId = TestDataFactory.getTestTemplate().Id;
        r.signerNames = new List<String>{ 'X' };
        r.signerEmails = new List<String>{ 'x@test.com' };

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Missing relatedRecordId must throw');
    }

    @isTest
    static void testValidate_emptySignerNames() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerNames = new List<String>();
        r.signerEmails = new List<String>();

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('signer'));
        }
        Test.stopTest();
        System.assert(caught);
    }

    @isTest
    static void testValidate_signerListLengthMismatch() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerEmails = new List<String>{ 'a@test.com' }; // two names, one email

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Length mismatch must throw');
    }

    @isTest
    static void testValidate_blankSignerName() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerNames = new List<String>{ '' };
        r.signerEmails = new List<String>{ 'x@test.com' };

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('Name'));
        }
        Test.stopTest();
        System.assert(caught);
    }

    @isTest
    static void testValidate_blankSignerEmail() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerNames = new List<String>{ 'X' };
        r.signerEmails = new List<String>{ '' };

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('Email'));
        }
        Test.stopTest();
        System.assert(caught);
    }

    // =========================================================================
    // Contact Ids provided for signers
    // =========================================================================

    @isTest
    static void testGenerate_withContactIds() {
        List<Contact> contacts = TestDataFactory.getTestContacts();
        System.assert(contacts.size() >= 2, 'Need at least two test contacts');

        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerContactIds = new List<String>{ contacts[0].Id, contacts[1].Id };

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ r }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        List<DocGen_Signer__c> signers = [
            SELECT Contact__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :results[0].signatureRequestId
            ORDER BY Sort_Order__c
        ];
        System.assertEquals(contacts[0].Id, signers[0].Contact__c, 'First signer linked to first contact');
        System.assertEquals(contacts[1].Id, signers[1].Contact__c, 'Second signer linked to second contact');
    }

    // =========================================================================
    // Null request in the input list
    // =========================================================================

    @isTest
    static void testValidate_nullRequestInList() {
        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ null });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('null'), 'Error mentions null');
        }
        Test.stopTest();
        System.assert(caught, 'Null request must throw');
    }

    // =========================================================================
    // Template not found
    // =========================================================================

    @isTest
    static void testGenerate_templateNotFound() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.templateId = '001000000000000AAA'; // any fake Id

        Test.startTest();
        // Runtime errors (like template not found) are caught and returned in Result
        // so Flows get a structured error instead of crashing the Flow.
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ r }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success, 'Invalid template Id should result in success=false');
        System.assertNotEquals(null, results[0].errorMessage, 'Error message should be populated');
    }
}
