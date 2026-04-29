// Smoke test for v1.72 AND/OR/NOT/parens support in {#IF} expressions.

Integer pass = 0;
Integer fail = 0;
List<String> failures = new List<String>();

Map<String, Object> d = new Map<String, Object>{
    'A__c' => 5,
    'B__c' => 10,
    'C__c' => 0,
    'D__c' => 7,
    'Active__c' => true,
    'Inactive__c' => false,
    'Name' => 'Acme',
    'Stage' => 'Closed Won'
};

List<List<String>> probes = new List<List<String>>{
    new List<String>{ 'AND both true', '{#IF A__c > 0 AND B__c > 0}YES{/IF}', 'YES' },
    new List<String>{ 'AND first false', '{#IF C__c > 0 AND B__c > 0}YES{/IF}', '' },
    new List<String>{ 'AND second false', '{#IF A__c > 0 AND C__c > 5}YES{/IF}', '' },
    new List<String>{ 'AND both false', '{#IF C__c > 5 AND C__c > 10}YES{/IF}', '' },
    new List<String>{ '&& symbolic', '{#IF A__c > 0 && B__c > 0}YES{/IF}', 'YES' },
    new List<String>{ 'OR first true', '{#IF A__c > 0 OR C__c > 5}YES{/IF}', 'YES' },
    new List<String>{ 'OR second true', '{#IF C__c > 5 OR B__c > 0}YES{/IF}', 'YES' },
    new List<String>{ 'OR both false', '{#IF C__c > 5 OR C__c > 10}YES{/IF}', '' },
    new List<String>{ '|| symbolic', '{#IF C__c > 5 || B__c > 0}YES{/IF}', 'YES' },
    new List<String>{ 'NOT true→false', '{#IF NOT Active__c}YES{/IF}', '' },
    new List<String>{ 'NOT false→true', '{#IF NOT Inactive__c}YES{/IF}', 'YES' },
    new List<String>{ '!Active', '{#IF !Active__c}YES{/IF}', '' },
    new List<String>{ '!Inactive', '{#IF !Inactive__c}YES{/IF}', 'YES' },
    new List<String>{ 'precedence A', '{#IF A__c > 0 OR C__c > 5 AND C__c > 10}YES{/IF}', 'YES' },
    new List<String>{ 'precedence B', '{#IF C__c > 5 OR A__c > 0 AND B__c > 0}YES{/IF}', 'YES' },
    new List<String>{ 'precedence C', '{#IF C__c > 5 OR A__c > 0 AND C__c > 5}YES{/IF}', '' },
    new List<String>{ 'parens 1', '{#IF (A__c > 0 OR C__c > 5) AND B__c > 0}YES{/IF}', 'YES' },
    new List<String>{ 'parens 2', '{#IF (C__c > 5 OR C__c > 10) AND B__c > 0}YES{/IF}', '' },
    new List<String>{ 'string AND', '{#IF Name = \'Acme\' AND Stage = \'Closed Won\'}WIN{/IF}', 'WIN' },
    new List<String>{ 'quoted AND inside', '{#IF Stage = \'big AND small\'}NO{/IF}', '' },
    new List<String>{ 'bare bool AND', '{#IF Active__c AND A__c > 0}YES{/IF}', 'YES' },
    new List<String>{ 'triple AND', '{#IF A__c > 0 AND B__c > 0 AND Active__c}YES{/IF}', 'YES' },
    new List<String>{ 'NOT parens', '{#IF NOT (C__c > 5)}YES{/IF}', 'YES' },
    // Multi-OR with parens (the user's requested pattern)
    // (A>0) OR (B>0 AND C>5) OR (D>0) → true OR (true AND false) OR true → true
    new List<String>{ 'multi-OR 1', '{#IF (A__c > 0) OR (B__c > 0 AND C__c > 5) OR (D__c > 0)}YES{/IF}', 'YES' },
    // (C>5) OR (B>0 AND C>5) OR (C>5) → false OR (true AND false) OR false → false
    new List<String>{ 'multi-OR 2', '{#IF (C__c > 5) OR (B__c > 0 AND C__c > 5) OR (C__c > 5)}YES{/IF}', '' },
    // (C>5) OR (B>0 AND A>0) OR (C>5) → false OR (true AND true) OR false → true
    new List<String>{ 'multi-OR 3', '{#IF (C__c > 5) OR (B__c > 0 AND A__c > 0) OR (C__c > 5)}YES{/IF}', 'YES' },
    // 4 chained groups
    new List<String>{
        'four chained groups',
        '{#IF (C__c > 5) OR (C__c > 10) OR (A__c > 0) OR (D__c > 0)}YES{/IF}',
        'YES'
    },
    // Mixed: NOT in chain
    new List<String>{ 'NOT in chain', '{#IF (C__c > 5) OR NOT (Active__c) OR (A__c > 0)}YES{/IF}', 'YES' },
    // Nested parens: ((A>0 AND B>0) OR (C>5)) AND D>0 → (true OR false) AND true → true
    new List<String>{ 'nested parens', '{#IF ((A__c > 0 AND B__c > 0) OR (C__c > 5)) AND D__c > 0}YES{/IF}', 'YES' },
    // Deep with else
    new List<String>{ 'with else (truthy)', '{#IF (A__c > 0 AND B__c > 0)}WIN{:else}LOSE{/IF}', 'WIN' },
    new List<String>{ 'with else (falsy)', '{#IF (C__c > 5 AND B__c > 0)}WIN{:else}LOSE{/IF}', 'LOSE' },
    // Nested IF inside AND/OR result
    new List<String>{
        'nested IF inside AND chain',
        '{#IF A__c > 0 AND B__c > 0}OUTER{#IF Active__c}-IN-{/IF}END{/IF}',
        'OUTER-IN-END'
    }
};

for (List<String> p : probes) {
    String label = p[0];
    String tpl = p[1];
    String expected = p[2];
    try {
        String r = portwoodglobal.DocGenService.processXmlForTest(tpl, d);
        if (r == expected) {
            pass++;
        } else {
            fail++;
            failures.add(label + ': expected [' + expected + '] got [' + r + ']');
        }
    } catch (Exception e) {
        fail++;
        failures.add(label + ': exception — ' + e.getMessage());
    }
}

System.debug('============================================');
System.debug('AND/OR SMOKE — PASS: ' + pass + '  FAIL: ' + fail);
if (fail > 0) {
    for (String f : failures) {
        System.debug('  FAIL: ' + f);
    }
} else {
    System.debug('ALL TESTS PASSED');
}
