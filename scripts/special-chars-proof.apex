// End-to-end proof that numeric character entities now decode through the renderer.
// Builds a small DOCX-style document with many &#NNNN; / &#xHH; entities, runs it through
// convertToHtml(), and asserts:
//   1) No raw "&amp;#NNNN;" / "&amp;#xHH;" sequences leak through (those would render as literal text)
//   2) The output contains either literal Unicode chars OR valid HTML named entities (both render in PDF)
//   3) Edge cases (malformed/control) survive untouched
// Then renders the result to PDF via Blob.toPdf and saves the PDF as a ContentVersion
// so you can pull it back and inspect it visually.

String docXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
    '<w:body>' +
    '<w:p><w:r><w:t>DocGen Special Characters Proof</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Punctuation: em-dash &#8212; en-dash &#8211; bullet &#8226; ellipsis &#8230; mid-dot &#183;</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Quotes: &#8220;double&#8221; and &#8216;single&#8217; (smart)</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Symbols: &#169; (c) &#174; (r) &#8482; (tm) &#167; section &#182; pilcrow</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Currency: &#8364; euro &#163; pound &#165; yen &#162; cent &#8377; rupee</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Math: &#177; &#215; &#247; &#8800; &#8804; &#8805; &#8776; &#8734; &#8730; &#8721; &#960; &#176;</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Fractions: &#189; &#188; &#190;</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Accented: &#225; &#233; &#241; &#252; &#231; &#230; &#248;</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Greek: &#945; &#946; &#947; &#948; &#960; &#937;</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Hex form: em-dash &#x2014; copyright &#xA9; euro &#x20AC; pi &#x3C0;</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>CJK: &#20320;&#22909; (Chinese) &#12371;&#12435;&#12395;&#12385;&#12399; (Japanese) &#50504;&#45397; (Korean)</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Hebrew: &#1513;&#1500;&#1493;&#1501;</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Arabic: &#1605;&#1585;&#1581;&#1576;&#1575;&#1611;</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>Edge cases preserved: &#abc; (non-numeric) &#xZZ; (invalid hex) &#0; (NUL) &#7; (BEL)</w:t></w:r></w:p>' +
    '</w:body></w:document>';

String html = DocGenHtmlRenderer.convertToHtml(docXml, new Map<String, String>());

// === Assertion 1: No raw entity-with-escaped-ampersand leakage ===
// Pre-fix: '&#8212;' would survive through unescapeXmlEntities, then escapeHtml4 would
// turn it into '&amp;#8212;' which Flying Saucer renders as literal text.
List<String> leakChecks = new List<String>{
    '&amp;#8212;',
    '&amp;#8211;',
    '&amp;#8226;',
    '&amp;#183;',
    '&amp;#8220;',
    '&amp;#8221;',
    '&amp;#169;',
    '&amp;#8364;',
    '&amp;#x2014;',
    '&amp;#xA9;',
    '&amp;#x20AC;',
    '&amp;#x3C0;',
    '&amp;#1513;',
    '&amp;#1605;',
    '&amp;#20320;'
};
Integer leaked = 0;
for (String entity : leakChecks) {
    if (html.contains(entity)) {
        leaked++;
        System.debug('  LEAKED: ' + entity);
    }
}
System.debug('=== ASSERTION 1: No escaped-ampersand entity leaks ===');
System.debug('Leaked count: ' + leaked + ' / ' + leakChecks.size() + ' (must be 0)');
System.assertEquals(0, leaked, 'Numeric entities leaked through escapeHtml4 — fix is broken');

// === Assertion 2: Renderable forms reach Flying Saucer ===
// Output should contain either literal Unicode codepoints OR named HTML entities.
// Both render correctly in Flying Saucer; the broken form is &amp;#NNNN;.
Map<String, String> renderableChecks = new Map<String, String>{
    'em-dash' => '&mdash;|—',
    'en-dash' => '&ndash;|–',
    'bullet' => '&bull;|•',
    'ellipsis' => '&hellip;|…',
    'mid-dot' => '&middot;|·',
    'left-dquote' => '&ldquo;|“',
    'right-dquote' => '&rdquo;|”',
    'copyright' => '&copy;|©',
    'registered' => '&reg;|®',
    'trademark' => '&trade;|™',
    'euro' => '&euro;|€',
    'pound' => '&pound;|£',
    'pi' => '&pi;|π',
    'degree' => '&deg;|°',
    'plus-minus' => '&plusmn;|±',
    'half' => '&frac12;|½'
};
Integer rendered = 0;
for (String label : renderableChecks.keySet()) {
    String[] options = renderableChecks.get(label).split('\\|');
    Boolean found = false;
    for (String opt : options) {
        if (html.contains(opt)) {
            found = true;
            break;
        }
    }
    if (found) {
        rendered++;
    } else {
        System.debug('  MISSING (no renderable form): ' + label);
    }
}
System.debug('=== ASSERTION 2: Renderable forms reach output ===');
System.debug('Rendered count: ' + rendered + ' / ' + renderableChecks.size());
System.assertEquals(renderableChecks.size(), rendered, 'Some entities did not produce renderable output');

// === Assertion 3: Edge cases preserved untouched ===
// '&#abc;', '&#xZZ;', '&#0;', '&#7;' should pass through as literal escaped strings.
System.debug('=== ASSERTION 3: Edge cases preserved ===');
System.assert(html.contains('&amp;#abc;'), 'Non-numeric &#abc; should survive escaped');
System.assert(html.contains('&amp;#xZZ;'), 'Invalid hex &#xZZ; should survive escaped');
System.assert(html.contains('&amp;#0;'), 'NUL control &#0; should survive escaped');
System.assert(html.contains('&amp;#7;'), 'BEL control &#7; should survive escaped');
System.debug('All edge cases preserved literally.');

// === Final step: Render to PDF and save as ContentVersion for visual inspection ===
Blob pdf = Blob.toPdf(html);
ContentVersion cv = new ContentVersion(
    Title = 'DocGen Special Characters Proof',
    PathOnClient = 'docgen-special-chars-proof.pdf',
    VersionData = pdf,
    FirstPublishLocationId = UserInfo.getUserId()
);
insert cv;
ContentVersion stored = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
System.debug('=== PDF SAVED ===');
System.debug('ContentVersion Id: ' + stored.Id);
System.debug('ContentDocument Id: ' + stored.ContentDocumentId);
System.debug('PDF size: ' + pdf.size() + ' bytes');
System.debug('=== ALL ASSERTIONS PASSED — fix verified end-to-end ===');
