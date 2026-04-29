// DocGen E2E Test 01 — Permission Set Validation
// Run: sf apex run --target-org <org> -f scripts/e2e-01-permissions.apex
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;

Boolean containsNs(Set<String> s, String val) {
    return s.contains(val) || s.contains('portwoodglobal__' + val);
}

// ===== DocGen_Admin Permission Set =====
try {
    List<PermissionSet> aps = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Admin' LIMIT 1];
    if (aps.isEmpty()) {
        fail++;
        System.debug('ADMIN EXISTS: FAIL — DocGen_Admin not found');
    } else {
        pass++;
        System.debug('ADMIN EXISTS: PASS');
        Id psId = aps[0].Id;

        // Apex class accesses
        Set<String> cls = new Set<String>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId = :psId AND SetupEntityType = 'ApexClass'
        ]) {
            cls.add([SELECT Name FROM ApexClass WHERE Id = :s.SetupEntityId LIMIT 1].Name);
        }

        // Core classes
        Boolean coreOk = cls.contains('DocGenController') && cls.contains('DocGenService');
        if (coreOk) {
            pass++;
            System.debug('ADMIN CORE CLASSES (DocGenController, DocGenService): PASS');
        } else {
            fail++;
            System.debug('ADMIN CORE CLASSES: FAIL — found: ' + cls);
        }

        // Bulk classes
        Boolean bulkOk = cls.contains('DocGenBulkController');
        if (bulkOk) {
            pass++;
            System.debug('ADMIN BULK CLASS (DocGenBulkController): PASS');
        } else {
            fail++;
            System.debug('ADMIN BULK CLASS: FAIL — found: ' + cls);
        }

        // Signature classes
        Boolean sigOk = cls.contains('DocGenSignatureController') && cls.contains('DocGenAuthenticatorController');
        if (sigOk) {
            pass++;
            System.debug('ADMIN SIGNATURE CLASSES: PASS');
        } else {
            fail++;
            System.debug('ADMIN SIGNATURE CLASSES: FAIL — found: ' + cls);
        }

        // Setup classes
        Boolean setupOk = cls.contains('DocGenSetupController');
        if (setupOk) {
            pass++;
            System.debug('ADMIN SETUP CLASS (DocGenSetupController): PASS');
        } else {
            fail++;
            System.debug('ADMIN SETUP CLASS: FAIL — found: ' + cls);
        }

        // Sender controller
        Boolean senderOk = cls.contains('DocGenSignatureSenderController');
        if (senderOk) {
            pass++;
            System.debug('ADMIN SENDER CLASS (DocGenSignatureSenderController): PASS');
        } else {
            fail++;
            System.debug('ADMIN SENDER CLASS: FAIL — found: ' + cls);
        }

        // Flow invocables (signature + giant query)
        Boolean sigFlowOk = cls.contains('DocGenSignatureFlowAction');
        if (sigFlowOk) {
            pass++;
            System.debug('ADMIN FLOW CLASS DocGenSignatureFlowAction: PASS');
        } else {
            fail++;
            System.debug('ADMIN FLOW CLASS DocGenSignatureFlowAction: FAIL — found: ' + cls);
        }

        Boolean gqFlowOk = cls.contains('DocGenGiantQueryFlowAction');
        if (gqFlowOk) {
            pass++;
            System.debug('ADMIN FLOW CLASS DocGenGiantQueryFlowAction: PASS');
        } else {
            fail++;
            System.debug('ADMIN FLOW CLASS DocGenGiantQueryFlowAction: FAIL — found: ' + cls);
        }

        // VF page accesses
        Set<String> apgs = new Set<String>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId = :psId AND SetupEntityType = 'ApexPage'
        ]) {
            apgs.add([SELECT Name FROM ApexPage WHERE Id = :s.SetupEntityId LIMIT 1].Name);
        }
        Boolean guideOk = apgs.contains('DocGenGuide');
        if (guideOk) {
            pass++;
            System.debug('ADMIN PAGE DocGenGuide: PASS');
        } else {
            fail++;
            System.debug('ADMIN PAGE DocGenGuide: FAIL — found: ' + apgs);
        }
        Boolean verifyOk = apgs.contains('DocGenVerify');
        if (verifyOk) {
            pass++;
            System.debug('ADMIN PAGE DocGenVerify: PASS');
        } else {
            fail++;
            System.debug('ADMIN PAGE DocGenVerify: FAIL — found: ' + apgs);
        }

        // Object permissions — templates, jobs, signature objects
        Set<String> objs = new Set<String>();
        for (ObjectPermissions op : [
            SELECT SobjectType
            FROM ObjectPermissions
            WHERE ParentId = :psId AND PermissionsRead = TRUE
        ]) {
            objs.add(op.SobjectType);
        }

        if (containsNs(objs, 'DocGen_Template__c')) {
            pass++;
            System.debug('ADMIN OBJ DocGen_Template__c: PASS');
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Template__c: FAIL — found: ' + objs);
        }

        if (containsNs(objs, 'DocGen_Job__c')) {
            pass++;
            System.debug('ADMIN OBJ DocGen_Job__c: PASS');
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Job__c: FAIL — found: ' + objs);
        }

        if (containsNs(objs, 'DocGen_Signature_Request__c')) {
            pass++;
            System.debug('ADMIN OBJ DocGen_Signature_Request__c: PASS');
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Signature_Request__c: FAIL — found: ' + objs);
        }

        if (containsNs(objs, 'DocGen_Signer__c')) {
            pass++;
            System.debug('ADMIN OBJ DocGen_Signer__c: PASS');
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Signer__c: FAIL — found: ' + objs);
        }

        if (containsNs(objs, 'DocGen_Signature_Audit__c')) {
            pass++;
            System.debug('ADMIN OBJ DocGen_Signature_Audit__c: PASS');
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Signature_Audit__c: FAIL — found: ' + objs);
        }

        if (containsNs(objs, 'DocGen_Signature_Placement__c')) {
            pass++;
            System.debug('ADMIN OBJ DocGen_Signature_Placement__c: PASS');
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Signature_Placement__c: FAIL — found: ' + objs);
        }

        if (containsNs(objs, 'DocGen_Saved_Query__c')) {
            pass++;
            System.debug('ADMIN OBJ DocGen_Saved_Query__c: PASS');
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Saved_Query__c: FAIL — found: ' + objs);
        }

        // Key signature field permissions
        Set<String> flds = new Set<String>();
        for (FieldPermissions fp : [
            SELECT Field
            FROM FieldPermissions
            WHERE ParentId = :psId AND PermissionsRead = TRUE
        ]) {
            flds.add(fp.Field);
        }

        Boolean pinHashOk =
            containsNs(flds, 'DocGen_Signer__c.PIN_Hash__c') ||
            containsNs(flds, 'DocGen_Signer__c.portwoodglobal__PIN_Hash__c') ||
            flds.contains('portwoodglobal__DocGen_Signer__c.portwoodglobal__PIN_Hash__c');
        if (pinHashOk) {
            pass++;
            System.debug('ADMIN FLD PIN_Hash__c: PASS');
        } else {
            fail++;
            System.debug(
                'ADMIN FLD PIN_Hash__c: FAIL — sample: ' + (flds.size() > 0 ? new List<String>(flds)[0] : 'empty')
            );
        }

        Boolean tokenOk =
            containsNs(flds, 'DocGen_Signer__c.Secure_Token__c') ||
            containsNs(flds, 'DocGen_Signer__c.portwoodglobal__Secure_Token__c') ||
            flds.contains('portwoodglobal__DocGen_Signer__c.portwoodglobal__Secure_Token__c');
        if (tokenOk) {
            pass++;
            System.debug('ADMIN FLD Secure_Token__c: PASS');
        } else {
            fail++;
            System.debug('ADMIN FLD Secure_Token__c: FAIL');
        }

        Boolean hashFieldOk =
            containsNs(flds, 'DocGen_Signature_Audit__c.Document_Hash_SHA256__c') ||
            containsNs(flds, 'DocGen_Signature_Audit__c.portwoodglobal__Document_Hash_SHA256__c') ||
            flds.contains('portwoodglobal__DocGen_Signature_Audit__c.portwoodglobal__Document_Hash_SHA256__c');
        if (hashFieldOk) {
            pass++;
            System.debug('ADMIN FLD Document_Hash_SHA256__c: PASS');
        } else {
            fail++;
            System.debug('ADMIN FLD Document_Hash_SHA256__c: FAIL');
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('ADMIN PERMS: FAIL — ' + e.getMessage());
}

// ===== DocGen_User Permission Set =====
try {
    List<PermissionSet> ups = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1];
    if (ups.isEmpty()) {
        fail++;
        System.debug('USER EXISTS: FAIL — DocGen_User not found');
    } else {
        pass++;
        System.debug('USER EXISTS: PASS');
        Id upsId = ups[0].Id;

        Set<String> uo = new Set<String>();
        for (ObjectPermissions op : [
            SELECT SobjectType
            FROM ObjectPermissions
            WHERE ParentId = :upsId AND PermissionsRead = TRUE
        ]) {
            uo.add(op.SobjectType);
        }

        if (containsNs(uo, 'DocGen_Template__c')) {
            pass++;
            System.debug('USER READ DocGen_Template__c: PASS');
        } else {
            fail++;
            System.debug('USER READ DocGen_Template__c: FAIL — found: ' + uo);
        }

        if (containsNs(uo, 'DocGen_Signature_Request__c')) {
            pass++;
            System.debug('USER READ DocGen_Signature_Request__c: PASS');
        } else {
            fail++;
            System.debug('USER READ DocGen_Signature_Request__c: FAIL — found: ' + uo);
        }

        if (containsNs(uo, 'DocGen_Signer__c')) {
            pass++;
            System.debug('USER READ DocGen_Signer__c: PASS');
        } else {
            fail++;
            System.debug('USER READ DocGen_Signer__c: FAIL — found: ' + uo);
        }

        // User class accesses
        Set<String> ucls = new Set<String>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId = :upsId AND SetupEntityType = 'ApexClass'
        ]) {
            ucls.add([SELECT Name FROM ApexClass WHERE Id = :s.SetupEntityId LIMIT 1].Name);
        }
        Boolean uClsOk = ucls.contains('DocGenController');
        if (uClsOk) {
            pass++;
            System.debug('USER CLASS DocGenController: PASS');
        } else {
            fail++;
            System.debug('USER CLASS DocGenController: FAIL — found: ' + ucls);
        }

        Boolean uFlowOk = ucls.contains('DocGenSignatureFlowAction');
        if (uFlowOk) {
            pass++;
            System.debug('USER CLASS DocGenSignatureFlowAction: PASS');
        } else {
            fail++;
            System.debug('USER CLASS DocGenSignatureFlowAction: FAIL — found: ' + ucls);
        }

        Boolean uGqFlowOk = ucls.contains('DocGenGiantQueryFlowAction');
        if (uGqFlowOk) {
            pass++;
            System.debug('USER CLASS DocGenGiantQueryFlowAction: PASS');
        } else {
            fail++;
            System.debug('USER CLASS DocGenGiantQueryFlowAction: FAIL — found: ' + ucls);
        }

        Boolean uAuthOk = ucls.contains('DocGenAuthenticatorController');
        if (uAuthOk) {
            pass++;
            System.debug('USER CLASS DocGenAuthenticatorController: PASS');
        } else {
            fail++;
            System.debug('USER CLASS DocGenAuthenticatorController: FAIL — found: ' + ucls);
        }

        Set<String> upgs = new Set<String>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId = :upsId AND SetupEntityType = 'ApexPage'
        ]) {
            upgs.add([SELECT Name FROM ApexPage WHERE Id = :s.SetupEntityId LIMIT 1].Name);
        }
        Boolean uVerifyOk = upgs.contains('DocGenVerify');
        if (uVerifyOk) {
            pass++;
            System.debug('USER PAGE DocGenVerify: PASS');
        } else {
            fail++;
            System.debug('USER PAGE DocGenVerify: FAIL — found: ' + upgs);
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('USER PERMS: FAIL — ' + e.getMessage());
}

// ===== DocGen_Guest_Signature Permission Set =====
try {
    List<PermissionSet> gps = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Guest_Signature' LIMIT 1];
    if (gps.isEmpty()) {
        fail++;
        System.debug('GUEST EXISTS: FAIL — DocGen_Guest_Signature not found');
    } else {
        pass++;
        System.debug('GUEST EXISTS: PASS');
        Id gId = gps[0].Id;

        Set<String> gc = new Set<String>();
        Set<String> gp = new Set<String>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId, SetupEntityType
            FROM SetupEntityAccess
            WHERE ParentId = :gId
        ]) {
            if (s.SetupEntityType == 'ApexClass') {
                gc.add([SELECT Name FROM ApexClass WHERE Id = :s.SetupEntityId LIMIT 1].Name);
            }
            if (s.SetupEntityType == 'ApexPage') {
                gp.add([SELECT Name FROM ApexPage WHERE Id = :s.SetupEntityId LIMIT 1].Name);
            }
        }

        // VF pages
        Boolean sigPageOk = gp.contains('DocGenSignature');
        if (sigPageOk) {
            pass++;
            System.debug('GUEST PAGE DocGenSignature: PASS');
        } else {
            fail++;
            System.debug('GUEST PAGE DocGenSignature: FAIL — found: ' + gp);
        }

        Boolean signPageOk = gp.contains('DocGenSign');
        if (signPageOk) {
            pass++;
            System.debug('GUEST PAGE DocGenSign: PASS');
        } else {
            fail++;
            System.debug('GUEST PAGE DocGenSign: FAIL — found: ' + gp);
        }

        Boolean verifyPageOk = gp.contains('DocGenVerify');
        if (verifyPageOk) {
            pass++;
            System.debug('GUEST PAGE DocGenVerify: PASS');
        } else {
            fail++;
            System.debug('GUEST PAGE DocGenVerify: FAIL — found: ' + gp);
        }

        // Apex classes
        Boolean gSigCtrl = gc.contains('DocGenSignatureController');
        if (gSigCtrl) {
            pass++;
            System.debug('GUEST CLASS DocGenSignatureController: PASS');
        } else {
            fail++;
            System.debug('GUEST CLASS DocGenSignatureController: FAIL — found: ' + gc);
        }

        Boolean gAuthCtrl = gc.contains('DocGenAuthenticatorController');
        if (gAuthCtrl) {
            pass++;
            System.debug('GUEST CLASS DocGenAuthenticatorController: PASS');
        } else {
            fail++;
            System.debug('GUEST CLASS DocGenAuthenticatorController: FAIL — found: ' + gc);
        }

        // Object permissions
        Set<String> go2 = new Set<String>();
        for (ObjectPermissions op : [
            SELECT SobjectType
            FROM ObjectPermissions
            WHERE ParentId = :gId AND PermissionsRead = TRUE
        ]) {
            go2.add(op.SobjectType);
        }

        if (containsNs(go2, 'DocGen_Signature_Request__c')) {
            pass++;
            System.debug('GUEST OBJ DocGen_Signature_Request__c: PASS');
        } else {
            fail++;
            System.debug('GUEST OBJ DocGen_Signature_Request__c: FAIL — found: ' + go2);
        }

        if (containsNs(go2, 'DocGen_Signer__c')) {
            pass++;
            System.debug('GUEST OBJ DocGen_Signer__c: PASS');
        } else {
            fail++;
            System.debug('GUEST OBJ DocGen_Signer__c: FAIL — found: ' + go2);
        }

        if (containsNs(go2, 'DocGen_Signature_Audit__c')) {
            pass++;
            System.debug('GUEST OBJ DocGen_Signature_Audit__c: PASS');
        } else {
            fail++;
            System.debug('GUEST OBJ DocGen_Signature_Audit__c: FAIL — found: ' + go2);
        }

        if (containsNs(go2, 'DocGen_Signature_Placement__c')) {
            pass++;
            System.debug('GUEST OBJ DocGen_Signature_Placement__c: PASS');
        } else {
            fail++;
            System.debug('GUEST OBJ DocGen_Signature_Placement__c: FAIL — found: ' + go2);
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('GUEST PERMS: FAIL — ' + e.getMessage());
}

System.debug('========================================');
System.debug(
    'E2E-01 PERMISSIONS — PASS: ' +
        pass +
        '  FAIL: ' +
        fail +
        (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
