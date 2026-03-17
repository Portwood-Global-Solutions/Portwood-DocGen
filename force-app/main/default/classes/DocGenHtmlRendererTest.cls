@isTest
private class DocGenHtmlRendererTest {

    @isTest
    static void testBasicParagraph() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:t>Hello World</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);

        System.assert(html.contains('<body>'), 'Should contain body tag');
        System.assert(html.contains('Hello World'), 'Should contain text');
        System.assert(html.contains('<p>'), 'Should contain paragraph tag');
    }

    @isTest
    static void testBoldItalicUnderline() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:rPr><w:b/><w:i/><w:u w:val="single"/></w:rPr><w:t>Styled</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);

        System.assert(html.contains('<b>'), 'Should contain bold');
        System.assert(html.contains('<i>'), 'Should contain italic');
        System.assert(html.contains('<u>'), 'Should contain underline');
        System.assert(html.contains('Styled'), 'Should contain text');
    }

    @isTest
    static void testParagraphAlignment() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>Centered</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);

        System.assert(html.contains('text-align:center'), 'Should have center alignment');
    }

    @isTest
    static void testFontSizeAndColor() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:rPr><w:sz w:val="28"/><w:color w:val="FF0000"/></w:rPr><w:t>Big Red</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);

        System.assert(html.contains('font-size:14'), 'Should have 14pt font (28/2)');
        System.assert(html.contains('#FF0000'), 'Should have red color');
    }

    @isTest
    static void testTable() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:tbl>' +
            '<w:tblPr><w:tblBorders><w:top w:val="single"/></w:tblBorders></w:tblPr>' +
            '<w:tr>' +
            '<w:tc><w:p><w:r><w:t>Cell 1</w:t></w:r></w:p></w:tc>' +
            '<w:tc><w:p><w:r><w:t>Cell 2</w:t></w:r></w:p></w:tc>' +
            '</w:tr>' +
            '</w:tbl>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);

        System.assert(html.contains('<table'), 'Should contain table');
        System.assert(html.contains('<tr>'), 'Should contain row');
        System.assert(html.contains('<td'), 'Should contain cell');
        System.assert(html.contains('Cell 1'), 'Should contain cell text');
        System.assert(html.contains('Cell 2'), 'Should contain cell text');
    }

    @isTest
    static void testTableCellShading() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:tbl><w:tblPr></w:tblPr>' +
            '<w:tr><w:tc><w:tcPr><w:shd w:val="clear" w:fill="E2EFDA"/></w:tcPr>' +
            '<w:p><w:r><w:t>Shaded</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);

        System.assert(html.contains('#E2EFDA'), 'Should contain shading color');
    }

    @isTest
    static void testLineBreak() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:t>Before</w:t></w:r><w:r><w:br/></w:r><w:r><w:t>After</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);

        System.assert(html.contains('<br/>'), 'Should contain line break');
        System.assert(html.contains('Before'), 'Should contain text before break');
        System.assert(html.contains('After'), 'Should contain text after break');
    }

    @isTest
    static void testImageWithBase64() {
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake image data'));
        Map<String, String> images = new Map<String, String>{
            'rIdImg1' => fakeBase64
        };

        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:drawing>' +
            '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
            '<wp:extent cx="1905000" cy="952500"/>' +
            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:blipFill><a:blip r:embed="rIdImg1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
            '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml, images);

        System.assert(html.contains('<img'), 'Should contain image tag');
        System.assert(html.contains('data:image/png;base64,'), 'Should contain base64 data URI');
    }

    @isTest
    static void testEmptyDocument() {
        String html = DocGenHtmlRenderer.convertToHtml('');
        System.assert(html.contains('<body>'), 'Should return valid HTML for empty input');
        System.assert(html.contains('</body>'), 'Should close body tag');
    }

    @isTest
    static void testNullDocument() {
        String html = DocGenHtmlRenderer.convertToHtml(null);
        System.assert(html.contains('<body>'), 'Should return valid HTML for null input');
    }

    @isTest
    static void testNoImagesOverload() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Test</w:t></w:r></w:p></w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('Test'), 'Should handle no-image overload');
    }

    @isTest
    static void testMultipleRuns() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p>' +
            '<w:r><w:t>Hello </w:t></w:r>' +
            '<w:r><w:rPr><w:b/></w:rPr><w:t>World</w:t></w:r>' +
            '</w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);

        System.assert(html.contains('Hello '), 'Should contain first run text');
        System.assert(html.contains('<b>'), 'Should contain bold tag');
        System.assert(html.contains('World'), 'Should contain second run text');
    }

    @isTest
    static void testSpacingAndIndent() {
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:pPr><w:spacing w:before="120" w:after="240"/><w:ind w:left="720"/></w:pPr>' +
            '<w:r><w:t>Indented</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);

        System.assert(html.contains('margin-top:'), 'Should have top margin');
        System.assert(html.contains('margin-bottom:'), 'Should have bottom margin');
        System.assert(html.contains('margin-left:'), 'Should have left indent');
    }

    // =========================================================================
    // Additional coverage tests
    // =========================================================================

    @isTest
    static void testNullImagesMap() {
        // Exercises the images == null guard in convertToHtml
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Text</w:t></w:r></w:p></w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml, null);
        System.assert(html.contains('Text'), 'Should handle null images map');
    }

    @isTest
    static void testParagraphAlignmentRightAndJustify() {
        // Covers right/end and both/distribute alignment branches
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>Right</w:t></w:r></w:p>' +
            '<w:p><w:pPr><w:jc w:val="end"/></w:pPr><w:r><w:t>End</w:t></w:r></w:p>' +
            '<w:p><w:pPr><w:jc w:val="both"/></w:pPr><w:r><w:t>Justify</w:t></w:r></w:p>' +
            '<w:p><w:pPr><w:jc w:val="distribute"/></w:pPr><w:r><w:t>Distribute</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('text-align:right'), 'Should have right alignment');
        System.assert(html.contains('text-align:justify'), 'Should have justify alignment');
    }

    @isTest
    static void testIndentRightAndFirstLine() {
        // Covers w:ind w:right and w:firstLine branches
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:pPr><w:ind w:left="360" w:right="360" w:firstLine="720"/></w:pPr>' +
            '<w:r><w:t>Indented</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('margin-right:'), 'Should have right indent');
        System.assert(html.contains('text-indent:'), 'Should have first line indent');
    }

    @isTest
    static void testStrikethrough() {
        // Covers w:strike branch
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:rPr><w:strike/></w:rPr><w:t>Struck</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('<s>'), 'Should contain strikethrough');
        System.assert(html.contains('Struck'), 'Should contain text');
    }

    @isTest
    static void testFontFamilyAndHighlight() {
        // Covers w:rFonts (hAnsi fallback) and w:highlight branches
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:rPr><w:rFonts w:hAnsi="Times New Roman"/><w:highlight w:val="yellow"/></w:rPr><w:t>Highlighted</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('Times New Roman'), 'Should contain font family from hAnsi');
        System.assert(html.contains('background-color:yellow'), 'Should contain highlight');
    }

    @isTest
    static void testColorAuto() {
        // Covers the color == 'auto' skip branch
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:rPr><w:color w:val="auto"/></w:rPr><w:t>Auto</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(!html.contains('color:#auto'), 'Should not include auto color');
        System.assert(html.contains('Auto'), 'Should contain text');
    }

    @isTest
    static void testTableWidthPercent() {
        // Covers tblW with type=pct branch
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/></w:tblPr>' +
            '<w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('width:') && html.contains('%'), 'Should have percentage width from pct type');
    }

    @isTest
    static void testTableCellWidthTypes() {
        // Covers tcW with pct type and dxa type branches
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:tbl><w:tblPr><w:tblBorders><w:top w:val="single"/></w:tblBorders></w:tblPr>' +
            '<w:tr>' +
            '<w:tc><w:tcPr><w:tcW w:w="2500" w:type="pct"/></w:tcPr><w:p><w:r><w:t>Pct</w:t></w:r></w:p></w:tc>' +
            '<w:tc><w:tcPr><w:tcW w:w="2880" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Dxa</w:t></w:r></w:p></w:tc>' +
            '</w:tr>' +
            '</w:tbl>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('border:1px solid #000'), 'Should have cell borders');
        System.assert(html.contains('Pct'), 'Should contain pct cell text');
        System.assert(html.contains('Dxa'), 'Should contain dxa cell text');
    }

    @isTest
    static void testCellVerticalAlignment() {
        // Covers w:vAlign branch
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:tbl><w:tblPr></w:tblPr>' +
            '<w:tr><w:tc><w:tcPr><w:vAlign w:val="center"/></w:tcPr>' +
            '<w:p><w:r><w:t>Centered</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('vertical-align:center'), 'Should have vertical alignment');
    }

    @isTest
    static void testImageJpegDetection() {
        // Covers JPEG detection branch (base64 starting with /9j/)
        String jpegBase64 = '/9j/4AAQSkZJRgABAQEASABIAAD';
        Map<String, String> images = new Map<String, String>{ 'rIdImg1' => jpegBase64 };

        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:drawing>' +
            '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
            '<wp:extent cx="952500" cy="476250"/>' +
            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:blipFill><a:blip r:embed="rIdImg1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
            '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml, images);
        System.assert(html.contains('image/jpeg'), 'Should detect JPEG MIME type');
    }

    @isTest
    static void testImageMissingRelId() {
        // Covers relId == null return '' branch
        Map<String, String> images = new Map<String, String>();

        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:drawing>' +
            '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
            '<wp:extent cx="952500" cy="476250"/>' +
            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:blipFill></pic:blipFill>' +
            '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml, images);
        System.assert(!html.contains('<img'), 'Should not produce img tag when no blip embed');
    }

    @isTest
    static void testImageMissingBase64() {
        // Covers base64 == null return '' branch (relId exists but not in images map)
        Map<String, String> images = new Map<String, String>();

        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:drawing>' +
            '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
            '<wp:extent cx="952500" cy="476250"/>' +
            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:blipFill><a:blip r:embed="rIdMissing" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
            '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml, images);
        System.assert(!html.contains('<img'), 'Should not produce img tag when base64 not in map');
    }

    @isTest
    static void testImageDimensionFallbackFromAExt() {
        // Covers the fallback to a:ext for cx/cy when wp:extent is absent
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake image'));
        Map<String, String> images = new Map<String, String>{ 'rIdImg2' => fakeBase64 };

        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:drawing>' +
            '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:blipFill><a:blip r:embed="rIdImg2" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
            '<pic:spPr><a:xfrm><a:ext cx="1905000" cy="952500"/></a:xfrm></pic:spPr>' +
            '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml, images);
        System.assert(html.contains('<img'), 'Should contain image tag');
    }

    @isTest
    static void testEmptyParagraphRendersNbsp() {
        // Covers blank content branch in processParagraph
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:pPr><w:jc w:val="center"/></w:pPr></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('&nbsp;'), 'Empty paragraph should render nbsp');
    }

    @isTest
    static void testSelfClosingParagraph() {
        // Covers <w:p/> self-closing paragraph handling
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p/>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('<body>'), 'Should produce valid HTML');
    }

    @isTest
    static void testSelfClosingTextElement() {
        // Covers self-closing <w:t/> skip in extractTextContent
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:t/><w:t>After</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('After'), 'Should skip self-closing w:t and continue');
    }

    @isTest
    static void testNoBodyTag() {
        // Covers extractBodyContent when no w:body tag exists
        String xml = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:p><w:r><w:t>NoBody</w:t></w:r></w:p></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('<body>'), 'Should still produce valid HTML');
    }

    @isTest
    static void testBodyWithoutClosingTag() {
        // Covers extractBodyContent when no </w:body> close tag
        String xml = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Open</w:t></w:r></w:p></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('Open'), 'Should handle missing close body tag');
    }

    @isTest
    static void testDrawingOutsideRun() {
        // Covers standalone w:drawing outside of w:r in processRuns
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake'));
        Map<String, String> images = new Map<String, String>{ 'rIdStandalone' => fakeBase64 };

        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:drawing>' +
            '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
            '<wp:extent cx="952500" cy="476250"/>' +
            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:blipFill><a:blip r:embed="rIdStandalone" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
            '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml, images);
        System.assert(html.contains('<img'), 'Should process drawing outside of w:r');
    }

    @isTest
    static void testSectPrStripping() {
        // Covers sectPr stripping from body content
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:t>Before</w:t></w:r></w:p>' +
            '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('Before'), 'Should contain text');
        System.assert(!html.contains('pgSz'), 'Should strip section properties');
    }

    @isTest
    static void testRunWithAttributeStart() {
        // Covers <w:r ...> with attributes (runStart2 branch)
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r w:rsidR="00112233"><w:t>WithAttr</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('WithAttr'), 'Should handle runs with attributes');
    }

    @isTest
    static void testParagraphWithAttributes() {
        // Covers <w:p ...> with attributes
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p w:rsidR="00112233"><w:r><w:t>ParaAttr</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('ParaAttr'), 'Should handle paragraphs with attributes');
    }

    @isTest
    static void testExtractElementSelfClosing() {
        // Covers self-closing element in extractElement
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:pPr><w:jc w:val="left"/></w:pPr><w:r><w:t>Left</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('Left'), 'Should handle self-closing elements in pPr');
    }

    @isTest
    static void testFontWithAsciiAttr() {
        // Covers w:rFonts w:ascii path (primary path)
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:r><w:rPr><w:rFonts w:ascii="Courier New"/></w:rPr><w:t>Mono</w:t></w:r></w:p>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('Courier New'), 'Should contain ascii font');
    }

    @isTest
    static void testCellShadingAutoFill() {
        // Covers fill == 'auto' skip branch in cell shading
        String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:tbl><w:tblPr></w:tblPr>' +
            '<w:tr><w:tc><w:tcPr><w:shd w:val="clear" w:fill="auto"/></w:tcPr>' +
            '<w:p><w:r><w:t>AutoFill</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(!html.contains('background-color:#auto'), 'Should not include auto fill');
        System.assert(html.contains('AutoFill'), 'Should contain text');
    }
}