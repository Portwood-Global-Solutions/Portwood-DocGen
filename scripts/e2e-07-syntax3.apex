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

System.debug('========================================');
System.debug(
    'E2E-07-SYNTAX3 — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
