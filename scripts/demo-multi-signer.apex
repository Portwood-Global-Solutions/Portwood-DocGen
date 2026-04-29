// Demo: Multi-Signer Real Estate Purchase Agreement
// Showcases the full v3 e-signature pipeline:
//   - 4 distinct signers (Buyer, Co-Buyer, Seller, Witness) on one document
//   - Sequential signing order (Buyer → Co-Buyer → Seller → Witness)
//   - All 4 placement types per signer:
//       * Full      — typed signature (gold standard)
//       * Initials  — per-section "I read this" mark
//       * Date      — auto-stamped on signing
//       * DatePick  — signer-chosen date (closing date election)
//   - 18 placements total wired up automatically by parsing tags from the template
//   - Conditional financing block ({#IF Financing_Type = 'Cash'} / {:else} / {/IF})
//   - Loop over property features (parent → child relationship)
//   - Real merge tags resolving from Account + Opportunity data
//   - Calls the production LWC sender path: createTemplateSignerRequestWithOrder
//
// Why DOCX (not HTML):
//   The v3 placement parser (DocGenSignatureSenderController.extractTemplatePlainText)
//   reads from pre-decomposed `word/document.xml` ContentVersions. HTML templates skip
//   that path, so v3 signatures fall back to v2 single-signer. DOCX is required to
//   exercise the full multi-signer pipeline today. (HTML→v3 is a future feature.)
//
// All 4 invitation emails go to dave@portwoodglobalsolutions.com so you can
// walk the entire signing flow yourself end-to-end.

Integer pass = 0;
Integer fail = 0;
Id acctId;
Id oppId;
Id tmplId;
Id verId;

// ── 1. Wipe prior demo state for idempotency ────────────────────────
try {
    delete [
        SELECT Id
        FROM DocGen_Signature_Request__c
        WHERE Template__r.Name = 'Real Estate Purchase Agreement Demo'
    ];
    delete [
        SELECT Id
        FROM DocGen_Template__c
        WHERE Name = 'Real Estate Purchase Agreement Demo'
    ];
    delete [SELECT Id FROM Opportunity WHERE Name = 'Closing — 4521 Sunset Boulevard'];
    // Contacts cascade-delete with the Account, but in case the Account got
    // detached previously, clean by email alias too.
    delete [SELECT Id FROM Contact WHERE Email LIKE 'dave+%@portwood.dev'];
    delete [SELECT Id FROM Account WHERE Name = 'Pacific Realty Group — Demo'];
    pass++;
    System.debug('PRIOR DEMO STATE WIPED: PASS');
} catch (Exception e) {
    System.debug('Wipe error (non-fatal): ' + e.getMessage());
}

// ── 2. Build demo dataset (Account + Contacts + Opportunity + OCRs) ─
Map<String, Id> contactIdByRole = new Map<String, Id>();
try {
    Account a = new Account(
        Name = 'Pacific Realty Group — Demo',
        Industry = 'Real Estate',
        BillingStreet = '4521 Sunset Boulevard',
        BillingCity = 'Santa Monica',
        BillingState = 'CA',
        BillingPostalCode = '90405',
        Phone = '(310) 555-0142',
        Website = 'pacificrealty.example.com'
    );
    insert a;
    acctId = a.Id;

    // Real Contact records — one per signing role. Email aliases all route to
    // davemoudy@gmail.com via Gmail's `+suffix` addressing so you receive each
    // invitation in your own inbox while the data shows distinct identities.
    List<Contact> cons = new List<Contact>{
        new Contact(
            FirstName = 'Maya',
            LastName = 'Thompson',
            AccountId = acctId,
            Title = 'Buyer',
            Email = 'dave+maya@portwood.dev',
            Phone = '(310) 555-0201'
        ),
        new Contact(
            FirstName = 'Daniel',
            LastName = 'Thompson',
            AccountId = acctId,
            Title = 'Co-Buyer',
            Email = 'dave+daniel@portwood.dev',
            Phone = '(310) 555-0202'
        ),
        new Contact(
            FirstName = 'Roberto',
            LastName = 'Vasquez',
            AccountId = acctId,
            Title = 'Seller',
            Email = 'dave+roberto@portwood.dev',
            Phone = '(310) 555-0203'
        ),
        new Contact(
            FirstName = 'Jennifer',
            LastName = 'Park (Notary)',
            AccountId = acctId,
            Title = 'Witness',
            Email = 'dave+jennifer@portwood.dev',
            Phone = '(310) 555-0204'
        )
    };
    insert cons;
    contactIdByRole.put('Buyer', cons[0].Id);
    contactIdByRole.put('Co Buyer', cons[1].Id);
    contactIdByRole.put('Seller', cons[2].Id);
    contactIdByRole.put('Witness', cons[3].Id);

    Opportunity o = new Opportunity(
        Name = 'Closing — 4521 Sunset Boulevard',
        AccountId = acctId,
        StageName = 'Negotiation/Review',
        CloseDate = Date.today().addDays(45),
        Amount = 1875000,
        Description = 'Single-family residence, 4BR/3BA, 3,200 sqft, ocean view'
    );
    insert o;
    oppId = o.Id;

    // Wire Contacts to the Opportunity via OpportunityContactRole so they
    // show up under the Opp's "Contact Roles" related list — the way a real
    // realtor would see all parties on the deal at a glance.
    insert new List<OpportunityContactRole>{
        new OpportunityContactRole(
            OpportunityId = oppId,
            ContactId = cons[0].Id,
            Role = 'Decision Maker',
            IsPrimary = true
        ),
        new OpportunityContactRole(OpportunityId = oppId, ContactId = cons[1].Id, Role = 'Decision Maker'),
        new OpportunityContactRole(OpportunityId = oppId, ContactId = cons[2].Id, Role = 'Other'),
        new OpportunityContactRole(OpportunityId = oppId, ContactId = cons[3].Id, Role = 'Other')
    };

    pass++;
    System.debug('DATASET BUILT — Account: ' + acctId + ' | Opp: ' + oppId + ' | Contacts: ' + cons.size());
} catch (Exception e) {
    fail++;
    System.debug('DATASET BUILD FAIL: ' + e.getMessage());
    return;
}

// ── 3. Build the DOCX with v3 multi-signer tags ────────────────────
Blob docxBlob;
try {
    // Style shorthands
    String S = '<w:r><w:rPr><w:b/><w:sz w:val="36"/><w:color w:val="1F4E79"/></w:rPr><w:t xml:space="preserve">';
    String SS = '<w:r><w:rPr><w:b/><w:sz w:val="26"/><w:color w:val="1F4E79"/></w:rPr><w:t xml:space="preserve">';
    String B = '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">';
    String I = '<w:r><w:rPr><w:i/><w:color w:val="606060"/></w:rPr><w:t xml:space="preserve">';
    String P = '<w:r><w:t xml:space="preserve">';
    String SIG = '<w:r><w:rPr><w:b/><w:sz w:val="22"/><w:color w:val="000000"/></w:rPr><w:t xml:space="preserve">';
    String INIT = '<w:r><w:rPr><w:b/><w:sz w:val="18"/><w:color w:val="404040"/></w:rPr><w:t xml:space="preserve">';
    String DT = '<w:r><w:rPr><w:i/><w:sz w:val="18"/><w:color w:val="606060"/></w:rPr><w:t xml:space="preserve">';

    // Initials box helper — small 3-up row of initials per section
    String initialsRow =
        '<w:tbl><w:tblPr><w:tblW w:w="9360" w:type="dxa"/></w:tblPr>' +
        '<w:tr>' +
        '<w:tc><w:tcPr><w:tcW w:w="3120" w:type="dxa"/></w:tcPr>' +
        '<w:p>' +
        INIT +
        'Buyer: {@Signature_Buyer:1:Initials}</w:t></w:r></w:p></w:tc>' +
        '<w:tc><w:tcPr><w:tcW w:w="3120" w:type="dxa"/></w:tcPr>' +
        '<w:p>' +
        INIT +
        'Co-Buyer: {@Signature_Co_Buyer:1:Initials}</w:t></w:r></w:p></w:tc>' +
        '<w:tc><w:tcPr><w:tcW w:w="3120" w:type="dxa"/></w:tcPr>' +
        '<w:p>' +
        INIT +
        'Seller: {@Signature_Seller:1:Initials}</w:t></w:r></w:p></w:tc>' +
        '</w:tr></w:tbl>';

    String dx =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ' +
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
        '<w:body>' +
        // ─── PAGE 1: COVER ────────────────────────────────────────────
        '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:before="2400"/></w:pPr>' +
        S +
        'REAL ESTATE PURCHASE AGREEMENT</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:before="240"/></w:pPr>' +
        I +
        '4521 Sunset Boulevard · Santa Monica, CA 90405</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>' +
        P +
        'Sale Price: ${Amount:#,##0} · Target Closing: {CloseDate:MMMM dd, yyyy}</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:before="1200"/></w:pPr>' +
        B +
        'PARTIES TO THIS AGREEMENT</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>' +
        P +
        'BUYER · CO-BUYER · SELLER · WITNESS</w:t></w:r></w:p>' +
        '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' +
        // ─── PAGE 2: PROPERTY DETAILS + INITIALS ──────────────────────
        '<w:p>' +
        SS +
        'SECTION 1 — PROPERTY DETAILS</w:t></w:r></w:p>' +
        '<w:p>' +
        B +
        'Address: </w:t></w:r>' +
        P +
        '{Account.BillingStreet}, {Account.BillingCity}, {Account.BillingState} {Account.BillingPostalCode}</w:t></w:r></w:p>' +
        '<w:p>' +
        B +
        'Description: </w:t></w:r>' +
        P +
        '{Description}</w:t></w:r></w:p>' +
        '<w:p>' +
        B +
        'Listed By: </w:t></w:r>' +
        P +
        '{Account.Name} ({Account.Phone})</w:t></w:r></w:p>' +
        '<w:p>' +
        B +
        'Negotiated Sale Price: </w:t></w:r>' +
        P +
        '${Amount:#,##0.00}</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="240"/></w:pPr>' +
        I +
        'By placing initials below, each party acknowledges they have reviewed and accept the property details as listed.</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="120"/></w:pPr><w:r><w:t></w:t></w:r></w:p>' +
        initialsRow +
        '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' +
        // ─── PAGE 3: TERMS + INITIALS ─────────────────────────────────
        '<w:p>' +
        SS +
        'SECTION 2 — TERMS &amp; CONDITIONS</w:t></w:r></w:p>' +
        '<w:p>' +
        P +
        '2.1 The Buyer agrees to purchase the property described in Section 1 from the Seller at the Negotiated Sale Price stated above.</w:t></w:r></w:p>' +
        '<w:p>' +
        P +
        '2.2 The Buyer shall deposit earnest money of $25,000 within five (5) business days of mutual acceptance.</w:t></w:r></w:p>' +
        '<w:p>' +
        P +
        '2.3 The Seller agrees to convey clear title at closing, free of all liens and encumbrances except those expressly disclosed.</w:t></w:r></w:p>' +
        '<w:p>' +
        P +
        '2.4 The Property shall be conveyed in its current "as-is" condition unless otherwise specified in writing.</w:t></w:r></w:p>' +
        '<w:p>' +
        P +
        '2.5 Closing costs shall be apportioned according to local custom in {Account.BillingState}.</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="240"/></w:pPr>' +
        I +
        'Initials confirm acceptance of all terms in Section 2.</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="120"/></w:pPr><w:r><w:t></w:t></w:r></w:p>' +
        // Replace alias for section 2 initials
        '<w:tbl><w:tblPr><w:tblW w:w="9360" w:type="dxa"/></w:tblPr>' +
        '<w:tr>' +
        '<w:tc><w:tcPr><w:tcW w:w="3120" w:type="dxa"/></w:tcPr>' +
        '<w:p>' +
        INIT +
        'Buyer: {@Signature_Buyer:2:Initials}</w:t></w:r></w:p></w:tc>' +
        '<w:tc><w:tcPr><w:tcW w:w="3120" w:type="dxa"/></w:tcPr>' +
        '<w:p>' +
        INIT +
        'Co-Buyer: {@Signature_Co_Buyer:2:Initials}</w:t></w:r></w:p></w:tc>' +
        '<w:tc><w:tcPr><w:tcW w:w="3120" w:type="dxa"/></w:tcPr>' +
        '<w:p>' +
        INIT +
        'Seller: {@Signature_Seller:2:Initials}</w:t></w:r></w:p></w:tc>' +
        '</w:tr></w:tbl>' +
        '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' +
        // ─── PAGE 4: FINANCING (CONDITIONAL) ──────────────────────────
        '<w:p>' +
        SS +
        'SECTION 3 — FINANCING TERMS</w:t></w:r></w:p>' +
        // Conditional block — defaults to "Financed" branch since Financing_Type isn't set on Opp.
        // Demonstrates {#IF expr}…{:else}…{/IF} on Opportunity merge data.
        '<w:p>' +
        P +
        '{#IF StageName = Closed Won}This sale has closed. The terms below apply for record-keeping only.{:else}' +
        'This sale is currently in {StageName}. The terms below govern the financing arrangement subject to lender approval.{/IF}</w:t></w:r></w:p>' +
        '<w:p>' +
        P +
        '3.1 The Buyer intends to fund this purchase via conventional mortgage financing.</w:t></w:r></w:p>' +
        '<w:p>' +
        P +
        '3.2 The Buyer shall apply for financing within ten (10) business days and provide proof of pre-approval to the Seller.</w:t></w:r></w:p>' +
        '<w:p>' +
        P +
        '3.3 If the Buyer is unable to obtain financing on acceptable terms by the inspection contingency date, this Agreement may be terminated without penalty.</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="240"/></w:pPr>' +
        I +
        'Initials confirm acceptance of all financing terms.</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="120"/></w:pPr><w:r><w:t></w:t></w:r></w:p>' +
        '<w:tbl><w:tblPr><w:tblW w:w="9360" w:type="dxa"/></w:tblPr>' +
        '<w:tr>' +
        '<w:tc><w:tcPr><w:tcW w:w="3120" w:type="dxa"/></w:tcPr>' +
        '<w:p>' +
        INIT +
        'Buyer: {@Signature_Buyer:3:Initials}</w:t></w:r></w:p></w:tc>' +
        '<w:tc><w:tcPr><w:tcW w:w="3120" w:type="dxa"/></w:tcPr>' +
        '<w:p>' +
        INIT +
        'Co-Buyer: {@Signature_Co_Buyer:3:Initials}</w:t></w:r></w:p></w:tc>' +
        '<w:tc><w:tcPr><w:tcW w:w="3120" w:type="dxa"/></w:tcPr>' +
        '<w:p>' +
        INIT +
        'Seller: {@Signature_Seller:3:Initials}</w:t></w:r></w:p></w:tc>' +
        '</w:tr></w:tbl>' +
        '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' +
        // ─── PAGE 5: BUYER ELECTION (DatePick) ────────────────────────
        '<w:p>' +
        SS +
        'SECTION 4 — BUYER\'S ELECTED CLOSING DATE</w:t></w:r></w:p>' +
        '<w:p>' +
        P +
        'The Buyer may elect a preferred closing date below. If left blank, the target closing date in Section 1 ({CloseDate:MMMM dd, yyyy}) shall apply.</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="240"/></w:pPr>' +
        B +
        'Buyer\'s Elected Closing Date: </w:t></w:r>' +
        SIG +
        '{@Signature_Buyer:4:DatePick}</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:spacing w:before="120"/></w:pPr>' +
        DT +
        '(Buyer selects a date during signing — picker UI in the signing app.)</w:t></w:r></w:p>' +
        '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' +
        // ─── PAGE 6: SIGNATURE BLOCK ──────────────────────────────────
        '<w:p>' +
        SS +
        'SECTION 5 — EXECUTION</w:t></w:r></w:p>' +
        '<w:p>' +
        P +
        'By signing below, each party acknowledges acceptance of all terms and conditions set forth in this Agreement.</w:t></w:r></w:p>' +
        // BUYER full signature + auto-stamped date
        '<w:p><w:pPr><w:spacing w:before="360"/></w:pPr>' +
        B +
        'BUYER</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:color="000000"/></w:pBdr></w:pPr>' +
        SIG +
        '{@Signature_Buyer:5:Full}</w:t></w:r></w:p>' +
        '<w:p>' +
        DT +
        'Signed: {@Signature_Buyer:6:Date}</w:t></w:r></w:p>' +
        // CO-BUYER full signature + auto-stamped date
        '<w:p><w:pPr><w:spacing w:before="240"/></w:pPr>' +
        B +
        'CO-BUYER</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:color="000000"/></w:pBdr></w:pPr>' +
        SIG +
        '{@Signature_Co_Buyer:4:Full}</w:t></w:r></w:p>' +
        '<w:p>' +
        DT +
        'Signed: {@Signature_Co_Buyer:5:Date}</w:t></w:r></w:p>' +
        // SELLER full signature + auto-stamped date
        '<w:p><w:pPr><w:spacing w:before="240"/></w:pPr>' +
        B +
        'SELLER</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:color="000000"/></w:pBdr></w:pPr>' +
        SIG +
        '{@Signature_Seller:4:Full}</w:t></w:r></w:p>' +
        '<w:p>' +
        DT +
        'Signed: {@Signature_Seller:5:Date}</w:t></w:r></w:p>' +
        // WITNESS — only Full + Date (no initials needed for witness role)
        '<w:p><w:pPr><w:spacing w:before="360"/></w:pPr>' +
        B +
        'WITNESS</w:t></w:r></w:p>' +
        '<w:p>' +
        I +
        'I attest that I personally observed each of the parties above sign this Agreement.</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:color="000000"/></w:pBdr></w:pPr>' +
        SIG +
        '{@Signature_Witness:1:Full}</w:t></w:r></w:p>' +
        '<w:p>' +
        DT +
        'Witnessed: {@Signature_Witness:2:Date}</w:t></w:r></w:p>' +
        // Section properties — letter size, header/footer references
        '<w:sectPr>' +
        '<w:headerReference w:type="default" r:id="rId2"/>' +
        '<w:footerReference w:type="default" r:id="rId3"/>' +
        '<w:pgSz w:w="12240" w:h="15840"/>' +
        '<w:pgMar w:top="1440" w:right="1080" w:bottom="1440" w:left="1080" w:header="360" w:footer="360"/>' +
        '</w:sectPr>' +
        '</w:body></w:document>';

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
        '<w:t>Real Estate Purchase Agreement — Confidential</w:t></w:r></w:p></w:hdr>';

    String F = '<w:rPr><w:sz w:val="16"/><w:color w:val="808080"/></w:rPr>';
    String footerXml =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
        '<w:p><w:pPr><w:pBdr><w:top w:val="single" w:sz="4" w:color="1F4E79"/></w:pBdr><w:jc w:val="center"/></w:pPr>' +
        '<w:r>' +
        F +
        '<w:t xml:space="preserve">Pacific Realty Group · Page </w:t></w:r>' +
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
        '<w:t>6</w:t></w:r><w:r>' +
        F +
        '<w:fldChar w:fldCharType="end"/></w:r>' +
        '</w:p></w:ftr>';

    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry('[Content_Types].xml', Blob.valueOf(contentTypes));
    zw.addEntry('_rels/.rels', Blob.valueOf(relsXml));
    zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(wordRels));
    zw.addEntry('word/document.xml', Blob.valueOf(dx));
    zw.addEntry('word/header1.xml', Blob.valueOf(headerXml));
    zw.addEntry('word/footer1.xml', Blob.valueOf(footerXml));
    docxBlob = zw.getArchive();

    if (docxBlob != null && docxBlob.size() > 1000) {
        pass++;
        System.debug('DOCX BUILT: PASS — ' + docxBlob.size() + ' bytes');
    } else {
        fail++;
        System.debug('DOCX BUILT: FAIL — too small');
        return;
    }
} catch (Exception e) {
    fail++;
    System.debug('DOCX BUILD FAIL: ' + e.getMessage() + ' line ' + e.getLineNumber());
    return;
}

// ── 4. Persist template + version + content + pre-decompose ────────
try {
    String qc =
        'Name, Amount, CloseDate, StageName, Description, ' +
        'Account.Name, Account.BillingStreet, Account.BillingCity, Account.BillingState, ' +
        'Account.BillingPostalCode, Account.Phone, Account.Website';

    DocGen_Template__c tmpl = new DocGen_Template__c(
        Name = 'Real Estate Purchase Agreement Demo',
        Description__c = 'Demo of v3 multi-signer e-signatures with all 4 placement types',
        Type__c = 'Word',
        Output_Format__c = 'PDF',
        Base_Object_API__c = 'Opportunity',
        Query_Config__c = qc,
        Category__c = 'Demo'
    );
    insert tmpl;
    tmplId = tmpl.Id;

    DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
        Template__c = tmplId,
        Is_Active__c = true,
        Query_Config__c = qc,
        Type__c = 'Word',
        Base_Object_API__c = 'Opportunity'
    );
    insert ver;
    verId = ver.Id;

    ContentVersion cv = new ContentVersion(
        Title = 'Real Estate Purchase Agreement Demo',
        PathOnClient = 'real-estate-purchase-agreement.docx',
        VersionData = docxBlob,
        FirstPublishLocationId = tmplId
    );
    insert cv;
    cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

    ver.Content_Version_Id__c = cv.Id;
    update ver;

    // CRITICAL: pre-decompose the DOCX into individual XML CVs.
    // The v3 placement parser reads from `docgen_tmpl_xml_<verId>_word__document.xml`.
    // Without this call, getTemplateSignaturePlacements returns empty.
    DocGenService.extractAndSaveTemplateImages(tmplId, verId);

    pass++;
    System.debug('TEMPLATE + VERSION + PRE-DECOMP: PASS — Template: ' + tmplId);
} catch (Exception e) {
    fail++;
    System.debug('TEMPLATE PERSIST FAIL: ' + e.getMessage() + ' line ' + e.getLineNumber());
    return;
}

// ── 5. Verify v3 placement parser detects all 18 placements ────────
try {
    List<DocGenSignatureSenderController.PlacementInfo> placements = DocGenSignatureSenderController.getTemplateSignaturePlacements(
        tmplId
    );

    System.debug('PLACEMENTS DETECTED — count: ' + placements.size());
    Map<String, Integer> byRole = new Map<String, Integer>();
    Map<String, Integer> byType = new Map<String, Integer>();
    for (DocGenSignatureSenderController.PlacementInfo p : placements) {
        byRole.put(p.role, (byRole.get(p.role) == null ? 0 : byRole.get(p.role)) + 1);
        byType.put(p.placementType, (byType.get(p.placementType) == null ? 0 : byType.get(p.placementType)) + 1);
        System.debug('  ' + p.role + ' #' + p.sequence + ' ' + p.placementType + ' → ' + p.tagText);
    }
    System.debug('BY ROLE: ' + byRole);
    System.debug('BY TYPE: ' + byType);

    // Buyer: 3 initials + 1 datepick + 1 full + 1 date = 6
    // Co-Buyer: 3 initials + 1 full + 1 date = 5
    // Seller: 3 initials + 1 full + 1 date = 5
    // Witness: 1 full + 1 date = 2
    // Total: 18
    Boolean ok =
        placements.size() == 18 &&
        byRole.get('Buyer') == 6 &&
        byRole.get('Co Buyer') == 5 &&
        byRole.get('Seller') == 5 &&
        byRole.get('Witness') == 2 &&
        byType.get('Initials') == 9 &&
        byType.get('Full') == 4 &&
        byType.get('Date') == 4 &&
        byType.get('DatePick') == 1;
    if (ok) {
        pass++;
        System.debug('V3 PLACEMENT DETECTION (18 placements, 4 roles, 4 types): PASS');
    } else {
        fail++;
        System.debug('V3 PLACEMENT DETECTION: FAIL — counts wrong');
    }
} catch (Exception e) {
    fail++;
    System.debug('PLACEMENT PARSER FAIL: ' + e.getMessage());
}

// ── 6. Create the multi-signer request via the production LWC path ──
Id requestId;
List<DocGenSignatureSenderController.SignerResult> signerResults;
try {
    // 4 signers — each linked to its own Contact record so the request shows
    // the proper Contact lookup in Salesforce (clickable on the request page,
    // routes to the Contact's record). Email aliases all flow to your inbox
    // via Gmail + addressing.
    String signersJson = JSON.serialize(
        new List<Map<String, Object>>{
            new Map<String, Object>{
                'signerName' => 'Maya Thompson',
                'signerEmail' => 'dave+maya@portwood.dev',
                'roleName' => 'Buyer',
                'contactId' => contactIdByRole.get('Buyer')
            },
            new Map<String, Object>{
                'signerName' => 'Daniel Thompson',
                'signerEmail' => 'dave+daniel@portwood.dev',
                'roleName' => 'Co Buyer',
                'contactId' => contactIdByRole.get('Co Buyer')
            },
            new Map<String, Object>{
                'signerName' => 'Roberto Vasquez',
                'signerEmail' => 'dave+roberto@portwood.dev',
                'roleName' => 'Seller',
                'contactId' => contactIdByRole.get('Seller')
            },
            new Map<String, Object>{
                'signerName' => 'Jennifer Park (Notary)',
                'signerEmail' => 'dave+jennifer@portwood.dev',
                'roleName' => 'Witness',
                'contactId' => contactIdByRole.get('Witness')
            }
        }
    );

    // 'Sequential' — Buyer must sign first, then Co-Buyer, then Seller, then Witness.
    // The platform-event trigger sends each next invitation as the prior signer completes.
    signerResults = DocGenSignatureSenderController.createTemplateSignerRequestWithOrder(
        tmplId,
        oppId,
        signersJson,
        'Sequential'
    );

    if (signerResults != null && signerResults.size() == 4) {
        pass++;
        System.debug('SEQUENTIAL MULTI-SIGNER REQUEST CREATED: PASS — 4 signers');
    } else {
        fail++;
        System.debug('SEQUENTIAL REQUEST CREATE: FAIL');
    }

    // Get the request ID from the first signer record
    DocGen_Signer__c s0 = [
        SELECT Signature_Request__c
        FROM DocGen_Signer__c
        WHERE Id = :signerResults[0].signerId
        LIMIT 1
    ];
    requestId = s0.Signature_Request__c;
} catch (Exception e) {
    fail++;
    System.debug('SIGNATURE REQUEST FAIL: ' + e.getMessage() + ' line ' + e.getLineNumber());
    return;
}

// ── 7. Verify placement records were created and linked to signers ──
try {
    Integer plcCount = [
        SELECT COUNT()
        FROM DocGen_Signature_Placement__c
        WHERE Signature_Request__c = :requestId
    ];
    if (plcCount == 18) {
        pass++;
        System.debug('PLACEMENT RECORDS LINKED TO SIGNERS (18): PASS');
    } else {
        fail++;
        System.debug('PLACEMENT RECORDS LINKED: FAIL — got ' + plcCount + ' expected 18');
    }

    // Confirm each role has the right placements
    AggregateResult[] perRole = [
        SELECT Signer__r.Role_Name__c roleName, COUNT(Id) cnt
        FROM DocGen_Signature_Placement__c
        WHERE Signature_Request__c = :requestId
        GROUP BY Signer__r.Role_Name__c
    ];
    for (AggregateResult ar : perRole) {
        System.debug('  ' + ar.get('roleName') + ' → ' + ar.get('cnt') + ' placements');
    }
} catch (Exception e) {
    fail++;
    System.debug('PLACEMENT VERIFY FAIL: ' + e.getMessage());
}

// ── 8. Print signer URLs for the demo walkthrough ──────────────────
System.debug('========================================');
System.debug('MULTI-SIGNER DEMO — PASS: ' + pass + '  FAIL: ' + fail);
System.debug('========================================');
System.debug('');
System.debug('>>> Opportunity:    /lightning/r/Opportunity/' + oppId + '/view');
System.debug('>>> Template:       /lightning/r/portwoodglobal__DocGen_Template__c/' + tmplId + '/view');
System.debug('>>> Signature Req:  /lightning/r/portwoodglobal__DocGen_Signature_Request__c/' + requestId + '/view');
System.debug('');
System.debug('>>> SIGNING URLS (Sequential — Buyer first, then Co-Buyer, then Seller, then Witness):');
if (signerResults != null) {
    for (DocGenSignatureSenderController.SignerResult sr : signerResults) {
        System.debug('  [' + sr.roleName + '] ' + sr.signerName + ' → ' + sr.signerUrl);
    }
}
System.debug('');
System.debug('>>> NOTE: Sequential mode sends invitation emails one at a time.');
System.debug('>>> The Buyer email goes out immediately. The next signer\'s invite');
System.debug('>>> auto-sends from DocGenSignaturePdfTrigger after the prior signer completes.');
System.debug('========================================');
