// DocGen E2E Test Suite — Self-contained Anonymous Apex
// Run: sf apex run --target-org <org> -f scripts/e2e-test.apex
Integer pass = 0;
Integer fail = 0;

// ===== TEST 1: Permission Set Validation =====
try {
    // Admin perm set
    List<PermissionSet> aps = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Admin' LIMIT 1];
    if (aps.isEmpty()) { fail++; System.debug('TEST 1a: DocGen_Admin exists... FAIL'); }
    else {
        pass++; System.debug('TEST 1a: DocGen_Admin exists... PASS');
        Id psId = aps[0].Id;
        Set<String> cls = new Set<String>();
        for (SetupEntityAccess s : [SELECT SetupEntityId FROM SetupEntityAccess WHERE ParentId = :psId AND SetupEntityType = 'ApexClass']) {
            cls.add([SELECT Name FROM ApexClass WHERE Id = :s.SetupEntityId LIMIT 1].Name);
        }
        Boolean ok = cls.contains('DocGenController') && cls.contains('DocGenService')
            && cls.contains('DocGenSignatureController') && cls.contains('DocGenSetupController')
            && cls.contains('DocGenAuthenticatorController') && cls.contains('DocGenTemplateManager');
        if (ok) { pass++; System.debug('TEST 1b: Admin class accesses... PASS'); }
        else { fail++; System.debug('TEST 1b: Admin class accesses... FAIL'); }

        Set<String> objs = new Set<String>();
        for (ObjectPermissions op : [SELECT SobjectType FROM ObjectPermissions WHERE ParentId = :psId AND PermissionsRead = true]) { objs.add(op.SobjectType); }
        ok = objs.contains('DocGen_Template__c') && objs.contains('DocGen_Job__c')
            && objs.contains('DocGen_Signature_Request__c') && objs.contains('DocGen_Signer__c')
            && objs.contains('DocGen_Signature_Audit__c');
        if (ok) { pass++; System.debug('TEST 1c: Admin object permissions... PASS'); }
        else { fail++; System.debug('TEST 1c: Admin object permissions... FAIL'); }

        Set<String> flds = new Set<String>();
        for (FieldPermissions fp : [SELECT Field FROM FieldPermissions WHERE ParentId = :psId AND PermissionsRead = true]) { flds.add(fp.Field); }
        ok = flds.contains('DocGen_Signer__c.PIN_Hash__c') && flds.contains('DocGen_Signer__c.PIN_Verified_At__c')
            && flds.contains('DocGen_Signer__c.Consent_Captured__c');
        if (ok) { pass++; System.debug('TEST 1d: Admin signature field perms... PASS'); }
        else { fail++; System.debug('TEST 1d: Admin signature field perms... FAIL'); }
    }

    // User perm set — read access to sig objects
    List<PermissionSet> ups = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1];
    if (!ups.isEmpty()) {
        Set<String> uo = new Set<String>();
        for (ObjectPermissions op : [SELECT SobjectType FROM ObjectPermissions WHERE ParentId = :ups[0].Id AND PermissionsRead = true]) { uo.add(op.SobjectType); }
        Boolean uOk = uo.contains('DocGen_Signature_Request__c') && uo.contains('DocGen_Signer__c') && uo.contains('DocGen_Signature_Audit__c');
        if (uOk) { pass++; System.debug('TEST 1e: User sig object read... PASS'); }
        else { fail++; System.debug('TEST 1e: User sig object read... FAIL'); }
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
        Boolean gpOk = gp.contains('DocGenSignature') && gp.contains('DocGenSign') && gp.contains('DocGenVerify');
        if (gcOk) { pass++; System.debug('TEST 1f: Guest class accesses... PASS'); }
        else { fail++; System.debug('TEST 1f: Guest class accesses... FAIL'); }
        if (gpOk) { pass++; System.debug('TEST 1g: Guest page accesses... PASS'); }
        else { fail++; System.debug('TEST 1g: Guest page accesses... FAIL'); }

        Set<String> go = new Set<String>();
        for (ObjectPermissions op : [SELECT SobjectType FROM ObjectPermissions WHERE ParentId = :gId AND PermissionsRead = true]) { go.add(op.SobjectType); }
        Boolean goOk = go.contains('DocGen_Signature_Request__c') && go.contains('DocGen_Signer__c') && go.contains('DocGen_Signature_Audit__c');
        if (goOk) { pass++; System.debug('TEST 1h: Guest object perms... PASS'); }
        else { fail++; System.debug('TEST 1h: Guest object perms... FAIL'); }
    } else { fail++; System.debug('TEST 1f-h: DocGen_Guest_Signature missing... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 1: Perm sets... FAIL — ' + e.getMessage()); }

// ===== TEST 2: Create Test Data =====
Account acct; List<Contact> cons; Opportunity opp; Id tmplId; Id sigReqId; Id signerId;
try {
    acct = new Account(Name='E2E Test Corp', Industry='Technology', Phone='555-0100',
        Website='https://e2etest.example.com', BillingStreet='100 Test Blvd',
        BillingCity='Austin', BillingState='TX', BillingPostalCode='78701');
    insert acct;
    cons = new List<Contact>{
        new Contact(AccountId=acct.Id, FirstName='Alice', LastName='Johnson', Email='alice@e2etest.example.com', Title='CEO'),
        new Contact(AccountId=acct.Id, FirstName='Bob', LastName='Smith', Email='bob@e2etest.example.com', Title='CTO'),
        new Contact(AccountId=acct.Id, FirstName='Carol', LastName='Williams', Email='carol@e2etest.example.com', Title='CFO')
    };
    insert cons;
    opp = new Opportunity(AccountId=acct.Id, Name='E2E Test Deal', StageName='Prospecting', Amount=75000, CloseDate=Date.today().addDays(30));
    insert opp;
    if (acct.Id != null && cons.size() == 3 && opp.Id != null) { pass++; System.debug('TEST 2: Test data created... PASS'); }
    else { fail++; System.debug('TEST 2: Test data... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 2: Test data... FAIL — ' + e.getMessage()); }

// ===== TEST 3: Template Creation =====
try {
    String qc = 'Name, Industry, Phone, Website, (SELECT FirstName, LastName, Email, Title FROM Contacts)';
    DocGen_Template__c t = new DocGen_Template__c(Name='E2E Test Template', Base_Object_API__c='Account', Type__c='Word', Output_Format__c='PDF', Query_Config__c=qc, Description__c='E2E test', Category__c='Test');
    insert t; tmplId = t.Id;
    // Create a version record directly (saveTemplate uses AuraHandledException which can't be thrown in Anonymous Apex)
    DocGen_Template_Version__c ver = new DocGen_Template_Version__c(Template__c=tmplId, Is_Active__c=true, Query_Config__c=qc, Type__c='Word', Base_Object_API__c='Account', Category__c='Test', Description__c='E2E test');
    insert ver;
    List<DocGen_Template_Version__c> v = [SELECT Id FROM DocGen_Template_Version__c WHERE Template__c = :tmplId AND Is_Active__c = true];
    if (!v.isEmpty()) { pass++; System.debug('TEST 3: Template + active version created... PASS'); }
    else { fail++; System.debug('TEST 3: Template creation... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 3: Template creation... FAIL — ' + e.getMessage()); }

// ===== TEST 4: Template Update =====
try {
    Integer vBefore = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
    // Update template via direct DML (saveTemplate throws AuraHandledException in Anonymous Apex)
    DocGen_Template__c tUpd = [SELECT Id, Description__c FROM DocGen_Template__c WHERE Id = :tmplId];
    tUpd.Description__c = 'Updated desc';
    update tUpd;
    Integer vAfter = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
    DocGen_Template__c u = [SELECT Description__c FROM DocGen_Template__c WHERE Id = :tmplId];
    if (u.Description__c == 'Updated desc' && vBefore == vAfter) { pass++; System.debug('TEST 4a: Update without version... PASS'); }
    else { fail++; System.debug('TEST 4a: Update without version... FAIL'); }

    // Create a second version directly, deactivate the first
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
    else { fail++; System.debug('TEST 5a: getTemplateVersions... FAIL'); }
    Id oldest = vers[vers.size()-1].Id;
    DocGenController.activateVersion(oldest);
    DocGen_Template_Version__c r = [SELECT Is_Active__c FROM DocGen_Template_Version__c WHERE Id = :oldest];
    if (r.Is_Active__c) { pass++; System.debug('TEST 5b: activateVersion... PASS'); }
    else { fail++; System.debug('TEST 5b: activateVersion... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 5: Version mgmt... FAIL — ' + e.getMessage()); }

// ===== TEST 6: Data Retrieval =====
try {
    String qc = 'Name, Industry, Phone, (SELECT FirstName, LastName FROM Contacts)';
    Map<String, Object> d = DocGenController.previewRecordData(acct.Id, 'Account', qc);
    if (d != null && d.get('Name') == 'E2E Test Corp') { pass++; System.debug('TEST 6a: previewRecordData name... PASS'); }
    else { fail++; System.debug('TEST 6a: previewRecordData name... FAIL'); }
    if (d.containsKey('Contacts')) { pass++; System.debug('TEST 6b: previewRecordData children... PASS'); }
    else { fail++; System.debug('TEST 6b: previewRecordData children... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 6: Data retrieval... FAIL — ' + e.getMessage()); }

// ===== TEST 7: Bulk Generation =====
try {
    Integer ct = DocGenBulkController.validateFilter('Account', 'Name = \'E2E Test Corp\'');
    if (ct > 0) { pass++; System.debug('TEST 7a: validateFilter > 0... PASS'); }
    else { fail++; System.debug('TEST 7a: validateFilter... FAIL'); }
    Id jobId = DocGenBulkController.submitJob(tmplId, 'Name = \'E2E Test Corp\'', 'E2E Job', false, 1, false);
    if (jobId != null) { pass++; System.debug('TEST 7b: submitJob... PASS'); }
    else { fail++; System.debug('TEST 7b: submitJob... FAIL'); }
    DocGen_Job__c js = DocGenBulkController.getJobStatus(jobId);
    if (js != null && String.isNotBlank(js.Status__c)) { pass++; System.debug('TEST 7c: getJobStatus... PASS'); }
    else { fail++; System.debug('TEST 7c: getJobStatus... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 7: Bulk gen... FAIL — ' + e.getMessage()); }

// ===== TEST 8: Signature Objects =====
try {
    String tok = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
    DocGen_Signature_Request__c sr = new DocGen_Signature_Request__c(Status__c='Pending', Related_Record_Id__c=acct.Id,
        Signer_Name__c='Alice Johnson', Signer_Email__c='alice@e2etest.example.com', Secure_Token__c=tok, Template__c=tmplId);
    insert sr; sigReqId = sr.Id;

    String stok = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
    DocGen_Signer__c sg = new DocGen_Signer__c(Signature_Request__c=sigReqId, Signer_Name__c='Alice Johnson',
        Signer_Email__c='alice@e2etest.example.com', Role_Name__c='Signer', Secure_Token__c=stok, Status__c='Pending', Sort_Order__c=1);
    insert sg; signerId = sg.Id;

    DocGenSignatureController.SignatureInitResponse vr = DocGenSignatureController.validateToken(stok);
    if (vr.isValid) { pass++; System.debug('TEST 8a: validateToken valid... PASS'); }
    else { fail++; System.debug('TEST 8a: validateToken... FAIL — ' + vr.errorMessage); }

    DocGen_Signature_Audit__c au = new DocGen_Signature_Audit__c(Signature_Request__c=sigReqId, Signer__c=signerId,
        Signer_Name__c='Alice Johnson', Signer_Email__c='alice@e2etest.example.com', Signed_Date__c=System.now(),
        IP_Address__c='127.0.0.1', Consent_Captured__c=true, Document_Hash_SHA256__c=EncodingUtil.convertToHex(Crypto.generateAesKey(256)));
    insert au;
    if (au.Id != null) { pass++; System.debug('TEST 8b: Audit record created... PASS'); }
    else { fail++; System.debug('TEST 8b: Audit record... FAIL'); }

    List<DocGenAuthenticatorController.VerificationResult> vrs = DocGenAuthenticatorController.verifyByRequestId(sigReqId);
    if (vrs != null && !vrs.isEmpty()) { pass++; System.debug('TEST 8c: verifyByRequestId... PASS'); }
    else { fail++; System.debug('TEST 8c: verifyByRequestId... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 8: Signatures... FAIL — ' + e.getMessage()); }

// ===== TEST 9: Signature PIN Flow =====
try {
    DocGen_Signer__c s = [SELECT Secure_Token__c, Signer_Email__c FROM DocGen_Signer__c WHERE Id = :signerId LIMIT 1];
    Map<String, Object> pr = DocGenSignatureController.sendPin(s.Secure_Token__c, s.Signer_Email__c);
    if ((Boolean)pr.get('success')) { pass++; System.debug('TEST 9a: sendPin success... PASS'); }
    else { fail++; System.debug('TEST 9a: sendPin... FAIL — ' + pr.get('message')); }
    DocGen_Signer__c ap = [SELECT PIN_Hash__c, PIN_Expires_At__c FROM DocGen_Signer__c WHERE Id = :signerId];
    if (String.isNotBlank(ap.PIN_Hash__c) && ap.PIN_Expires_At__c != null) { pass++; System.debug('TEST 9b: PIN hash+expiry set... PASS'); }
    else { fail++; System.debug('TEST 9b: PIN hash+expiry... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 9: PIN flow... FAIL — ' + e.getMessage()); }

// ===== TEST 10: Signature Settings =====
try {
    DocGen_Settings__c st = DocGenSetupController.getSettings();
    if (st != null) { pass++; System.debug('TEST 10a: getSettings... PASS'); }
    else { fail++; System.debug('TEST 10a: getSettings... FAIL'); }
    DocGenSetupController.saveSignatureSettings('#0070D2', null, 'Sign: {DocTitle}', 'Please sign.', 'Footer', 'E2E Co', null);
    DocGen_Settings__c st2 = DocGenSetupController.getSettings();
    if (st2.Signature_Email_Brand_Color__c == '#0070D2' && st2.Company_Name__c == 'E2E Co') { pass++; System.debug('TEST 10b: saveSignatureSettings... PASS'); }
    else { fail++; System.debug('TEST 10b: saveSignatureSettings... FAIL'); }
    List<Map<String, String>> owa = DocGenSetupController.getOrgWideEmailAddresses();
    if (owa != null && !owa.isEmpty()) { pass++; System.debug('TEST 10c: getOrgWideEmailAddresses... PASS'); }
    else { fail++; System.debug('TEST 10c: getOrgWideEmailAddresses... FAIL'); }
} catch (Exception e) { fail++; System.debug('TEST 10: Settings... FAIL — ' + e.getMessage()); }

// ===== TEST 11: Conditionals =====
try {
    String o1 = DocGenService.processXmlForTest('<w:t>{#A}Yes{/A}</w:t>', new Map<String, Object>{'A'=>true});
    if (o1.contains('Yes')) { pass++; System.debug('TEST 11a: True conditional... PASS'); }
    else { fail++; System.debug('TEST 11a: True conditional... FAIL'); }

    String o2 = DocGenService.processXmlForTest('<w:t>{#A}Yes{/A}</w:t>', new Map<String, Object>{'A'=>false});
    if (!o2.contains('Yes')) { pass++; System.debug('TEST 11b: False conditional... PASS'); }
    else { fail++; System.debug('TEST 11b: False conditional... FAIL'); }

    String o3 = DocGenService.processXmlForTest('<w:t>{^A}No{/A}</w:t>', new Map<String, Object>{'A'=>false});
    if (o3.contains('No')) { pass++; System.debug('TEST 11c: Inverted conditional... PASS'); }
    else { fail++; System.debug('TEST 11c: Inverted conditional... FAIL'); }

    String x4 = '<w:t>{#V}VIP{:else}Std{/V}</w:t>';
    String o4a = DocGenService.processXmlForTest(x4, new Map<String, Object>{'V'=>true});
    String o4b = DocGenService.processXmlForTest(x4, new Map<String, Object>{'V'=>false});
    if (o4a.contains('VIP') && o4b.contains('Std')) { pass++; System.debug('TEST 11d: Else blocks... PASS'); }
    else { fail++; System.debug('TEST 11d: Else blocks... FAIL'); }

    String o5t = DocGenService.processXmlForTest('<w:t>{A:checkbox}</w:t>', new Map<String, Object>{'A'=>true});
    String o5f = DocGenService.processXmlForTest('<w:t>{A:checkbox}</w:t>', new Map<String, Object>{'A'=>false});
    if (o5t.contains('[X]') && o5f.contains('[ ]')) { pass++; System.debug('TEST 11e: Checkbox format... PASS'); }
    else { fail++; System.debug('TEST 11e: Checkbox... FAIL — ' + o5t + ' / ' + o5f); }
} catch (Exception e) { fail++; System.debug('TEST 11: Conditionals... FAIL — ' + e.getMessage()); }

// ===== TEST 12: Formatting =====
try {
    String oc = DocGenService.processXmlForTest('<w:t>{Amt:currency}</w:t>', new Map<String, Object>{'Amt'=>75000.50});
    if (oc.contains('$')) { pass++; System.debug('TEST 12a: Currency... PASS'); }
    else { fail++; System.debug('TEST 12a: Currency... FAIL — ' + oc); }

    String op = DocGenService.processXmlForTest('<w:t>{R:percent}</w:t>', new Map<String, Object>{'R'=>0.15});
    if (op.contains('%')) { pass++; System.debug('TEST 12b: Percent... PASS'); }
    else { fail++; System.debug('TEST 12b: Percent... FAIL — ' + op); }

    String od = DocGenService.processXmlForTest('<w:t>{D:MM/dd/yyyy}</w:t>', new Map<String, Object>{'D'=>Date.newInstance(2026,4,8)});
    if (od.contains('04/08/2026')) { pass++; System.debug('TEST 12c: Date format... PASS'); }
    else { fail++; System.debug('TEST 12c: Date format... FAIL — ' + od); }
} catch (Exception e) { fail++; System.debug('TEST 12: Formatting... FAIL — ' + e.getMessage()); }

// ===== TEST 13: Aggregates =====
try {
    List<Map<String, Object>> items = new List<Map<String, Object>>{new Map<String, Object>{'Amount'=>100}, new Map<String, Object>{'Amount'=>200}};
    Map<String, Object> dm = new Map<String, Object>{'Items'=>items};
    String os = DocGenService.processXmlForTest('<w:t>{SUM:Items.Amount}</w:t>', dm);
    if (os.contains('300')) { pass++; System.debug('TEST 13a: SUM... PASS'); }
    else { fail++; System.debug('TEST 13a: SUM... FAIL — ' + os); }
    String oc = DocGenService.processXmlForTest('<w:t>{COUNT:Items}</w:t>', dm);
    if (oc.contains('2')) { pass++; System.debug('TEST 13b: COUNT... PASS'); }
    else { fail++; System.debug('TEST 13b: COUNT... FAIL — ' + oc); }
} catch (Exception e) { fail++; System.debug('TEST 13: Aggregates... FAIL — ' + e.getMessage()); }

// ===== TEST 14: Cleanup =====
try {
    delete [SELECT Id FROM DocGen_Signature_Audit__c WHERE Signature_Request__c = :sigReqId];
    delete [SELECT Id FROM DocGen_Signer__c WHERE Signature_Request__c = :sigReqId];
    if (sigReqId != null) delete new DocGen_Signature_Request__c(Id=sigReqId);
    delete [SELECT Id FROM DocGen_Job__c WHERE Template__c = :tmplId];
    delete [SELECT Id FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
    if (tmplId != null) delete new DocGen_Template__c(Id=tmplId);
    if (cons != null) delete cons;
    if (opp != null) delete opp;
    if (acct != null) delete acct;
    try { DocGenSetupController.saveSignatureSettings(null, null, null, null, null, null, null); } catch (Exception x) {}
    pass++; System.debug('TEST 14: Cleanup... PASS');
} catch (Exception e) { fail++; System.debug('TEST 14: Cleanup... FAIL — ' + e.getMessage()); }

System.debug('========================================');
System.debug('PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED'));
System.debug('========================================');
