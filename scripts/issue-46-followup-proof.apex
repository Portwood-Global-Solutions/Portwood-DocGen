// Proof for v1.80 #46 follow-up regression.
// Joe's scenario: {%Image:N:240} with a high-res CV-backed image on PDF output.
// Pre-fix: <img max-width:240px;max-height:240px;width:auto;height:auto;> with no
//   HTML attrs — Flying Saucer renders at natural pixel size (4032×3024 → 6.5" wide).
// Post-fix: <img width="240" max-width:240px;max-height:240px;> — Flying Saucer
//   scales height from intrinsic aspect, capping width at 240px.

// Set up: minimal embedded image to act as our CV-backed "phone photo"
// (3024x4032 portrait shape — same proportions as Joe's reported phone photos).
// Use a real test PNG so dims are non-zero.
Blob fakeImage = EncodingUtil.base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
);
ContentVersion testCv = new ContentVersion(
    Title = 'docgen-test-phone-photo',
    PathOnClient = 'phone-photo.png',
    VersionData = fakeImage,
    FirstPublishLocationId = UserInfo.getUserId()
);
insert testCv;
Id cvId = [SELECT Id FROM ContentVersion WHERE Id = :testCv.Id LIMIT 1].Id;
System.debug('Test ContentVersion: ' + cvId);

// Build a minimal docx-like XML that contains an autoSize-marked drawing.
// (Bypasses the buildImageXml path; we're testing processDrawing directly.)
// 240px in EMUs = 240 * 9525 = 2286000.
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

Map<String, String> images = new Map<String, String>{ 'rId99' => '/sfc/servlet.shepherd/version/download/' + cvId };
String html = DocGenHtmlRenderer.convertToHtml(docXml, images);

System.debug('=== OUTPUT HTML ===');
System.debug(html);

// === Assertion: HTML width attr is emitted in autoSize branch ===
Boolean hasWidthAttr = html.contains('width="240"');
Boolean hasHeightAttr = html.contains('height="240"');
Boolean hasMaxWidthCss = html.contains('max-width:240px');
Boolean hasOldWidthAuto = html.contains('width:auto;height:auto');

System.debug('=== ASSERTIONS ===');
System.debug('width="240" HTML attr present (REQUIRED): ' + hasWidthAttr);
System.debug('height="240" HTML attr present (must be FALSE for autoSize): ' + hasHeightAttr);
System.debug('max-width:240px CSS present: ' + hasMaxWidthCss);
System.debug('OLD width:auto;height:auto leaked (must be FALSE): ' + hasOldWidthAuto);

System.assert(hasWidthAttr, 'autoSize branch must emit HTML width attr to anchor Flying Saucer layout');
System.assert(!hasHeightAttr, 'autoSize must NOT emit height attr — would force squashing');
System.assert(hasMaxWidthCss, 'max-width CSS still expected as belt-and-suspenders');
System.assert(!hasOldWidthAuto, 'Old width:auto;height:auto declarations would override HTML width attr');

// Render to PDF and save for visual inspection
Blob pdf = Blob.toPdf(html);
ContentVersion proof = new ContentVersion(
    Title = 'Issue 46 Followup Proof',
    PathOnClient = 'issue-46-followup-proof.pdf',
    VersionData = pdf,
    FirstPublishLocationId = UserInfo.getUserId()
);
insert proof;
ContentVersion stored = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :proof.Id];
System.debug('PDF CV: ' + stored.Id);
System.debug('=== ALL ASSERTIONS PASSED ===');
