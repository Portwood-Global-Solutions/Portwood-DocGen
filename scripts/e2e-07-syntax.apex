// DocGen E2E Test 07 — ALL Merge Tag Syntax via processXmlForTest()
// Run: sf apex run --target-org <org> -f scripts/e2e-07-syntax.apex
// Depends on: nothing (uses DocGenService.processXmlForTest directly)
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;
String r;

// ===== Basic field replacement =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Name}</w:t>', new Map<String, Object>{'Name'=>'Acme Corp'});
    if (r.contains('Acme Corp')) { pass++; System.debug('BASIC FIELD: PASS'); }
    else { fail++; System.debug('BASIC FIELD: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('BASIC FIELD: FAIL — ' + e.getMessage()); }

// ===== Null/missing field =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Missing}</w:t>', new Map<String, Object>{'Name'=>'Acme'});
    if (!r.contains('{Missing}')) { pass++; System.debug('NULL FIELD: PASS — replaced to empty'); }
    else { fail++; System.debug('NULL FIELD: FAIL — tag not replaced: ' + r); }
} catch (Exception e) { fail++; System.debug('NULL FIELD: FAIL — ' + e.getMessage()); }

// ===== Child loop =====
try {
    Map<String, Object> loopData = new Map<String, Object>{
        'Items' => new List<Object>{
            new Map<String, Object>{'Name'=>'Item A'},
            new Map<String, Object>{'Name'=>'Item B'},
            new Map<String, Object>{'Name'=>'Item C'}
        }
    };
    r = DocGenService.processXmlForTest('<w:t>{#Items}</w:t><w:t>{Name}</w:t><w:t>{/Items}</w:t>', loopData);
    if (r.contains('Item A') && r.contains('Item B') && r.contains('Item C')) {
        pass++; System.debug('CHILD LOOP: PASS');
    } else { fail++; System.debug('CHILD LOOP: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('CHILD LOOP: FAIL — ' + e.getMessage()); }

// ===== Conditional true =====
try {
    r = DocGenService.processXmlForTest('<w:t>{#Flag}Yes{/Flag}</w:t>', new Map<String, Object>{'Flag'=>true});
    if (r.contains('Yes')) { pass++; System.debug('CONDITIONAL TRUE: PASS'); }
    else { fail++; System.debug('CONDITIONAL TRUE: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('CONDITIONAL TRUE: FAIL — ' + e.getMessage()); }

// ===== Conditional false =====
try {
    r = DocGenService.processXmlForTest('<w:t>{#Flag}Yes{/Flag}</w:t>', new Map<String, Object>{'Flag'=>false});
    if (!r.contains('Yes')) { pass++; System.debug('CONDITIONAL FALSE: PASS'); }
    else { fail++; System.debug('CONDITIONAL FALSE: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('CONDITIONAL FALSE: FAIL — ' + e.getMessage()); }

// ===== Inverse conditional (false shows) =====
try {
    r = DocGenService.processXmlForTest('<w:t>{^Flag}No{/Flag}</w:t>', new Map<String, Object>{'Flag'=>false});
    if (r.contains('No')) { pass++; System.debug('INVERSE FALSE (show): PASS'); }
    else { fail++; System.debug('INVERSE FALSE (show): FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('INVERSE FALSE: FAIL — ' + e.getMessage()); }

// ===== Inverse conditional (true hides) =====
try {
    r = DocGenService.processXmlForTest('<w:t>{^Flag}No{/Flag}</w:t>', new Map<String, Object>{'Flag'=>true});
    if (!r.contains('No')) { pass++; System.debug('INVERSE TRUE (hide): PASS'); }
    else { fail++; System.debug('INVERSE TRUE (hide): FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('INVERSE TRUE: FAIL — ' + e.getMessage()); }

// ===== Else in conditional =====
try {
    r = DocGenService.processXmlForTest('<w:t>{#Flag}Yes{:else}No{/Flag}</w:t>', new Map<String, Object>{'Flag'=>false});
    if (r.contains('No') && !r.contains('Yes')) { pass++; System.debug('CONDITIONAL ELSE (false): PASS'); }
    else { fail++; System.debug('CONDITIONAL ELSE (false): FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('CONDITIONAL ELSE: FAIL — ' + e.getMessage()); }

// ===== Else in conditional (true) =====
try {
    r = DocGenService.processXmlForTest('<w:t>{#Flag}Yes{:else}No{/Flag}</w:t>', new Map<String, Object>{'Flag'=>true});
    if (r.contains('Yes') && !r.contains('>No<')) { pass++; System.debug('CONDITIONAL ELSE (true): PASS'); }
    else { fail++; System.debug('CONDITIONAL ELSE (true): FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('CONDITIONAL ELSE TRUE: FAIL — ' + e.getMessage()); }

// ===== Else in inverse =====
try {
    r = DocGenService.processXmlForTest('<w:t>{^Flag}Nope{:else}Yep{/Flag}</w:t>', new Map<String, Object>{'Flag'=>true});
    if (r.contains('Yep') && !r.contains('Nope')) { pass++; System.debug('INVERSE ELSE (true): PASS'); }
    else { fail++; System.debug('INVERSE ELSE (true): FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('INVERSE ELSE: FAIL — ' + e.getMessage()); }

// ===== IF comparison numeric greater than =====
try {
    r = DocGenService.processXmlForTest('<w:t>{#IF Amount > 10000}Big{/IF}</w:t>', new Map<String, Object>{'Amount'=>75000});
    if (r.contains('Big')) { pass++; System.debug('IF NUMERIC >: PASS'); }
    else { fail++; System.debug('IF NUMERIC >: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('IF NUMERIC >: FAIL — ' + e.getMessage()); }

// ===== IF comparison numeric less than =====
try {
    r = DocGenService.processXmlForTest('<w:t>{#IF Amount < 100}Tiny{/IF}</w:t>', new Map<String, Object>{'Amount'=>50});
    if (r.contains('Tiny')) { pass++; System.debug('IF NUMERIC <: PASS'); }
    else { fail++; System.debug('IF NUMERIC <: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('IF NUMERIC <: FAIL — ' + e.getMessage()); }

// ===== IF comparison string equals =====
try {
    r = DocGenService.processXmlForTest('<w:t>{#IF Stage = \'Won\'}Closed{/IF}</w:t>', new Map<String, Object>{'Stage'=>'Won'});
    if (r.contains('Closed')) { pass++; System.debug('IF STRING =: PASS'); }
    else { fail++; System.debug('IF STRING =: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('IF STRING =: FAIL — ' + e.getMessage()); }

// ===== IF string equals (no match) =====
try {
    r = DocGenService.processXmlForTest('<w:t>{#IF Stage = \'Won\'}Closed{/IF}</w:t>', new Map<String, Object>{'Stage'=>'Open'});
    if (!r.contains('Closed')) { pass++; System.debug('IF STRING = (no match): PASS'); }
    else { fail++; System.debug('IF STRING = (no match): FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('IF STRING = no match: FAIL — ' + e.getMessage()); }

// ===== IF not equals =====
try {
    r = DocGenService.processXmlForTest('<w:t>{#IF Stage != \'Lost\'}Active{/IF}</w:t>', new Map<String, Object>{'Stage'=>'Open'});
    if (r.contains('Active')) { pass++; System.debug('IF NOT EQUALS: PASS'); }
    else { fail++; System.debug('IF NOT EQUALS: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('IF NOT EQUALS: FAIL — ' + e.getMessage()); }

// ===== IF with else =====
try {
    r = DocGenService.processXmlForTest('<w:t>{#IF Amount > 10000}Big{:else}Small{/IF}</w:t>', new Map<String, Object>{'Amount'=>500});
    if (r.contains('Small') && !r.contains('Big')) { pass++; System.debug('IF ELSE (false branch): PASS'); }
    else { fail++; System.debug('IF ELSE (false branch): FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('IF ELSE: FAIL — ' + e.getMessage()); }

// ===== Checkbox true =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Active:checkbox}</w:t>', new Map<String, Object>{'Active'=>true});
    if (r.contains('[X]')) { pass++; System.debug('CHECKBOX TRUE: PASS'); }
    else { fail++; System.debug('CHECKBOX TRUE: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('CHECKBOX TRUE: FAIL — ' + e.getMessage()); }

// ===== Checkbox false =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Active:checkbox}</w:t>', new Map<String, Object>{'Active'=>false});
    if (r.contains('[ ]')) { pass++; System.debug('CHECKBOX FALSE: PASS'); }
    else { fail++; System.debug('CHECKBOX FALSE: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('CHECKBOX FALSE: FAIL — ' + e.getMessage()); }

// ===== Currency format =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Amt:currency}</w:t>', new Map<String, Object>{'Amt'=>75000.50});
    if (r.contains('$')) { pass++; System.debug('CURRENCY FORMAT: PASS — ' + r.substringBetween('<w:t>', '</w:t>')); }
    else { fail++; System.debug('CURRENCY FORMAT: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('CURRENCY FORMAT: FAIL — ' + e.getMessage()); }

// ===== Percent format =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Rate:percent}</w:t>', new Map<String, Object>{'Rate'=>15.5});
    if (r.contains('%')) { pass++; System.debug('PERCENT FORMAT: PASS — ' + r.substringBetween('<w:t>', '</w:t>')); }
    else { fail++; System.debug('PERCENT FORMAT: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('PERCENT FORMAT: FAIL — ' + e.getMessage()); }

// ===== Number format (comma) =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Qty:number}</w:t>', new Map<String, Object>{'Qty'=>1234567});
    if (r.contains(',')) { pass++; System.debug('NUMBER FORMAT: PASS — ' + r.substringBetween('<w:t>', '</w:t>')); }
    else { fail++; System.debug('NUMBER FORMAT: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('NUMBER FORMAT: FAIL — ' + e.getMessage()); }

// ===== Date format MM/dd/yyyy =====
try {
    r = DocGenService.processXmlForTest('<w:t>{D:MM/dd/yyyy}</w:t>', new Map<String, Object>{'D'=>DateTime.newInstance(2026, 4, 8, 12, 0, 0)});
    if (r.contains('04/08/2026')) { pass++; System.debug('DATE MM/dd/yyyy: PASS'); }
    else { fail++; System.debug('DATE MM/dd/yyyy: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('DATE MM/dd/yyyy: FAIL — ' + e.getMessage()); }

// ===== Date format MMMM d, yyyy =====
try {
    r = DocGenService.processXmlForTest('<w:t>{D:MMMM d, yyyy}</w:t>', new Map<String, Object>{'D'=>DateTime.newInstance(2026, 4, 8, 12, 0, 0)});
    if (r.contains('April') && r.contains('2026')) { pass++; System.debug('DATE MMMM d yyyy: PASS'); }
    else { fail++; System.debug('DATE MMMM d yyyy: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('DATE MMMM d yyyy: FAIL — ' + e.getMessage()); }

// ===== SUM aggregate =====
try {
    Map<String, Object> aggData = new Map<String, Object>{
        'Items' => new List<Object>{
            new Map<String, Object>{'Amount'=>100, 'Name'=>'A'},
            new Map<String, Object>{'Amount'=>200, 'Name'=>'B'},
            new Map<String, Object>{'Amount'=>50, 'Name'=>'C'}
        }
    };
    r = DocGenService.processXmlForTest('<w:t>{SUM:Items.Amount}</w:t>', aggData);
    if (r.contains('350')) { pass++; System.debug('SUM AGGREGATE: PASS'); }
    else { fail++; System.debug('SUM AGGREGATE: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('SUM AGGREGATE: FAIL — ' + e.getMessage()); }

// ===== COUNT aggregate =====
try {
    Map<String, Object> aggData = new Map<String, Object>{
        'Items' => new List<Object>{
            new Map<String, Object>{'Amount'=>100},
            new Map<String, Object>{'Amount'=>200}
        }
    };
    r = DocGenService.processXmlForTest('<w:t>{COUNT:Items}</w:t>', aggData);
    if (r.contains('2')) { pass++; System.debug('COUNT AGGREGATE: PASS'); }
    else { fail++; System.debug('COUNT AGGREGATE: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('COUNT AGGREGATE: FAIL — ' + e.getMessage()); }

// ===== AVG aggregate =====
try {
    Map<String, Object> aggData = new Map<String, Object>{
        'Items' => new List<Object>{
            new Map<String, Object>{'Amount'=>100},
            new Map<String, Object>{'Amount'=>200},
            new Map<String, Object>{'Amount'=>300}
        }
    };
    r = DocGenService.processXmlForTest('<w:t>{AVG:Items.Amount}</w:t>', aggData);
    if (r.contains('200')) { pass++; System.debug('AVG AGGREGATE: PASS'); }
    else { fail++; System.debug('AVG AGGREGATE: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('AVG AGGREGATE: FAIL — ' + e.getMessage()); }

// ===== Nested conditional in loop =====
try {
    Map<String, Object> nestedData = new Map<String, Object>{
        'Items' => new List<Object>{
            new Map<String, Object>{'Name'=>'Active Item', 'IsActive'=>true},
            new Map<String, Object>{'Name'=>'Inactive Item', 'IsActive'=>false}
        }
    };
    r = DocGenService.processXmlForTest(
        '<w:t>{#Items}</w:t><w:t>{#IsActive}ACTIVE:{Name}{/IsActive}</w:t><w:t>{/Items}</w:t>', nestedData);
    if (r.contains('ACTIVE:Active Item') && !r.contains('ACTIVE:Inactive Item')) {
        pass++; System.debug('NESTED CONDITIONAL IN LOOP: PASS');
    } else { fail++; System.debug('NESTED CONDITIONAL IN LOOP: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('NESTED CONDITIONAL IN LOOP: FAIL — ' + e.getMessage()); }

// ===== Signature tag preserved =====
try {
    r = DocGenService.processXmlForTest('<w:t>{@Signature_Buyer}</w:t>', new Map<String, Object>{'Name'=>'Test'});
    if (r.contains('{@Signature_Buyer}')) { pass++; System.debug('SIGNATURE TAG PRESERVED: PASS'); }
    else { fail++; System.debug('SIGNATURE TAG PRESERVED: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('SIGNATURE TAG PRESERVED: FAIL — ' + e.getMessage()); }

// ===== Table row loop (content repeats) =====
try {
    Map<String, Object> tableData = new Map<String, Object>{
        'Rows' => new List<Object>{
            new Map<String, Object>{'Col1'=>'R1C1', 'Col2'=>'R1C2'},
            new Map<String, Object>{'Col1'=>'R2C1', 'Col2'=>'R2C2'}
        }
    };
    String tableXml = '<w:tbl>'
        + '<w:tr><w:tc><w:p><w:r><w:t>{#Rows}</w:t></w:r></w:p></w:tc></w:tr>'
        + '<w:tr><w:tc><w:p><w:r><w:t>{Col1}</w:t></w:r></w:p></w:tc>'
        + '<w:tc><w:p><w:r><w:t>{Col2}</w:t></w:r></w:p></w:tc></w:tr>'
        + '<w:tr><w:tc><w:p><w:r><w:t>{/Rows}</w:t></w:r></w:p></w:tc></w:tr>'
        + '</w:tbl>';
    r = DocGenService.processXmlForTest(tableXml, tableData);
    if (r.contains('R1C1') && r.contains('R2C1') && r.contains('R1C2') && r.contains('R2C2')) {
        pass++; System.debug('TABLE ROW LOOP: PASS');
    } else { fail++; System.debug('TABLE ROW LOOP: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('TABLE ROW LOOP: FAIL — ' + e.getMessage()); }

// ===== Empty loop (no items) =====
try {
    Map<String, Object> emptyLoop = new Map<String, Object>{
        'Items' => new List<Object>()
    };
    r = DocGenService.processXmlForTest('<w:t>{#Items}</w:t><w:t>{Name}</w:t><w:t>{/Items}</w:t>', emptyLoop);
    if (!r.contains('{Name}') && !r.contains('{#Items}')) { pass++; System.debug('EMPTY LOOP: PASS'); }
    else { fail++; System.debug('EMPTY LOOP: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('EMPTY LOOP: FAIL — ' + e.getMessage()); }

// ===== Multiple fields in one text node =====
try {
    r = DocGenService.processXmlForTest('<w:t>{First} {Last}</w:t>', new Map<String, Object>{'First'=>'John', 'Last'=>'Doe'});
    if (r.contains('John') && r.contains('Doe')) { pass++; System.debug('MULTI FIELD SINGLE NODE: PASS'); }
    else { fail++; System.debug('MULTI FIELD SINGLE NODE: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('MULTI FIELD SINGLE NODE: FAIL — ' + e.getMessage()); }

// ===== Locale formatting: currency:EUR =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Amt:currency:EUR}</w:t>', new Map<String, Object>{'Amt'=>1234.56});
    if (r.contains('\u20AC')) { pass++; System.debug('CURRENCY EUR: PASS'); }
    else { fail++; System.debug('CURRENCY EUR: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('CURRENCY EUR: FAIL — ' + e.getMessage()); }

// ===== currency:JPY zero decimal =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Amt:currency:JPY}</w:t>', new Map<String, Object>{'Amt'=>1234.56});
    if (r.contains('\u00A5') && !r.contains('.')) { pass++; System.debug('CURRENCY JPY: PASS'); }
    else { fail++; System.debug('CURRENCY JPY: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('CURRENCY JPY: FAIL — ' + e.getMessage()); }

// ===== number:de_DE =====
try {
    r = DocGenService.processXmlForTest('<w:t>{Qty:number:de_DE}</w:t>', new Map<String, Object>{'Qty'=>1234567});
    if (r.contains('1.234.567')) { pass++; System.debug('NUMBER de_DE: PASS'); }
    else { fail++; System.debug('NUMBER de_DE: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('NUMBER de_DE: FAIL — ' + e.getMessage()); }

// ===== SUM:Items.Amount:currency:GBP =====
try {
    Map<String, Object> ad = new Map<String, Object>{'Items' => new List<Object>{
        new Map<String, Object>{'Amount'=>1000}, new Map<String, Object>{'Amount'=>2000}}};
    r = DocGenService.processXmlForTest('<w:t>{SUM:Items.Amount:currency:GBP}</w:t>', ad);
    if (r.contains('\u00A3')) { pass++; System.debug('SUM GBP: PASS'); }
    else { fail++; System.debug('SUM GBP: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('SUM GBP: FAIL — ' + e.getMessage()); }

// ===== date:de_DE =====
try {
    r = DocGenService.processXmlForTest('<w:t>{D:date:de_DE}</w:t>', new Map<String, Object>{'D'=>DateTime.newInstance(2026,4,17,12,0,0)});
    if (r.contains('17.04.2026')) { pass++; System.debug('DATE de_DE: PASS'); }
    else { fail++; System.debug('DATE de_DE: FAIL — ' + r); }
} catch (Exception e) { fail++; System.debug('DATE de_DE: FAIL — ' + e.getMessage()); }

// ===== Textarea newline preserves formatting #32 =====
try {
    r = DocGenService.processXmlForTest('<w:r><w:rPr><w:sz w:val="28"/></w:rPr><w:t>{Desc}</w:t></w:r>', new Map<String, Object>{'Desc'=>'Line1\nLine2'});
    Integer brCount = r.countMatches('<w:sz w:val="28"/>');
    if (r.contains('w:br') && brCount >= 3 && r.contains('Line1') && r.contains('Line2')) { pass++; System.debug('TEXTAREA NEWLINE FMT: PASS'); }
    else { fail++; System.debug('TEXTAREA NEWLINE FMT: FAIL — szCount=' + brCount + ' — ' + r); }
} catch (Exception e) { fail++; System.debug('TEXTAREA NEWLINE FMT: FAIL — ' + e.getMessage()); }

System.debug('========================================');
System.debug('E2E-07 SYNTAX — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED'));
System.debug('========================================');
