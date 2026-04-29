// Smoke test for v1.72 fixes — nested IF balancing + empty-rel totalSize.
// Run: sf apex run --target-org docgen-dev -f scripts/smoke-v172.apex

Integer pass = 0;
Integer fail = 0;
List<String> failures = new List<String>();

{
    // ============= Issue 1: nested IF balancing =================
    // Use processXmlForTest which exposes processXml directly for testing.

    // Test A: nested IF — both true → outer + inner content render
    Map<String, Object> data = new Map<String, Object>{ 'Outer__c' => 1, 'Inner__c' => 1 };
    String tpl = '{#IF Outer__c != 0}OUTER{#IF Inner__c != 0}INNER{/IF}OUTER_END{/IF}';
    String result = portwoodglobal.DocGenService.processXmlForTest(tpl, data);
    String expected = 'OUTERINNEROUTER_END';
    if (result == expected) {
        pass++;
        System.debug('PASS A: ' + result);
    } else {
        fail++;
        failures.add('A expected [' + expected + '] got [' + result + ']');
    }
}

{
    // Test B: nested IF — outer true, inner false → only outer content
    Map<String, Object> data = new Map<String, Object>{ 'Outer__c' => 1, 'Inner__c' => 0 };
    String tpl = '{#IF Outer__c != 0}OUTER{#IF Inner__c != 0}INNER{/IF}OUTER_END{/IF}';
    String result = portwoodglobal.DocGenService.processXmlForTest(tpl, data);
    String expected = 'OUTEROUTER_END';
    if (result == expected) {
        pass++;
        System.debug('PASS B: ' + result);
    } else {
        fail++;
        failures.add('B expected [' + expected + '] got [' + result + ']');
    }
}

{
    // Test C: nested IF — outer false → entire block suppressed
    Map<String, Object> data = new Map<String, Object>{ 'Outer__c' => 0, 'Inner__c' => 1 };
    String tpl = '{#IF Outer__c != 0}OUTER{#IF Inner__c != 0}INNER{/IF}OUTER_END{/IF}';
    String result = portwoodglobal.DocGenService.processXmlForTest(tpl, data);
    String expected = '';
    if (result == expected) {
        pass++;
        System.debug('PASS C: ' + result);
    } else {
        fail++;
        failures.add('C expected [empty] got [' + result + ']');
    }
}

{
    // Test D: triple-nested IF
    Map<String, Object> data = new Map<String, Object>{ 'A__c' => 1, 'B__c' => 1, 'C__c' => 1 };
    String tpl = '{#IF A__c != 0}A{#IF B__c != 0}B{#IF C__c != 0}C{/IF}B_END{/IF}A_END{/IF}';
    String result = portwoodglobal.DocGenService.processXmlForTest(tpl, data);
    String expected = 'ABCB_ENDA_END';
    if (result == expected) {
        pass++;
        System.debug('PASS D: ' + result);
    } else {
        fail++;
        failures.add('D expected [' + expected + '] got [' + result + ']');
    }
}

{
    // Test E: nested IF with two comparison operators
    Map<String, Object> data = new Map<String, Object>{ 'Count__c' => 5, 'Total__c' => 100 };
    String tpl = '{#IF Count__c > 0}HAS{#IF Total__c > 50}BIG{/IF}END{/IF}';
    String result = portwoodglobal.DocGenService.processXmlForTest(tpl, data);
    String expected = 'HASBIGEND';
    if (result == expected) {
        pass++;
        System.debug('PASS E: ' + result);
    } else {
        fail++;
        failures.add('E expected [' + expected + '] got [' + result + ']');
    }
}

{
    // Test F: non-nested IF (regression check — must still work after fix)
    Map<String, Object> data = new Map<String, Object>{ 'Field__c' => 1 };
    String tpl = '{#IF Field__c != 0}YES{/IF}';
    String result = portwoodglobal.DocGenService.processXmlForTest(tpl, data);
    String expected = 'YES';
    if (result == expected) {
        pass++;
        System.debug('PASS F: ' + result);
    } else {
        fail++;
        failures.add('F expected [' + expected + '] got [' + result + ']');
    }
}

// ============= Issue 2: empty-rel totalSize =================
// Find an Account with no Contacts, query via DocGenDataRetriever, verify
// data map has Contacts.totalSize = 0 (not null).

// Create an isolated Account
Account acc = new Account(Name = 'DG_v172_Smoke_' + System.now().getTime());
insert acc;
try {
    // V1 flat config: ask for Name and (SELECT Id FROM Contacts)
    String config = 'Name, (SELECT Id FROM Contacts)';
    Map<String, Object> data = portwoodglobal.DocGenDataRetriever.getRecordData(acc.Id, 'Account', config);

    if (data != null && data.containsKey('Contacts')) {
        Map<String, Object> rel = (Map<String, Object>) data.get('Contacts');
        Object ts = rel.get('totalSize');
        if (ts != null && Integer.valueOf(ts) == 0) {
            pass++;
            System.debug('PASS G: V1 empty rel → totalSize=0');
        } else {
            fail++;
            failures.add('G V1 expected totalSize=0, got ' + ts);
        }
    } else {
        fail++;
        failures.add('G V1 missing Contacts key in data map');
    }

    // IF check on empty rel
    String tpl = '{#IF Contacts.totalSize != 0}HAS{/IF}';
    String result = portwoodglobal.DocGenService.processXmlForTest(tpl, data);
    if (result == '') {
        pass++;
        System.debug('PASS H: IF empty rel → suppressed');
    } else {
        fail++;
        failures.add('H IF empty rel expected [empty], got [' + result + ']');
    }

    // {Rel.totalSize} renders 0 (not blank)
    String tpl2 = '[{Contacts.totalSize}]';
    String result2 = portwoodglobal.DocGenService.processXmlForTest(tpl2, data);
    if (result2 == '[0]') {
        pass++;
        System.debug('PASS I: {Rel.totalSize} renders [0]');
    } else {
        fail++;
        failures.add('I expected [0], got [' + result2 + ']');
    }
} finally {
    delete acc;
}

// =================================================================
System.debug('PASS: ' + pass + '  FAIL: ' + fail);
if (fail == 0) {
    System.debug('ALL TESTS PASSED');
} else {
    for (String f : failures) {
        System.debug('FAILURE: ' + f);
    }
}
