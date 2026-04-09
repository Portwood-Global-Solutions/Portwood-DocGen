// DocGen E2E Test Script — Comprehensive Pipeline Validation
// Run: sf apex run --target-org <org> -f scripts/e2e-test.apex
// Expected: PASS: N  FAIL: 0  ALL TESTS PASSED

Integer pass = 0;
Integer fail = 0;
Id acctId; Id tmplId; Id sigReqId; Id signerId; Id jobId;
String signerToken;

// Helper: check if a set contains a value with or without namespace prefix
Boolean containsNs(Set<String> s, String val) {
    return s.contains(val) || s.contains('portwoodglobal__' + val);
}

// ===== TEST 1: Permission Set Validation =====
try {
    List<PermissionSet> aps = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Admin' LIMIT 1];
    if (aps.isEmpty()) { fail++; System.debug('TEST 1a: DocGen_Admin exists... FAIL'); }
    else {
        pass++; System.debug('TEST 1a: DocGen_Admin exists... PASS');
        Id psId = aps[0].Id;

        // Class accesses
        Set<String> cls = new Set<String>();
        for (SetupEntityAccess s : [SELECT SetupEntityId FROM SetupEntityAccess WHERE ParentId = :psId AND SetupEntityType = 'ApexClass']) {
            cls.add([SELECT Name FROM ApexClass WHERE Id = :s.SetupEntityId LIMIT 1].Name);
        }
        Boolean ok = cls.contains('DocGenController') && cls.contains('DocGenService') && cls.contains('DocGenSignatureController');
        if (ok) { pass++; System.debug('TEST 1b: Admin class accesses... PASS'); }
        else { fail++; System.debug('TEST 1b: Admin class accesses... FAIL — found: ' + cls); }

        // Object permissions — check with and without namespace
        Set<String> objs = new Set<String>();
        for (ObjectPermissions op : [SELECT SobjectType FROM ObjectPermissions WHERE ParentId = :psId AND PermissionsRead = true]) { objs.add(op.SobjectType); }
        ok = containsNs(objs, 'DocGen_Template__c') && containsNs(objs, 'DocGen_Job__c')
            && containsNs(objs, 'DocGen_Signature_Request__c') && containsNs(objs, 'DocGen_Signer__c');
        if (ok) { pass++; System.debug('TEST 1c: Admin object permissions... PASS'); }
        else { fail++; System.debug('TEST 1c: Admin object permissions... FAIL — found: ' + objs); }

        // Signature field permissions — check with and without namespace
        Set<String> flds = new Set<String>();
        for (FieldPermissions fp : [SELECT Field FROM FieldPermissions WHERE ParentId = :psId AND PermissionsRead = true]) { flds.add(fp.Field); }
        ok = containsNs(flds, 'DocGen_Signer__c.PIN_Hash__c') || containsNs(flds, 'DocGen_Signer__c.portwoodglobal__PIN_Hash__c')
            || flds.contains('portwoodglobal__DocGen_Signer__c.portwoodglobal__PIN_Hash__c');
        if (ok) { pass++; System.debug('TEST 1d: Admin signature field perms... PASS'); }
        else { fail++; System.debug('TEST 1d: Admin signature field perms... FAIL — sample: ' + (flds.size() > 0 ? new List<String>(flds)[0] : 'empty')); }
    }

    // User perm set
    List<PermissionSet> ups = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1];
    if (!ups.isEmpty()) {
        Set<String> uo = new Set<String>();
        for (ObjectPermissions op : [SELECT SobjectType FROM ObjectPermissions WHERE ParentId = :ups[0].Id AND PermissionsRead = true]) { uo.add(op.SobjectType); }
        Boolean uOk = containsNs(uo, 'DocGen_Signature_Request__c') && containsNs(uo, 'DocGen_Signer__c');
        if (uOk) { pass++; System.debug('TEST 1e: User sig object read... PASS'); }
        else { fail++; System.debug('TEST 1e: User sig object read... FAIL — found: ' + uo); }
    } else { fail++; System.debug('TEST 1e: DocGen_User missing... FAIL'); }

    // Guest perm set
    List<PermissionSet> gps = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Guest_Signature' LIMIT 1];
    if (!gps.isEmpty()) {
        Id gId = gps[0].Id;
        Set<String> gc = new Set<String>();
        Set<String> gp = new Set<String>();
        for (SetupEntityAccess s : [SELECT SetupEntityId, SetupEntityType FROM SetupEntityAccess WHERE ParentId = :gId]) {
            if (s.SetupEntityType == 'ApexClass') { gc.add([SELECT Name FROM ApexClass WHERE Id = :s.SetupEntityId LIMIT 1].Name); }
            if (s.SetupEntityType == 'ApexPage') { gp.add([SELECT Name FROM ApexPage WHERE Id = :s.SetupEntityId LIMIT 1].Name); }
        }
        Boolean gcOk = gc.contains('DocGenSignatureController') && gc.contains('DocGenAuthenticatorController');
        if (gcOk) { pass++; System.debug('TEST 1f: Guest class accesses... PASS'); }
        else { fail++; System.debug('TEST 1f: Guest class accesses... FAIL — found: ' + gc); }
        Boolean gpOk = gp.contains('DocGenSignature') && gp.contains('DocGenSign') && gp.contains('DocGenVerify');
        if (gpOk) { pass++; System.debug('TEST 1g: Guest page accesses... PASS'); }
        else { fail++; System.debug('TEST 1g: Guest page accesses... FAIL — found: ' + gp); }

        Set<String> go2 = new Set<String>();
        for (ObjectPermissions op : [SELECT SobjectType FROM ObjectPermissions WHERE ParentId = :gId AND PermissionsRead = true]) { go2.add(op.SobjectType); }
        Boolean goOk = containsNs(go2, 'DocGen_Signature_Request__c') && containsNs(go2, 'DocGen_Signer__c');
        if (goOk) { pass++; System.debug('TEST 1h: Guest object perms... PASS'); }
        else { fail++; System.debug('TEST 1h: Guest object perms... FAIL — found: ' + go2); }
    } else { fail++; System.debug('TEST 1f-h: DocGen_Guest_Signature missing... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 1: Perm sets... FAIL — ' + e.getMessage()); }

// ===== TEST 2: Create Test Data =====
Account acct;
List<Contact> cons;
Opportunity opp;
try {
    acct = new Account(Name='E2E Test Corp', Industry='Technology', Phone='555-0100', Website='https://e2etest.example.com',
        BillingStreet='123 Test St', BillingCity='Indianapolis', BillingState='IN', BillingPostalCode='46204');
    insert acct; acctId = acct.Id;
    cons = new List<Contact>{
        new Contact(FirstName='Alice', LastName='Johnson', Email='alice@e2etest.example.com', Title='CEO', AccountId=acctId),
        new Contact(FirstName='Bob', LastName='Smith', Email='bob@e2etest.example.com', Title='CTO', AccountId=acctId),
        new Contact(FirstName='Carol', LastName='Davis', Email='carol@e2etest.example.com', Title='CFO', AccountId=acctId)
    };
    insert cons;
    opp = new Opportunity(Name='E2E Test Opp', StageName='Prospecting', Amount=75000, CloseDate=Date.today().addDays(30), AccountId=acctId);
    insert opp;
    if (acct.Id != null && cons.size() == 3 && opp.Id != null) { pass++; System.debug('TEST 2: Test data created... PASS'); }
    else { fail++; System.debug('TEST 2: Test data... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 2: Test data... FAIL — ' + e.getMessage()); }

// ===== TEST 3: Template Creation =====
try {
    String qc = 'Name, Industry, Phone, Website, (SELECT FirstName, LastName, Email, Title FROM Contacts)';
    DocGen_Template__c t = new DocGen_Template__c(Name='E2E Test Template', Base_Object_API__c='Account', Type__c='Word', Output_Format__c='PDF', Query_Config__c=qc, Description__c='E2E test', Category__c='Test');
    insert t; tmplId = t.Id;
    DocGen_Template_Version__c ver = new DocGen_Template_Version__c(Template__c=tmplId, Is_Active__c=true, Query_Config__c=qc, Type__c='Word', Base_Object_API__c='Account', Category__c='Test', Description__c='E2E test');
    insert ver;
    List<DocGen_Template_Version__c> v = [SELECT Id FROM DocGen_Template_Version__c WHERE Template__c = :tmplId AND Is_Active__c = true];
    if (!v.isEmpty()) { pass++; System.debug('TEST 3: Template + active version created... PASS'); }
    else { fail++; System.debug('TEST 3: Template creation... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 3: Template creation... FAIL — ' + e.getMessage()); }

// ===== TEST 4: Template Update =====
try {
    Integer vBefore = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
    DocGen_Template__c tUpd = [SELECT Id, Description__c FROM DocGen_Template__c WHERE Id = :tmplId];
    tUpd.Description__c = 'Updated desc';
    update tUpd;
    Integer vAfter = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
    DocGen_Template__c u = [SELECT Description__c FROM DocGen_Template__c WHERE Id = :tmplId];
    if (u.Description__c == 'Updated desc' && vBefore == vAfter) { pass++; System.debug('TEST 4a: Update without version... PASS'); }
    else { fail++; System.debug('TEST 4a: Update without version... FAIL'); }

    List<DocGen_Template_Version__c> actVers = [SELECT Id FROM DocGen_Template_Version__c WHERE Template__c = :tmplId AND Is_Active__c = true];
    for (DocGen_Template_Version__c av : actVers) { av.Is_Active__c = false; }
    if (!actVers.isEmpty()) { update actVers; }
    DocGen_Template_Version__c ver2 = new DocGen_Template_Version__c(Template__c=tmplId, Is_Active__c=true, Query_Config__c='Name, Industry', Type__c='Word', Base_Object_API__c='Account');
    insert ver2;
    Integer vNew = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
    Integer activeCount = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tmplId AND Is_Active__c = true];
    if (vNew == vAfter + 1 && activeCount == 1) { pass++; System.debug('TEST 4b: New version, old deactivated... PASS'); }
    else { fail++; System.debug('TEST 4b: New version... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 4: Template update... FAIL — ' + e.getMessage()); }

// ===== TEST 5: Version Management =====
try {
    List<DocGen_Template_Version__c> vers = DocGenController.getTemplateVersions(tmplId);
    if (vers != null && vers.size() >= 2) { pass++; System.debug('TEST 5a: getTemplateVersions >= 2... PASS'); }
    else { fail++; System.debug('TEST 5a: getTemplateVersions... FAIL — count: ' + (vers != null ? vers.size() : 0)); }

    DocGenController.activateVersion(vers[0].Id);
    DocGen_Template_Version__c r = [SELECT Is_Active__c FROM DocGen_Template_Version__c WHERE Id = :vers[0].Id];
    if (r.Is_Active__c) { pass++; System.debug('TEST 5b: activateVersion... PASS'); }
    else { fail++; System.debug('TEST 5b: activateVersion... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 5: Version mgmt... FAIL — ' + e.getMessage()); }

// ===== TEST 6: Data Retrieval =====
try {
    Map<String, Object> d = DocGenController.previewRecordData(acctId, 'Account', 'Name, Industry, (SELECT FirstName, LastName FROM Contacts)');
    if (d != null && d.get('Name') == 'E2E Test Corp') { pass++; System.debug('TEST 6a: previewRecordData name... PASS'); }
    else { fail++; System.debug('TEST 6a: previewRecordData name... FAIL — ' + d); }
    if (d.containsKey('Contacts')) { pass++; System.debug('TEST 6b: previewRecordData children... PASS'); }
    else { fail++; System.debug('TEST 6b: previewRecordData children... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 6: Data retrieval... FAIL — ' + e.getMessage()); }

// ===== TEST 7: Bulk Generation =====
try {
    Integer ct = DocGenBulkController.validateFilter('Account', 'Name = \'E2E Test Corp\'');
    if (ct > 0) { pass++; System.debug('TEST 7a: validateFilter > 0... PASS'); }
    else { fail++; System.debug('TEST 7a: validateFilter... FAIL — count: ' + ct); }

    jobId = DocGenBulkController.submitJob(tmplId, 'Name = \'E2E Test Corp\'', 'E2E Test Job', false, 1, false);
    if (jobId != null) { pass++; System.debug('TEST 7b: submitJob... PASS'); }
    else { fail++; System.debug('TEST 7b: submitJob... FAIL'); }

    DocGen_Job__c j = DocGenBulkController.getJobStatus(jobId);
    if (j != null && j.Status__c != null) { pass++; System.debug('TEST 7c: getJobStatus... PASS'); }
    else { fail++; System.debug('TEST 7c: getJobStatus... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 7: Bulk gen... FAIL — ' + e.getMessage()); }

// ===== TEST 8: Signature Objects =====
try {
    signerToken = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
    DocGen_Signature_Request__c sr = new DocGen_Signature_Request__c(
        Status__c='Sent', Related_Record_Id__c=acctId, Template__c=tmplId,
        Signer_Name__c='Alice Johnson', Signer_Email__c='alice@e2etest.example.com');
    insert sr; sigReqId = sr.Id;

    DocGen_Signer__c sg = new DocGen_Signer__c(
        Signature_Request__c=sigReqId, Signer_Name__c='Alice Johnson',
        Signer_Email__c='alice@e2etest.example.com', Role_Name__c='Signer',
        Secure_Token__c=signerToken, Status__c='Pending', Sort_Order__c=1);
    insert sg; signerId = sg.Id;

    DocGenSignatureController.SignatureInitResponse vr = DocGenSignatureController.validateToken(signerToken);
    if (vr.isValid) { pass++; System.debug('TEST 8a: validateToken valid... PASS'); }
    else { fail++; System.debug('TEST 8a: validateToken... FAIL — ' + vr.errorMessage); }

    DocGen_Signature_Audit__c au = new DocGen_Signature_Audit__c(
        Signature_Request__c=sigReqId, Signer__c=signerId,
        Signer_Name__c='Alice Johnson', Signer_Email__c='alice@e2etest.example.com',
        Signed_Date__c=System.now(), IP_Address__c='127.0.0.1', Consent_Captured__c=true,
        Document_Hash_SHA256__c=EncodingUtil.convertToHex(Crypto.generateAesKey(256)));
    insert au;
    if (au.Id != null) { pass++; System.debug('TEST 8b: Audit record created... PASS'); }
    else { fail++; System.debug('TEST 8b: Audit record... FAIL'); }

    List<DocGenAuthenticatorController.VerificationResult> vrs = DocGenAuthenticatorController.verifyByRequestId(sigReqId);
    if (vrs != null && !vrs.isEmpty()) { pass++; System.debug('TEST 8c: verifyByRequestId... PASS'); }
    else { fail++; System.debug('TEST 8c: verifyByRequestId... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 8: Signatures... FAIL — ' + e.getMessage()); }

// ===== TEST 9: Signature PIN Flow =====
try {
    Map<String, Object> pinResult = DocGenSignatureController.sendPin(signerToken, 'alice@e2etest.example.com');
    if ((Boolean)pinResult.get('success')) { pass++; System.debug('TEST 9a: sendPin success... PASS'); }
    else { fail++; System.debug('TEST 9a: sendPin... FAIL — ' + pinResult.get('message')); }

    DocGen_Signer__c sg2 = [SELECT PIN_Hash__c, PIN_Expires_At__c FROM DocGen_Signer__c WHERE Id = :signerId];
    if (sg2.PIN_Hash__c != null && sg2.PIN_Expires_At__c != null) { pass++; System.debug('TEST 9b: PIN hash + expiry set... PASS'); }
    else { fail++; System.debug('TEST 9b: PIN fields... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 9: PIN flow... FAIL — ' + e.getMessage()); }

// ===== TEST 10: Settings =====
try {
    DocGen_Settings__c s = DocGenSetupController.getSettings();
    if (s != null) { pass++; System.debug('TEST 10a: getSettings... PASS'); }
    else { fail++; System.debug('TEST 10a: getSettings... FAIL'); }

    DocGenSetupController.saveSignatureSettings('#FF0000', null, null, null, null, 'E2E Corp', '');
    DocGen_Settings__c s2 = DocGenSetupController.getSettings();
    if (s2.Signature_Email_Brand_Color__c == '#FF0000' && s2.Company_Name__c == 'E2E Corp') { pass++; System.debug('TEST 10b: saveSignatureSettings... PASS'); }
    else { fail++; System.debug('TEST 10b: saveSignatureSettings... FAIL'); }

    List<Map<String, String>> owas = DocGenSetupController.getOrgWideEmailAddresses();
    if (owas != null && !owas.isEmpty()) { pass++; System.debug('TEST 10c: getOrgWideEmailAddresses... PASS'); }
    else { fail++; System.debug('TEST 10c: OWAs... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 10: Settings... FAIL — ' + e.getMessage()); }

// ===== TEST 11: Conditional Logic =====
try {
    String r1 = DocGenService.processXmlForTest('<w:t>{#IsVIP}VIP{/IsVIP}</w:t>', new Map<String, Object>{'IsVIP'=>true});
    if (r1.contains('VIP')) { pass++; System.debug('TEST 11a: True conditional... PASS'); }
    else { fail++; System.debug('TEST 11a: True conditional... FAIL — ' + r1); }

    String r2 = DocGenService.processXmlForTest('<w:t>{#IsVIP}VIP{/IsVIP}</w:t>', new Map<String, Object>{'IsVIP'=>false});
    if (!r2.contains('VIP')) { pass++; System.debug('TEST 11b: False conditional... PASS'); }
    else { fail++; System.debug('TEST 11b: False conditional... FAIL — ' + r2); }

    String r3 = DocGenService.processXmlForTest('<w:t>{^IsVIP}Standard{/IsVIP}</w:t>', new Map<String, Object>{'IsVIP'=>false});
    if (r3.contains('Standard')) { pass++; System.debug('TEST 11c: Inverted conditional... PASS'); }
    else { fail++; System.debug('TEST 11c: Inverted... FAIL — ' + r3); }

    String r4 = DocGenService.processXmlForTest('<w:t>{#IsVIP}VIP{:else}Standard{/IsVIP}</w:t>', new Map<String, Object>{'IsVIP'=>false});
    if (r4.contains('Standard') && !r4.contains('VIP')) { pass++; System.debug('TEST 11d: Else blocks... PASS'); }
    else { fail++; System.debug('TEST 11d: Else... FAIL — ' + r4); }

    String r5 = DocGenService.processXmlForTest('<w:t>{Active:checkbox}</w:t>', new Map<String, Object>{'Active'=>true});
    String r6 = DocGenService.processXmlForTest('<w:t>{Active:checkbox}</w:t>', new Map<String, Object>{'Active'=>false});
    if (r5.contains('[X]') && r6.contains('[ ]')) { pass++; System.debug('TEST 11e: Checkbox format... PASS'); }
    else { fail++; System.debug('TEST 11e: Checkbox... FAIL — true=' + r5 + ' false=' + r6); }

    String r7 = DocGenService.processXmlForTest('<w:t>{#IF Amt > 50000}Big{/IF}</w:t>', new Map<String, Object>{'Amt'=>75000});
    if (r7.contains('Big')) { pass++; System.debug('TEST 11f: IF comparison... PASS'); }
    else { fail++; System.debug('TEST 11f: IF comparison... FAIL — ' + r7); }

    String r8 = DocGenService.processXmlForTest('<w:t>{#IF Stage = \'Won\'}Closed{:else}Open{/IF}</w:t>', new Map<String, Object>{'Stage'=>'Lost'});
    if (r8.contains('Open') && !r8.contains('Closed')) { pass++; System.debug('TEST 11g: IF with else... PASS'); }
    else { fail++; System.debug('TEST 11g: IF else... FAIL — ' + r8); }
} catch (Exception e) { fail++; System.debug('TEST 11: Conditionals... FAIL — ' + e.getMessage()); }

// ===== TEST 12: Formatting =====
try {
    String oc = DocGenService.processXmlForTest('<w:t>{Amt:currency}</w:t>', new Map<String, Object>{'Amt'=>75000.50});
    if (oc.contains('$')) { pass++; System.debug('TEST 12a: Currency... PASS'); }
    else { fail++; System.debug('TEST 12a: Currency... FAIL — ' + oc); }

    String op = DocGenService.processXmlForTest('<w:t>{R:percent}</w:t>', new Map<String, Object>{'R'=>15.5});
    if (op.contains('%')) { pass++; System.debug('TEST 12b: Percent... PASS'); }
    else { fail++; System.debug('TEST 12b: Percent... FAIL — ' + op); }

    // Use DateTime to avoid timezone date shift
    String od = DocGenService.processXmlForTest('<w:t>{D:MM/dd/yyyy}</w:t>', new Map<String, Object>{'D'=>DateTime.newInstance(2026, 4, 8, 12, 0, 0)});
    if (od.contains('04/08/2026')) { pass++; System.debug('TEST 12c: Date format... PASS'); }
    else { fail++; System.debug('TEST 12c: Date format... FAIL — ' + od); }
} catch (Exception e) { fail++; System.debug('TEST 12: Formatting... FAIL — ' + e.getMessage()); }

// ===== TEST 13: Aggregates =====
try {
    Map<String, Object> aggData = new Map<String, Object>{
        'Items' => new List<Object>{
            new Map<String, Object>{'Amount'=>100, 'Name'=>'A'},
            new Map<String, Object>{'Amount'=>200, 'Name'=>'B'}
        }
    };
    String s1 = DocGenService.processXmlForTest('<w:t>{SUM:Items.Amount}</w:t>', aggData);
    if (s1.contains('300')) { pass++; System.debug('TEST 13a: SUM... PASS'); }
    else { fail++; System.debug('TEST 13a: SUM... FAIL — ' + s1); }

    String s2 = DocGenService.processXmlForTest('<w:t>{COUNT:Items}</w:t>', aggData);
    if (s2.contains('2')) { pass++; System.debug('TEST 13b: COUNT... PASS'); }
    else { fail++; System.debug('TEST 13b: COUNT... FAIL — ' + s2); }
} catch (Exception e) { fail++; System.debug('TEST 13: Aggregates... FAIL — ' + e.getMessage()); }

// ===== TEST 14: Cleanup =====
try {
    delete [SELECT Id FROM DocGen_Signature_Audit__c WHERE Signature_Request__c = :sigReqId];
    delete [SELECT Id FROM DocGen_Signer__c WHERE Signature_Request__c = :sigReqId];
    delete [SELECT Id FROM DocGen_Signature_Request__c WHERE Id = :sigReqId];
    if (jobId != null) { delete [SELECT Id FROM DocGen_Job__c WHERE Id = :jobId]; }
    delete [SELECT Id FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
    delete [SELECT Id FROM DocGen_Template__c WHERE Id = :tmplId];
    delete [SELECT Id FROM Opportunity WHERE AccountId = :acctId];
    delete [SELECT Id FROM Contact WHERE AccountId = :acctId];
    delete [SELECT Id FROM Account WHERE Id = :acctId];
    // Reset signature settings
    DocGenSetupController.saveSignatureSettings(null, null, null, null, null, null, '');
    pass++; System.debug('TEST 14: Cleanup... PASS');
} catch (Exception e) { fail++; System.debug('TEST 14: Cleanup... FAIL — ' + e.getMessage()); }

System.debug('========================================');
System.debug('PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED'));
System.debug('========================================');
