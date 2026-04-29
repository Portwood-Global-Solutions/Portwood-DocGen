// DocGen E2E Test 09 — {%Image:N} record-attached image tag
// Run: sf apex run --target-org <org> -f scripts/e2e-09-images.apex
// Depends on: nothing (self-contained — creates + cleans its own test data)
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;
String r;

// ===== Setup: create a test Account and attach 2 images =====
Account testAcct = new Account(Name = 'DocGen Image Test ' + System.currentTimeMillis());
insert testAcct;

String tinyPngB64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==';
List<ContentVersion> cvs = new List<ContentVersion>{
    new ContentVersion(
        Title = 'docgen_e2e09_img_1',
        PathOnClient = 'img1.png',
        VersionData = EncodingUtil.base64Decode(tinyPngB64)
    ),
    new ContentVersion(
        Title = 'docgen_e2e09_img_2',
        PathOnClient = 'img2.png',
        VersionData = EncodingUtil.base64Decode(tinyPngB64)
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
for (ContentVersion cv : committed) {
    cdls.add(
        new ContentDocumentLink(ContentDocumentId = cv.ContentDocumentId, LinkedEntityId = testAcct.Id, ShareType = 'V')
    );
}
insert cdls;

Map<String, Object> data = new Map<String, Object>{ 'Id' => testAcct.Id, 'Name' => 'Test' };

// ===== {%Image:1} — base record first image =====
try {
    r = DocGenService.processXmlForTest('A{%Image:1}B', data);
    if (r.contains('w:drawing') && r.startsWith('A') && r.endsWith('B')) {
        pass++;
        System.debug('IMAGE 1 BASE: PASS');
    } else {
        fail++;
        System.debug('IMAGE 1 BASE: FAIL — ' + r.left(200));
    }
} catch (Exception e) {
    fail++;
    System.debug('IMAGE 1 BASE: FAIL — ' + e.getMessage());
}

// ===== {%Image:2} — second image =====
try {
    r = DocGenService.processXmlForTest('{%Image:2}', data);
    if (r.contains('w:drawing')) {
        pass++;
        System.debug('IMAGE 2: PASS');
    } else {
        fail++;
        System.debug('IMAGE 2: FAIL — ' + r.left(200));
    }
} catch (Exception e) {
    fail++;
    System.debug('IMAGE 2: FAIL — ' + e.getMessage());
}

// ===== {%Image:5} — out of range renders empty =====
try {
    r = DocGenService.processXmlForTest('<w:r>A{%Image:5}B</w:r>', data);
    if (r == '<w:r>AB</w:r>') {
        pass++;
        System.debug('IMAGE OUT-OF-RANGE: PASS');
    } else {
        fail++;
        System.debug('IMAGE OUT-OF-RANGE: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('IMAGE OUT-OF-RANGE: FAIL — ' + e.getMessage());
}

// ===== {%Image:1:200} — single-number max size =====
try {
    r = DocGenService.processXmlForTest('{%Image:1:200}', data);
    if (r.contains('w:drawing')) {
        pass++;
        System.debug('IMAGE SIZE MAX: PASS');
    } else {
        fail++;
        System.debug('IMAGE SIZE MAX: FAIL — ' + r.left(200));
    }
} catch (Exception e) {
    fail++;
    System.debug('IMAGE SIZE MAX: FAIL — ' + e.getMessage());
}

// ===== {%Image:1:200x150} — explicit width x height =====
try {
    r = DocGenService.processXmlForTest('{%Image:1:200x150}', data);
    if (r.contains('w:drawing')) {
        pass++;
        System.debug('IMAGE SIZE WxH: PASS');
    } else {
        fail++;
        System.debug('IMAGE SIZE WxH: FAIL — ' + r.left(200));
    }
} catch (Exception e) {
    fail++;
    System.debug('IMAGE SIZE WxH: FAIL — ' + e.getMessage());
}

// ===== {%Image:0} and invalid index safely render empty =====
try {
    r = DocGenService.processXmlForTest('<a>{%Image:0}</a>', data);
    if (r == '<a></a>') {
        pass++;
        System.debug('IMAGE INVALID INDEX: PASS');
    } else {
        fail++;
        System.debug('IMAGE INVALID INDEX: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('IMAGE INVALID INDEX: FAIL — ' + e.getMessage());
}

// ===== Record with no images — renders empty =====
try {
    Account emptyAcct = new Account(Name = 'DocGen No Img ' + System.currentTimeMillis());
    insert emptyAcct;
    Map<String, Object> emptyData = new Map<String, Object>{ 'Id' => emptyAcct.Id };
    r = DocGenService.processXmlForTest('<x>{%Image:1}</x>', emptyData);
    if (r == '<x></x>') {
        pass++;
        System.debug('IMAGE NO ATTACHMENTS: PASS');
    } else {
        fail++;
        System.debug('IMAGE NO ATTACHMENTS: FAIL — ' + r);
    }
    delete emptyAcct;
} catch (Exception e) {
    fail++;
    System.debug('IMAGE NO ATTACHMENTS: FAIL — ' + e.getMessage());
}

// ===== In-loop: {#Children}{%Image:1}{/Children} — each iteration's image =====
try {
    // Create 2 child Contacts each with their own image
    List<Contact> kids = new List<Contact>{
        new Contact(FirstName = 'A', LastName = 'KidA', AccountId = testAcct.Id),
        new Contact(FirstName = 'B', LastName = 'KidB', AccountId = testAcct.Id)
    };
    insert kids;
    List<ContentVersion> kidCvs = new List<ContentVersion>{
        new ContentVersion(
            Title = 'docgen_e2e09_kidA',
            PathOnClient = 'a.png',
            VersionData = EncodingUtil.base64Decode(tinyPngB64)
        ),
        new ContentVersion(
            Title = 'docgen_e2e09_kidB',
            PathOnClient = 'b.png',
            VersionData = EncodingUtil.base64Decode(tinyPngB64)
        )
    };
    insert kidCvs;
    List<ContentVersion> kidCommitted = [
        SELECT Id, ContentDocumentId
        FROM ContentVersion
        WHERE Id IN :kidCvs
        ORDER BY CreatedDate ASC
    ];
    List<ContentDocumentLink> kidCdls = new List<ContentDocumentLink>();
    for (Integer i = 0; i < 2; i++) {
        kidCdls.add(
            new ContentDocumentLink(
                ContentDocumentId = kidCommitted[i].ContentDocumentId,
                LinkedEntityId = kids[i].Id,
                ShareType = 'V'
            )
        );
    }
    insert kidCdls;

    Map<String, Object> loopData = new Map<String, Object>{
        'Id' => testAcct.Id,
        'Kids' => new Map<String, Object>{
            'totalSize' => 2,
            'records' => new List<Object>{
                new Map<String, Object>{ 'Id' => kids[0].Id, 'FirstName' => 'A' },
                new Map<String, Object>{ 'Id' => kids[1].Id, 'FirstName' => 'B' }
            }
        }
    };

    Integer soqlBefore = Limits.getQueries();
    r = DocGenService.processXmlForTest('{#Kids}<p>{FirstName}{%Image:1}</p>{/Kids}', loopData);
    Integer soqlDelta = Limits.getQueries() - soqlBefore;

    Integer drawCount = 0;
    Integer idx = 0;
    while ((idx = r.indexOf('<w:drawing', idx)) != -1) {
        drawCount++;
        idx += 10;
    }

    // Expect 2 drawings (one per iteration) and only 1 bulk CDL query (+ 2 CV lookups = 3 or 4 total)
    Boolean drawOk = (drawCount == 2);
    Boolean soqlOk = (soqlDelta <= 5); // 1 prefetch + 2 buildImageXml CV lookups + safety buffer
    if (drawOk && soqlOk) {
        pass++;
        System.debug('IMAGE IN-LOOP: PASS — drawings=' + drawCount + ', soql=' + soqlDelta);
    } else {
        fail++;
        System.debug('IMAGE IN-LOOP: FAIL — drawings=' + drawCount + ', soql=' + soqlDelta + ', r=' + r.left(500));
    }

    // Cleanup loop data
    delete kidCdls;
    delete [
        SELECT Id
        FROM ContentDocument
        WHERE Id IN (SELECT ContentDocumentId FROM ContentVersion WHERE Id IN :kidCommitted)
    ];
    delete kids;
} catch (Exception e) {
    fail++;
    System.debug('IMAGE IN-LOOP: FAIL — ' + e.getMessage() + ' @ ' + e.getStackTraceString());
}

// ===== Cleanup =====
delete cdls;
delete [
    SELECT Id
    FROM ContentDocument
    WHERE Id IN (SELECT ContentDocumentId FROM ContentVersion WHERE Id IN :committed)
];
delete testAcct;

System.debug('========================================');
System.debug(
    'E2E-09 IMAGES — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
