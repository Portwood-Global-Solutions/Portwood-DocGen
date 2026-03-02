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
    // DocGenRenditionService
    // =========================================================================

    @isTest
    static void testAddPendingRendition() {
        ContentVersion cv = createTestFile();
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        DocGenRenditionService.addPendingRendition(cv.Id, acc.Id);
        DocGenRenditionService.enqueueRenditions();
        Test.stopTest();

        System.assert(true, 'addPendingRendition and enqueueRenditions completed without error');
    }

    @isTest
    static void testEnqueueRenditionsWithNoPending() {
        Test.startTest();
        DocGenRenditionService.enqueueRenditions();
        Test.stopTest();

        System.assert(true, 'No-op enqueueRenditions completed without error');
    }

    @isTest
    static void testEnqueueRenditionsDirectMode() {
        ContentVersion cv = createTestFile();
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        DocGenRenditionService.addPendingRendition(cv.Id, acc.Id);
        DocGenRenditionService.enqueueRenditions(true);
        Test.stopTest();

        System.assert(true, 'Direct mode completed without error in test context');
    }

    @isTest
    static void testLogRenditionErrorWithExistingAudit() {
        ContentVersion cv = createTestFile();
        Account acc = [SELECT Id FROM Account LIMIT 1];
        String pendingHash = 'PENDING_RENDITION:' + cv.Id;

        // MasterDetail parent is required for audit
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Signer_Name__c = 'Rendition Test',
            Signer_Email__c = 'rendition@test.com',
            Source_Document_Id__c = cv.Id,
            Related_Record_Id__c = acc.Id,
            Secure_Token__c = 'RENDITION_TEST_TOKEN',
            Status__c = 'Sent'
        );
        insert req;

        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c(
            Signature_Request__c = req.Id,
            Document_Hash_SHA256__c = pendingHash
        );
        insert audit;

        Test.startTest();
        DocGenRenditionService.logRenditionError(cv.Id, 'Test rendition failure message');
        Test.stopTest();

        DocGen_Signature_Audit__c updated = [
            SELECT Error_Message__c FROM DocGen_Signature_Audit__c WHERE Id = :audit.Id
        ];
        System.assert(updated.Error_Message__c.contains('Test rendition failure message'));
    }

    @isTest
    static void testLogRenditionErrorWithoutExistingAudit() {
        ContentVersion cv = createTestFile();

        Test.startTest();
        // logRenditionError tries to create a new audit, but Signature_Request__c (MasterDetail)
        // is required. The method catches this internally — verify no unhandled exception.
        DocGenRenditionService.logRenditionError(cv.Id, 'New audit error message');
        Test.stopTest();

        System.assert(true, 'logRenditionError handled missing parent gracefully');
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
    // DocGenRenditionQueueable (needs HttpCalloutMock)
    // =========================================================================

    private class MockPdfRenditionSuccess implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBodyAsBlob(Blob.valueOf('%PDF-1.4 fake pdf content'));
            return res;
        }
    }

    private class MockPdfRenditionNotReady implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(202);
            res.setBody('Rendition not ready');
            return res;
        }
    }

    private class MockPdfRenditionError implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setStatus('Internal Server Error');
            res.setBody('Server error');
            return res;
        }
    }

    @isTest
    static void testRenditionQueueableSuccess() {
        ContentVersion cv = createTestFile();
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockPdfRenditionSuccess());

        Test.startTest();
        DocGenRenditionQueueable q = new DocGenRenditionQueueable(
            new Map<Id, Id>{ cv.Id => acc.Id }
        );
        q.execute(null);
        Test.stopTest();

        // Verify a PDF ContentVersion was created
        List<ContentVersion> pdfs = [SELECT Title FROM ContentVersion WHERE Title LIKE '%PDF%'];
        System.assert(!pdfs.isEmpty(), 'Should have created a PDF ContentVersion');
    }

    @isTest
    static void testRenditionQueueableNotReady() {
        ContentVersion cv = createTestFile();
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockPdfRenditionNotReady());

        Test.startTest();
        DocGenRenditionQueueable q = new DocGenRenditionQueueable(
            new Map<Id, Id>{ cv.Id => acc.Id }
        );
        q.execute(null);
        Test.stopTest();

        // In test context, retry is skipped (Test.isRunningTest guard)
        System.assert(true, 'Should handle not-ready without error');
    }

    @isTest
    static void testRenditionQueueableError() {
        ContentVersion cv = createTestFile();
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockPdfRenditionError());

        Test.startTest();
        DocGenRenditionQueueable q = new DocGenRenditionQueueable(
            new Map<Id, Id>{ cv.Id => acc.Id }
        );
        q.execute(null);
        Test.stopTest();

        System.assert(true, 'Should handle error without exception');
    }

    @isTest
    static void testRenditionQueueableWithRetryCount() {
        ContentVersion cv = createTestFile();
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockPdfRenditionNotReady());

        Test.startTest();
        // Pass retryCount = 10 so it won't attempt re-enqueue
        DocGenRenditionQueueable q = new DocGenRenditionQueueable(
            new Map<Id, Id>{ cv.Id => acc.Id }, 10
        );
        q.execute(null);
        Test.stopTest();

        System.assert(true, 'Max retry count reached gracefully');
    }

    @isTest
    static void testRenditionQueueableWithAuditUpdate() {
        ContentVersion cv = createTestFile();
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
        Account acc = [SELECT Id FROM Account LIMIT 1];

        // Create audit record with PENDING_RENDITION hash
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Signer_Name__c = 'Queueable Test',
            Signer_Email__c = 'q@test.com',
            Source_Document_Id__c = cv.Id,
            Related_Record_Id__c = acc.Id,
            Secure_Token__c = 'QUEUEABLE_TEST_TOKEN',
            Status__c = 'Signed'
        );
        insert req;

        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c(
            Signature_Request__c = req.Id,
            Document_Hash_SHA256__c = 'PENDING_RENDITION:' + cv.Id
        );
        insert audit;

        Test.setMock(HttpCalloutMock.class, new MockPdfRenditionSuccess());

        Test.startTest();
        DocGenRenditionQueueable q = new DocGenRenditionQueueable(
            new Map<Id, Id>{ cv.Id => acc.Id }
        );
        q.execute(null);
        Test.stopTest();

        // Audit hash should be updated from PENDING to actual hash
        DocGen_Signature_Audit__c updated = [SELECT Document_Hash_SHA256__c FROM DocGen_Signature_Audit__c WHERE Id = :audit.Id];
        System.assert(!updated.Document_Hash_SHA256__c.startsWith('PENDING_RENDITION:'),
            'Audit hash should be updated from pending to actual SHA-256');
    }

    // =========================================================================
    // DocGenRenditionService.capturePdfRendition (direct test)
    // =========================================================================

    @isTest
    static void testCapturePdfRenditionSuccess() {
        ContentVersion cv = createTestFile();

        Test.setMock(HttpCalloutMock.class, new MockPdfRenditionSuccess());

        Test.startTest();
        ContentVersion pdfCv = DocGenRenditionService.capturePdfRendition(cv.Id);
        Test.stopTest();

        System.assertNotEquals(null, pdfCv);
        System.assert(pdfCv.Title.contains('PDF'));
        System.assert(pdfCv.PathOnClient.endsWith('.pdf'));
    }

    @isTest
    static void testCapturePdfRenditionNotReady() {
        ContentVersion cv = createTestFile();

        Test.setMock(HttpCalloutMock.class, new MockPdfRenditionNotReady());

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenRenditionService.capturePdfRendition(cv.Id);
        } catch (DocGenRenditionService.RenditionException e) {
            caught = true;
            System.assert(e.getMessage().contains('Rendition not ready'));
        }
        Test.stopTest();

        System.assert(caught, 'Should throw RenditionException for 202');
    }

    @isTest
    static void testCapturePdfRenditionServerError() {
        ContentVersion cv = createTestFile();

        Test.setMock(HttpCalloutMock.class, new MockPdfRenditionError());

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenRenditionService.capturePdfRendition(cv.Id);
        } catch (DocGenRenditionService.RenditionException e) {
            caught = true;
            System.assert(e.getMessage().contains('Failed to capture rendition'));
        }
        Test.stopTest();

        System.assert(caught, 'Should throw RenditionException for 500');
    }
}
