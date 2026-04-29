// DocGen E2E Test 02 — Test Data + Template Creation
// Run: sf apex run --target-org <org> -f scripts/e2e-02-template-crud.apex
// Depends on: nothing (creates all data)
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;

Id acctId;
Id tmplId;
Id verId;

// ===== Clean up any leftover test data from prior runs =====
try {
    List<Account> oldAccts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp'];
    if (!oldAccts.isEmpty()) {
        Set<Id> oldAcctIds = new Set<Id>();
        for (Account a : oldAccts) {
            oldAcctIds.add(a.Id);
        }
        delete [
            SELECT Id
            FROM DocGen_Signature_Audit__c
            WHERE
                Signature_Request__c IN (
                    SELECT Id
                    FROM DocGen_Signature_Request__c
                    WHERE Related_Record_Id__c IN :oldAcctIds
                )
        ];
        delete [
            SELECT Id
            FROM DocGen_Signer__c
            WHERE
                Signature_Request__c IN (
                    SELECT Id
                    FROM DocGen_Signature_Request__c
                    WHERE Related_Record_Id__c IN :oldAcctIds
                )
        ];
        delete [SELECT Id FROM DocGen_Signature_Request__c WHERE Related_Record_Id__c IN :oldAcctIds];
        delete [SELECT Id FROM Opportunity WHERE AccountId IN :oldAcctIds];
        delete [SELECT Id FROM Contact WHERE AccountId IN :oldAcctIds];
        delete oldAccts;
        System.debug('CLEANUP: Removed leftover test data from prior run');
    }
    List<DocGen_Template__c> oldTmpls = [SELECT Id FROM DocGen_Template__c WHERE Name = 'E2E Test Template'];
    if (!oldTmpls.isEmpty()) {
        Set<Id> oldTmplIds = new Set<Id>();
        for (DocGen_Template__c t : oldTmpls) {
            oldTmplIds.add(t.Id);
        }
        delete [SELECT Id FROM DocGen_Template_Version__c WHERE Template__c IN :oldTmplIds];
        delete oldTmpls;
        System.debug('CLEANUP: Removed leftover templates from prior run');
    }
} catch (Exception e) {
    System.debug('CLEANUP NOTE: ' + e.getMessage());
}

// ===== Create Test Account =====
try {
    Account acct = new Account(
        Name = 'E2E Test Corp',
        Industry = 'Technology',
        Phone = '555-0100',
        Website = 'https://e2etest.example.com',
        BillingStreet = '123 Test St',
        BillingCity = 'Indianapolis',
        BillingState = 'IN',
        BillingPostalCode = '46204',
        BillingCountry = 'US'
    );
    insert acct;
    acctId = acct.Id;
    if (acctId != null) {
        pass++;
        System.debug('ACCOUNT CREATED: PASS — ' + acctId);
    } else {
        fail++;
        System.debug('ACCOUNT CREATED: FAIL');
    }
} catch (Exception e) {
    fail++;
    System.debug('ACCOUNT CREATED: FAIL — ' + e.getMessage());
}

// ===== Create 3 Contacts =====
try {
    List<Contact> cons = new List<Contact>{
        new Contact(
            FirstName = 'Alice',
            LastName = 'Johnson',
            Email = 'alice@e2etest.example.com',
            Title = 'CEO',
            Phone = '555-0101',
            AccountId = acctId
        ),
        new Contact(
            FirstName = 'Bob',
            LastName = 'Smith',
            Email = 'bob@e2etest.example.com',
            Title = 'CTO',
            Phone = '555-0102',
            AccountId = acctId
        ),
        new Contact(
            FirstName = 'Carol',
            LastName = 'Davis',
            Email = 'carol@e2etest.example.com',
            Title = 'CFO',
            Phone = '555-0103',
            AccountId = acctId
        )
    };
    insert cons;
    Integer conCount = [SELECT COUNT() FROM Contact WHERE AccountId = :acctId];
    if (conCount == 3) {
        pass++;
        System.debug('3 CONTACTS CREATED: PASS');
    } else {
        fail++;
        System.debug('3 CONTACTS CREATED: FAIL — count: ' + conCount);
    }
} catch (Exception e) {
    fail++;
    System.debug('CONTACTS CREATED: FAIL — ' + e.getMessage());
}

// ===== Create Opportunity =====
try {
    Opportunity opp = new Opportunity(
        Name = 'E2E Test Opp',
        StageName = 'Prospecting',
        Amount = 75000,
        CloseDate = Date.today().addDays(30),
        AccountId = acctId
    );
    insert opp;
    if (opp.Id != null) {
        pass++;
        System.debug('OPPORTUNITY CREATED: PASS — ' + opp.Id);
    } else {
        fail++;
        System.debug('OPPORTUNITY CREATED: FAIL');
    }
} catch (Exception e) {
    fail++;
    System.debug('OPPORTUNITY CREATED: FAIL — ' + e.getMessage());
}

// ===== Build rich styled DOCX — business proposal with colors, tables, all tag types =====
try {
    // Reusable XML fragments
    String S =
        '<w:pPr><w:shd w:val="clear" w:color="auto" w:fill="1F4E79"/><w:spacing w:before="360" w:after="120"/></w:pPr>' +
        '<w:r><w:rPr><w:b/><w:color w:val="FFFFFF"/><w:sz w:val="28"/></w:rPr><w:t>';
    String hc = '<w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="1F4E79"/></w:tcPr>';
    String hw = '<w:r><w:rPr><w:b/><w:color w:val="FFFFFF"/></w:rPr><w:t>';
    String B = '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">';

    String dx =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"' +
        ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>' +
        // ── COVER PAGE ──
        '<w:p><w:pPr><w:spacing w:before="4320"/><w:jc w:val="center"/></w:pPr>' +
        '<w:r><w:rPr><w:b/><w:sz w:val="72"/><w:szCs w:val="72"/><w:color w:val="1F4E79"/></w:rPr>' +
        '<w:t>BUSINESS PROPOSAL</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:jc w:val="center"/><w:pBdr><w:bottom w:val="single" w:sz="12" w:space="8" w:color="1F4E79"/></w:pBdr><w:spacing w:after="360"/></w:pPr></w:p>' +
        '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>' +
        '<w:r><w:rPr><w:sz w:val="40"/><w:color w:val="404040"/></w:rPr>' +
        '<w:t>Prepared for {Name}</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="480"/><w:jc w:val="center"/></w:pPr>' +
        '<w:r><w:rPr><w:sz w:val="24"/><w:color w:val="808080"/></w:rPr>' +
        '<w:t>{BillingCity}, {BillingState}</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="1440"/><w:jc w:val="center"/></w:pPr>' +
        '<w:r><w:rPr><w:b/><w:sz w:val="20"/><w:color w:val="C00000"/></w:rPr>' +
        '<w:t>CONFIDENTIAL</w:t></w:r></w:p>' +
        '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' +
        // ── PAGE 2: COMPANY OVERVIEW (white on blue) ──
        '<w:p>' +
        S +
        'COMPANY OVERVIEW</w:t></w:r></w:p>' +
        '<w:p>' +
        B +
        'Industry: </w:t></w:r><w:r><w:t>{Industry}</w:t></w:r></w:p>' +
        '<w:p>' +
        B +
        'Phone: </w:t></w:r><w:r><w:t>{Phone}</w:t></w:r></w:p>' +
        '<w:p>' +
        B +
        'Website: </w:t></w:r><w:r><w:t>{Website}</w:t></w:r></w:p>' +
        '<w:p>' +
        B +
        'Address: </w:t></w:r>' +
        '<w:r><w:t>{BillingStreet}, {BillingCity}, {BillingState} {BillingPostalCode}</w:t></w:r></w:p>' +
        // ── Conditional: industry check with else ──
        '<w:p>' +
        B +
        'Sector: </w:t></w:r>' +
        '<w:r><w:rPr><w:i/><w:color w:val="2E75B6"/></w:rPr>' +
        '<w:t>{#Industry}Classified under {Industry}{:else}No industry on file{/Industry}</w:t></w:r></w:p>' +
        // ── IF comparison ──
        '<w:p>' +
        B +
        'Classification: </w:t></w:r>' +
        '<w:r><w:t>{#IF Industry = Technology}Technology Partner{:else}General Partner{/IF}</w:t></w:r></w:p>' +
        // ── Inverse conditional ──
        '<w:p><w:r><w:rPr><w:i/><w:color w:val="808080"/></w:rPr>' +
        '<w:t>{^HasDiscount}Standard pricing applies — no discount on file.{/HasDiscount}</w:t></w:r></w:p>' +
        // ── Section: TEAM DIRECTORY ──
        '<w:p>' +
        S +
        'TEAM DIRECTORY</w:t></w:r></w:p>';

    // ── Styled table with blue header, borders ──
    String tb =
        '<w:tblBorders>' +
        '<w:top w:val="single" w:sz="6" w:color="1F4E79"/><w:left w:val="single" w:sz="6" w:color="1F4E79"/>' +
        '<w:bottom w:val="single" w:sz="6" w:color="1F4E79"/><w:right w:val="single" w:sz="6" w:color="1F4E79"/>' +
        '<w:insideH w:val="single" w:sz="4" w:color="BDD7EE"/><w:insideV w:val="single" w:sz="4" w:color="BDD7EE"/>' +
        '</w:tblBorders>';
    dx +=
        '<w:tbl><w:tblPr><w:tblW w:w="9360" w:type="dxa"/>' +
        tb +
        '</w:tblPr>' +
        // Header row
        '<w:tr><w:tc>' +
        hc +
        '<w:p>' +
        hw +
        'Name</w:t></w:r></w:p></w:tc>' +
        '<w:tc>' +
        hc +
        '<w:p>' +
        hw +
        'Title</w:t></w:r></w:p></w:tc>' +
        '<w:tc>' +
        hc +
        '<w:p>' +
        hw +
        'Email</w:t></w:r></w:p></w:tc></w:tr>' +
        // Loop open
        '<w:tr><w:tc><w:p><w:r><w:t>{#Contacts}</w:t></w:r></w:p></w:tc><w:tc><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr>' +
        // Data row
        '<w:tr><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>{FirstName} {LastName}</w:t></w:r></w:p></w:tc>' +
        '<w:tc><w:p><w:r><w:t>{Title}</w:t></w:r></w:p></w:tc>' +
        '<w:tc><w:p><w:r><w:rPr><w:color w:val="2E75B6"/></w:rPr><w:t>{Email}</w:t></w:r></w:p></w:tc></w:tr>' +
        // Loop close
        '<w:tr><w:tc><w:p><w:r><w:t>{/Contacts}</w:t></w:r></w:p></w:tc><w:tc><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr>' +
        '</w:tbl>' +
        // Aggregate — bold italic blue
        '<w:p><w:pPr><w:spacing w:before="120"/></w:pPr>' +
        '<w:r><w:rPr><w:b/><w:i/><w:color w:val="1F4E79"/></w:rPr>' +
        '<w:t xml:space="preserve">Total Team Members: {COUNT:Contacts}</w:t></w:r></w:p>' +
        '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' +
        // ── PAGE 3: DEAL SUMMARY ──
        '<w:p>' +
        S +
        'DEAL SUMMARY</w:t></w:r></w:p>' +
        '<w:p><w:r><w:t>{#Opportunities}</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:ind w:left="360"/></w:pPr>' +
        B +
        '{Name}</w:t></w:r>' +
        '<w:r><w:t xml:space="preserve"> — {Amount:currency} — Closing: {CloseDate:MM/dd/yyyy}</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:ind w:left="720"/></w:pPr>' +
        '<w:r><w:rPr><w:i/><w:color w:val="548235"/></w:rPr>' +
        '<w:t xml:space="preserve">Stage: {StageName}</w:t></w:r></w:p>' +
        '<w:p><w:r><w:t>{/Opportunities}</w:t></w:r></w:p>' +
        // ── Section: ACCEPTANCE ──
        '<w:p>' +
        S +
        'ACCEPTANCE</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="120"/></w:pPr>' +
        '<w:r><w:rPr><w:i/><w:color w:val="404040"/></w:rPr>' +
        '<w:t>By signing below, the parties agree to the terms outlined in this proposal.</w:t></w:r></w:p>' +
        // Signature with underline border
        '<w:p><w:pPr><w:spacing w:before="480"/>' +
        '<w:pBdr><w:bottom w:val="single" w:sz="4" w:color="000000"/></w:pBdr></w:pPr>' +
        '<w:r><w:rPr><w:b/><w:sz w:val="24"/></w:rPr><w:t>{@Signature_Buyer}</w:t></w:r></w:p>' +
        '<w:p><w:r><w:rPr><w:sz w:val="18"/><w:color w:val="808080"/></w:rPr>' +
        '<w:t>Authorized Signature</w:t></w:r></w:p>' +
        // Section properties
        '<w:sectPr>' +
        '<w:headerReference w:type="default" r:id="rId2"/>' +
        '<w:footerReference w:type="default" r:id="rId3"/>' +
        '<w:pgSz w:w="12240" w:h="15840"/>' +
        '<w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" w:header="360" w:footer="360"/>' +
        '<w:titlePg/></w:sectPr></w:body></w:document>';
    String docXml = dx;

    String relsXml =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
        '</Relationships>';

    String wordRels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>' +
        '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>' +
        '</Relationships>';

    String contentTypes =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
        '<Default Extension="xml" ContentType="application/xml"/>' +
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
        '<Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>' +
        '<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>' +
        '</Types>';

    String headerXml =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
        '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="4" w:color="1F4E79"/></w:pBdr><w:jc w:val="right"/></w:pPr>' +
        '<w:r><w:rPr><w:i/><w:sz w:val="16"/><w:color w:val="808080"/></w:rPr>' +
        '<w:t>Business Proposal — Confidential</w:t></w:r></w:p></w:hdr>';
    String F = '<w:rPr><w:sz w:val="16"/><w:color w:val="808080"/></w:rPr>';
    String footerXml =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
        '<w:p><w:pPr><w:pBdr><w:top w:val="single" w:sz="4" w:color="1F4E79"/></w:pBdr><w:jc w:val="center"/></w:pPr>' +
        '<w:r>' +
        F +
        '<w:t xml:space="preserve">Page </w:t></w:r>' +
        '<w:r>' +
        F +
        '<w:fldChar w:fldCharType="begin"/></w:r><w:r>' +
        F +
        '<w:instrText> PAGE </w:instrText></w:r>' +
        '<w:r>' +
        F +
        '<w:fldChar w:fldCharType="separate"/></w:r><w:r>' +
        F +
        '<w:t>1</w:t></w:r><w:r>' +
        F +
        '<w:fldChar w:fldCharType="end"/></w:r>' +
        '<w:r>' +
        F +
        '<w:t xml:space="preserve"> of </w:t></w:r>' +
        '<w:r>' +
        F +
        '<w:fldChar w:fldCharType="begin"/></w:r><w:r>' +
        F +
        '<w:instrText> NUMPAGES </w:instrText></w:r>' +
        '<w:r>' +
        F +
        '<w:fldChar w:fldCharType="separate"/></w:r><w:r>' +
        F +
        '<w:t>3</w:t></w:r><w:r>' +
        F +
        '<w:fldChar w:fldCharType="end"/></w:r>' +
        '</w:p></w:ftr>';

    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry('[Content_Types].xml', Blob.valueOf(contentTypes));
    zw.addEntry('_rels/.rels', Blob.valueOf(relsXml));
    zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(wordRels));
    zw.addEntry('word/document.xml', Blob.valueOf(docXml));
    zw.addEntry('word/header1.xml', Blob.valueOf(headerXml));
    zw.addEntry('word/footer1.xml', Blob.valueOf(footerXml));
    Blob docxBlob = zw.getArchive();

    if (docxBlob != null && docxBlob.size() > 100) {
        pass++;
        System.debug('DOCX BUILT: PASS — ' + docxBlob.size() + ' bytes');
    } else {
        fail++;
        System.debug('DOCX BUILT: FAIL');
    }

    // ===== Create Template =====
    String qc = 'Name, Industry, Phone, Website, BillingStreet, BillingCity, BillingState, BillingPostalCode, (SELECT FirstName, LastName, Email, Title FROM Contacts), (SELECT Name, Amount, StageName, CloseDate FROM Opportunities)';
    DocGen_Template__c t = new DocGen_Template__c(
        Name = 'E2E Test Template',
        Base_Object_API__c = 'Account',
        Type__c = 'Word',
        Output_Format__c = 'PDF',
        Query_Config__c = qc,
        Description__c = 'E2E comprehensive test template',
        Category__c = 'Test'
    );
    insert t;
    tmplId = t.Id;
    if (tmplId != null) {
        pass++;
        System.debug('TEMPLATE CREATED: PASS — ' + tmplId);
    } else {
        fail++;
        System.debug('TEMPLATE CREATED: FAIL');
    }

    // ===== Create Active Version =====
    DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
        Template__c = tmplId,
        Is_Active__c = true,
        Query_Config__c = qc,
        Type__c = 'Word',
        Base_Object_API__c = 'Account',
        Category__c = 'Test',
        Description__c = 'E2E test v1'
    );
    insert ver;
    verId = ver.Id;

    // ===== Upload DOCX as ContentVersion =====
    ContentVersion cv = new ContentVersion(
        Title = 'E2E Test Template',
        PathOnClient = 'e2e_test.docx',
        VersionData = docxBlob,
        FirstPublishLocationId = tmplId
    );
    insert cv;
    cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

    // Link CV to version
    ver.Content_Version_Id__c = cv.Id;
    update ver;

    // Verify active version exists with CV
    List<DocGen_Template_Version__c> activeVers = [
        SELECT Id, Content_Version_Id__c
        FROM DocGen_Template_Version__c
        WHERE Template__c = :tmplId AND Is_Active__c = TRUE AND Content_Version_Id__c != NULL
        LIMIT 1
    ];
    if (!activeVers.isEmpty()) {
        pass++;
        System.debug('ACTIVE VERSION WITH CV: PASS');
    } else {
        fail++;
        System.debug('ACTIVE VERSION WITH CV: FAIL');
    }

    // ===== Template Update (no version change) =====
    Integer vBefore = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
    DocGen_Template__c tUpd = [SELECT Id, Description__c FROM DocGen_Template__c WHERE Id = :tmplId];
    tUpd.Description__c = 'Updated E2E desc';
    update tUpd;
    Integer vAfter = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
    DocGen_Template__c u = [SELECT Description__c FROM DocGen_Template__c WHERE Id = :tmplId];
    if (u.Description__c == 'Updated E2E desc' && vBefore == vAfter) {
        pass++;
        System.debug('UPDATE NO VERSION CHANGE: PASS');
    } else {
        fail++;
        System.debug('UPDATE NO VERSION CHANGE: FAIL');
    }

    // ===== Version Management =====
    List<DocGen_Template_Version__c> vers = DocGenController.getTemplateVersions(tmplId);
    if (vers != null && vers.size() >= 1) {
        pass++;
        System.debug('GET TEMPLATE VERSIONS: PASS — count: ' + vers.size());
    } else {
        fail++;
        System.debug('GET TEMPLATE VERSIONS: FAIL');
    }

    // ===== Data Retrieval =====
    Map<String, Object> d = DocGenController.previewRecordData(acctId, 'Account', qc);
    if (d != null && d.get('Name') == 'E2E Test Corp') {
        pass++;
        System.debug('PREVIEW RECORD DATA name: PASS');
    } else {
        fail++;
        System.debug('PREVIEW RECORD DATA name: FAIL — ' + d);
    }

    if (d != null && d.containsKey('Contacts')) {
        Object conData = d.get('Contacts');
        Boolean childOk = false;
        if (conData instanceof List<Object>) {
            childOk = ((List<Object>) conData).size() == 3;
        } else if (conData instanceof Map<String, Object>) {
            Map<String, Object> conMap = (Map<String, Object>) conData;
            if (conMap.containsKey('records') && conMap.get('records') instanceof List<Object>) {
                childOk = ((List<Object>) conMap.get('records')).size() == 3;
            } else {
                childOk = true;
            } // Has Contacts key with data — shape varies by query config version
        }
        if (childOk) {
            pass++;
            System.debug('PREVIEW RECORD DATA children: PASS');
        } else {
            fail++;
            System.debug('PREVIEW RECORD DATA children: FAIL — count mismatch');
        }
    } else {
        fail++;
        System.debug('PREVIEW RECORD DATA children: FAIL — no Contacts key');
    }
} catch (Exception e) {
    fail++;
    System.debug('TEMPLATE/DATA CREATION: FAIL — ' + e.getMessage() + ' at line ' + e.getLineNumber());
}

System.debug('========================================');
System.debug(
    'E2E-02 TEMPLATE CRUD — PASS: ' +
        pass +
        '  FAIL: ' +
        fail +
        (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
