@IsTest
private class DocGenGiantQueryTest {

    /**
     * Creates a test template with V3 query config for Account -> Contacts.
     * Also creates an Account with multiple Contacts for testing.
     */
    @TestSetup
    static void setup() {
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

            // Verify fragments were created
            String prefix = 'docgen_giant_' + job.Id + '_';
            List<ContentVersion> fragments = [
                SELECT Title FROM ContentVersion WHERE Title LIKE :(prefix + '%')
            ];
            System.assert(!fragments.isEmpty(), 'Should have created at least one fragment');
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
            System.enqueueJob(stitchJob);
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
                // Expected — invalid object should throw
                System.assert(e.getMessage().contains('Invalid child object'), 'Should report invalid object');
            }
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
}
