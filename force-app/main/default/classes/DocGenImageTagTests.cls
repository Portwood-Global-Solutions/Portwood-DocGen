/**
 * Covers:
 *  - {%Image:N} tag resolution (DocGenService): parsing, CDL lookup, cache, size tokens
 *  - {%Image:N} parent-level resolution (DocGenGiantQueryAssembler.resolveParentImageTags)
 *  - extractCurrentRunProperties used by the #32 textarea-newline formatting fix
 *
 * All helpers are @TestVisible private. These tests exercise them directly plus
 * the processXmlForTest surface so the integration path is covered too.
 */
@IsTest
private class DocGenImageTagTests {
    // 1x1 red PNG for test fixtures
    private static final String TINY_PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==';

    /** Attaches one image to an Account and returns both records. */
    private static Account setupAccountWithImages(Integer imageCount) {
        Account a = new Account(Name = 'DocGenImgTest ' + imageCount + ' ' + System.currentTimeMillis());
        insert a;
        if (imageCount <= 0) {
            return a;
        }
        List<ContentVersion> cvs = new List<ContentVersion>();
        for (Integer i = 0; i < imageCount; i++) {
            cvs.add(
                new ContentVersion(
                    Title = 'docgen_imgtag_test_' + i + '_' + System.currentTimeMillis(),
                    PathOnClient = 'img' + i + '.png',
                    VersionData = EncodingUtil.base64Decode(TINY_PNG_B64)
                )
            );
        }
        insert cvs;
        List<ContentVersion> committed = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id IN :cvs
            ORDER BY CreatedDate ASC
        ];
        List<ContentDocumentLink> cdls = new List<ContentDocumentLink>();
        for (ContentVersion cv : committed) {
            cdls.add(
                new ContentDocumentLink(
                    ContentDocumentId = cv.ContentDocumentId,
                    LinkedEntityId = a.Id,
                    ShareType = 'V'
                )
            );
        }
        insert cdls;
        return a;
    }

    // ==================================================================
    // applyImageSizeToken
    // ==================================================================

    @IsTest
    static void sizeToken_singleNumberSetsBothMax() {
        // Use processXmlForTest surface — the size token gets applied inside resolveImageByIndexTag
        Account a = setupAccountWithImages(1);
        String r = DocGenService.processXmlForTest('{%Image:1:200}', new Map<String, Object>{ 'Id' => a.Id });
        System.assert(r.contains('w:drawing'), 'Expected drawing block, got: ' + r.left(300));
    }

    @IsTest
    static void sizeToken_explicitWidthHeight() {
        Account a = setupAccountWithImages(1);
        String r = DocGenService.processXmlForTest('{%Image:1:100x150}', new Map<String, Object>{ 'Id' => a.Id });
        System.assert(r.contains('w:drawing'), 'Expected drawing block');
    }

    @IsTest
    static void sizeToken_widthOnly() {
        Account a = setupAccountWithImages(1);
        String r = DocGenService.processXmlForTest('{%Image:1:100x}', new Map<String, Object>{ 'Id' => a.Id });
        System.assert(r.contains('w:drawing'), 'Expected drawing block');
    }

    @IsTest
    static void sizeToken_heightOnly() {
        Account a = setupAccountWithImages(1);
        String r = DocGenService.processXmlForTest('{%Image:1:x150}', new Map<String, Object>{ 'Id' => a.Id });
        System.assert(r.contains('w:drawing'), 'Expected drawing block');
    }

    @IsTest
    static void sizeToken_emptyAndInvalidNoop() {
        Account a = setupAccountWithImages(1);
        String r1 = DocGenService.processXmlForTest('{%Image:1:}', new Map<String, Object>{ 'Id' => a.Id });
        String r2 = DocGenService.processXmlForTest('{%Image:1:abc}', new Map<String, Object>{ 'Id' => a.Id });
        // Both should still render the image (size token gracefully skipped) or render natural size
        System.assert(r1.contains('w:drawing') && r2.contains('w:drawing'), 'Expected drawing blocks for both');
    }

    // ==================================================================
    // resolveImageByIndexTag — parsing edge cases
    // ==================================================================

    @IsTest
    static void resolveImageByIndex_missingIndex() {
        // {%Image} with no N — should return null/empty
        Account a = setupAccountWithImages(1);
        String r = DocGenService.processXmlForTest('<a>{%Image}</a>', new Map<String, Object>{ 'Id' => a.Id });
        // "Image" as a standalone tag gets treated as the Image keyword but with no index → returns null → empty render
        System.assertEquals('<a></a>', r, 'Expected empty render for {%Image} with no index');
    }

    @IsTest
    static void resolveImageByIndex_nonNumericIndex() {
        Account a = setupAccountWithImages(1);
        String r = DocGenService.processXmlForTest('<a>{%Image:abc}</a>', new Map<String, Object>{ 'Id' => a.Id });
        System.assertEquals('<a></a>', r, 'Non-numeric index must render empty');
    }

    @IsTest
    static void resolveImageByIndex_zeroIndex() {
        Account a = setupAccountWithImages(1);
        String r = DocGenService.processXmlForTest('<a>{%Image:0}</a>', new Map<String, Object>{ 'Id' => a.Id });
        System.assertEquals('<a></a>', r, 'Index 0 must render empty');
    }

    @IsTest
    static void resolveImageByIndex_noRecordIdInDataMap() {
        String r = DocGenService.processXmlForTest('<a>{%Image:1}</a>', new Map<String, Object>{ 'Name' => 'x' });
        System.assertEquals('<a></a>', r, 'No Id in data map must render empty');
    }

    @IsTest
    static void resolveImageByIndex_invalidIdFormat() {
        String r = DocGenService.processXmlForTest('<a>{%Image:1}</a>', new Map<String, Object>{ 'Id' => 'not-an-id' });
        System.assertEquals('<a></a>', r, 'Invalid Id format must render empty');
    }

    @IsTest
    static void resolveImageByIndex_outOfRange() {
        Account a = setupAccountWithImages(1);
        String r = DocGenService.processXmlForTest('<a>{%Image:99}</a>', new Map<String, Object>{ 'Id' => a.Id });
        System.assertEquals('<a></a>', r, 'Out-of-range index must render empty');
    }

    @IsTest
    static void resolveImageByIndex_firstImageResolves() {
        Account a = setupAccountWithImages(2);
        String r = DocGenService.processXmlForTest('start{%Image:1}end', new Map<String, Object>{ 'Id' => a.Id });
        System.assert(
            r.startsWith('start') && r.endsWith('end') && r.contains('w:drawing'),
            'First image must resolve: ' + r.left(200)
        );
    }

    // ==================================================================
    // prefetchImagesForIds + imageCvCache
    // ==================================================================

    @IsTest
    static void prefetch_nullAndEmptyAreNoOps() {
        DocGenService.imageCvCache = null;
        DocGenService.prefetchImagesForIds(null);
        DocGenService.prefetchImagesForIds(new Set<Id>());
        System.assert(
            DocGenService.imageCvCache == null || DocGenService.imageCvCache.isEmpty(),
            'Null/empty set inputs should not populate the cache'
        );
    }

    @IsTest
    static void prefetch_populatesCacheAndAvoidsRequery() {
        Account a1 = setupAccountWithImages(2);
        Account a2 = setupAccountWithImages(0);

        DocGenService.imageCvCache = null;
        DocGenService.prefetchImagesForIds(new Set<Id>{ a1.Id, a2.Id });

        System.assert(DocGenService.imageCvCache != null, 'Cache must be populated');
        System.assertEquals(
            2,
            DocGenService.imageCvCache.get(a1.Id).size(),
            'Account with 2 images should have 2 cached CV IDs'
        );
        System.assertEquals(
            0,
            DocGenService.imageCvCache.get(a2.Id).size(),
            'Account with 0 images should have empty bucket'
        );

        // Second call for same IDs — should NOT run additional SOQL (cache hit for all)
        Integer soqlBefore = Limits.getQueries();
        DocGenService.prefetchImagesForIds(new Set<Id>{ a1.Id, a2.Id });
        System.assertEquals(soqlBefore, Limits.getQueries(), 'Second prefetch for cached IDs must not query');
    }

    // ==================================================================
    // loopBodyHasImageTag
    // ==================================================================

    @IsTest
    static void loopBodyScan_detectsTag() {
        System.assertEquals(true, DocGenService.loopBodyHasImageTag('hello {%Image:1} world'));
        System.assertEquals(true, DocGenService.loopBodyHasImageTag('hello {%image:2:200} world'));
        System.assertEquals(false, DocGenService.loopBodyHasImageTag('hello {Name} world'));
        System.assertEquals(false, DocGenService.loopBodyHasImageTag(''));
        System.assertEquals(false, DocGenService.loopBodyHasImageTag(null));
    }

    // ==================================================================
    // In-loop integration — validates pre-fetch + per-iteration resolve
    // ==================================================================

    @IsTest
    static void inLoop_eachIterationResolvesOwnImage() {
        Account parent = new Account(Name = 'DocGenImgTest-parent ' + System.currentTimeMillis());
        insert parent;
        List<Contact> kids = new List<Contact>{
            new Contact(FirstName = 'A', LastName = 'K1', AccountId = parent.Id),
            new Contact(FirstName = 'B', LastName = 'K2', AccountId = parent.Id)
        };
        insert kids;
        List<ContentVersion> cvs = new List<ContentVersion>{
            new ContentVersion(
                Title = 'kidA' + System.currentTimeMillis(),
                PathOnClient = 'a.png',
                VersionData = EncodingUtil.base64Decode(TINY_PNG_B64)
            ),
            new ContentVersion(
                Title = 'kidB' + System.currentTimeMillis(),
                PathOnClient = 'b.png',
                VersionData = EncodingUtil.base64Decode(TINY_PNG_B64)
            )
        };
        insert cvs;
        List<ContentVersion> committed = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id IN :cvs
            ORDER BY CreatedDate ASC
        ];
        List<ContentDocumentLink> cdls = new List<ContentDocumentLink>();
        for (Integer i = 0; i < 2; i++) {
            cdls.add(
                new ContentDocumentLink(
                    ContentDocumentId = committed[i].ContentDocumentId,
                    LinkedEntityId = kids[i].Id,
                    ShareType = 'V'
                )
            );
        }
        insert cdls;

        Map<String, Object> data = new Map<String, Object>{
            'Id' => parent.Id,
            'Kids' => new Map<String, Object>{
                'totalSize' => 2,
                'records' => new List<Object>{
                    new Map<String, Object>{ 'Id' => kids[0].Id, 'FirstName' => 'A' },
                    new Map<String, Object>{ 'Id' => kids[1].Id, 'FirstName' => 'B' }
                }
            }
        };

        DocGenService.imageCvCache = null;
        String r = DocGenService.processXmlForTest('{#Kids}{FirstName}{%Image:1}{/Kids}', data);
        Integer drawCount = 0;
        Integer idx = 0;
        while ((idx = r.indexOf('<w:drawing', idx)) != -1) {
            drawCount++;
            idx += 10;
        }
        System.assertEquals(2, drawCount, 'Each of 2 iterations should emit one drawing: ' + r.left(400));
    }

    // ==================================================================
    // extractCurrentRunProperties (used by #32 multiline-formatting fix)
    // ==================================================================

    @IsTest
    static void extractRunProps_blankReturnsEmpty() {
        System.assertEquals('', DocGenService.extractCurrentRunProperties(null));
        System.assertEquals('', DocGenService.extractCurrentRunProperties(''));
    }

    @IsTest
    static void extractRunProps_noOpenRunReturnsEmpty() {
        // Closed run — no open run exists
        String out = '<w:r><w:rPr><w:b/></w:rPr><w:t>hi</w:t></w:r>';
        System.assertEquals('', DocGenService.extractCurrentRunProperties(out));
    }

    @IsTest
    static void extractRunProps_openRunWithPropsExtracted() {
        String out = '<w:p><w:r><w:rPr><w:sz w:val="28"/><w:b/></w:rPr><w:t>hi';
        String rPr = DocGenService.extractCurrentRunProperties(out);
        System.assertEquals(
            '<w:rPr><w:sz w:val="28"/><w:b/></w:rPr>',
            rPr,
            'Should extract full rPr block from currently-open run'
        );
    }

    @IsTest
    static void extractRunProps_openRunWithoutPropsReturnsEmpty() {
        String out = '<w:p><w:r><w:t>plain';
        System.assertEquals('', DocGenService.extractCurrentRunProperties(out));
    }

    @IsTest
    static void extractRunProps_openRunWithAttributesSyntax() {
        // <w:r xmlns:w="..."> — opening uses attribute form
        String out = '<w:p><w:r xmlns:w="foo"><w:rPr><w:i/></w:rPr><w:t>x';
        String rPr = DocGenService.extractCurrentRunProperties(out);
        System.assertEquals('<w:rPr><w:i/></w:rPr>', rPr);
    }

    @IsTest
    static void extractRunProps_selfClosingRPrReturnsEmpty() {
        // <w:rPr/> is self-closing — no closing tag, fix should return empty not crash
        String out = '<w:p><w:r><w:rPr/><w:t>x';
        // The current implementation looks for </w:rPr>; self-closing has no close tag → returns ''
        System.assertEquals('', DocGenService.extractCurrentRunProperties(out));
    }

    // ==================================================================
    // End-to-end of #32 fix — multiline value preserves rPr across breaks
    // ==================================================================

    @IsTest
    static void multilineTextarea_preservesRunPropsAcrossBreaks() {
        String r = DocGenService.processXmlForTest(
            '<w:r><w:rPr><w:sz w:val="28"/></w:rPr><w:t>{Desc}</w:t></w:r>',
            new Map<String, Object>{ 'Desc' => 'Line1\nLine2\nLine3' }
        );
        Integer szCount = r.countMatches('<w:sz w:val="28"/>');
        // 1 original + 2*(n-1) re-emitted = 1 + 4 = 5 for 3 lines
        System.assert(szCount >= 5, 'rPr should be re-emitted around each break. Got szCount=' + szCount);
        System.assert(r.contains('w:br'), 'Line breaks must be emitted');
    }

    // ==================================================================
    // DocGenGiantQueryAssembler.resolveParentImageTags
    // ==================================================================

    @IsTest
    static void giantQuery_parentImageTagEmitsImgElement() {
        Account a = setupAccountWithImages(2);

        // Use reflection via the @TestVisible method — need to construct an assembler instance
        // Fake jobId + templateId aren't validated for this method path; it only uses recordId.
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 't',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'PDF'
        );
        insert tpl;
        DocGen_Job__c job = new DocGen_Job__c(
            Status__c = 'In Progress',
            Template__c = tpl.Id,
            Parent_Record_Id__c = a.Id
        );
        insert job;
        DocGenGiantQueryAssembler asm = new DocGenGiantQueryAssembler(job.Id, tpl.Id, a.Id, 'Contacts');

        String html = 'Logo: {%Image:1} / Second: {%Image:2:150} / Missing: {%Image:99}';
        String resolved = asm.resolveParentImageTags(html);

        System.assert(
            resolved.contains('<img src="/sfc/servlet.shepherd/version/download/'),
            'Should emit /sfc/ img: ' + resolved
        );
        Integer imgCount = resolved.countMatches('<img ');
        System.assertEquals(
            2,
            imgCount,
            'Should emit 2 img tags (indexes 1 and 2), not 3 (99 is out of range): ' + resolved
        );
        System.assert(resolved.contains('max-width:150px'), 'Size token should produce CSS max-width: ' + resolved);
    }

    @IsTest
    static void giantQuery_parentImageTag_noImagesRecordRendersEmpty() {
        Account a = setupAccountWithImages(0);
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 't2',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'PDF'
        );
        insert tpl;
        DocGen_Job__c job = new DocGen_Job__c(
            Status__c = 'In Progress',
            Template__c = tpl.Id,
            Parent_Record_Id__c = a.Id
        );
        insert job;
        DocGenGiantQueryAssembler asm = new DocGenGiantQueryAssembler(job.Id, tpl.Id, a.Id, 'Contacts');

        String resolved = asm.resolveParentImageTags('Header: {%Image:1} End');
        System.assertEquals('Header:  End', resolved, 'Record with no images should render empty at the tag position');
    }

    @IsTest
    static void giantQuery_noImageTagsInHtml_returnsUnchanged() {
        Account a = setupAccountWithImages(1);
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 't3',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'PDF'
        );
        insert tpl;
        DocGen_Job__c job = new DocGen_Job__c(
            Status__c = 'In Progress',
            Template__c = tpl.Id,
            Parent_Record_Id__c = a.Id
        );
        insert job;
        DocGenGiantQueryAssembler asm = new DocGenGiantQueryAssembler(job.Id, tpl.Id, a.Id, 'Contacts');

        String original = 'plain html <b>no tags</b>';
        System.assertEquals(
            original,
            asm.resolveParentImageTags(original),
            'HTML without Image tags should pass through unchanged'
        );
    }

    @IsTest
    static void giantQuery_sizeVariants() {
        Account a = setupAccountWithImages(1);
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 't4',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'PDF'
        );
        insert tpl;
        DocGen_Job__c job = new DocGen_Job__c(
            Status__c = 'In Progress',
            Template__c = tpl.Id,
            Parent_Record_Id__c = a.Id
        );
        insert job;
        DocGenGiantQueryAssembler asm = new DocGenGiantQueryAssembler(job.Id, tpl.Id, a.Id, 'Contacts');

        String r1 = asm.resolveParentImageTags('{%Image:1:200x100}');
        System.assert(r1.contains('width:200px') && r1.contains('height:100px'), 'WxH style: ' + r1);

        String r2 = asm.resolveParentImageTags('{%Image:1:400x}');
        System.assert(r2.contains('width:400px') && !r2.contains('height:'), 'Wx style: ' + r2);

        String r3 = asm.resolveParentImageTags('{%Image:1:x250}');
        System.assert(r3.contains('height:250px') && !r3.contains('width:'), 'xH style: ' + r3);

        String r4 = asm.resolveParentImageTags('{%Image:1}');
        System.assert(
            r4.contains('<img src="/sfc/') && !r4.contains(' style='),
            'No size token → no style attr: ' + r4
        );
    }

    // ==================================================================
    // v1.80 #46 — autoSize fallback when intrinsic dims unavailable
    // ==================================================================

    /**
     * Joe's bug: {%Image:N:max-dim} on PDF output forced 4:3 because the PDF
     * path skips loading the blob (heap rule), so getImageDimensionsInEmu
     * returned null and the code fell back to a hardcoded 4×3 default.
     * Post-fix: when no intrinsic dims AND no explicit fixed WxH, the drawing
     * gets a DOCGEN_AUTOSIZE marker and the renderer uses max-width/max-height
     * + width:auto so Flying Saucer computes aspect from actual bytes.
     */
    @IsTest
    static void v180Issue46_singleNumberMaxDimEmitsAutoSizeOnPdf() {
        Account a = setupAccountWithImages(1);
        DocGenService.currentOutputFormat = 'PDF';
        try {
            // Single-number form sets BOTH maxWidthPx and maxHeightPx — the
            // exact `{%Image:N:240}` pattern Joe filed against.
            String r = DocGenService.processXmlForTest(
                '<w:p><w:r><w:t>{%Image:1:240}</w:t></w:r></w:p>',
                new Map<String, Object>{ 'Id' => a.Id }
            );
            System.assert(
                r.contains('DOCGEN_AUTOSIZE'),
                'PDF path with single-number max-dim must emit DOCGEN_AUTOSIZE marker so the renderer preserves source aspect: ' +
                r.left(400)
            );
            // wp:extent should be the max constraint in EMU, not the 4:3 fallback.
            // 240px * 9525 EMU/px = 2286000 EMU. The bug fallback was 288*12700 = 3657600.
            System.assert(
                r.contains('cx="2286000"') && r.contains('cy="2286000"'),
                'wp:extent should reflect the max constraint (240px = 2286000 EMU each), not the 4:3 default. Got: ' +
                r.left(400)
            );
        } finally {
            DocGenService.currentOutputFormat = null;
        }
    }

    @IsTest
    static void v180Issue46_noSizeTokenDefaultsToPageContentArea() {
        // {%Image:N} with no size token at all on PDF — autoSize should still
        // engage (no intrinsic dims, no explicit fixed WxH) and cx/cy should
        // default to the page content area (5943600 × 8229600 EMU).
        Account a = setupAccountWithImages(1);
        DocGenService.currentOutputFormat = 'PDF';
        try {
            String r = DocGenService.processXmlForTest(
                '<w:p><w:r><w:t>{%Image:1}</w:t></w:r></w:p>',
                new Map<String, Object>{ 'Id' => a.Id }
            );
            System.assert(
                r.contains('DOCGEN_AUTOSIZE'),
                'Bare {%Image:N} on PDF must emit autosize marker: ' + r.left(400)
            );
            System.assert(
                r.contains('cx="5943600"') && r.contains('cy="8229600"'),
                'No-size-token should fall back to page content area cx/cy: ' + r.left(400)
            );
        } finally {
            DocGenService.currentOutputFormat = null;
        }
    }

    @IsTest
    static void v180Issue46_explicitWxHSkipsAutoSize() {
        // When the user gives W and H explicitly, we have a definitive size and
        // should NOT emit the autosize marker — Flying Saucer locks the aspect.
        Account a = setupAccountWithImages(1);
        DocGenService.currentOutputFormat = 'PDF';
        try {
            String r = DocGenService.processXmlForTest(
                '<w:p><w:r><w:t>{%Image:1:300x200}</w:t></w:r></w:p>',
                new Map<String, Object>{ 'Id' => a.Id }
            );
            System.assert(
                !r.contains('DOCGEN_AUTOSIZE'),
                'Explicit WxH should NOT emit autosize marker: ' + r.left(400)
            );
        } finally {
            DocGenService.currentOutputFormat = null;
        }
    }

    @IsTest
    static void v181Issue46Followup_autoSizeEmitsHtmlWidthAttr() {
        // Joe's regression: in autoSize mode the rendered <img> had no HTML
        // width/height attrs, only CSS max-width/max-height + width:auto;height:auto.
        // Flying Saucer ignored the CSS clamp and rendered images at natural pixel
        // size — 4032x3024 phone photos blew past the 240px cap. Fix emits a
        // single-axis HTML width attr so FS computes height proportionally.
        String drawingXml =
            '<w:drawing>' +
            '<wp:inline distT="0" distB="0" distL="0" distR="0">' +
            '<wp:extent cx="2286000" cy="2286000"/>' +
            '<wp:docPr id="1" name="Picture 1" descr="DOCGEN_AUTOSIZE"/>' +
            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:blipFill><a:blip r:embed="rId99" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
            '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>';
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r>' +
            drawingXml +
            '</w:r></w:p></w:body></w:document>';

        Map<String, String> images = new Map<String, String>{
            'rId99' => '/sfc/servlet.shepherd/version/download/068000000000999'
        };
        String html = DocGenHtmlRenderer.convertToHtml(docXml, images);

        System.assert(
            html.contains('width="240"'),
            'autoSize must emit HTML width attr to anchor Flying Saucer layout: ' + html.left(800)
        );
        System.assert(
            !html.contains('height="240"'),
            'autoSize must NOT emit height attr — would force squashing: ' + html.left(800)
        );
        System.assert(
            html.contains('max-width:240px'),
            'max-width CSS still expected as a backstop: ' + html.left(800)
        );
        System.assert(
            !html.contains('width:auto;height:auto'),
            'Old width:auto;height:auto would override HTML width attr: ' + html.left(800)
        );
    }
}
