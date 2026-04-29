@IsTest
private class DocGenHtmlTemplateTest {
    @TestSetup
    static void setup() {
        insert new Account(Name = 'HTMLTpl Test Co', Industry = 'Technology');
    }

    private static Id createHtmlTemplate(String header, String footer, String bodyHtml) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'HTMLTpl ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, Industry',
            Header_Html__c = header,
            Footer_Html__c = footer
        );
        insert tmpl;

        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(bodyHtml),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );
        return tmpl.Id;
    }

    @IsTest
    static void mergesBodyHeaderFooterAndResolvesTags() {
        Account acct = [SELECT Id, Name FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(
            '<div>Hdr {Name} Page {PageNumber}</div>',
            '<div>Ftr {PageNumber} of {TotalPages}</div>',
            '<html><body><h1>{Name}</h1><p>{Industry}</p></body></html>'
        );

        Test.startTest();
        Map<String, Object> result = DocGenService.generatePdfBlob(tmplId, acct.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'PDF blob should be returned');
        String rendered = DocGenService.lastRenderedHtml;
        System.assert(rendered.contains('HTMLTpl Test Co'), 'Body merge tag should resolve: ' + rendered);
        System.assert(rendered.contains('Technology'), 'Industry merge tag should resolve');
        // Headers WITH counter tokens emit @page content CSS (Flying Saucer only
        // resolves counter(page)/counter(pages) inside @page rules).
        System.assert(rendered.contains('@top-center'), '@top-center margin box expected for header with counters');
        System.assert(
            rendered.contains('@bottom-center'),
            '@bottom-center margin box expected for footer with counters'
        );
        System.assert(rendered.contains('counter(page)'), 'counter(page) call expected for {PageNumber}');
        System.assert(rendered.contains('counter(pages)'), 'counter(pages) call expected for {TotalPages}');
        // Header text should survive into the CSS content string (with merged {Name} resolved).
        System.assert(
            rendered.contains('Hdr HTMLTpl Test Co'),
            'Header text with {Name} resolved should appear in CSS: ' + rendered
        );
        // When all headers/footers contain counter tokens, the running-element scaffolding is skipped.
        System.assert(
            !rendered.contains('running(dgheader)'),
            'Running header CSS should NOT be present when header uses counters'
        );
        System.assert(
            !rendered.contains('running(dgfooter)'),
            'Running footer CSS should NOT be present when footer uses counters'
        );
    }

    @IsTest
    static void headerWithoutCountersUsesRunningElement() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(
            '<div><img src="/sfc/fake" alt="logo"/> Header</div>',
            null,
            '<html><body><p>{Name}</p></body></html>'
        );

        Test.startTest();
        DocGenService.generatePdfBlob(tmplId, acct.Id);
        Test.stopTest();

        String rendered = DocGenService.lastRenderedHtml;
        System.assert(
            rendered.contains('running(dgheader)'),
            'Running header expected for rich header with no counters'
        );
        System.assert(rendered.contains('element(dgheader)'), '@top-center should reference the running element');
    }

    @IsTest
    static void preservesSourceStyleBlock() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        String body =
            '<html><head><style>.mystyle{color:red}</style></head>' +
            '<body><p class="mystyle">{Name}</p></body></html>';
        Id tmplId = createHtmlTemplate(null, null, body);

        Test.startTest();
        DocGenService.generatePdfBlob(tmplId, acct.Id);
        Test.stopTest();

        String rendered = DocGenService.lastRenderedHtml;
        System.assert(rendered.contains('.mystyle{color:red}'), 'Source <style> should be preserved');
    }

    @IsTest
    static void worksWithoutHeaderOrFooter() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<html><body><p>{Name}</p></body></html>');

        Test.startTest();
        Map<String, Object> r = DocGenService.generatePdfBlob(tmplId, acct.Id);
        Test.stopTest();

        System.assertNotEquals(null, r.get('blob'));
        String rendered = DocGenService.lastRenderedHtml;
        System.assert(!rendered.contains('running(dgheader)'), 'No header CSS when field blank');
        System.assert(!rendered.contains('running(dgfooter)'), 'No footer CSS when field blank');
    }

    @IsTest
    static void treatsBodylessHtmlAsContent() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<p>Just {Name}</p>');

        Test.startTest();
        DocGenService.generatePdfBlob(tmplId, acct.Id);
        Test.stopTest();

        String rendered = DocGenService.lastRenderedHtml;
        System.assert(rendered.contains('Just HTMLTpl Test Co'), 'Content without <body> wrapper should still merge');
    }

    @IsTest
    static void renderPreviewHtmlReturnsRenderedDoc() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate('<div>Hdr</div>', '<div>Ftr</div>', '<html><body><h1>{Name}</h1></body></html>');

        Test.startTest();
        String preview = DocGenService.renderPreviewHtml(tmplId, acct.Id);
        Test.stopTest();

        System.assert(preview.contains('<html>'), 'Preview should be a full HTML document');
        System.assert(preview.contains('HTMLTpl Test Co'), 'Preview should have merged data');
    }

    @IsTest
    static void extractsImagesFromGoogleDocsZip() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'ZipHtml ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        String body = '<html><body><h1>{Name}</h1><img src="images/image1.png"/></body></html>';
        Blob png = EncodingUtil.base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='
        );
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('export.html', Blob.valueOf(body));
        zw.addEntry('images/image1.png', png);

        ContentVersion zipCv = new ContentVersion(
            Title = tmpl.Name + '.zip',
            PathOnClient = 'export.zip',
            VersionData = zw.getArchive(),
            FirstPublishLocationId = tmpl.Id
        );
        insert zipCv;
        zipCv = [SELECT Id FROM ContentVersion WHERE Id = :zipCv.Id];

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = zipCv.Id,
            Is_Active__c = true
        );
        insert ver;

        Test.startTest();
        DocGenService.extractAndSaveHtmlTemplateAssets(tmpl.Id, ver.Id);
        Test.stopTest();

        DocGen_Template_Version__c after = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Id = :ver.Id
        ];
        System.assertNotEquals(zipCv.Id, after.Content_Version_Id__c, 'Version should repoint off the zip');
        ContentVersion newCv = [SELECT Title, VersionData FROM ContentVersion WHERE Id = :after.Content_Version_Id__c];
        System.assert(newCv.Title.startsWith('docgen_html_body_'), 'Rewritten HTML CV expected; got ' + newCv.Title);
        String rewritten = newCv.VersionData.toString();
        System.assert(rewritten.contains('/sfc/servlet.shepherd/version/download/'), 'src should be rewritten');
        System.assert(!rewritten.contains('images/image1.png'), 'Original src should be gone');
        List<ContentVersion> imgs = [
            SELECT Id
            FROM ContentVersion
            WHERE Title LIKE :('docgen_html_img_' + ver.Id + '_%')
        ];
        System.assertEquals(1, imgs.size(), 'One image CV expected');
    }

    @IsTest
    static void zipExtractorNoOpsOnPlainHtml() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<html><body>{Name}</body></html>');
        DocGen_Template_Version__c ver = [
            SELECT Id, Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :tmplId AND Is_Active__c = TRUE
            LIMIT 1
        ];
        Id originalCvId = (Id) ver.Content_Version_Id__c;

        Test.startTest();
        DocGenService.extractAndSaveHtmlTemplateAssets(tmplId, ver.Id);
        Test.stopTest();

        DocGen_Template_Version__c after = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Id = :ver.Id
        ];
        System.assertEquals(originalCvId, after.Content_Version_Id__c, 'Plain-html upload should stay unchanged');
    }

    @IsTest
    static void saveHtmlTemplateImageInsertsCvAndReturnsUrl() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Img ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        String pngB64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

        Test.startTest();
        Map<String, Object> r = DocGenController.saveHtmlTemplateImage(tmpl.Id, 'image1.png', pngB64);
        Test.stopTest();

        System.assertNotEquals(null, r.get('contentVersionId'), 'CV Id expected');
        String url = (String) r.get('url');
        System.assert(url.startsWith('/sfc/servlet.shepherd/version/download/'), 'URL should be relative: ' + url);
        System.assertEquals('image1.png', r.get('fileName'));

        ContentVersion cv = [SELECT Id, Title FROM ContentVersion WHERE Id = :(Id) r.get('contentVersionId')];
        System.assert(cv.Title.startsWith('docgen_html_img_'), 'Title prefix expected: ' + cv.Title);
    }

    @IsTest
    static void saveHtmlTemplateBodyStoresHtmlCv() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Body ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        String html = '<html><body><h1>{Name}</h1></body></html>';

        Test.startTest();
        Map<String, Object> r = DocGenController.saveHtmlTemplateBody(tmpl.Id, 'source.html', html);
        Test.stopTest();

        System.assertNotEquals(null, r.get('contentVersionId'));
        System.assertNotEquals(null, r.get('contentDocumentId'));
        ContentVersion cv = [SELECT Title, VersionData FROM ContentVersion WHERE Id = :(Id) r.get('contentVersionId')];
        System.assert(cv.Title.startsWith('docgen_html_body_'), 'Title prefix expected: ' + cv.Title);
        System.assertEquals(html, cv.VersionData.toString(), 'Stored HTML should match input verbatim');
    }

    @IsTest
    static void saveHtmlTemplateImageRejectsNonHtmlTemplate() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Word ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        Boolean threw = false;
        try {
            DocGenController.saveHtmlTemplateImage(tmpl.Id, 'a.png', 'AAAA');
        } catch (Exception e) {
            threw = true;
            System.assert(e.getMessage().contains('HTML-type'), 'Error should mention HTML-type: ' + e.getMessage());
        }
        System.assert(threw, 'Should refuse non-HTML templates');
    }

    @IsTest
    static void loopInsideTrExpandsEntireRow() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        insert new List<Contact>{
            new Contact(LastName = 'Alpha', AccountId = acct.Id),
            new Contact(LastName = 'Beta', AccountId = acct.Id),
            new Contact(LastName = 'Gamma', AccountId = acct.Id)
        };

        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'LoopTr ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, (SELECT LastName FROM Contacts)'
        );
        insert tmpl;

        // Loop tag sits inside a single <tr> — the whole row should repeat per contact.
        String body =
            '<html><body><table>' +
            '<tr><th>Name</th></tr>' +
            '<tr>{#Contacts}<td>{LastName}</td>{/Contacts}</tr>' +
            '</table></body></html>';

        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name,
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );

        Test.startTest();
        DocGenService.generatePdfBlob(tmpl.Id, acct.Id);
        Test.stopTest();

        String rendered = DocGenService.lastRenderedHtml;
        Integer trCount = rendered.countMatches('<tr>') + rendered.countMatches('<tr ');
        System.assert(
            trCount >= 4,
            'Expected at least 4 <tr> (header + 3 contacts), got ' + trCount + ' in: ' + rendered
        );
        System.assert(rendered.contains('Alpha'), 'Alpha should appear');
        System.assert(rendered.contains('Beta'), 'Beta should appear');
        System.assert(rendered.contains('Gamma'), 'Gamma should appear');
    }

    @IsTest
    static void loopInsideLiExpandsEntireListItem() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        insert new List<Contact>{
            new Contact(LastName = 'One', AccountId = acct.Id),
            new Contact(LastName = 'Two', AccountId = acct.Id)
        };

        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'LoopLi ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, (SELECT LastName FROM Contacts)'
        );
        insert tmpl;

        String body = '<html><body><ul>' + '<li>{#Contacts}Contact: {LastName}{/Contacts}</li>' + '</ul></body></html>';

        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name,
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );

        Test.startTest();
        DocGenService.generatePdfBlob(tmpl.Id, acct.Id);
        Test.stopTest();

        String rendered = DocGenService.lastRenderedHtml;
        Integer liCount = rendered.countMatches('<li>') + rendered.countMatches('<li ');
        System.assert(liCount >= 2, 'Expected at least 2 <li> items, got ' + liCount + ' in: ' + rendered);
        System.assert(rendered.contains('Contact: One'), 'Contact One should appear');
        System.assert(rendered.contains('Contact: Two'), 'Contact Two should appear');
    }

    @IsTest
    static void loopWrappingTrStillWorks() {
        // Sanity check: the "loop wraps the row" pattern must keep working
        // after we added the auto-expand for the "loop inside row" pattern.
        Account acct = [SELECT Id FROM Account LIMIT 1];
        insert new Contact(LastName = 'OnlyOne', AccountId = acct.Id);

        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'LoopWrap ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, (SELECT LastName FROM Contacts)'
        );
        insert tmpl;

        String body =
            '<html><body><table>' +
            '{#Contacts}<tr><td>{LastName}</td></tr>{/Contacts}' +
            '</table></body></html>';

        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name,
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );

        Test.startTest();
        DocGenService.generatePdfBlob(tmpl.Id, acct.Id);
        Test.stopTest();

        System.assert(
            DocGenService.lastRenderedHtml.contains('OnlyOne'),
            'Loop-wraps-row form should still emit contact'
        );
    }

    @IsTest
    static void giantQueryPdfBatchProcessesHtmlTemplate() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < 5; i++) {
            contacts.add(new Contact(LastName = 'Giant' + i, AccountId = acct.Id));
        }
        insert contacts;

        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'GiantHtml ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = JSON.serialize(
                new Map<String, Object>{
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
                            'fields' => new List<String>{ 'LastName' },
                            'parentFields' => new List<String>(),
                            'parentNode' => 'n0',
                            'lookupField' => 'AccountId',
                            'relationshipName' => 'Contacts'
                        }
                    }
                }
            ),
            Header_Html__c = '<div>Page {PageNumber} of {TotalPages}</div>'
        );
        insert tmpl;

        String body =
            '<html><body>' +
            '<h1>{Name} — Contact Roster</h1>' +
            '<table><tr><th>Name</th></tr>' +
            '<tr>{#Contacts}<td>{LastName}</td>{/Contacts}</tr>' +
            '</table></body></html>';
        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name,
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );

        // Build the child-node-config JSON the UI would pass to launchGiantQueryPdfBatch
        String childNodeConfigJson = JSON.serialize(
            new Map<String, Object>{
                'relationshipName' => 'Contacts',
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'fields' => new List<String>{ 'LastName' }
            }
        );

        Test.startTest();
        Map<String, Object> r = DocGenController.launchGiantQueryPdfBatch(
            tmpl.Id,
            acct.Id,
            'Contacts',
            childNodeConfigJson
        );
        Test.stopTest();

        System.assertEquals(true, r.get('isGiantQuery'), 'Batch should run as giant-query path');
        Id jobId = (Id) r.get('jobId');
        System.assertNotEquals(null, jobId, 'Job should exist');

        // After Test.stopTest, batch + queueable have run synchronously.
        // Verify fragment CVs were produced (batch ran) and a final PDF exists.
        List<ContentVersion> finalPdf = [
            SELECT Id, VersionData
            FROM ContentVersion
            WHERE Title = :('docgen_giant_' + jobId + '_final')
            LIMIT 1
        ];
        System.assertEquals(1, finalPdf.size(), 'Final giant-query PDF CV should exist');
        System.assert(finalPdf[0].VersionData.size() > 100, 'Final PDF should be non-trivial');

        DocGen_Job__c job = [SELECT Status__c, Success_Count__c FROM DocGen_Job__c WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status__c, 'Job should be Completed; got ' + job.Status__c);
    }

    @IsTest
    static void extractLoopBodyFindsHtmlTrContainer() {
        String html =
            '<html><body><table>' +
            '<tr><th>Header</th></tr>' +
            '<tr>{#Rel}<td>{Field}</td>{/Rel}</tr>' +
            '</table></body></html>';

        Map<String, String> parts = DocGenService.extractLoopBody(html, 'Rel');
        System.assertNotEquals(null, parts, 'Should find the loop body');
        String innerXml = parts.get('innerXml');
        System.assert(
            innerXml.contains('<tr>') || innerXml.contains('<tr '),
            'Container should be the <tr>: ' + innerXml
        );
        System.assert(innerXml.contains('<td>{Field}</td>'), 'Cell content should be preserved');
        System.assert(parts.get('beforeLoop').contains('<th>Header</th>'), 'Header row goes in beforeLoop');
        System.assert(parts.get('afterLoop').startsWith('</table>'), 'afterLoop starts at </table>');
    }

    @IsTest
    static void extractLoopBodyFindsHtmlLiContainer() {
        String html = '<html><body><ul><li>{#Rel}Item {Name}{/Rel}</li></ul></body></html>';
        Map<String, String> parts = DocGenService.extractLoopBody(html, 'Rel');
        System.assertNotEquals(null, parts);
        System.assert(
            parts.get('innerXml').contains('<li>'),
            'Container should include <li>: ' + parts.get('innerXml')
        );
    }

    @IsTest
    static void generateDocumentRoutesHtmlToPdf() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<html><body><p>{Name}</p></body></html>');

        Test.startTest();
        Id cdId = DocGenService.generateDocument(tmplId, acct.Id);
        Test.stopTest();

        System.assertNotEquals(null, cdId, 'generateDocument should return a ContentDocumentId');
        List<ContentDocument> docs = [SELECT FileType FROM ContentDocument WHERE Id = :cdId];
        System.assertEquals(1, docs.size(), 'ContentDocument should exist');
    }
}
