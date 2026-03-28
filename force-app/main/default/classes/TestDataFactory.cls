@IsTest
public class TestDataFactory {

    // =========================================================================
    // Core test data — call from @TestSetup
    // =========================================================================

    /**
     * Creates a standard set of test data: Account, Contacts, Opportunity with
     * Line Items, Template (V3 config), and an active Template Version.
     * Use the getter methods below to retrieve records in individual tests.
     */
    public static void createStandardTestData() {
        // 1. Account
        Account acc = new Account(
            Name = 'DocGen Test Account',
            Industry = 'Technology',
            Website = 'https://test.com',
            AccountSource = 'Web'
        );
        insert acc;

        // 2. Contacts (3)
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 1; i <= 3; i++) {
            contacts.add(new Contact(
                FirstName = 'Test',
                LastName = 'Contact ' + i,
                Email = 'test' + i + '@example.com',
                AccountId = acc.Id
            ));
        }
        insert contacts;

        // 3. Opportunity with Line Items
        Opportunity opp = new Opportunity(
            Name = 'DocGen Test Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount = 50000
        );
        insert opp;

        Id stdPbId = Test.getStandardPricebookId();
        Product2 prod = new Product2(
            Name = 'Test Product',
            ProductCode = 'TP-001',
            IsActive = true
        );
        insert prod;
        PricebookEntry stdPbe = new PricebookEntry(
            Pricebook2Id = stdPbId,
            Product2Id = prod.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert stdPbe;
        OpportunityLineItem oli = new OpportunityLineItem(
            OpportunityId = opp.Id,
            PricebookEntryId = stdPbe.Id,
            Quantity = 10,
            UnitPrice = 100
        );
        insert oli;

        // 4. Template with V3 config and Output_Format__c
        String v3Config = '{"v":3,"root":"Account","nodes":[' +
            '{"id":"n0","object":"Account","fields":["Name","Industry","Website"],' +
            '"parentFields":["Owner.Name"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
            '{"id":"n1","object":"Contact","fields":["FirstName","LastName","Email"],' +
            '"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"}' +
            ']}';

        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'DocGen Test Template',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Query_Config__c = v3Config,
            Test_Record_Id__c = acc.Id
        );
        insert tpl;

        // 5. Template Version (active)
        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Query_Config__c = v3Config,
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        insert ver;
    }

    // =========================================================================
    // Helper getters — retrieve standard test data by known names
    // =========================================================================

    public static Account getTestAccount() {
        return [SELECT Id, Name FROM Account WHERE Name = 'DocGen Test Account' LIMIT 1];
    }

    public static DocGen_Template__c getTestTemplate() {
        return [SELECT Id, Name, Query_Config__c, Base_Object_API__c, Type__c,
                       Output_Format__c, Test_Record_Id__c, Document_Title_Format__c,
                       Category__c, Description__c, OwnerId
                FROM DocGen_Template__c WHERE Name = 'DocGen Test Template' LIMIT 1];
    }

    public static List<Contact> getTestContacts() {
        return [SELECT Id, FirstName, LastName, Email, AccountId
                FROM Contact WHERE Account.Name = 'DocGen Test Account'];
    }

    public static Opportunity getTestOpportunity() {
        return [SELECT Id, Name FROM Opportunity WHERE Name = 'DocGen Test Opp' LIMIT 1];
    }

    public static DocGen_Template_Version__c getTestTemplateVersion() {
        return [SELECT Id, Template__c, Is_Active__c, Query_Config__c, Type__c, Base_Object_API__c
                FROM DocGen_Template_Version__c WHERE Is_Active__c = true LIMIT 1];
    }

    // =========================================================================
    // Factory: DocGen_Job__c
    // =========================================================================

    /**
     * Creates and inserts a DocGen_Job__c linked to the standard test template.
     */
    public static DocGen_Job__c createTestJob() {
        DocGen_Template__c tpl = getTestTemplate();
        DocGen_Job__c job = new DocGen_Job__c(
            Template__c = tpl.Id,
            Status__c = 'Queued',
            Label__c = 'Test Job'
        );
        insert job;
        return job;
    }

    // =========================================================================
    // Factory: ContentVersion linked to a template
    // =========================================================================

    /**
     * Creates a simple ContentVersion (fake content, not a real DOCX) and links
     * it to the given template via ContentDocumentLink.
     */
    public static ContentVersion createTestTemplateFile(Id templateId) {
        ContentVersion cv = new ContentVersion(
            Title = 'TestTemplate',
            PathOnClient = 'TestTemplate.docx',
            VersionData = Blob.valueOf('PK test content')
        );
        insert cv;

        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
        insert new ContentDocumentLink(
            LinkedEntityId = templateId,
            ContentDocumentId = cv.ContentDocumentId,
            ShareType = 'V'
        );
        return cv;
    }

    // =========================================================================
    // Factory: Minimal valid DOCX (ZIP) linked to a template
    // =========================================================================

    /**
     * Builds a minimal valid DOCX (ZIP archive) with the supplied document.xml content,
     * inserts it as a ContentVersion, and links it to the given template.
     */
    public static ContentVersion createValidDocxFile(Id templateId, String docXml) {
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
        insert new ContentDocumentLink(
            LinkedEntityId = templateId,
            ContentDocumentId = conDocId,
            ShareType = 'V'
        );
        return cv;
    }

    /**
     * Convenience overload: creates a valid DOCX linked to the standard test template.
     */
    public static ContentVersion createValidDocxFile(String docXml) {
        DocGen_Template__c tpl = getTestTemplate();
        return createValidDocxFile(tpl.Id, docXml);
    }

    // =========================================================================
    // Common XML snippets
    // =========================================================================

    /**
     * Returns a simple DOCX document.xml with a single {Name} merge tag and all
     * standard Word namespaces.
     */
    public static String buildSimpleDocXml() {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas" ' +
            'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" ' +
            'xmlns:o="urn:schemas-microsoft-com:office:office" ' +
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ' +
            'xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" ' +
            'xmlns:v="urn:schemas-microsoft-com:vml" ' +
            'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" ' +
            'xmlns:w10="urn:schemas-microsoft-com:office:word" ' +
            'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ' +
            'xmlns:wne="http://schemas.microsoft.com/office/word/2006/wordml" ' +
            'mc:Ignorable="w14 wp14">' +
            '<w:body>' +
            '<w:p><w:r><w:t>Hello {Name}</w:t></w:r></w:p>' +
            '</w:body>' +
            '</w:document>';
    }

    /**
     * Returns a minimal document.xml with a single merge tag (no extra namespaces).
     */
    public static String buildMinimalDocXml(String mergeTag) {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>' + mergeTag + '</w:t></w:r></w:p></w:body></w:document>';
    }
}
