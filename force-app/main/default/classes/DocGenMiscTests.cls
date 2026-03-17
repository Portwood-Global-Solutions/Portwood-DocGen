@isTest
private class DocGenMiscTests {

    @testSetup
    static void setup() {
        Account acc = new Account(Name = 'Misc Test Account', AccountSource = 'Web', Website = 'https://test.com');
        insert acc;

        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Misc Test Template',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, AccountSource',
            Type__c = 'Word'
        );
        insert tpl;
    }

    /**
     * Creates a ContentVersion linked to the test template (fake content).
     */
    private static ContentVersion createTestFile() {
        ContentVersion cv = new ContentVersion(
            Title = 'MiscTestDoc',
            PathOnClient = 'MiscTestDoc.docx',
            VersionData = Blob.valueOf('Not a real DOCX file')
        );
        insert cv;

        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        insert new ContentDocumentLink(
            LinkedEntityId = tpl.Id,
            ContentDocumentId = conDocId,
            ShareType = 'V'
        );
        return cv;
    }

    /**
     * Builds a minimal valid DOCX (ZIP) with template merge tags and links to template.
     */
    private static ContentVersion createValidDocxFile(String docXml) {
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
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '</Relationships>'
        ));
        zw.addEntry('word/document.xml', Blob.valueOf(docXml));

        ContentVersion cv = new ContentVersion(
            Title = 'ValidDocx',
            PathOnClient = 'ValidDocx.docx',
            VersionData = zw.getArchive()
        );
        insert cv;

        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        insert new ContentDocumentLink(
            LinkedEntityId = tpl.Id,
            ContentDocumentId = conDocId,
            ShareType = 'V'
        );
        return cv;
    }

    // =========================================================================
    // DocGenSetupController
    // =========================================================================

    @isTest
    static void testGetOrgUrl() {
        Test.startTest();
        String orgUrl = DocGenSetupController.getOrgUrl();
        Test.stopTest();

        System.assertNotEquals(null, orgUrl);
        System.assert(orgUrl.length() > 0);
    }

    @isTest
    static void testGetSettings() {
        Test.startTest();
        DocGen_Settings__c settings = DocGenSetupController.getSettings();
        Test.stopTest();

        System.assertNotEquals(null, settings);
    }

    @isTest
    static void testSaveSettings() {
        Test.startTest();
        DocGenSetupController.saveSettings('https://example.my.site.com');
        Test.stopTest();

        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        System.assertEquals('https://example.my.site.com', settings.Experience_Site_Url__c);
    }

    @isTest
    static void testSaveSettingsUpdatesExisting() {
        DocGenSetupController.saveSettings('https://first.my.site.com');

        Test.startTest();
        DocGenSetupController.saveSettings('https://second.my.site.com');
        Test.stopTest();

        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        System.assertEquals('https://second.my.site.com', settings.Experience_Site_Url__c);
    }

    // =========================================================================
    // DocGenDataRetriever
    // =========================================================================

    @isTest
    static void testGetRecordDataWithValidFields() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, AccountSource');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Misc Test Account', result.get('Name'));
        System.assertEquals('Web', result.get('AccountSource'));
    }

    @isTest
    static void testGetRecordDataWithInvalidObject() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenDataRetriever.getRecordData(acc.Id, 'NotARealObject__c', 'Name');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw AuraHandledException for invalid object');
    }

    @isTest
    static void testGetRecordDataWithBlankParams() {
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenDataRetriever.getRecordData(null, '', '');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw AuraHandledException for blank params');
    }

    @isTest
    static void testGetRecordDataWithRelationshipField() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, Owner.Name');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Misc Test Account', result.get('Name'));
        System.assert(result.containsKey('Owner'), 'Should contain Owner relationship data');
    }

    @isTest
    static void testGetRecordDataWithNonExistentField() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, TotallyFakeField__xyz');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Misc Test Account', result.get('Name'));
    }

    @isTest
    static void testGetRecordDataWithBlankObjectOrFields() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Boolean caught1 = false;
        Boolean caught2 = false;

        Test.startTest();
        try {
            DocGenDataRetriever.getRecordData(acc.Id, '', 'Name');
        } catch (AuraHandledException e) {
            caught1 = true;
        }
        try {
            DocGenDataRetriever.getRecordData(acc.Id, 'Account', '');
        } catch (AuraHandledException e) {
            caught2 = true;
        }
        Test.stopTest();

        System.assert(caught1, 'Should throw for blank object name');
        System.assert(caught2, 'Should throw for blank fields config');
    }

    // =========================================================================
    // DocGenFlowAction
    // =========================================================================

    @isTest
    static void testGenerateDocumentFlowActionErrorPath() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, responses.size());
        System.assertNotEquals(null, responses[0].errorMessage);
        System.assertEquals(null, responses[0].contentDocumentId);
    }

    @isTest
    static void testGenerateDocumentFlowActionResponseStructure() {
        DocGenFlowAction.Response res = new DocGenFlowAction.Response();
        res.contentDocumentId = null;
        res.errorMessage = 'test error';
        System.assertEquals(null, res.contentDocumentId);
        System.assertEquals('test error', res.errorMessage);
    }

    // =========================================================================
    // DocGenException
    // =========================================================================

    @isTest
    static void testDocGenExceptionConstruction() {
        DocGenException ex = new DocGenException('Test error message');
        System.assertEquals('Test error message', ex.getMessage());

        DocGenException exCause = new DocGenException('Wrapped error', new DmlException());
        System.assertEquals('Wrapped error', exCause.getMessage());
        System.assertNotEquals(null, exCause.getCause());

        DocGenException exDefault = new DocGenException();
        System.assertNotEquals(null, exDefault);
    }

    // =========================================================================
    // DocGenService — error paths
    // =========================================================================

    @isTest
    static void testProcessDocumentThrowsOnInvalidDocx() {
        createTestFile();
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        try {
            DocGenService.processDocument(tpl.Id, acc.Id);
            System.assert(false, 'Expected exception');
        } catch (DocGenException e) {
            System.assert(e.getMessage().length() > 0);
        } catch (Exception e) {
            System.assert(e.getMessage().length() > 0);
        }
        Test.stopTest();
    }

    @isTest
    static void testProcessDocumentNullTemplate() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        try {
            DocGenService.processDocument(null, acc.Id);
            System.assert(false, 'Expected exception');
        } catch (Exception e) {
            System.assert(e.getMessage().length() > 0);
        }
        Test.stopTest();
    }

    @isTest
    static void testGenerateDocumentNullRecord() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        try {
            DocGenService.generateDocument(tpl.Id, null);
            System.assert(false, 'Expected exception');
        } catch (Exception e) {
            System.assert(e.getMessage().length() > 0);
        }
        Test.stopTest();
    }

    // =========================================================================
    // DocGenService — valid DOCX processing (covers processXml, resolveValue,
    // mergeRunsInTags, generateDocTitle, saveFile, buildImageXml)
    // =========================================================================

    @isTest
    static void testProcessDocumentWithSimpleTags() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{AccountSource}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.get('blob'));
        System.assertNotEquals(null, result.get('title'));
        System.assertEquals('Word', result.get('templateType'));
    }

    @isTest
    static void testGenerateDocumentWithValidDocx() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Hello {Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'Should return ContentDocumentId');
    }

    @isTest
    static void testProcessDocumentMergesRunsInTags() {
        // Simulate Word splitting {Name} across multiple <w:t> elements
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p>' +
            '<w:r><w:t>{Na</w:t></w:r>' +
            '<w:r><w:t>me}</w:t></w:r>' +
            '</w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithSectionTag() {
        // Boolean-true section (Account always truthy via Owner)
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Before {Name} After</w:t></w:r></w:p>' +
            '</w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithHtmlFieldValue() {
        // Account Website field is plain text, but we test that HTML stripping works
        // by using a field config that includes Website
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name} - {Website}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        // Update template query config to include Website
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, AccountSource, Website';
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithTitleFormat() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Document_Title_Format__c = 'Doc_{Name}_{AccountSource}';
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        String title = (String) result.get('title');
        System.assert(title.contains('Misc Test Account'), 'Title should contain account name');
        System.assert(title.contains('Web'), 'Title should contain account source');
    }

    @isTest
    static void testProcessDocumentWithImageTag() {
        // {%SomeImage} tag — resolveValue returns null so image is skipped, but code path is covered
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name} {%NonExistentImage}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithImageSizeTag() {
        // {%SomeImage:200x150} — image with dimensions
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%NonExistentImage:200x150}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithClosingTagOnly() {
        // Orphaned {/something} tag — should be output as literal
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{/orphan}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithUnmatchedSection() {
        // {#section} without closing {/section} — output as literal
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#NoClose}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithHeaderAndFooter() {
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
        String bodyXml = '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        zw.addEntry('word/document.xml', Blob.valueOf(bodyXml));
        String headerXml = '<?xml version="1.0"?><w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Header: {Name}</w:t></w:r></w:p></w:hdr>';
        zw.addEntry('word/header1.xml', Blob.valueOf(headerXml));
        String footerXml = '<?xml version="1.0"?><w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Footer: {AccountSource}</w:t></w:r></w:p></w:ftr>';
        zw.addEntry('word/footer1.xml', Blob.valueOf(footerXml));

        ContentVersion cv = new ContentVersion(Title='HeaderFooterDoc', PathOnClient='HeaderFooterDoc.docx', VersionData=zw.getArchive());
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        insert new ContentDocumentLink(LinkedEntityId=tpl.Id, ContentDocumentId=conDocId, ShareType='V');

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testGenerateDocumentWithPdfFormat() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Output_Format__c = 'PDF';
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId);
    }

    // =========================================================================
    // DocGenService — additional coverage for uncovered branches
    // =========================================================================

    @isTest
    static void testProcessDocumentWithChildSubquery() {
        // Use Contacts subquery to exercise loop processing with records list
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, (SELECT FirstName, LastName FROM Contacts)';
        tpl.Base_Object_API__c = 'Account';
        update tpl;

        // Add a contact to the account
        Account acc = [SELECT Id FROM Account LIMIT 1];
        insert new Contact(FirstName = 'Loop', LastName = 'Tester', AccountId = acc.Id);

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{#Contacts}{FirstName} {LastName}{/Contacts}</w:t></w:r></w:p>' +
            '</w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithTableRowLoop() {
        // Section inside a <w:tr> — exercises table row expansion code
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, (SELECT FirstName, LastName FROM Contacts)';
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];
        insert new Contact(FirstName = 'Row', LastName = 'Expand', AccountId = acc.Id);

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:tbl>' +
            '<w:tr><w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Last</w:t></w:r></w:p></w:tc></w:tr>' +
            '<w:tr><w:tc><w:p><w:r><w:t>{#Contacts}{FirstName}</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>{LastName}{/Contacts}</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithNestedDotPath() {
        // Owner.Name uses dotted path — exercises resolveValue with nested map
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Owner.Name';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Owner.Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithBase64ImageField() {
        // Inject a base64 data URI value to exercise buildImageXml data URI path
        // We can't easily inject custom field data, but we can test the image tag with
        // a ContentVersion ID. Create a small PNG and reference it.
        ContentVersion imgCv = new ContentVersion(
            Title = 'TestImage',
            PathOnClient = 'TestImage.png',
            VersionData = Blob.valueOf('PNG_FAKE_DATA')
        );
        insert imgCv;
        imgCv = [SELECT Id FROM ContentVersion WHERE Id = :imgCv.Id];

        // Template with {%ImageField} — field value will be a CV Id
        // We need the query to return a field containing the CV Id
        // Use Description field on Account to hold the CV Id
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = imgCv.Id;
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description:100x80}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithHtmlRichText() {
        // Field value contains <p>/<div> HTML that should be stripped
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = '<p>Hello</p><div>World</div>';
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithPowerPoint() {
        // PowerPoint template — exercises the ppt/slides branch
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Type__c = 'PowerPoint';
        update tpl;

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('[Content_Types].xml', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/>' +
            '</Types>'
        ));
        zw.addEntry('_rels/.rels', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
        ));
        String slideXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:cSld><p:spTree><p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>';
        zw.addEntry('ppt/slides/slide1.xml', Blob.valueOf(slideXml));

        ContentVersion cv = new ContentVersion(Title='PPTDoc', PathOnClient='PPTDoc.pptx', VersionData=zw.getArchive());
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId=tpl.Id, ContentDocumentId=conDocId, ShareType='V');

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
        System.assertEquals('PowerPoint', result.get('templateType'));
    }

    @isTest
    static void testProcessDocumentNoTitleFallsBackToName() {
        // No Document_Title_Format__c — falls back to record Name
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Document_Title_Format__c = null;
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        String title = (String) result.get('title');
        System.assertEquals('Misc Test Account', title, 'Should fall back to record Name');
    }

    // =========================================================================
    // DocGenDataRetriever — additional coverage
    // =========================================================================

    @isTest
    static void testGetRecordDataWithSubquery() {
        // Exercises the subquery (parenthesized SELECT) branch in field parsing
        Account acc = [SELECT Id FROM Account LIMIT 1];
        insert new Contact(FirstName = 'Sub', LastName = 'Query', AccountId = acc.Id);

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, (SELECT FirstName, LastName FROM Contacts)');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Misc Test Account', result.get('Name'));
        System.assert(result.containsKey('Contacts'), 'Should contain Contacts subquery');
    }

    @isTest
    static void testGetRecordDataWithAutoAppendC() {
        // Exercises the __c auto-append branch — AccountSource exists, but try without __c
        // "Website" is a standard field so this tests the field-not-found skip path
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, ZZZInvalidField');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Misc Test Account', result.get('Name'));
    }

    @isTest
    static void testGetRecordDataWithInvalidRelationship() {
        // Exercises the invalid relationship field branch (relFound = false)
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, FakeRel__r.Field');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Misc Test Account', result.get('Name'));
    }

    @isTest
    static void testGetRecordDataAllFieldsInvalid() {
        // Exercises the cleanSelect == '' fallback to 'Id'
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'ZZZFake1, ZZZFake2');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.get('Id'));
    }

    @isTest
    static void testGetRecordDataWithBlankFieldPart() {
        // Exercises the blank field part skip (trailing comma)
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, , AccountSource');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Misc Test Account', result.get('Name'));
    }

    @isTest
    static void testGetRecordDataWithAddressField() {
        // Exercises the Address type branch in mapSObject
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.BillingStreet = '123 Main St';
        acc.BillingCity = 'TestCity';
        acc.BillingState = 'CA';
        acc.BillingPostalCode = '90210';
        acc.BillingCountry = 'US';
        update acc;

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, BillingAddress');
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.containsKey('BillingAddress'), 'Should contain BillingAddress compound field');
    }

    // =========================================================================
    // DocGenSetupController — additional coverage
    // =========================================================================

    @isTest
    static void testSaveEmailBrandingSettings() {
        Test.startTest();
        DocGenSetupController.saveEmailBrandingSettings(
            'Acme Corp', 'https://logo.png', '#FF5733', 'Please Sign {DocumentTitle}', 'Footer text here'
        );
        Test.stopTest();

        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        System.assertEquals('Acme Corp', settings.Company_Name__c);
        System.assertEquals('https://logo.png', settings.Signature_Email_Logo_Url__c);
        System.assertEquals('#FF5733', settings.Signature_Email_Brand_Color__c);
        System.assertEquals('Please Sign {DocumentTitle}', settings.Signature_Email_Subject__c);
        System.assertEquals('Footer text here', settings.Signature_Email_Footer_Text__c);
    }

    @isTest
    static void testSaveEmailBrandingSettingsUpdatesExisting() {
        DocGenSetupController.saveEmailBrandingSettings('First', null, null, null, null);

        Test.startTest();
        DocGenSetupController.saveEmailBrandingSettings('Second', 'https://logo2.png', '#000000', 'Subject2', 'Footer2');
        Test.stopTest();

        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        System.assertEquals('Second', settings.Company_Name__c);
    }

    // =========================================================================
    // DocGenFlowAction — success path coverage
    // =========================================================================

    @isTest
    static void testGenerateDocumentFlowActionSuccess() {
        // Create a valid DOCX so the flow action succeeds (covers contentDocumentId assignment)
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, responses.size());
        System.assertNotEquals(null, responses[0].contentDocumentId, 'Should have a document ID on success');
        System.assertEquals(null, responses[0].errorMessage, 'Should not have error on success');
    }

    // =========================================================================
    // DocGenTemplateManager — additional coverage
    // =========================================================================

    @isTest
    static void testGetTemplateFileContentNullId() {
        Boolean caught = false;
        Test.startTest();
        try {
            DocGenTemplateManager.getTemplateFileContent(null);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Should throw for null template ID');
    }

    @isTest
    static void testGetTemplateFileContentNoFile() {
        // Template exists but no file attached and no active version
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Boolean caught = false;
        Test.startTest();
        try {
            DocGenTemplateManager.getTemplateFileContent(tpl.Id);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Should throw when no file found');
    }

    // =========================================================================
    // DocGenService — processDocumentAsPdf
    // =========================================================================

    @isTest
    static void testProcessDocumentAsPdfWord() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Hello {Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocumentAsPdf(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Should return a PDF blob');
        System.assertEquals('PDF', result.get('outputFormat'));
        System.assertEquals('Word', result.get('templateType'));
        System.assertNotEquals(null, result.get('title'));
    }

    @isTest
    static void testProcessDocumentAsPdfThrowsForPowerPoint() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Type__c = 'PowerPoint';
        update tpl;

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('[Content_Types].xml', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/></Types>'
        ));
        zw.addEntry('_rels/.rels', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
        ));
        zw.addEntry('ppt/slides/slide1.xml', Blob.valueOf(
            '<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:cSld><p:spTree><p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
        ));
        ContentVersion cv = new ContentVersion(Title='PPT', PathOnClient='PPT.pptx', VersionData=zw.getArchive());
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId=tpl.Id, ContentDocumentId=conDocId, ShareType='V');

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenService.processDocumentAsPdf(tpl.Id, acc.Id);
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('only supported for Word'));
        }
        Test.stopTest();
        System.assert(caught, 'Should throw for PowerPoint PDF generation');
    }

    @isTest
    static void testProcessDocumentAsPdfWithTitleFormat() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Account: {Name}, Source: {AccountSource}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Document_Title_Format__c = 'PDF_{Name}';
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocumentAsPdf(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
        String title = (String) result.get('title');
        System.assert(title.contains('Misc Test Account'));
    }

    @isTest
    static void testProcessDocumentAsPdfWithImage() {
        // PDF path with image — exercises imageBase64ByRelId collection
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('PNGFAKE'));
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = 'data:image/png;base64,' + tinyBase64;
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocumentAsPdf(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
        System.assertEquals('PDF', result.get('outputFormat'));
    }

    // =========================================================================
    // DocGenService — generateDocument save paths
    // =========================================================================

    @isTest
    static void testGenerateDocumentSavesPdfWhenOutputFormatPdf() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Output_Format__c = 'PDF';
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId);
        ContentVersion savedCv = [SELECT PathOnClient FROM ContentVersion WHERE ContentDocumentId = :docId LIMIT 1];
        System.assert(savedCv.PathOnClient.endsWith('.pdf'), 'Saved file should be a PDF');
    }

    @isTest
    static void testGenerateDocumentSavesPptx() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Type__c = 'PowerPoint';
        update tpl;

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('[Content_Types].xml', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/></Types>'
        ));
        zw.addEntry('_rels/.rels', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
        ));
        zw.addEntry('ppt/_rels/presentation.xml.rels', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
        ));
        zw.addEntry('ppt/slides/slide1.xml', Blob.valueOf(
            '<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:cSld><p:spTree><p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
        ));
        ContentVersion cv = new ContentVersion(Title='PPTSave', PathOnClient='PPTSave.pptx', VersionData=zw.getArchive());
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId=tpl.Id, ContentDocumentId=conDocId, ShareType='V');

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId);
        ContentVersion savedCv = [SELECT PathOnClient FROM ContentVersion WHERE ContentDocumentId = :docId LIMIT 1];
        System.assert(savedCv.PathOnClient.endsWith('.pptx'), 'Saved file should be a PPTX');
    }

    // =========================================================================
    // DocGenService — processXml: conditional sections (various data types)
    // =========================================================================

    @isTest
    static void testProcessDocumentConditionalSectionTruthyString() {
        // Section where key resolves to a non-null string — exercises the non-null fallback path
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = 'Has description';
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Description}Has Desc: {Description}{/Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentConditionalSectionNullValue() {
        // Section where key resolves to null — produces empty output for section
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Description}This should not appear{/Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — processXml: date formatting
    // =========================================================================

    @isTest
    static void testProcessDocumentWithDateFormatTag() {
        // {CreatedDate:MM/dd/yyyy} — exercises DateTime format path in processXml
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, CreatedDate';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{CreatedDate:MM/dd/yyyy}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentWithColonInNonDateField() {
        // {Name:someformat} — non-date field with colon, exercises dateFormat != null but not DateTime
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name:uppercase}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — processXml: HTML stripping
    // =========================================================================

    @isTest
    static void testProcessDocumentHtmlSpanAndBrStrip() {
        // Field value with <span> and <br> tags — exercises stripHtmlTags path
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = '<p>Line one</p><br/><span style="color:red">Line two</span>';
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — buildImageXml: data URI and rich text <img> paths
    // =========================================================================

    @isTest
    static void testProcessDocumentFieldWithImgTag() {
        // Field value contains <img src="data:image/png;base64,..."> — exercises
        // the rich text image detection and extractImageFromHtml data URI path
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('PNGDATA'));
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = '<img src="data:image/png;base64,' + tinyBase64 + '" />';
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentImageTagDataUri() {
        // {%Description} where Description is a data:image/jpeg URI — exercises data URI branch in buildImageXml
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('JPEGFAKE'));
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = 'data:image/jpeg;base64,' + tinyBase64;
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentImageTagBlankValue() {
        // {%Description} where Description is blank — exercises null return from buildImageXml
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = '';
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentImageTagWithDimensions() {
        // {%Description:200x150} with a data URI — exercises size parsing in image tag
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('SIZED'));
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = 'data:image/png;base64,' + tinyBase64;
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description:200x150}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — buildImageXml: raw base64 and ContentVersion ID paths
    // =========================================================================

    @isTest
    static void testProcessDocumentImageTagRawBase64() {
        // {%Description} where Description is a long raw base64 string (no data URI prefix)
        // Exercises the "raw base64" branch (length > 100, no / or space)
        // Generate a base64 string > 100 chars
        String longBase64 = EncodingUtil.base64Encode(Blob.valueOf(
            'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
        ));

        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = longBase64;
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentImageTagContentVersionId() {
        // {%Description} where Description holds a ContentVersion ID (starts with 068)
        ContentVersion imgCv = new ContentVersion(
            Title = 'TestImage',
            PathOnClient = 'TestImage.png',
            VersionData = Blob.valueOf('PNG_FAKE_DATA')
        );
        insert imgCv;
        imgCv = [SELECT Id FROM ContentVersion WHERE Id = :imgCv.Id];

        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = imgCv.Id;
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — buildImageXml: refid and servlet URL paths (fail gracefully)
    // =========================================================================

    @isTest
    static void testProcessDocumentImageTagRefidUrl() {
        // {%Description} where Description contains a refid URL — exercises fetchSalesforceImage with refid
        // Will fail to find image (no matching record) but exercises the code path
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = 'https://example.com/servlet/rtaImage?refid=0EM000000000001';
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        // Image could not be resolved, but document should still generate
        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentImageTagServletUrl() {
        // {%Description} with /servlet/ URL — exercises the servlet/sfc branch
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = '/servlet/filedownload?file=015000000000001';
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — mergeRunsInTags: three-segment split
    // =========================================================================

    @isTest
    static void testMergeRunsThreeSegments() {
        // Tag split across three <w:t> segments
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p>' +
            '<w:r><w:t>{N</w:t></w:r>' +
            '<w:r><w:t>am</w:t></w:r>' +
            '<w:r><w:t>e}</w:t></w:r>' +
            '</w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testMergeRunsNoTagsNoModification() {
        // Document with no merge tags — mergeRunsInTags returns unchanged
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Plain text no tags</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — processXml: edge cases
    // =========================================================================

    @isTest
    static void testProcessDocumentUnclosedBrace() {
        // { without matching } — exercises tagClose == -1 path
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Hello {Name} and {unclosed</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentEmptyBody() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentNullFieldValue() {
        // {NonExistentField} — resolveValue returns null, tag replaced with nothing
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Before {NonExistentField} After</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentXmlSpecialChars() {
        // Account name with & < > — exercises escapeXml
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Name = 'Acme & Co <Test>';
        update acc;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — resolveValue: case-insensitive and deep nested path
    // =========================================================================

    @isTest
    static void testProcessDocumentCaseInsensitiveField() {
        // {name} lowercase — exercises case-insensitive match
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentDeepNestedPathNull() {
        // {Owner.Manager.Name} — deeply nested, Manager is null
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Owner.Name';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Owner.Manager.Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — generateDocTitle: mixed present/missing fields
    // =========================================================================

    @isTest
    static void testGenerateDocTitleWithMixedFields() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Document_Title_Format__c = 'Doc-{Name}-{MissingField}-{AccountSource}';
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        String title = (String) result.get('title');
        System.assert(title.contains('Misc Test Account'));
        System.assert(title.contains('Web'));
        System.assert(title.contains('--'), 'Missing field should be replaced with empty string');
    }

    // =========================================================================
    // DocGenService — table row expansion with multiple contacts
    // =========================================================================

    @isTest
    static void testProcessDocumentTableRowExpansionMultipleRows() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, (SELECT FirstName, LastName FROM Contacts)';
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];
        insert new List<Contact>{
            new Contact(FirstName = 'Alice', LastName = 'Smith', AccountId = acc.Id),
            new Contact(FirstName = 'Bob', LastName = 'Jones', AccountId = acc.Id)
        };

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:tbl>' +
            '<w:tr><w:tc><w:p><w:r><w:t>Header</w:t></w:r></w:p></w:tc></w:tr>' +
            '<w:tr><w:tc><w:p><w:r><w:t>{#Contacts}{FirstName} {LastName}{/Contacts}</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — nested sections
    // =========================================================================

    @isTest
    static void testProcessDocumentNestedSections() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = 'Present';
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description, AccountSource';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Description}{#AccountSource}Both present{/AccountSource}{/Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — section outside table rows
    // =========================================================================

    @isTest
    static void testProcessDocumentSectionOutsideTr() {
        // {#Contacts} before TR, {/Contacts} after TR — exercises trClosesBefore path
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, (SELECT FirstName FROM Contacts)';
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];
        insert new Contact(FirstName = 'Multi', LastName = 'Row', AccountId = acc.Id);

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Contacts}</w:t></w:r></w:p>' +
            '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{FirstName}</w:t></w:r></w:p></w:tc></w:tr></w:tbl>' +
            '<w:p><w:r><w:t>{/Contacts}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — pendingImages: content types already contain png/jpeg
    // =========================================================================

    @isTest
    static void testProcessDocumentImageWithExistingContentTypes() {
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('IMG'));
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = 'data:image/png;base64,' + tinyBase64;
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('[Content_Types].xml', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/>' +
            '<Default Extension="png" ContentType="image/png"/>' +
            '<Default Extension="jpeg" ContentType="image/jpeg"/>' +
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
        zw.addEntry('word/document.xml', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>'
        ));

        ContentVersion cv = new ContentVersion(Title='ImgExist', PathOnClient='ImgExist.docx', VersionData=zw.getArchive());
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId=tpl.Id, ContentDocumentId=conDocId, ShareType='V');

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — multiple images (two data URIs to exercise pendingImages rels)
    // =========================================================================

    @isTest
    static void testProcessDocumentMultipleImageTags() {
        String pngBase64 = EncodingUtil.base64Encode(Blob.valueOf('PNGDATA'));
        String jpgBase64 = EncodingUtil.base64Encode(Blob.valueOf('JPGDATA'));
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = 'data:image/png;base64,' + pngBase64;
        acc.Website = 'data:image/jpeg;base64,' + jpgBase64;
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description, Website';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description} {%Website}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — multiple PPTX slides
    // =========================================================================

    @isTest
    static void testProcessDocumentMultipleSlides() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Type__c = 'PowerPoint';
        update tpl;

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('[Content_Types].xml', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/></Types>'
        ));
        zw.addEntry('_rels/.rels', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
        ));
        zw.addEntry('ppt/_rels/presentation.xml.rels', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
        ));
        String slide1 = '<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:cSld><p:spTree><p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>';
        String slide2 = '<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:cSld><p:spTree><p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:r><a:t>{AccountSource}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>';
        zw.addEntry('ppt/slides/slide1.xml', Blob.valueOf(slide1));
        zw.addEntry('ppt/slides/slide2.xml', Blob.valueOf(slide2));

        ContentVersion cv = new ContentVersion(Title='MultiSlide', PathOnClient='MultiSlide.pptx', VersionData=zw.getArchive());
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId=tpl.Id, ContentDocumentId=conDocId, ShareType='V');

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
        System.assertEquals('PowerPoint', result.get('templateType'));
    }

    // =========================================================================
    // DocGenService — generateDocument with null title fallback in saveFile
    // =========================================================================

    @isTest
    static void testGenerateDocumentNullTitleFallback() {
        // Document_Title_Format__c is null → generateDocTitle returns null → falls back to Name
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = [SELECT Id, Document_Title_Format__c FROM DocGen_Template__c LIMIT 1];
        tpl.Document_Title_Format__c = null;
        update tpl;

        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId);
    }

    // =========================================================================
    // DocGenService — extractImageFromHtml: various URL patterns in <img> tag
    // =========================================================================

    @isTest
    static void testProcessDocumentImgTagWithRefid() {
        // <img> with refid= attribute — exercises extractImageFromHtml refid branch
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = '<img src="https://example.com/servlet/rtaImage?eid=001&refid=0EM000000000001" />';
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    @isTest
    static void testProcessDocumentImgTagWithSfcUrl() {
        // <img> with /sfc/ URL — exercises extractImageFromHtml servlet/sfc branch
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = '<img src="/sfc/servlet.shepherd/version/download/068000000000001" />';
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

    // =========================================================================
    // DocGenService — fetchSalesforceImage: ContentDocument ID (069) branch
    // =========================================================================

    @isTest
    static void testProcessDocumentImageContentDocumentId() {
        // {%Description} where Description holds a ContentDocument ID (069...)
        ContentVersion imgCv = new ContentVersion(
            Title = 'TestImg069',
            PathOnClient = 'TestImg069.png',
            VersionData = Blob.valueOf('PNG069DATA')
        );
        insert imgCv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :imgCv.Id].ContentDocumentId;

        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Description = String.valueOf(conDocId);
        update acc;

        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        tpl.Query_Config__c = 'Name, Description';
        update tpl;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'));
    }

}
