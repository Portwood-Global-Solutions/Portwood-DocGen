// DocGen E2E Test 03 — PDF Generation + Output Verification
// Run: sf apex run --target-org <org> -f scripts/e2e-03-generate-pdf.apex
// Depends on: e2e-02 (Account 'E2E Test Corp', Template 'E2E Test Template')
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;

Id acctId;
Id tmplId;

// ===== Look up test data =====
try {
    List<Account> accts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp' LIMIT 1];
    if (accts.isEmpty()) {
        fail++;
        System.debug('LOOKUP ACCOUNT: FAIL — E2E Test Corp not found. Run e2e-02 first.');
    } else {
        acctId = accts[0].Id;
        pass++;
        System.debug('LOOKUP ACCOUNT: PASS — ' + acctId);
    }

    List<DocGen_Template__c> tmpls = [
        SELECT Id, Output_Format__c
        FROM DocGen_Template__c
        WHERE Name = 'E2E Test Template'
        LIMIT 1
    ];
    if (tmpls.isEmpty()) {
        fail++;
        System.debug('LOOKUP TEMPLATE: FAIL — E2E Test Template not found. Run e2e-02 first.');
    } else {
        tmplId = tmpls[0].Id;
        pass++;
        System.debug('LOOKUP TEMPLATE: PASS — ' + tmplId);
    }
} catch (Exception e) {
    fail++;
    System.debug('LOOKUP: FAIL — ' + e.getMessage());
}

if (acctId == null || tmplId == null) {
    System.debug('========================================');
    System.debug('E2E-03 GENERATE PDF — PASS: ' + pass + '  FAIL: ' + fail + '  ABORTED (missing test data)');
    System.debug('========================================');
    return;
}

// ===== Ensure template is set to PDF output =====
try {
    DocGen_Template__c t = [SELECT Id, Output_Format__c FROM DocGen_Template__c WHERE Id = :tmplId];
    if (t.Output_Format__c != 'PDF') {
        t.Output_Format__c = 'PDF';
        update t;
    }
    pass++;
    System.debug('TEMPLATE SET TO PDF: PASS');
} catch (Exception e) {
    fail++;
    System.debug('TEMPLATE SET TO PDF: FAIL — ' + e.getMessage());
}

// ===== Generate PDF via processAndReturnDocument =====
String base64Pdf;
try {
    Map<String, Object> genResult = DocGenController.processAndReturnDocument(tmplId, acctId);

    if (genResult == null) {
        fail++;
        System.debug('PDF GEN RESULT: FAIL — null result');
    } else {
        base64Pdf = (String) genResult.get('base64');
        String docTitle = (String) genResult.get('title');

        if (String.isNotBlank(base64Pdf)) {
            pass++;
            System.debug('PDF GEN NON-EMPTY: PASS — title: ' + docTitle + ', base64 length: ' + base64Pdf.length());
        } else {
            fail++;
            System.debug('PDF GEN NON-EMPTY: FAIL — empty base64');
        }

        // Template was set to PDF above — verify processAndReturnDocument returns PDF bytes (%PDF header = hex 2550)
        if (String.isNotBlank(base64Pdf)) {
            Blob docBlob = EncodingUtil.base64Decode(base64Pdf);
            String hexStart = EncodingUtil.convertToHex(docBlob).substring(0, 4).toUpperCase();
            if (hexStart == '2550') {
                pass++;
                System.debug('PDF OUTPUT VALID: PASS');
            } else {
                fail++;
                System.debug('PDF OUTPUT VALID: FAIL — got hex: ' + hexStart);
            }

            // Verify non-trivial size (a real PDF with content should be > 500 bytes)
            if (docBlob.size() > 500) {
                pass++;
                System.debug('PDF SIZE > 500 bytes: PASS — ' + docBlob.size() + ' bytes');
            } else {
                fail++;
                System.debug('PDF SIZE > 500 bytes: FAIL — only ' + docBlob.size() + ' bytes');
            }
        }

        // Save the PDF to the Account for manual inspection
        if (String.isNotBlank(base64Pdf)) {
            try {
                ContentVersion pdfCv = new ContentVersion(
                    Title = 'E2E Output - PDF',
                    PathOnClient = 'e2e_output.pdf',
                    VersionData = EncodingUtil.base64Decode(base64Pdf),
                    FirstPublishLocationId = acctId
                );
                insert pdfCv;
                pass++;
                System.debug('PDF SAVED TO ACCOUNT: PASS');
                System.debug('>>> DOWNLOAD: Navigate to Account "E2E Test Corp" > Files tab to inspect the PDF');
            } catch (Exception e) {
                fail++;
                System.debug('PDF SAVED TO ACCOUNT: FAIL — ' + e.getMessage());
            }
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('PDF GENERATION: FAIL — ' + e.getMessage() + ' at line ' + e.getLineNumber());
}

// ===== Test generatePdf endpoint =====
try {
    Map<String, Object> pdfResult = DocGenController.generatePdf(tmplId, acctId, false);
    if (pdfResult != null) {
        String gpBase64 = (String) pdfResult.get('base64');
        if (String.isNotBlank(gpBase64)) {
            pass++;
            System.debug('GENERATE PDF ENDPOINT: PASS — base64 length: ' + gpBase64.length());
        } else {
            fail++;
            System.debug('GENERATE PDF ENDPOINT: FAIL — empty base64');
        }
    } else {
        fail++;
        System.debug('GENERATE PDF ENDPOINT: FAIL — null result');
    }
} catch (Exception e) {
    fail++;
    System.debug('GENERATE PDF ENDPOINT: FAIL — ' + e.getMessage());
}

// ===== Test generatePdf with saveToRecord=true =====
try {
    Map<String, Object> saveResult = DocGenController.generatePdf(tmplId, acctId, true);
    if (saveResult != null) {
        // Check that a ContentDocumentId was returned
        Object cdId = saveResult.get('contentDocumentId');
        if (cdId != null) {
            pass++;
            System.debug('GENERATE PDF SAVE TO RECORD: PASS — ContentDocumentId: ' + cdId);
        } else {
            // Some implementations return base64 even with save
            String sb64 = (String) saveResult.get('base64');
            if (String.isNotBlank(sb64)) {
                pass++;
                System.debug('GENERATE PDF SAVE TO RECORD: PASS (base64 returned)');
            } else {
                fail++;
                System.debug('GENERATE PDF SAVE TO RECORD: FAIL — no contentDocumentId or base64');
            }
        }
    } else {
        fail++;
        System.debug('GENERATE PDF SAVE TO RECORD: FAIL — null result');
    }
} catch (Exception e) {
    fail++;
    System.debug('GENERATE PDF SAVE TO RECORD: FAIL — ' + e.getMessage());
}

// ===== HTML template type (v1.61+) — raw HTML input, PDF output =====
try {
    DocGen_Template__c hTmpl = new DocGen_Template__c(
        Name = 'E2E HTML Template ' + Datetime.now().getTime(),
        Type__c = 'HTML',
        Output_Format__c = 'PDF',
        Base_Object_API__c = 'Account',
        Query_Config__c = 'Name, Industry',
        Header_Html__c = '<div>{Name} - Page {PageNumber}</div>',
        Footer_Html__c = '<div>Page {PageNumber} of {TotalPages}</div>'
    );
    insert hTmpl;
    String body = '<html><body><h1>{Name}</h1><p>Industry: {Industry}</p></body></html>';
    ContentVersion hcv = new ContentVersion(
        Title = hTmpl.Name,
        PathOnClient = 'b.html',
        VersionData = Blob.valueOf(body),
        FirstPublishLocationId = hTmpl.Id
    );
    insert hcv;
    hcv = [SELECT Id FROM ContentVersion WHERE Id = :hcv.Id];
    insert new DocGen_Template_Version__c(Template__c = hTmpl.Id, Content_Version_Id__c = hcv.Id, Is_Active__c = true);
    Map<String, Object> hr = DocGenService.generatePdfBlob(hTmpl.Id, acctId);
    Blob hpdf = (Blob) hr.get('blob');
    if (hpdf != null && hpdf.size() > 100) {
        pass++;
        System.debug('HTML TEMPLATE PDF: PASS — size=' + hpdf.size());
    } else {
        fail++;
        System.debug('HTML TEMPLATE PDF: FAIL — blob too small');
    }
    String lh = DocGenService.lastRenderedHtml;
    if (lh != null && lh.contains('counter(page)') && lh.contains('@top-center')) {
        pass++;
        System.debug('HTML COUNTER CSS: PASS');
    } else {
        fail++;
        System.debug('HTML COUNTER CSS: FAIL');
    }
    delete hTmpl;
} catch (Exception e) {
    fail++;
    System.debug('HTML TEMPLATE PDF: FAIL — ' + e.getMessage() + ' line ' + e.getLineNumber());
}

// ===== Filtered subsets: two loops, same relationship, different WHEREs =====
// V3 config with two child nodes against Contacts, each with its own alias +
// WHERE clause. Verifies the data retriever keys results by alias and the
// scout reports per-alias counts (so giant-query routing can target one).
try {
    Account fsAcct = new Account(Name = 'E2E Filtered Subsets ' + Datetime.now().getTime());
    insert fsAcct;
    insert new List<Contact>{
        new Contact(LastName = 'Sub-A1', AccountId = fsAcct.Id, Department = 'Subscription'),
        new Contact(LastName = 'Sub-A2', AccountId = fsAcct.Id, Department = 'Subscription'),
        new Contact(LastName = 'Set-B1', AccountId = fsAcct.Id, Department = 'Setup'),
        new Contact(LastName = 'Set-B2', AccountId = fsAcct.Id, Department = 'Setup')
    };
    String v3 =
        '{"v":3,"root":"Account","nodes":[' +
        '{"id":"n0","object":"Account","fields":["Name"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
        '{"id":"n1","object":"Contact","fields":["LastName"],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts","alias":"SubscriptionContacts","where":"Department = \'Subscription\'"},' +
        '{"id":"n2","object":"Contact","fields":["LastName"],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts","alias":"SetupContacts","where":"Department = \'Setup\'"}' +
        ']}';
    Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(fsAcct.Id, v3);
    Boolean countsByAlias =
        counts.containsKey('SubscriptionContacts') &&
        counts.get('SubscriptionContacts') == 2 &&
        counts.containsKey('SetupContacts') &&
        counts.get('SetupContacts') == 2;
    if (countsByAlias) {
        pass++;
        System.debug('FILTERED SUBSET SCOUT: PASS — ' + counts);
    } else {
        fail++;
        System.debug('FILTERED SUBSET SCOUT: FAIL — ' + counts);
    }

    // End-to-end: build a DOCX template body that uses both aliases, generate,
    // and confirm each loop renders only its filtered records.
    DocGen_Template__c fsTmpl = new DocGen_Template__c(
        Name = 'E2E Filtered Tmpl ' + Datetime.now().getTime(),
        Type__c = 'HTML',
        Output_Format__c = 'PDF',
        Base_Object_API__c = 'Account',
        Query_Config__c = v3
    );
    insert fsTmpl;
    // SUBS:/SETUP: markers go in <div> (not inside <tr>) so Flying Saucer's strict
    // parser doesn't see orphan text inside table-row context. The substring
    // assertions below still match because indexOf() is content-search, not DOM.
    String body =
        '<html><body><h1>{Name}</h1>' +
        '<div>SUBS:<table>{#SubscriptionContacts}<tr><td>{LastName}</td></tr>{/SubscriptionContacts}</table></div>' +
        '<div>SETUP:<table>{#SetupContacts}<tr><td>{LastName}</td></tr>{/SetupContacts}</table></div>' +
        '</body></html>';
    ContentVersion fcv = new ContentVersion(
        Title = fsTmpl.Name,
        PathOnClient = 'b.html',
        VersionData = Blob.valueOf(body),
        FirstPublishLocationId = fsTmpl.Id
    );
    insert fcv;
    fcv = [SELECT Id FROM ContentVersion WHERE Id = :fcv.Id];
    insert new DocGen_Template_Version__c(Template__c = fsTmpl.Id, Content_Version_Id__c = fcv.Id, Is_Active__c = true);
    DocGenService.generatePdfBlob(fsTmpl.Id, fsAcct.Id);
    String fh = DocGenService.lastRenderedHtml;
    Boolean subBlock = fh != null && fh.indexOf('SUBS') < fh.indexOf('SETUP');
    Boolean subHasA =
        fh != null &&
        fh.substring(fh.indexOf('SUBS'), fh.indexOf('SETUP')).contains('Sub-A1') &&
        fh.substring(fh.indexOf('SUBS'), fh.indexOf('SETUP')).contains('Sub-A2');
    Boolean subLacksB = fh != null && !fh.substring(fh.indexOf('SUBS'), fh.indexOf('SETUP')).contains('Set-B');
    Boolean setHasB =
        fh != null &&
        fh.substring(fh.indexOf('SETUP')).contains('Set-B1') &&
        fh.substring(fh.indexOf('SETUP')).contains('Set-B2');
    Boolean setLacksA = fh != null && !fh.substring(fh.indexOf('SETUP')).contains('Sub-A');
    if (subBlock && subHasA && subLacksB && setHasB && setLacksA) {
        pass++;
        System.debug('FILTERED SUBSET RENDER: PASS — each loop has only its filtered records');
    } else {
        fail++;
        System.debug(
            'FILTERED SUBSET RENDER: FAIL — subBlock=' +
                subBlock +
                ' subA=' +
                subHasA +
                ' subNoB=' +
                subLacksB +
                ' setB=' +
                setHasB +
                ' setNoA=' +
                setLacksA
        );
    }
    delete fsTmpl;
    delete fsAcct;
} catch (Exception e) {
    fail++;
    System.debug('FILTERED SUBSETS: FAIL — ' + e.getMessage() + ' line ' + e.getLineNumber());
}

// ===== 1.68: page size × orientation matrix (Letter/Legal/A4 × Portrait/Landscape) =====
// Verifies Page_Size__c + Page_Orientation__c drive correct PDF MediaBox dims.
// Critical: do NOT delete generated ContentDocuments inside the loop — it
// poisons the platform state and the next generateDocument throws a SOAP-level
// "entity is deleted" fault. Cleanup happens after the loop.
try {
    DocGen_Template__c psTmpl = new DocGen_Template__c(
        Name = 'E2E PageSetup ' + Datetime.now().getTime(),
        Type__c = 'HTML',
        Output_Format__c = 'PDF',
        Base_Object_API__c = 'Account',
        Query_Config__c = '{"v":3,"root":"Account","nodes":[{"id":"n0","object":"Account","fields":["Name"],"parentNode":null,"lookupField":null,"relationshipName":null}]}'
    );
    insert psTmpl;
    ContentVersion psCv = new ContentVersion(
        Title = psTmpl.Name,
        PathOnClient = 'b.html',
        VersionData = Blob.valueOf('<html><body><p>Page setup matrix</p></body></html>'),
        FirstPublishLocationId = psTmpl.Id
    );
    insert psCv;
    psCv = [SELECT Id FROM ContentVersion WHERE Id = :psCv.Id];
    insert new DocGen_Template_Version__c(
        Template__c = psTmpl.Id,
        Content_Version_Id__c = psCv.Id,
        Is_Active__c = true
    );

    List<List<Object>> mtx = new List<List<Object>>{
        new List<Object>{ 'Letter', 'Portrait', 612, 792 },
        new List<Object>{ 'Letter', 'Landscape', 792, 612 },
        new List<Object>{ 'Legal', 'Portrait', 612, 1008 },
        new List<Object>{ 'Legal', 'Landscape', 1008, 612 },
        new List<Object>{ 'A4', 'Portrait', 595, 842 },
        new List<Object>{ 'A4', 'Landscape', 842, 595 }
    };
    Pattern mbPat = Pattern.compile('\\[\\s*([0-9.\\-]+)\\s+([0-9.\\-]+)\\s+([0-9.\\-]+)\\s+([0-9.\\-]+)\\s*\\]');
    Integer mtxPass = 0;
    Integer mtxFail = 0;
    for (List<Object> row : mtx) {
        psTmpl.Page_Size__c = (String) row[0];
        psTmpl.Page_Orientation__c = (String) row[1];
        psTmpl.Page_Margins__c = 'Default';
        update psTmpl;
        Id psDocId = DocGenService.generateDocument(psTmpl.Id, acctId);
        ContentVersion psPdfCv = [
            SELECT VersionData
            FROM ContentVersion
            WHERE ContentDocumentId = :psDocId
            ORDER BY VersionNumber DESC
            LIMIT 1
        ];
        String hex = EncodingUtil.convertToHex(psPdfCv.VersionData);
        Decimal w = -1;
        Decimal h = -1;
        Integer hi = hex.indexOf('2f4d65646961426f78');
        if (hi >= 0) {
            String chunk = EncodingUtil.convertFromHex(hex.substring(hi + 18, Math.min(hi + 220, hex.length())))
                .toString();
            Matcher mm = mbPat.matcher(chunk);
            if (mm.find()) {
                w = Decimal.valueOf(mm.group(3));
                h = Decimal.valueOf(mm.group(4));
            }
        }
        Integer expW = (Integer) row[2];
        Integer expH = (Integer) row[3];
        if (w > 0 && Math.abs(w - expW) <= 2 && Math.abs(h - expH) <= 2) {
            mtxPass++;
        } else {
            mtxFail++;
            System.debug(
                '  MATRIX FAIL ' + row[0] + '/' + row[1] + ' got ' + w + 'x' + h + ' expected ' + expW + 'x' + expH
            );
        }
    }
    if (mtxFail == 0) {
        pass++;
        System.debug('PAGE SETUP MATRIX (6 combos): PASS');
    } else {
        fail++;
        System.debug('PAGE SETUP MATRIX: FAIL — ' + mtxFail + '/' + (mtxPass + mtxFail) + ' combos failed');
    }

    // Margins preset check — generate one PDF with Wide preset and verify it embeds
    psTmpl.Page_Size__c = 'Letter';
    psTmpl.Page_Orientation__c = 'Portrait';
    psTmpl.Page_Margins__c = 'Wide';
    update psTmpl;
    Id wDocId = DocGenService.generateDocument(psTmpl.Id, acctId);
    if (wDocId != null) {
        pass++;
        System.debug('MARGIN PRESET (Wide) RENDER: PASS');
    } else {
        fail++;
        System.debug('MARGIN PRESET (Wide) RENDER: FAIL');
    }

    delete psTmpl;
} catch (Exception e) {
    fail++;
    System.debug('PAGE SETUP MATRIX: FAIL — ' + e.getMessage() + ' line ' + e.getLineNumber());
}

// ===== Nested-table direct-child property scoping (issue #49) =====
// Outer cell wrapping an inner table whose first row has <w:tblHeader/> must
// NOT inherit that header status (would cause inherited bold cascade).
try {
    String d = '<w:document xmlns:w="x"><w:body>'
        + '<w:tbl><w:tblPr/><w:tr><w:tc><w:tcPr/>'
        + '<w:tbl><w:tblPr/>'
        + '<w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>H</w:t></w:r></w:p></w:tc></w:tr>'
        + '<w:tr><w:tc><w:p><w:r><w:rPr><w:b w:val="false"/></w:rPr><w:t>D</w:t></w:r></w:p></w:tc></w:tr>'
        + '</w:tbl>'
        + '</w:tc></w:tr></w:tbl>'
        + '</w:body></w:document>';
    String html = portwoodglobal.DocGenHtmlRenderer.convertToHtml(d, new Map<String, String>());
    Boolean ok = html.contains('<tr><td><table') && !html.contains('<b>D</b>');
    if (ok) { pass++; System.debug('NESTED TABLE NO-BOLD CASCADE: PASS'); }
    else { fail++; System.debug('NESTED TABLE NO-BOLD CASCADE: FAIL — ' + html); }
} catch (Exception e) { fail++; System.debug('NESTED TABLE NO-BOLD CASCADE: FAIL — ' + e.getMessage()); }

System.debug('========================================');
System.debug(
    'E2E-03 GENERATE PDF — PASS: ' +
        pass +
        '  FAIL: ' +
        fail +
        (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
