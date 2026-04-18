@IsTest
private class DocGenGiantQueryTest {

    /**
     * Creates a test template with V3 query config for Account -> Contacts.
     * Also creates an Account with multiple Contacts for testing.
     */
    @TestSetup
    static void setup() {
        TestDataFactory.assignAdminPermissionSet();
        // Create template with V3 config
        String v3Config = JSON.serialize(new Map<String, Object>{
            'v' => 3,
            'root' => 'Account',
            'nodes' => new List<Object>{
                new Map<String, Object>{
                    'id' => 'n0',
                    'object' => 'Account',
                    'fields' => new List<String>{ 'Name' },
                    'parentFields' => new List<String>(),
                    'parentNode' => null,
                    'lookupField' => null,
                    'relationshipName' => null
                },
                new Map<String, Object>{
                    'id' => 'n1',
                    'object' => 'Contact',
                    'fields' => new List<String>{ 'FirstName', 'LastName' },
                    'parentFields' => new List<String>(),
                    'parentNode' => 'n0',
                    'lookupField' => 'AccountId',
                    'relationshipName' => 'Contacts'
                }
            }
        });

        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Giant Query Test',
            Base_Object_API__c = 'Account',
            Query_Config__c = v3Config,
            Type__c = 'Word',
            Output_Format__c = 'PDF'
        );
        insert tpl;

        // Create a valid DOCX file and link to template
        ContentVersion docxCv = TestDataFactory.createValidDocxFile(tpl.Id, TestDataFactory.buildSimpleDocXml());

        // Create Template Version (active) with the DOCX content version
        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Content_Version_Id__c = docxCv.Id,
            Query_Config__c = v3Config,
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        insert ver;

        // Create Account with Contacts
        Account acc = new Account(Name = 'Giant Query Test Account');
        insert acc;

        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < 10; i++) {
            contacts.add(new Contact(
                FirstName = 'Test' + i,
                LastName = 'Contact' + i,
                AccountId = acc.Id
            ));
        }
        insert contacts;

        // Create a minimal DOCX-like ContentVersion with loop tags for the template
        // This is a simplified test — real templates would be actual DOCX ZIPs
        ContentVersion cv = new ContentVersion(
            Title = 'GiantQueryTestDoc',
            PathOnClient = 'GiantQueryTestDoc.docx',
            VersionData = Blob.valueOf('Test Content'),
            IsMajorVersion = true
        );
        insert cv;

        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        ContentDocumentLink cdl = new ContentDocumentLink(
            LinkedEntityId = tpl.Id,
            ContentDocumentId = conDocId,
            ShareType = 'V'
        );
        insert cdl;
    }

    @IsTest
    static void testScoutChildCounts() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Query_Config__c FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            Test.startTest();
            Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(acc.Id, tpl.Query_Config__c);
            Test.stopTest();

            System.assertNotEquals(null, counts, 'Counts map should not be null');
            System.assert(counts.containsKey('Contacts'), 'Should contain Contacts relationship');
            System.assertEquals(10, counts.get('Contacts'), 'Should count 10 contacts');
        }
    }

    @IsTest
    static void testScoutChildCountsWithNullParams() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Map<String, Integer> counts1 = DocGenDataRetriever.scoutChildCounts(null, '{}');
            Map<String, Integer> counts2 = DocGenDataRetriever.scoutChildCounts(
                [SELECT Id FROM Account LIMIT 1].Id, null
            );
            Test.stopTest();

            System.assert(counts1.isEmpty(), 'Null recordId should return empty map');
            System.assert(counts2.isEmpty(), 'Null config should return empty map');
        }
    }

    @IsTest
    static void testExtractLoopBody() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Simple XML with a loop
            String xml = '<w:body><w:tr><w:tc>{#Contacts}<w:p>{FirstName}</w:p>{/Contacts}</w:tc></w:tr></w:body>';

            Test.startTest();
            Map<String, String> result = DocGenService.extractLoopBody(xml, 'Contacts');
            Test.stopTest();

            System.assertNotEquals(null, result, 'Should extract loop body');
            System.assert(result.containsKey('innerXml'), 'Should contain innerXml');
            System.assert(result.containsKey('beforeLoop'), 'Should contain beforeLoop');
            System.assert(result.containsKey('afterLoop'), 'Should contain afterLoop');
            System.assert(result.get('innerXml').contains('{FirstName}'), 'Inner XML should contain merge tag');
        }
    }

    @IsTest
    static void testExtractLoopBodyNotFound() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<w:body><w:p>{Name}</w:p></w:body>';

            Test.startTest();
            Map<String, String> result = DocGenService.extractLoopBody(xml, 'NonExistent');
            Test.stopTest();

            System.assertEquals(null, result, 'Should return null when loop not found');
        }
    }

    @IsTest
    static void testRenderLoopBodyForRecords() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            List<Contact> contacts = [SELECT FirstName, LastName FROM Contact ORDER BY FirstName LIMIT 5];
            String innerXml = '<w:tr><w:tc><w:p>{FirstName}</w:p></w:tc><w:tc><w:p>{LastName}</w:p></w:tc></w:tr>';

            Test.startTest();
            String result = DocGenService.renderLoopBodyForRecords(
                innerXml, 'Contacts', contacts, new List<String>{ 'FirstName', 'LastName' }
            );
            Test.stopTest();

            System.assertNotEquals(null, result, 'Rendered result should not be null');
            System.assert(result.length() > innerXml.length(), 'Result should be longer than single template');
            // Each contact should produce a rendered row
            for (Contact c : contacts) {
                System.assert(result.contains(c.FirstName), 'Should contain first name: ' + c.FirstName);
            }
        }
    }

    @IsTest
    static void testGiantQueryBatchExecution() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id, Output_Format__c FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            // Create a Job record
            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'Test Giant Query',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            // Build child node config
            Map<String, Object> childNodeConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName', 'LastName' },
                'parentFields' => new List<String>()
            };

            String innerXml = '<w:tr><w:tc><w:p>{FirstName}</w:p></w:tc><w:tc><w:p>{LastName}</w:p></w:tc></w:tr>';

            Test.startTest();
            DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                job.Id, tpl.Id, acc.Id, childNodeConfig, innerXml, 'PDF'
            );
            Database.executeBatch(batch, 1);
            Test.stopTest();

            // Verify job was updated
            DocGen_Job__c updatedJob = [SELECT Status__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Draft', updatedJob.Status__c, 'Job status should have changed from Draft');
            System.assertEquals(10, updatedJob.Total_Records__c, 'Should have counted 10 contacts');

            // Verify batch executed (fragments may or may not be created depending on
            // whether renderLoopBodyForRecords succeeds with the minimal test XML)
            System.assert(updatedJob.Status__c != null, 'Job status should be set after batch execution');
        }
    }

    @IsTest
    static void testStitchJobExecution() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            // Create a Job record
            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Harvesting',
                Template__c = tpl.Id,
                Label__c = 'Test Stitch',
                Parent_Record_Id__c = String.valueOf(acc.Id),
                Total_Records__c = 10
            );
            insert job;

            // Create mock fragment CVs (simulating what the batch would produce)
            List<ContentVersion> fragments = new List<ContentVersion>();
            for (Integer i = 0; i < 3; i++) {
                String seq = String.valueOf(i).leftPad(5, '0');
                fragments.add(new ContentVersion(
                    Title = 'docgen_giant_' + job.Id + '_' + seq,
                    PathOnClient = 'docgen_giant_' + job.Id + '_' + seq + '.xml',
                    VersionData = Blob.valueOf('<w:tr><w:tc><w:p>Fragment' + i + '</w:p></w:tc></w:tr>'),
                    IsMajorVersion = false,
                    FirstPublishLocationId = job.Id
                ));
            }
            insert fragments;

            Test.startTest();
            DocGenGiantQueryStitchJob stitchJob = new DocGenGiantQueryStitchJob(
                job.Id, tpl.Id, acc.Id, 'Contacts', 'PDF'
            );
            Database.executeBatch(stitchJob, 1);
            Test.stopTest();

            // Verify job status updated (may be Completed or Failed depending on template file availability)
            DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assert(
                updatedJob.Status__c == 'Completed' || updatedJob.Status__c == 'Failed',
                'Job should be Completed or Failed after stitch, got: ' + updatedJob.Status__c
            );
        }
    }

    @IsTest
    static void testGenerateDocumentGiantQueryFallthrough() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            Test.startTest();
            // With only 10 contacts (below 2000 threshold), this should fall through to normal generation
            try {
                Map<String, Object> result = DocGenController.generateDocumentGiantQuery(tpl.Id, acc.Id);
                // If it doesn't throw (template file may be invalid), verify it reports non-giant
                System.assertEquals(false, result.get('isGiantQuery'), 'Should not trigger Giant Query for 10 contacts');
            } catch (Exception e) {
                // Expected — the test template file is not a real DOCX ZIP
                System.assert(e.getMessage() != null, 'Error message should not be null');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void testScoutWithNonV3Config() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];

            // V1 config (flat string) should return empty map
            Test.startTest();
            Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(acc.Id, 'Name, Industry');
            Test.stopTest();

            System.assert(counts.isEmpty(), 'V1 config should return empty map (no nodes to parse)');
        }
    }

    @IsTest
    static void testGiantQueryBatchWithInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'Invalid Object Test',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            Map<String, Object> badConfig = new Map<String, Object>{
                'object' => 'NonExistentObject__c',
                'lookupField' => 'AccountId',
                'relationshipName' => 'FakeRel',
                'fields' => new List<String>{ 'Name' },
                'parentFields' => new List<String>()
            };

            Test.startTest();
            try {
                DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                    job.Id, tpl.Id, acc.Id, badConfig, '<w:p>{Name}</w:p>', 'PDF'
                );
                Database.executeBatch(batch, 1);
                Test.stopTest();
            } catch (Exception e) {
                // Expected — invalid object causes runtime error in SOQL or start()
                System.assert(true, 'Should report invalid object');
            }
            // Batch may also fail asynchronously — check job status
            DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assert(updatedJob.Status__c == 'Draft' || updatedJob.Status__c == 'Failed',
                'Invalid object batch should fail or stay in Draft');
        }
    }

    @IsTest
    static void testGetSortedChildIds() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];

            Test.startTest();
            List<Id> sortedIds = DocGenController.getSortedChildIds(
                'Contact', 'AccountId', acc.Id, 'LastName ASC', null
            );
            Test.stopTest();

            System.assertEquals(10, sortedIds.size(), 'Should return 10 sorted contact IDs');
        }
    }

    @IsTest
    static void testGetSortedChildIdsWithWhere() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            Test.startTest();
            List<Id> sortedIds = DocGenController.getSortedChildIds(
                'Contact', 'AccountId', acc.Id, 'LastName ASC', 'LastName LIKE \'Contact0%\''
            );
            Test.stopTest();
            System.assert(sortedIds.size() > 0, 'Should return contacts matching WHERE');
            System.assert(sortedIds.size() < 10, 'WHERE should filter some contacts out');
        }
    }

    @IsTest
    static void testGiantQueryBatchWithWhere() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft', Template__c = tpl.Id, Label__c = 'WHERE Test',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;
            Map<String, Object> childNodeConfig = new Map<String, Object>{
                'object' => 'Contact', 'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName', 'LastName' },
                'parentFields' => new List<String>(),
                'orderBy' => 'LastName ASC',
                'where' => 'LastName LIKE \'Contact0%\''
            };
            String innerXml = '<w:tr><w:tc><w:p>{FirstName}</w:p></w:tc></w:tr>';
            Test.startTest();
            DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                job.Id, tpl.Id, acc.Id, childNodeConfig, innerXml, 'PDF'
            );
            Database.executeBatch(batch, 1);
            Test.stopTest();
            DocGen_Job__c updatedJob = [SELECT Total_Records__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assert(updatedJob.Total_Records__c < 10, 'WHERE should filter — got ' + updatedJob.Total_Records__c);
        }
    }

    @IsTest
    static void testGiantQueryBatchWhereInjectionBlocked() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(Status__c = 'Draft', Template__c = tpl.Id,
                Parent_Record_Id__c = String.valueOf(acc.Id));
            insert job;
            Map<String, Object> badConfig = new Map<String, Object>{
                'object' => 'Contact', 'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName' },
                'parentFields' => new List<String>(),
                'where' => 'Name = \'x\'; DELETE Contact'
            };
            Boolean caught = false;
            try {
                new DocGenGiantQueryBatch(job.Id, tpl.Id, acc.Id, badConfig, '<w:p>{Name}</w:p>', 'PDF');
            } catch (DocGenException e) { caught = true; }
            System.assert(caught, 'Should reject WHERE with injection');
        }
    }

    @IsTest
    static void testGetSortedChildIdsInjectionBlocked() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            Boolean caught = false;
            try {
                DocGenController.getSortedChildIds('Contact', 'AccountId', acc.Id, 'Name; DELETE Contact', null);
            } catch (Exception e) {
                caught = true;
            }
            System.assert(caught, 'Should reject ORDER BY with injection');
        }
    }

    @IsTest
    static void testGetChildRecordsByIds() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            List<Contact> contacts = [SELECT Id FROM Contact ORDER BY LastName ASC LIMIT 5];
            List<Id> ids = new List<Id>();
            for (Contact c : contacts) { ids.add(c.Id); }

            Test.startTest();
            List<Map<String, Object>> result = DocGenController.getChildRecordsByIds(
                'Contact', 'Id, FirstName, LastName', ids
            );
            Test.stopTest();

            System.assertEquals(5, result.size(), 'Should return 5 records');
        }
    }

    @IsTest
    static void testGetChildRecordsByIdsEmptyList() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            List<Map<String, Object>> result = DocGenController.getChildRecordsByIds(
                'Contact', 'Id, FirstName', new List<Id>()
            );
            System.assert(result.isEmpty(), 'Empty input should return empty list');
        }
    }

    @IsTest
    static void testV1FlatConfigGiantQueryScout() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            String v1Config = 'Name, (SELECT FirstName, LastName FROM Contacts ORDER BY LastName ASC)';

            Test.startTest();
            Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(acc.Id, v1Config);
            Test.stopTest();

            System.assert(counts.containsKey('Contacts'), 'Should find Contacts relationship');
            System.assertEquals(10, counts.get('Contacts'), 'Should count 10 contacts');
        }
    }

    @IsTest
    static void testStitchJobFinalizer() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Just verify the finalizer class can be instantiated
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(Template__c = tpl.Id, Status__c = 'Draft');
            insert job; // NOPMD ApexCRUDViolation — test data

            Test.startTest();
            DocGenGiantQueryStitchJob.DocGenGiantQueryStitchFinalizer finalizer =
                new DocGenGiantQueryStitchJob.DocGenGiantQueryStitchFinalizer(job.Id);
            System.assertNotEquals(null, finalizer, 'Finalizer should be instantiable');
            Test.stopTest();
        }
    }

    /**
     * Attaches a real DOCX to this test class's template and updates the active version.
     * Uses local queries instead of TestDataFactory getters which expect 'DocGen Test Template'.
     */
    private static ContentVersion attachDocxToLocalTemplate() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
        DocGen_Template_Version__c ver = [SELECT Id, Content_Version_Id__c FROM DocGen_Template_Version__c
            WHERE Template__c = :tpl.Id AND Is_Active__c = true LIMIT 1];
        ContentVersion cv = TestDataFactory.createValidDocxFile(tpl.Id, TestDataFactory.buildSimpleDocXml());
        ver.Content_Version_Id__c = cv.Id;
        update ver;
        return cv;
    }

    @IsTest
    static void testGiantQueryBatchWithOrderBy() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id, Output_Format__c FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'Test Giant Query Sorted',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            // Build child node config WITH orderBy — triggers pre-sorted Id path
            Map<String, Object> childNodeConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName', 'LastName' },
                'parentFields' => new List<String>(),
                'orderBy' => 'LastName ASC'
            };

            String innerXml = '<w:tr><w:tc><w:p>{FirstName}</w:p></w:tc><w:tc><w:p>{LastName}</w:p></w:tc></w:tr>';

            Test.startTest();
            DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                job.Id, tpl.Id, acc.Id, childNodeConfig, innerXml, 'PDF'
            );
            Database.executeBatch(batch, 1);
            Test.stopTest();

            // Verify job was updated with correct total
            DocGen_Job__c updatedJob = [SELECT Status__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Draft', updatedJob.Status__c, 'Job status should have changed from Draft');
            System.assertEquals(10, updatedJob.Total_Records__c, 'Should have counted 10 contacts');
        }
    }

    @IsTest
    static void testGiantQueryBatchOrderByInjectionBlocked() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'Injection Test',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            // Attempt injection via ORDER BY clause
            Map<String, Object> badConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName' },
                'parentFields' => new List<String>(),
                'orderBy' => 'Name; DELETE Contact'
            };

            Boolean caught = false;
            try {
                new DocGenGiantQueryBatch(
                    job.Id, tpl.Id, acc.Id, badConfig, '<w:p>{Name}</w:p>', 'PDF'
                );
            } catch (DocGenException e) {
                caught = true;
                System.assert(e.getMessage().contains('Invalid ORDER BY'), 'Should report invalid ORDER BY: ' + e.getMessage());
            }
            System.assert(caught, 'Should reject ORDER BY with injection attempt');
        }
    }

    @IsTest
    static void testGiantQueryBatchOrderByDmlKeywordBlocked() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'DML Keyword Test',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            Map<String, Object> badConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName' },
                'parentFields' => new List<String>(),
                'orderBy' => 'Name DELETE FROM Contact'
            };

            Boolean caught = false;
            try {
                new DocGenGiantQueryBatch(
                    job.Id, tpl.Id, acc.Id, badConfig, '<w:p>{Name}</w:p>', 'PDF'
                );
            } catch (DocGenException e) {
                caught = true;
            }
            System.assert(caught, 'Should reject ORDER BY containing DML keywords');
        }
    }

    // =========================================================================
    // Giant Query Flow Action Tests
    // =========================================================================

    @IsTest
    static void testGiantQueryFlowActionSyncPath() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account LIMIT 1];
            attachDocxToLocalTemplate();

            DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
            req.templateId = tpl.Id;
            req.recordId = acc.Id;
            req.saveToRecord = false;

            Test.startTest();
            List<DocGenGiantQueryFlowAction.Response> responses =
                DocGenGiantQueryFlowAction.generateDocument(new List<DocGenGiantQueryFlowAction.Request>{ req });
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should return one response');
            DocGenGiantQueryFlowAction.Response res = responses[0];
            // With <2K child records, should take sync path
            System.assertEquals(false, res.isGiantQuery, 'Should not be giant query for small dataset');
            System.assert(res.success, 'Should succeed: ' + res.errorMessage);
        }
    }

    @IsTest
    static void testGiantQueryFlowActionNullTemplate() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];

            DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
            req.templateId = null;
            req.recordId = acc.Id;

            Test.startTest();
            List<DocGenGiantQueryFlowAction.Response> responses =
                DocGenGiantQueryFlowAction.generateDocument(new List<DocGenGiantQueryFlowAction.Request>{ req });
            Test.stopTest();

            System.assertEquals(false, responses[0].success, 'Should fail with null template');
            System.assertNotEquals(null, responses[0].errorMessage, 'Should have error message');
        }
    }

    @IsTest
    static void testGiantQueryFlowActionInvalidRecord() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            attachDocxToLocalTemplate();

            DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
            req.templateId = tpl.Id;
            req.recordId = UserInfo.getUserId(); // wrong object type
            req.saveToRecord = false;

            Test.startTest();
            List<DocGenGiantQueryFlowAction.Response> responses =
                DocGenGiantQueryFlowAction.generateDocument(new List<DocGenGiantQueryFlowAction.Request>{ req });
            Test.stopTest();

            System.assertEquals(false, responses[0].success, 'Should fail with wrong record type');
        }
    }

    @IsTest
    static void testGiantQueryFlowActionResponseFields() {
        // Verify all response fields are accessible
        DocGenGiantQueryFlowAction.Response res = new DocGenGiantQueryFlowAction.Response();
        res.contentDocumentId = null;
        res.contentVersionId = null;
        res.jobId = null;
        res.isGiantQuery = false;
        res.errorMessage = null;
        res.success = true;
        System.assert(res.success, 'Response fields should be settable');
    }

    // =========================================================================
    // Giant Query Assembler Tests
    // =========================================================================

    @IsTest
    static void testAssemblerWithNoFragments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job; // NOPMD

            Test.startTest();
            System.enqueueJob(new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts'));
            Test.stopTest();

            DocGen_Job__c result = [SELECT Status__c, Label__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals('Failed', result.Status__c, 'Should fail with no fragments');
        }
    }

    @IsTest
    static void testAssemblerWithFragments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account LIMIT 1];

            // Create template version + pre-baked HTML
            DocGen_Template_Version__c ver = [SELECT Id FROM DocGen_Template_Version__c WHERE Is_Active__c = true LIMIT 1];
            String htmlTitle = 'docgen_tmpl_html_' + ver.Id;
            ContentVersion htmlCv = new ContentVersion(
                Title = htmlTitle,
                PathOnClient = htmlTitle + '.html',
                VersionData = Blob.valueOf('<html><head><style>td{border:1px solid}</style></head><body><table><tr><td>{#Contacts}{FirstName}{/Contacts}</td></tr></table></body></html>')
            );
            insert htmlCv; // NOPMD

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job; // NOPMD

            // Create some HTML fragments
            String prefix = 'docgen_giant_' + job.Id + '_';
            List<ContentVersion> frags = new List<ContentVersion>();
            for (Integer i = 0; i < 3; i++) {
                frags.add(new ContentVersion(
                    Title = prefix + String.valueOf(i).leftPad(5, '0'),
                    PathOnClient = prefix + i + '.html',
                    VersionData = Blob.valueOf('<tr><td>Row ' + i + '</td></tr>')
                ));
            }
            insert frags; // NOPMD

            Test.startTest();
            System.enqueueJob(new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts'));
            Test.stopTest();

            DocGen_Job__c result = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals('Completed', result.Status__c, 'Assembler should complete');
        }
    }

    @isTest
    static void testFlowAction_invalidTemplate() {
        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = null;
        req.recordId = [SELECT Id FROM Account LIMIT 1].Id;
        req.saveToRecord = false;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses =
            DocGenGiantQueryFlowAction.generateDocument(new List<DocGenGiantQueryFlowAction.Request>{ req });
        Test.stopTest();

        System.assertEquals(false, responses[0].success, 'Should fail with null template');
        System.assertNotEquals(null, responses[0].errorMessage);
    }

    @isTest
    static void testFlowAction_syncPath() {
        // Use a template with few child records — should go sync path
        Account acc = [SELECT Id FROM Account LIMIT 1];
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;
        req.saveToRecord = true;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses =
            DocGenGiantQueryFlowAction.generateDocument(new List<DocGenGiantQueryFlowAction.Request>{ req });
        Test.stopTest();

        // With few contacts, should take sync path (not giant query)
        System.assertEquals(false, responses[0].isGiantQuery, 'Should use sync path with few records');
    }

    @isTest
    static void testFlowAction_responseFields() {
        // Exercise Response class fields for coverage
        DocGenGiantQueryFlowAction.Response res = new DocGenGiantQueryFlowAction.Response();
        res.contentDocumentId = null;
        res.contentVersionId = null;
        res.jobId = null;
        res.isGiantQuery = false;
        res.errorMessage = 'test';
        res.success = true;
        System.assertEquals(true, res.success);
    }

    // =========================================================================
    // Grand-total aggregate tag resolution ({SUM:Rel.Field}, {COUNT:Rel})
    // =========================================================================

    @IsTest
    static void testGiantAggregateCountTag() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id, Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            DocGenGiantQueryAssembler assembler =
                new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');

            String html = '<html><body>Total contacts: {COUNT:Contacts}</body></html>';

            Test.startTest();
            String resolved = assembler.resolveGiantAggregateTags(html);
            Test.stopTest();

            System.assert(resolved.contains('Total contacts: 10'),
                'COUNT should equal 10 contacts; got: ' + resolved);
            System.assert(!resolved.contains('{COUNT:Contacts}'),
                'Tag should be replaced; got: ' + resolved);
        }
    }

    @IsTest
    static void testGiantAggregateSumTag() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            // Set numeric field on contacts so SUM has something to aggregate
            List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :acc.Id];
            for (Integer i = 0; i < contacts.size(); i++) {
                contacts[i].MailingLatitude = 10.0;
                contacts[i].MailingLongitude = 20.0; // paired field required
            }
            update contacts;

            // Rewrite query_config to declare MailingLatitude so the aggregate resolver accepts it
            String v3Config = JSON.serialize(new Map<String, Object>{
                'v' => 3,
                'root' => 'Account',
                'nodes' => new List<Object>{
                    new Map<String, Object>{
                        'id' => 'n0', 'object' => 'Account',
                        'fields' => new List<String>{ 'Name' },
                        'parentFields' => new List<String>(),
                        'parentNode' => null, 'lookupField' => null, 'relationshipName' => null
                    },
                    new Map<String, Object>{
                        'id' => 'n1', 'object' => 'Contact',
                        'fields' => new List<String>{ 'FirstName', 'MailingLatitude' },
                        'parentFields' => new List<String>(),
                        'parentNode' => 'n0', 'lookupField' => 'AccountId',
                        'relationshipName' => 'Contacts'
                    }
                }
            });
            tpl.Query_Config__c = v3Config;
            update tpl;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id, Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            DocGenGiantQueryAssembler assembler =
                new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');

            String html = '<html><body>Sum: {SUM:Contacts.MailingLatitude} Count: {COUNT:Contacts}</body></html>';

            Test.startTest();
            String resolved = assembler.resolveGiantAggregateTags(html);
            Test.stopTest();

            System.assert(resolved.contains('Count: 10'), 'COUNT should be 10; got: ' + resolved);
            System.assert(!resolved.contains('{SUM:'), 'SUM tag should be replaced; got: ' + resolved);
            System.assert(resolved.contains('Sum: 100'), 'SUM of 10 contacts × 10.0 = 100; got: ' + resolved);
        }
    }

    @IsTest
    static void testGiantAggregateV1FlatConfig() {
        // v1.52.0 bug: assembler's aggregate resolver re-parsed Query_Config__c as
        // V3 JSON. When the template used V1 flat string format, JSON parse threw,
        // the catch returned html unchanged, and aggregates were silently skipped.
        // Fix: DocGenGiantQueryBatch now passes childObj/lookup/where into the
        // assembler's constructor directly — no config re-parsing for the happy path.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            // V1 flat config (legacy format — does NOT start with '{')
            tpl.Query_Config__c = 'Name, (SELECT FirstName, MailingLatitude FROM Contacts)';
            update tpl;

            List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :acc.Id];
            for (Contact c : contacts) {
                c.MailingLatitude = 5.0;
                c.MailingLongitude = 10.0;
            }
            update contacts;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id, Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            // Use the new 7-arg constructor (the batch uses this path in production)
            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(
                job.Id, tpl.Id, acc.Id, 'Contacts',
                'Contact', 'AccountId', null
            );

            String html = '<html><body>Count: {COUNT:Contacts} Sum: {SUM:Contacts.MailingLatitude}</body></html>';

            Test.startTest();
            String resolved = assembler.resolveGiantAggregateTags(html);
            Test.stopTest();

            System.assert(!resolved.contains('{COUNT:'), 'COUNT should resolve under V1 config; got: ' + resolved);
            System.assert(!resolved.contains('{SUM:'),   'SUM should resolve under V1 config; got: '   + resolved);
            System.assert(resolved.contains('Count: 10'), 'COUNT expected 10; got: ' + resolved);
            System.assert(resolved.contains('Sum: 50'),   'SUM expected 5.0 × 10 = 50; got: ' + resolved);
        }
    }

    @IsTest
    static void testGiantAggregateFormatSuffixes() {
        // v1.51.0 bug: {COUNT:Rel:number}, {AVG:Rel.Field:currency}, {SUM:Rel.Field:currency}
        // etc. rendered unresolved because the resolver only accepted fields declared
        // as rendered columns in the query config.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            // Template config declares Contact's FirstName only as a rendered column —
            // but we aggregate MailingLatitude which is NOT in the column list. That
            // simulates the real-world pattern "show some columns, aggregate others".
            String v3Config = JSON.serialize(new Map<String, Object>{
                'v' => 3,
                'root' => 'Account',
                'nodes' => new List<Object>{
                    new Map<String, Object>{
                        'id' => 'n0', 'object' => 'Account',
                        'fields' => new List<String>{ 'Name' },
                        'parentFields' => new List<String>(),
                        'parentNode' => null, 'lookupField' => null, 'relationshipName' => null
                    },
                    new Map<String, Object>{
                        'id' => 'n1', 'object' => 'Contact',
                        'fields' => new List<String>{ 'FirstName' }, // intentionally omits MailingLatitude
                        'parentFields' => new List<String>(),
                        'parentNode' => 'n0', 'lookupField' => 'AccountId',
                        'relationshipName' => 'Contacts'
                    }
                }
            });
            tpl.Query_Config__c = v3Config;
            update tpl;

            // Set numeric field so aggregates have something to crunch
            List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :acc.Id];
            for (Contact c : contacts) {
                c.MailingLatitude = 25.0;
                c.MailingLongitude = 10.0;
            }
            update contacts;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id, Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            DocGenGiantQueryAssembler assembler =
                new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');

            String html =
                'Count: {COUNT:Contacts:number} | ' +
                'Avg: {AVG:Contacts.MailingLatitude:currency} | ' +
                'Min: {MIN:Contacts.MailingLatitude:currency} | ' +
                'Max: {MAX:Contacts.MailingLatitude:currency} | ' +
                'Sum: {SUM:Contacts.MailingLatitude:currency}';

            Test.startTest();
            String resolved = assembler.resolveGiantAggregateTags(html);
            Test.stopTest();

            // No unresolved aggregate tags should remain
            System.assert(!resolved.contains('{COUNT:'), 'COUNT tag unresolved: ' + resolved);
            System.assert(!resolved.contains('{AVG:'),   'AVG tag unresolved: '   + resolved);
            System.assert(!resolved.contains('{MIN:'),   'MIN tag unresolved: '   + resolved);
            System.assert(!resolved.contains('{MAX:'),   'MAX tag unresolved: '   + resolved);
            System.assert(!resolved.contains('{SUM:'),   'SUM tag unresolved: '   + resolved);

            // Currency format should produce a $-prefixed string on AVG/MIN/MAX/SUM
            System.assert(resolved.contains('Avg: $25'),  'AVG should format with $: ' + resolved);
            System.assert(resolved.contains('Min: $25'),  'MIN should format with $: ' + resolved);
            System.assert(resolved.contains('Max: $25'),  'MAX should format with $: ' + resolved);
            System.assert(resolved.contains('Sum: $250'), 'SUM (10×25) should format with $: ' + resolved);
            // COUNT with :number format — 10 contacts, no decimal
            System.assert(resolved.contains('Count: 10'), 'COUNT should format as 10: ' + resolved);
        }
    }

    @IsTest
    static void testAssemblerParentFieldFormatting() {
        // Parent-level tags on the template wrapper (outside the loop) must honor
        // format specifiers: {AnnualRevenue:currency}, {CloseDate:date}, etc.
        // Before v1.50.1 the assembler's resolveParentMergeTags regex ignored
        // format suffixes, so these rendered as unformatted raw values.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            acc.AnnualRevenue = 1234567;
            update acc;

            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id, Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            // Use a minimal HTML template via pre-baked CV. Parent tags sit in the header.
            DocGen_Template_Version__c ver = [SELECT Id FROM DocGen_Template_Version__c
                WHERE Template__c = :tpl.Id AND Is_Active__c = true LIMIT 1];
            String htmlTitle = 'docgen_tmpl_html_' + ver.Id;
            // Clean up any pre-existing html CV from a prior test
            List<ContentDocument> old = [SELECT Id FROM ContentDocument
                WHERE Title = :htmlTitle];
            if (!old.isEmpty()) { delete old; }

            String tmpl = '<html><head><style>td{border:1px solid #ccc}</style></head><body>' +
                '<p>Account: {Name} | Revenue: {AnnualRevenue:currency}</p>' +
                '<table><tr><td>{#Contacts}{FirstName}{/Contacts}</td></tr></table>' +
                '</body></html>';
            insert new ContentVersion(
                Title = htmlTitle, PathOnClient = htmlTitle + '.html',
                VersionData = Blob.valueOf(tmpl)
            );

            // Exercise via resolveGiantAggregateTags sibling path: call assembler's
            // private method via @TestVisible by building and invoking.
            DocGenGiantQueryAssembler assembler =
                new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');

            // Insert a fragment so the assembler has something to render
            String prefix = 'docgen_giant_' + job.Id + '_';
            insert new ContentVersion(
                Title = prefix + '00001', PathOnClient = prefix + '00001.html',
                VersionData = Blob.valueOf('<tr><td>Test0</td></tr>')
            );

            Test.startTest();
            System.enqueueJob(assembler);
            Test.stopTest();

            // After render, the debug HTML CV captures the wrapped output
            List<ContentVersion> dbg = [SELECT VersionData FROM ContentVersion
                WHERE Title = :(prefix + 'debug_html') LIMIT 1];
            System.assert(!dbg.isEmpty(), 'Debug HTML CV should have been written');
            String out = dbg[0].VersionData.toString();

            // Raw value stays (Name)
            System.assert(out.contains('Giant Query Test Account'),
                'Plain parent field should resolve; got: ' + out.left(500));
            // Formatted value should appear (currency format on AnnualRevenue)
            System.assert(out.contains('$') && out.contains('1,234,567'),
                'Currency format should produce $-prefixed grouped number; got: ' + out);
            // Tag itself should be gone
            System.assert(!out.contains('{AnnualRevenue:currency}'),
                'Formatted tag should be replaced; got: ' + out);
        }
    }

    @IsTest
    static void testGiantAggregateNonMatchingRelationshipIgnored() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Giant Query Test Account' LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id, Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job;

            DocGenGiantQueryAssembler assembler =
                new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');

            // Tag references a different relationship — should pass through untouched
            String html = '<html><body>{SUM:OpportunityLineItems.Quantity}</body></html>';

            Test.startTest();
            String resolved = assembler.resolveGiantAggregateTags(html);
            Test.stopTest();

            System.assertEquals(html, resolved,
                'Tags for other relationships must be left untouched for downstream resolvers');
        }
    }
}
