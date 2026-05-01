// Direct trace: render a tiny doc and see the HTML output exactly
String docXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
    '<w:body>' +
    '<w:p><w:r><w:t>EM&#8212;DASH HEX&#x2014;DASH MID&#183;DOT EURO&#8364;</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>COPY&#169; PI&#x3C0;</w:t></w:r></w:p>' +
    '</w:body></w:document>';

String html = DocGenHtmlRenderer.convertToHtml(docXml, new Map<String, String>());

System.debug('=== INPUT ===');
System.debug(docXml);
System.debug('=== OUTPUT HTML ===');
System.debug(html);
System.debug('=== CONTAINS CHECKS ===');
System.debug('contains em-dash literal: ' + html.contains('—'));
System.debug('contains &#8212; literal: ' + html.contains('&#8212;'));
System.debug('contains &amp;#8212; (escaped): ' + html.contains('&amp;#8212;'));
System.debug('contains euro: ' + html.contains('€'));
System.debug('contains pi: ' + html.contains('π'));
System.debug('contains copyright: ' + html.contains('©'));
