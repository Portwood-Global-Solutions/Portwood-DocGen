// DocGen E2E Test 07-syntax3 — Running-user merge tags (v1.77+)
// Run: sf apex run --target-org <org> -f scripts/e2e-07-syntax3.apex
// Depends on: nothing (uses DocGenService.processXmlForTest directly)
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;
String r;

// ===== {RunningUser.Name} resolves to UserInfo.getName() =====
try {
    r = DocGenService.processXmlForTest('<w:t>{RunningUser.Name}</w:t>', new Map<String, Object>());
    if (r.contains(UserInfo.getName())) {
        pass++;
        System.debug('RUNNING USER NAME: PASS — ' + r);
    } else {
        fail++;
        System.debug('RUNNING USER NAME: FAIL — got [' + r + '] expected to contain [' + UserInfo.getName() + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER NAME: FAIL — ' + e.getMessage());
}

// ===== {RunningUser.FirstName} =====
try {
    r = DocGenService.processXmlForTest('<w:t>{RunningUser.FirstName}</w:t>', new Map<String, Object>());
    if (UserInfo.getFirstName() == null || r.contains(UserInfo.getFirstName())) {
        pass++;
        System.debug('RUNNING USER FIRSTNAME: PASS — ' + r);
    } else {
        fail++;
        System.debug('RUNNING USER FIRSTNAME: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER FIRSTNAME: FAIL — ' + e.getMessage());
}

// ===== {RunningUser.Email} =====
try {
    r = DocGenService.processXmlForTest('<w:t>{RunningUser.Email}</w:t>', new Map<String, Object>());
    if (r.contains(UserInfo.getUserEmail())) {
        pass++;
        System.debug('RUNNING USER EMAIL: PASS');
    } else {
        fail++;
        System.debug('RUNNING USER EMAIL: FAIL — got [' + r + '] expected [' + UserInfo.getUserEmail() + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER EMAIL: FAIL — ' + e.getMessage());
}

// ===== {RunningUser.Username} =====
try {
    r = DocGenService.processXmlForTest('<w:t>{RunningUser.Username}</w:t>', new Map<String, Object>());
    if (r.contains(UserInfo.getUserName())) {
        pass++;
        System.debug('RUNNING USER USERNAME: PASS');
    } else {
        fail++;
        System.debug('RUNNING USER USERNAME: FAIL — got [' + r + '] expected [' + UserInfo.getUserName() + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER USERNAME: FAIL — ' + e.getMessage());
}

// ===== {RunningUser.Id} resolves to current user Id =====
try {
    r = DocGenService.processXmlForTest('<w:t>{RunningUser.Id}</w:t>', new Map<String, Object>());
    if (r.contains(String.valueOf(UserInfo.getUserId()).left(15))) {
        pass++;
        System.debug('RUNNING USER ID: PASS');
    } else {
        fail++;
        System.debug('RUNNING USER ID: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER ID: FAIL — ' + e.getMessage());
}

// ===== Case insensitive: {runninguser.name} should also work =====
try {
    r = DocGenService.processXmlForTest('<w:t>{runninguser.name}</w:t>', new Map<String, Object>());
    if (r.contains(UserInfo.getName())) {
        pass++;
        System.debug('RUNNING USER LOWERCASE: PASS');
    } else {
        fail++;
        System.debug('RUNNING USER LOWERCASE: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER LOWERCASE: FAIL — ' + e.getMessage());
}

// ===== Unknown subfield (not in allowlist) → empty resolution =====
try {
    r = DocGenService.processXmlForTest('<w:t>[{RunningUser.SomethingFake}]</w:t>', new Map<String, Object>());
    // Expected: tag resolves to empty — output is "[]"
    if (r.contains('[]')) {
        pass++;
        System.debug('RUNNING USER UNKNOWN FIELD: PASS — ' + r);
    } else {
        fail++;
        System.debug('RUNNING USER UNKNOWN FIELD: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER UNKNOWN FIELD: FAIL — ' + e.getMessage());
}

// ===== Rich-text apostrophe decode (issue #51) =====
// Lightning RTE stores apostrophes as &#39; and double-quotes as &quot;;
// convertRichTextToDocxXml must decode both before emitting OOXML.
try {
    String rt = '<p>ain&#39;t it &quot;great&quot;</p>';
    r = DocGenService.processXmlForTest(
        '<w:p><w:r><w:t>{Notes}</w:t></w:r></w:p>',
        new Map<String, Object>{ 'Notes' => rt }
    );
    // After decode, OOXML re-escapes apostrophe as &apos; and quote as &quot;
    // for XML safety; Word/PDF unescape on render. The bug signature is the
    // numeric reference &#39; surviving — that's what we must NOT see.
    Boolean noNumericRef = !r.contains('&#39;');
    Boolean apos = r.contains('ain&apos;t') || r.contains('ain\'t');
    Boolean quot = r.contains('&quot;great&quot;') || r.contains('"great"');
    if (apos && quot && noNumericRef) {
        pass++;
        System.debug('RICHTEXT APOSTROPHE DECODE: PASS');
    } else {
        fail++;
        System.debug(
            'RICHTEXT APOSTROPHE DECODE: FAIL — apos=' +
                apos +
                ' quot=' +
                quot +
                ' noNumericRef=' +
                noNumericRef +
                ' r=' +
                r
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('RICHTEXT APOSTROPHE DECODE: FAIL — ' + e.getMessage());
}

// ===== Rich-text Unicode numeric entities (issue #51 follow-up) =====
// Smart quotes / em-dash / en-dash / hex-form accented char must all decode.
// The renderer's decodeNumericEntities is reused by the DOCX rich-text path.
try {
    String rt = '<p>he said &#8220;don&#8217;t&#8221; &#8212; ok&#8211;done caf&#xE9;</p>';
    r = DocGenService.processXmlForTest('<w:p><w:r><w:t>{N}</w:t></w:r></w:p>', new Map<String, Object>{ 'N' => rt });
    Boolean noRefs =
        !r.contains('&#8220;') &&
        !r.contains('&#8217;') &&
        !r.contains('&#8221;') &&
        !r.contains('&#8212;') &&
        !r.contains('&#8211;') &&
        !r.contains('&#xE9;');
    Boolean ldquo = r.contains('“'); // left double quote
    Boolean rsquo = r.contains('’'); // right single quote
    Boolean rdquo = r.contains('”'); // right double quote
    Boolean mdash = r.contains('—'); // em dash
    Boolean ndash = r.contains('–'); // en dash
    Boolean eacute = r.contains('é'); // é
    if (noRefs && ldquo && rsquo && rdquo && mdash && ndash && eacute) {
        pass++;
        System.debug('RICHTEXT UNICODE DECODE: PASS');
    } else {
        fail++;
        System.debug(
            'RICHTEXT UNICODE DECODE: FAIL — noRefs=' +
                noRefs +
                ' ldquo=' +
                ldquo +
                ' rsquo=' +
                rsquo +
                ' rdquo=' +
                rdquo +
                ' mdash=' +
                mdash +
                ' ndash=' +
                ndash +
                ' eacute=' +
                eacute +
                ' r=' +
                r
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('RICHTEXT UNICODE DECODE: FAIL — ' + e.getMessage());
}

// ===== Allowlist enforcement: a User field NOT in the allowlist (e.g., ProfileId) =====
try {
    r = DocGenService.processXmlForTest('<w:t>[{RunningUser.ProfileId}]</w:t>', new Map<String, Object>());
    // ProfileId is intentionally NOT in the allowlist — must resolve to empty.
    if (r.contains('[]')) {
        pass++;
        System.debug('RUNNING USER ALLOWLIST GUARD: PASS — ProfileId not exposed');
    } else {
        fail++;
        System.debug('RUNNING USER ALLOWLIST GUARD: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER ALLOWLIST GUARD: FAIL — ' + e.getMessage());
}

// ===== Document title built-ins: {Today}, {Now}, {RunningUser.X}, format suffixes =====
// generateDocTitle previously only walked data-map fields; built-ins rendered empty.
try {
    Map<String, Object> recData = new Map<String, Object>{ 'Name' => 'Acme' };
    String t1 = DocGenService.generateDocTitle('{Name}-{Today:MM-dd-yyyy}', recData);
    Date td = Date.today();
    String mm = td.month() < 10 ? '0' + td.month() : '' + td.month();
    String dd = td.day() < 10 ? '0' + td.day() : '' + td.day();
    String expected1 = 'Acme-' + mm + '-' + dd + '-' + td.year();
    Boolean ok1 = (t1 == expected1);

    String t2 = DocGenService.generateDocTitle('{Now:yyyy}', recData);
    Boolean ok2 = (t2 == String.valueOf(DateTime.now().year()));

    String t3 = DocGenService.generateDocTitle('Prepared by {RunningUser.Name}', recData);
    Boolean ok3 = t3.contains(UserInfo.getName());

    String t4 = DocGenService.generateDocTitle('{Today}', recData);
    Boolean ok4 = String.isNotBlank(t4) && t4.contains(String.valueOf(td.year()));

    if (ok1 && ok2 && ok3 && ok4) {
        pass++;
        System.debug('TITLE BUILTINS: PASS — ' + t1 + ' | ' + t2 + ' | ' + t3 + ' | ' + t4);
    } else {
        fail++;
        System.debug(
            'TITLE BUILTINS: FAIL — ok1=' +
                ok1 +
                ' ok2=' +
                ok2 +
                ' ok3=' +
                ok3 +
                ' ok4=' +
                ok4 +
                ' t1=' +
                t1 +
                ' t2=' +
                t2 +
                ' t3=' +
                t3 +
                ' t4=' +
                t4
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('TITLE BUILTINS: FAIL — ' + e.getMessage());
}

// ===== IF inside table row, condition false, no else (issue #53) =====
// Pre-fix: smart-container expansion backtracked the row's <w:tr> opening,
// IF emitted nothing, downstream </w:tr> orphaned → DOCX corruption + PDF
// trailing-content drop. Post-fix: IF must NEVER trigger container expansion.
try {
    String tableXml =
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{#IF Status = open}{Name}{/IF}</w:t></w:r></w:p></w:tc></w:tr>' +
        '<w:tr><w:tc><w:p><w:r><w:t>after-row</w:t></w:r></w:p></w:tc></w:tr></w:tbl>';
    Map<String, Object> falseData = new Map<String, Object>{ 'Status' => 'closed', 'Name' => 'Acme' };
    String r1 = DocGenService.processXmlForTest(tableXml, falseData);
    Boolean falseHasFirstRow = r1.contains('<w:tr>') && r1.indexOf('<w:tr>') < r1.indexOf('after-row');
    Boolean falseHasAfter = r1.contains('after-row');
    Boolean falseBalanced =
        (r1.indexOf('<w:tr>') != -1) &&
        (r1.indexOf('</w:tr>') != -1) &&
        r1.split('<w:tr>').size() == r1.split('</w:tr>').size();

    Map<String, Object> trueData = new Map<String, Object>{ 'Status' => 'open', 'Name' => 'Acme' };
    String r2 = DocGenService.processXmlForTest(tableXml, trueData);
    Boolean trueHasName = r2.contains('Acme');
    Boolean trueHasAfter = r2.contains('after-row');

    if (falseHasFirstRow && falseHasAfter && falseBalanced && trueHasName && trueHasAfter) {
        pass++;
        System.debug('IF-IN-ROW (issue #53): PASS');
    } else {
        fail++;
        System.debug(
            'IF-IN-ROW (issue #53): FAIL — falseHasFirstRow=' +
                falseHasFirstRow +
                ' falseHasAfter=' +
                falseHasAfter +
                ' falseBalanced=' +
                falseBalanced +
                ' trueHasName=' +
                trueHasName +
                ' trueHasAfter=' +
                trueHasAfter +
                ' r1=' +
                r1 +
                ' r2=' +
                r2
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('IF-IN-ROW (issue #53): FAIL — ' + e.getMessage());
}

System.debug('========================================');
System.debug(
    'E2E-07-SYNTAX3 — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
