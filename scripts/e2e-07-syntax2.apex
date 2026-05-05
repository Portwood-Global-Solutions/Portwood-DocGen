// DocGen E2E Test 07-syntax2 — Advanced Merge Tag Syntax (continuation of e2e-07-syntax1)
// Run: sf apex run --target-org <org> -f scripts/e2e-07-syntax2.apex
// Depends on: nothing (uses DocGenService.processXmlForTest directly)
// Expected: PASS: N  FAIL: 0
//
// Split from e2e-07-syntax in v1.73 — original file exceeded the 20,000-char
// Anonymous Apex limit. Sections 1-29 are in e2e-07-syntax1.apex.

Integer pass = 0;
Integer fail = 0;
String r;

// ===== Locale formatting: currency:EUR =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Amt:currency:EUR}</w:t>', new Map<String, Object>{ 'Amt' => 1234.56 });
    if (r.contains('\u20AC')) {
        pass++;
        System.debug('CURRENCY EUR: PASS');
    } else {
        fail++;
        System.debug('CURRENCY EUR: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('CURRENCY EUR: FAIL — ' + e.getMessage());
}

// ===== currency:JPY zero decimal =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Amt:currency:JPY}</w:t>', new Map<String, Object>{ 'Amt' => 1234.56 });
    if (r.contains('\u00A5') && !r.contains('.')) {
        pass++;
        System.debug('CURRENCY JPY: PASS');
    } else {
        fail++;
        System.debug('CURRENCY JPY: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('CURRENCY JPY: FAIL — ' + e.getMessage());
}

// ===== number:de_DE =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Qty:number:de_DE}</w:t>', new Map<String, Object>{ 'Qty' => 1234567 });
    if (r.contains('1.234.567')) {
        pass++;
        System.debug('NUMBER de_DE: PASS');
    } else {
        fail++;
        System.debug('NUMBER de_DE: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('NUMBER de_DE: FAIL — ' + e.getMessage());
}

// ===== SUM:Items.Amount:currency:GBP =====
try {
    Map<String, Object> ad = new Map<String, Object>{
        'Items' => new List<Object>{
            new Map<String, Object>{ 'Amount' => 1000 },
            new Map<String, Object>{ 'Amount' => 2000 }
        }
    };
    r = DocGenService.processXmlForTest('<w:t>{SUM:Items.Amount:currency:GBP}</w:t>', ad);
    if (r.contains('\u00A3')) {
        pass++;
        System.debug('SUM GBP: PASS');
    } else {
        fail++;
        System.debug('SUM GBP: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('SUM GBP: FAIL — ' + e.getMessage());
}

// ===== date:de_DE =====
try {
    r = DocGenService.processXmlForTest(
        '<w:t>{D:date:de_DE}</w:t>',
        new Map<String, Object>{ 'D' => DateTime.newInstance(2026, 4, 17, 12, 0, 0) }
    );
    if (r.contains('17.04.2026')) {
        pass++;
        System.debug('DATE de_DE: PASS');
    } else {
        fail++;
        System.debug('DATE de_DE: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('DATE de_DE: FAIL — ' + e.getMessage());
}

// ===== {Today} built-in =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Today}</w:t>', new Map<String, Object>());
    String yearStr = String.valueOf(Date.today().year());
    if (r.contains(yearStr) && !r.contains('{Today}')) {
        pass++;
        System.debug('TODAY BUILTIN: PASS — ' + r);
    } else {
        fail++;
        System.debug('TODAY BUILTIN: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('TODAY BUILTIN: FAIL — ' + e.getMessage());
}

// ===== {Today:MM/dd/yyyy} with format =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Today:MM/dd/yyyy}</w:t>', new Map<String, Object>());
    Date td = Date.today();
    String expected =
        String.valueOf(td.month()).leftPad(2, '0') +
        '/' +
        String.valueOf(td.day()).leftPad(2, '0') +
        '/' +
        String.valueOf(td.year());
    if (r.contains(expected)) {
        pass++;
        System.debug('TODAY FORMATTED: PASS');
    } else {
        fail++;
        System.debug('TODAY FORMATTED: FAIL — got ' + r + ', expected ' + expected);
    }
} catch (Exception e) {
    fail++;
    System.debug('TODAY FORMATTED: FAIL — ' + e.getMessage());
}

// ===== {Today:date:de_DE} with locale format =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Today:date:de_DE}</w:t>', new Map<String, Object>());
    Date td = Date.today();
    String expected =
        String.valueOf(td.day()).leftPad(2, '0') +
        '.' +
        String.valueOf(td.month()).leftPad(2, '0') +
        '.' +
        String.valueOf(td.year());
    if (r.contains(expected)) {
        pass++;
        System.debug('TODAY de_DE: PASS');
    } else {
        fail++;
        System.debug('TODAY de_DE: FAIL — got ' + r + ', expected ' + expected);
    }
} catch (Exception e) {
    fail++;
    System.debug('TODAY de_DE: FAIL — ' + e.getMessage());
}

// ===== {Now} built-in (DateTime) =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Now}</w:t>', new Map<String, Object>());
    String yearStr = String.valueOf(DateTime.now().year());
    if (r.contains(yearStr) && !r.contains('{Now}')) {
        pass++;
        System.debug('NOW BUILTIN: PASS — ' + r);
    } else {
        fail++;
        System.debug('NOW BUILTIN: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('NOW BUILTIN: FAIL — ' + e.getMessage());
}

// ===== {Now:yyyy-MM-dd HH:mm} formatted =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Now:yyyy-MM-dd HH:mm}</w:t>', new Map<String, Object>());
    String yearStr = String.valueOf(DateTime.now().year());
    // Expect a value like 2026-04-20 08:33 (pattern, not exact time)
    if (r.contains(yearStr + '-') && r.length() > 20) {
        pass++;
        System.debug('NOW FORMATTED: PASS — ' + r);
    } else {
        fail++;
        System.debug('NOW FORMATTED: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('NOW FORMATTED: FAIL — ' + e.getMessage());
}

// ===== Textarea newline preserves run formatting (#32, fix by @raykeating) =====
try {
    r = DocGenService.processXmlForTest(
        '<w:r><w:rPr><w:sz w:val="28"/></w:rPr><w:t>{Desc}</w:t></w:r>',
        new Map<String, Object>{ 'Desc' => 'Line1\nLine2' }
    );
    Integer szCount = r.countMatches('<w:sz w:val="28"/>');
    if (r.contains('w:br') && szCount >= 3 && r.contains('Line1') && r.contains('Line2')) {
        pass++;
        System.debug('TEXTAREA NEWLINE FMT: PASS');
    } else {
        fail++;
        System.debug('TEXTAREA NEWLINE FMT: FAIL — szCount=' + szCount + ' — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('TEXTAREA NEWLINE FMT: FAIL — ' + e.getMessage());
}

// ===== Textarea newline preserves RTL marker across breaks =====
try {
    r = DocGenService.processXmlForTest(
        '<w:r><w:rPr><w:rtl/></w:rPr><w:t>{Desc}</w:t></w:r>',
        new Map<String, Object>{ 'Desc' => 'A\nB' }
    );
    Integer rtlCount = r.countMatches('<w:rtl/>');
    if (r.contains('w:br') && rtlCount >= 3) {
        pass++;
        System.debug('TEXTAREA NEWLINE RTL: PASS');
    } else {
        fail++;
        System.debug('TEXTAREA NEWLINE RTL: FAIL — rtlCount=' + rtlCount);
    }
} catch (Exception e) {
    fail++;
    System.debug('TEXTAREA NEWLINE RTL: FAIL — ' + e.getMessage());
}

// ===== VML watermark detection in DocGenHtmlRenderer =====
// Word inserts picture watermarks via <w:pict><v:shape><v:imagedata r:id="..."/></v:shape></w:pict>.
// In production, DocGenService.namespaceImageRelIds merges header pict markup into body XML
// before convertToHtml runs, so the renderer sees the pict in body context. Mirror that here
// (don't wrap in DOCGEN_HEADER markers — those strip the pict out of the body content path).
try {
    String docWithPict =
        '<w:document><w:body>' +
        '<w:p><w:r><w:pict>' +
        '<v:shape id="PowerPlusWaterMarkObject" style="position:absolute;width:468pt;height:240pt;rotation:315;mso-position-horizontal:center" type="#_x0000_t75">' +
        '<v:imagedata r:id="rIdImg1" o:title=""/>' +
        '</v:shape>' +
        '</w:pict></w:r></w:p>' +
        '<w:p><w:r><w:t>Body text</w:t></w:r></w:p>' +
        '</w:body></w:document>';
    Map<String, String> images = new Map<String, String>{
        'rIdImg1' => '/sfc/servlet.shepherd/version/download/068000000000000'
    };
    String html = DocGenHtmlRenderer.convertToHtml(docWithPict, images, null);
    // After extractWatermarks() lifts the watermark out of the body, it appears as
    // @page background-image CSS — that's the final, shipping form. The intermediate
    // 'docgen-watermark' div doesn't survive into the rendered output.
    Boolean hasPageBg =
        html.contains('@page') &&
        html.contains('background-image:') &&
        html.contains('068000000000000');
    Boolean hasBodyContent = html.contains('Body text');
    if (hasPageBg && hasBodyContent) {
        pass++;
        System.debug('VML WATERMARK RENDER: PASS — pict lifted to @page background-image');
    } else {
        fail++;
        System.debug('VML WATERMARK RENDER: FAIL — pageBg=' + hasPageBg + ' body=' + hasBodyContent);
    }
} catch (Exception e) {
    fail++;
    System.debug('VML WATERMARK RENDER: FAIL — ' + e.getMessage());
}

// ===== Table width <w:tblW w:type="dxa"> emits absolute pt =====
// 9360 twips = 6.5". Without the dxa branch the table fell back to width:100%, which
// over-stretched on landscape pages. Authored width must survive into the HTML.
try {
    String tblXml =
        '<w:document><w:body><w:tbl><w:tblPr><w:tblW w:w="9360" w:type="dxa"/></w:tblPr>' +
        '<w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>';
    String html = DocGenHtmlRenderer.convertToHtml(tblXml, new Map<String, String>(), null);
    if (Pattern.matches('(?s).*width:468(\\.0+)?pt.*', html)) {
        pass++;
        System.debug('TABLE WIDTH dxa: PASS — 9360 twips → 468pt');
    } else {
        fail++;
        System.debug(
            'TABLE WIDTH dxa: FAIL — expected width:468pt, got: ' +
            html.substring(html.indexOf('<table'), Math.min(html.indexOf('<table') + 200, html.length()))
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('TABLE WIDTH dxa: FAIL — ' + e.getMessage());
}

// ===== Table width <w:tblW w:type="auto"> emits width:auto (shrink-wrap) =====
// Without this branch a right-aligned auto-width totals table falls through to
// global table{width:100%} and stretches the full content area.
try {
    String tblXml =
        '<w:document><w:body><w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>' +
        '<w:tr><w:tc><w:p><w:r><w:t>Total</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>';
    String html = DocGenHtmlRenderer.convertToHtml(tblXml, new Map<String, String>(), null);
    if (html.contains('width:auto')) {
        pass++;
        System.debug('TABLE WIDTH auto: PASS — w:type=auto → width:auto');
    } else {
        fail++;
        System.debug(
            'TABLE WIDTH auto: FAIL — got: ' +
            html.substring(html.indexOf('<table'), Math.min(html.indexOf('<table') + 200, html.length()))
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('TABLE WIDTH auto: FAIL — ' + e.getMessage());
}

// ===== Table width <w:tblW w:type="pct"> still emits percentage =====
try {
    String tblXml =
        '<w:document><w:body><w:tbl><w:tblPr><w:tblW w:w="2500" w:type="pct"/></w:tblPr>' +
        '<w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>';
    String html = DocGenHtmlRenderer.convertToHtml(tblXml, new Map<String, String>(), null);
    if (Pattern.matches('(?s).*width:50(\\.0+)?%.*', html)) {
        pass++;
        System.debug('TABLE WIDTH pct: PASS — 2500 → 50%');
    } else {
        fail++;
        System.debug(
            'TABLE WIDTH pct: FAIL — got: ' +
            html.substring(html.indexOf('<table'), Math.min(html.indexOf('<table') + 200, html.length()))
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('TABLE WIDTH pct: FAIL — ' + e.getMessage());
}

// ===== Nested {#IF} blocks pair correctly (v1.72) =====
// Pre-1.72: findBalancedEnd matched openers with content.equals('#IF'),
// which never matches '#IF Field != 0' (expression-bearing). Inner {/IF}
// got returned as outer's match, parser desynced, "missing closing for"
// thrown. v1.72 changes the IF balancer to prefix-match openers.
try {
    Map<String, Object> data = new Map<String, Object>{ 'O__c' => 1, 'I__c' => 1 };
    String r = DocGenService.processXmlForTest('{#IF O__c != 0}OUTER{#IF I__c != 0}INNER{/IF}END{/IF}', data);
    if (r == 'OUTERINNEREND') {
        pass++;
        System.debug('NESTED IF (both true): PASS');
    } else {
        fail++;
        System.debug('NESTED IF (both true): FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('NESTED IF (both true): FAIL — ' + e.getMessage());
}

try {
    Map<String, Object> data = new Map<String, Object>{ 'O__c' => 1, 'I__c' => 0 };
    String r = DocGenService.processXmlForTest('{#IF O__c != 0}OUTER{#IF I__c != 0}INNER{/IF}END{/IF}', data);
    if (r == 'OUTEREND') {
        pass++;
        System.debug('NESTED IF (inner false): PASS');
    } else {
        fail++;
        System.debug('NESTED IF (inner false): FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('NESTED IF (inner false): FAIL — ' + e.getMessage());
}

try {
    Map<String, Object> data = new Map<String, Object>{ 'O__c' => 0, 'I__c' => 1 };
    String r = DocGenService.processXmlForTest('{#IF O__c != 0}OUTER{#IF I__c != 0}INNER{/IF}END{/IF}', data);
    if (r == '') {
        pass++;
        System.debug('NESTED IF (outer false): PASS');
    } else {
        fail++;
        System.debug('NESTED IF (outer false): FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('NESTED IF (outer false): FAIL — ' + e.getMessage());
}

try {
    Map<String, Object> data = new Map<String, Object>{ 'A__c' => 1, 'B__c' => 1, 'C__c' => 1 };
    String r = DocGenService.processXmlForTest(
        '{#IF A__c != 0}A{#IF B__c != 0}B{#IF C__c != 0}C{/IF}/B{/IF}/A{/IF}',
        data
    );
    if (r == 'ABC/B/A') {
        pass++;
        System.debug('NESTED IF (triple): PASS');
    } else {
        fail++;
        System.debug('NESTED IF (triple): FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('NESTED IF (triple): FAIL — ' + e.getMessage());
}

// ===== Empty child relationship totalSize is 0, not null (v1.72) =====
// Pre-1.72: SOQL child subqueries returning zero rows were stripped from
// getPopulatedFieldsAsMap(), so {Rel.totalSize} resolved to null and
// {#IF Rel.totalSize != 0} evaluated truthy on the empty case. v1.72
// synthesizes empty {records:[], totalSize:0} wrappers in V1+V2 retrievers.
Account dgAcc = new Account(Name = 'DG_e2e07_v172_' + System.now().getTime());
insert dgAcc;
try {
    Map<String, Object> data = DocGenDataRetriever.getRecordData(
        dgAcc.Id,
        'Account',
        'Name, (SELECT Id FROM Contacts)'
    );
    Object rel = data.get('Contacts');
    if (rel instanceof Map<String, Object>) {
        Object ts = ((Map<String, Object>) rel).get('totalSize');
        if (ts != null && Integer.valueOf(ts) == 0) {
            pass++;
            System.debug('EMPTY REL totalSize: PASS — 0 not null');
        } else {
            fail++;
            System.debug('EMPTY REL totalSize: FAIL — got [' + ts + ']');
        }
    } else {
        fail++;
        System.debug('EMPTY REL totalSize: FAIL — Contacts key missing');
    }

    String r = DocGenService.processXmlForTest('{#IF Contacts.totalSize != 0}HAS{/IF}', data);
    if (r == '') {
        pass++;
        System.debug('EMPTY REL IF: PASS — suppressed');
    } else {
        fail++;
        System.debug('EMPTY REL IF: FAIL — got [' + r + ']');
    }

    String r2 = DocGenService.processXmlForTest('[{Contacts.totalSize}]', data);
    if (r2 == '[0]') {
        pass++;
        System.debug('EMPTY REL render: PASS — [0]');
    } else {
        fail++;
        System.debug('EMPTY REL render: FAIL — got [' + r2 + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('EMPTY REL: FAIL — ' + e.getMessage());
} finally {
    delete dgAcc;
}

// ===== AND / OR / NOT / parens in IF expressions (v1.72) =====
try {
    Map<String, Object> data = new Map<String, Object>{
        'A__c' => 5,
        'B__c' => 10,
        'C__c' => 0,
        'D__c' => 7,
        'Active__c' => true
    };
    String r;
    r = DocGenService.processXmlForTest('{#IF A__c > 0 AND B__c > 0}YES{/IF}', data);
    if (r == 'YES') {
        pass++;
        System.debug('IF AND: PASS');
    } else {
        fail++;
        System.debug('IF AND: FAIL — got [' + r + ']');
    }

    r = DocGenService.processXmlForTest('{#IF C__c > 5 OR B__c > 0}YES{/IF}', data);
    if (r == 'YES') {
        pass++;
        System.debug('IF OR: PASS');
    } else {
        fail++;
        System.debug('IF OR: FAIL — got [' + r + ']');
    }

    r = DocGenService.processXmlForTest('{#IF NOT (C__c > 5)}YES{/IF}', data);
    if (r == 'YES') {
        pass++;
        System.debug('IF NOT parens: PASS');
    } else {
        fail++;
        System.debug('IF NOT parens: FAIL — got [' + r + ']');
    }

    // (A>0) OR (B>0 AND C>5) OR (D>0) → true OR (true AND false) OR true → true
    r = DocGenService.processXmlForTest('{#IF (A__c > 0) OR (B__c > 0 AND C__c > 5) OR (D__c > 0)}YES{/IF}', data);
    if (r == 'YES') {
        pass++;
        System.debug('IF multi-OR chain: PASS');
    } else {
        fail++;
        System.debug('IF multi-OR chain: FAIL — got [' + r + ']');
    }

    // Precedence: AND binds tighter than OR
    r = DocGenService.processXmlForTest('{#IF C__c > 5 OR A__c > 0 AND C__c > 5}YES{/IF}', data);
    if (r == '') {
        pass++;
        System.debug('IF precedence: PASS');
    } else {
        fail++;
        System.debug('IF precedence: FAIL — got [' + r + ']');
    }

    // Bare boolean field in compound expression
    r = DocGenService.processXmlForTest('{#IF Active__c AND A__c > 0}YES{/IF}', data);
    if (r == 'YES') {
        pass++;
        System.debug('IF bare-bool AND: PASS');
    } else {
        fail++;
        System.debug('IF bare-bool AND: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('IF AND/OR: FAIL — ' + e.getMessage());
}

System.debug('========================================');

// ===== Rich text <ul>/<ol>/<li> (issue #47) =====
try {
    String t = '<w:p><w:r><w:t>{N}</w:t></w:r></w:p>';
    String s = '</w:t></w:r><w:r><w:t xml:space="preserve">';
    r = DocGenService.processXmlForTest(t, new Map<String, Object>{ 'N' => '<ul><li>a</li><li>b</li></ul>' });
    if (r.contains('• ' + s + 'a') && r.contains('• ' + s + 'b')) { pass++; System.debug('RT BULLETED: PASS'); }
    else { fail++; System.debug('RT BULLETED: FAIL — ' + r); }
    r = DocGenService.processXmlForTest(t, new Map<String, Object>{ 'N' => '<ol><li>x</li><li>y</li></ol>' });
    if (r.contains('1. ' + s + 'x') && r.contains('2. ' + s + 'y')) { pass++; System.debug('RT NUMBERED: PASS'); }
    else { fail++; System.debug('RT NUMBERED: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('RT LIST: FAIL — ' + e.getMessage()); }

System.debug('========================================');
System.debug(
    'E2E-07-SYNTAX2 — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
