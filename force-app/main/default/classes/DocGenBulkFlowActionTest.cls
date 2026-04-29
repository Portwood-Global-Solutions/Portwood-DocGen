// CxSAST: Test class — SOQL/DML findings are test data operations, not production code paths
@IsTest
private class DocGenBulkFlowActionTest {
    @TestSetup
    static void setup() {
        TestDataFactory.assignAdminPermissionSet();
        DocGen_Template__c temp = new DocGen_Template__c(
            Name = 'Test Bulk Template',
            Base_Object_API__c = 'Account',
            Type__c = 'Word'
        );
        insert temp;

        insert new Account(Name = 'Test Account 1', Website = 'https://test1.com');
        insert new Account(Name = 'Test Account 2', Website = 'https://test2.com');
    }

    @IsTest
    static void testGenerateBulkDocuments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateId = temp.Id;
            req.queryCondition = 'Name = \'Test Account 1\'';

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should have one response');
            System.assertNotEquals(null, responses[0].jobId, 'Should have a jobId');

            DocGen_Job__c job = [SELECT Status__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :responses[0].jobId];
            // Note: Status might be Processing or Completed depending on execution speed in test
            System.assertNotEquals(null, job.Status__c, 'Job should have a status');
        }
    }

    @IsTest
    static void testGenerateBulkDocumentsErrorPath() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Use a null templateId to trigger the error/catch branch
            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateId = null;
            req.queryCondition = 'Name = \'Test\'';

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should have one response');
            System.assertNotEquals(null, responses[0].errorMessage, 'Should have an error message');
            System.assertEquals(null, responses[0].jobId, 'Should not have a jobId on error');
        }
    }

    // ─── Record-IDs collection input ─────────────────────────────────────
    // Lets a Flow that has already filtered records (e.g. via decision logic
    // or a Get Records collection) hand them directly to bulk generation
    // without saving a Query Filter or building a WHERE clause manually.

    @IsTest
    static void testBuildEffectiveCondition_idsOnly() {
        Account a = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];
        String result = DocGenBulkFlowAction.buildEffectiveCondition(null, new List<String>{ a.Id });
        System.assert(result.startsWith('Id IN ('), 'Should start with Id IN, got: ' + result);
        System.assert(result.contains(a.Id), 'Should include the supplied ID');
    }

    @IsTest
    static void testBuildEffectiveCondition_idsAndCondition_combine() {
        Account a = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];
        String result = DocGenBulkFlowAction.buildEffectiveCondition('Industry = \'Tech\'', new List<String>{ a.Id });
        // Expect the user condition to be parenthesized then AND-ed with Id IN
        System.assert(result.contains('Industry'), 'Should preserve user condition');
        System.assert(result.contains('AND Id IN ('), 'Should AND-combine, got: ' + result);
    }

    @IsTest
    static void testBuildEffectiveCondition_userOnly() {
        String result = DocGenBulkFlowAction.buildEffectiveCondition('Industry = \'Tech\'', null);
        System.assertEquals('Industry = \'Tech\'', result);
    }

    @IsTest
    static void testBuildEffectiveCondition_invalidIdRejected() {
        try {
            DocGenBulkFlowAction.buildEffectiveCondition(null, new List<String>{ 'not-an-id-haha' });
            System.assert(false, 'Should have thrown for invalid ID');
        } catch (DocGenException e) {
            System.assert(e.getMessage().contains('Invalid record ID'), 'Got: ' + e.getMessage());
        }
    }

    @IsTest
    static void testBuildEffectiveCondition_blanksSkipped() {
        Account a = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];
        String result = DocGenBulkFlowAction.buildEffectiveCondition(null, new List<String>{ '', null, a.Id, '   ' });
        System.assertEquals('Id IN (\'' + a.Id + '\')', result, 'Blanks should be skipped silently');
    }

    @IsTest
    static void testGenerateBulk_withRecordIdsInput_endToEnd() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            // Two records cause Apex's batch framework to fire 2 chunks at the
            // default batchSize=1, which trips the test-mode "no more than one
            // executeBatch" governor. Two record IDs at batchSize=200 is the
            // valid shape — one Id IN clause, one chunk, one batch invocation.
            List<Account> accts = [SELECT Id FROM Account LIMIT 2];

            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateId = temp.Id;
            req.recordIds = new List<String>{ accts[0].Id, accts[1].Id };
            req.batchSize = 200;

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(
                true,
                responses[0].success,
                'IDs-only path should succeed: ' + responses[0].errorMessage
            );
            DocGen_Job__c job = [SELECT Query_Condition__c FROM DocGen_Job__c WHERE Id = :responses[0].jobId];
            System.assert(
                job.Query_Condition__c.startsWith('Id IN ('),
                'Job should be scoped by Id IN, got: ' + job.Query_Condition__c
            );
            System.assert(job.Query_Condition__c.contains(accts[0].Id), 'Should target first Account');
            System.assert(job.Query_Condition__c.contains(accts[1].Id), 'Should target second Account');
        }
    }

    @IsTest
    static void testBulkFlowActionResponseCoverage() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGenBulkFlowAction.Response res = new DocGenBulkFlowAction.Response();
            res.jobId = null;
            res.errorMessage = 'test';
            System.assertEquals(null, res.jobId, 'jobId should be null when not set');
            System.assertEquals('test', res.errorMessage, 'errorMessage should match assigned value');
        }
    }
}
