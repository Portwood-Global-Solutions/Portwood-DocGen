@IsTest
private class DocGenTests {
    @TestSetup
    static void setup() {
        TestDataFactory.createStandardTestData();

        // Link a fake content file to the template (needed for testVersioning)
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        ContentVersion cv = new ContentVersion(
            Title = 'TestDoc',
            PathOnClient = 'TestDoc.docx',
            VersionData = Blob.valueOf('Test Content'),
            IsMajorVersion = true
        );
        insert cv;

        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');
    }

    @IsTest
    static void testGenerationFlow() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            // Use V1 config for this legacy test
            tpl.Query_Config__c = 'Name, AccountSource';
            update tpl;

            Account acc = TestDataFactory.getTestAccount();

            Test.startTest();
            Map<String, Object> result = DocGenController.generateDocumentData(tpl.Id, acc.Id);
            Test.stopTest();

            System.assertNotEquals(null, result.get('data'), 'Data should not be null');
            System.assertNotEquals(null, result.get('templateFile'), 'File should not be null');
            Map<String, Object> data = (Map<String, Object>) result.get('data');
            System.assertEquals('DocGen Test Account', data.get('Name'), 'Account Name should match test data');
        }
    }

    @IsTest
    static void testGetTemplates() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            List<DocGen_Template__c> tpls = DocGenController.getTemplatesForObject('Account');
            System.assertEquals(1, tpls.size(), 'Should return 1 template for Account');
        }
    }
    @IsTest
    static void testVersioning() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            // 1. Setup - Create V1 Record
            ContentVersion cv1 = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Title = 'TestDoc' LIMIT 1];

            DocGen_Template_Version__c v1 = new DocGen_Template_Version__c(
                Template__c = tpl.Id,
                Content_Version_Id__c = cv1.Id,
                Is_Active__c = true,
                Type__c = 'Word',
                Base_Object_API__c = 'Account',
                Category__c = 'General',
                Description__c = 'V1 Description'
            );
            insert v1;

            // 2. Upload "V2" File
            ContentVersion cv2 = new ContentVersion(
                Title = 'TestDoc_V2',
                PathOnClient = 'TestDoc_V2.docx',
                VersionData = Blob.valueOf('V2 Content') // Distinct content
            );
            insert cv2;

            // Link V2 to Template (simulates upload)
            Id conDocId2 = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv2.Id].ContentDocumentId;
            ContentDocumentLink cdl2 = new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId2,
                ShareType = 'V'
            );
            insert cdl2;

            // Create V2 Version Record (Active)
            DocGen_Template_Version__c v2 = new DocGen_Template_Version__c(
                Template__c = tpl.Id,
                Content_Version_Id__c = cv2.Id,
                Is_Active__c = true,
                Type__c = 'Word',
                Base_Object_API__c = 'Account',
                Category__c = 'General',
                Description__c = 'V2 Description'
            );
            insert v2;

            // Deactivate V1
            v1.Is_Active__c = false;
            update v1;

            // 3. Verify Generation uses V2
            Test.startTest();
            String contentV2 = DocGenTemplateManager.getTemplateFileContent(tpl.Id);
            System.assertEquals(
                EncodingUtil.base64Encode(Blob.valueOf('V2 Content')),
                contentV2,
                'Should return V2 content'
            );

            // 4. Activate V1
            DocGenController.activateVersion(v1.Id);

            String contentV1 = DocGenTemplateManager.getTemplateFileContent(tpl.Id);
            System.assertEquals(
                EncodingUtil.base64Encode(Blob.valueOf('Test Content')),
                contentV1,
                'Should return V1 content'
            );
            Test.stopTest();
        }
    }
}
