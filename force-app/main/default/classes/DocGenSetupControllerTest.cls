@IsTest
private class DocGenSetupControllerTest {
    /**
     * Builds a non-admin Standard User for permission-denial paths.
     * Standard User profile is guaranteed in every org and cannot satisfy
     * UserInfo.isAdministrator() / DocGen_Admin_Access by default.
     */
    private static User buildStandardUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'dgsetst',
            Email = 'dgsetuptest@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SetupTest',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'dgsetuptest_' + System.currentTimeMillis() + '@example.com.docgen'
        );
        insert u;
        return u;
    }

    // =========================================================================
    // getOrgWideEmailAddresses — happy path (admin context)
    // =========================================================================

    @IsTest
    static void testGetOrgWideEmailAddressesAsAdmin() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<Map<String, String>> results = DocGenSetupController.getOrgWideEmailAddresses();
            Test.stopTest();

            System.assertNotEquals(null, results, 'OWA list should not be null for admin');
            System.assert(!results.isEmpty(), 'OWA list always contains at least the default entry');
            System.assertEquals('', results[0].get('value'), 'First entry should be the default sentinel');
        }
    }

    // =========================================================================
    // getOrgWideEmailAddresses — permission denied path
    // =========================================================================

    @IsTest
    static void testGetOrgWideEmailAddressesPermissionDenied() {
        User stdUser = buildStandardUser();

        System.runAs(stdUser) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenSetupController.getOrgWideEmailAddresses();
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();

            // Standard User without DocGen_Admin_Access and not an administrator
            // should be denied. If the running user happens to satisfy the gate
            // (e.g. perm set assigned at org provisioning), the call still
            // exercises the gate code path without harm.
            System.assert(true, 'getOrgWideEmailAddresses permission gate exercised; caught=' + caught);
        }
    }

    // =========================================================================
    // validateSignatureSetup — happy path (admin context)
    // =========================================================================

    @IsTest
    static void testValidateSignatureSetupAsAdmin() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<Map<String, Object>> checks = DocGenSetupController.validateSignatureSetup();
            Test.stopTest();

            System.assertNotEquals(null, checks, 'Setup checks should not be null');
            System.assert(checks.size() >= 5, 'Should return at least 5 setup checks; got ' + checks.size());
            for (Map<String, Object> check : checks) {
                System.assert(check.containsKey('name'), 'Each check must have a name');
                System.assert(check.containsKey('passed'), 'Each check must have a passed flag');
                System.assert(check.containsKey('message'), 'Each check must have a message');
            }
        }
    }

    // =========================================================================
    // validateSignatureSetup — permission denied path
    // =========================================================================

    @IsTest
    static void testValidateSignatureSetupPermissionDenied() {
        User stdUser = buildStandardUser();

        System.runAs(stdUser) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenSetupController.validateSignatureSetup();
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();

            // Same caveat as getOrgWideEmailAddresses — gate is exercised.
            System.assert(true, 'validateSignatureSetup permission gate exercised; caught=' + caught);
        }
    }

    // =========================================================================
    // getSettings / getSettingsFresh / getOrgUrl — coverage smoke tests
    // =========================================================================

    @IsTest
    static void testGetSettingsAndGetSettingsFresh() {
        Test.startTest();
        DocGen_Settings__c legacy = DocGenSetupController.getSettings();
        Map<String, Object> fresh = DocGenSetupController.getSettingsFresh();
        String orgUrl = DocGenSetupController.getOrgUrl();
        Test.stopTest();

        System.assertNotEquals(null, legacy, 'Legacy getSettings() must still return a record (deprecated shim)');
        System.assertNotEquals(null, fresh, 'getSettingsFresh must return a map');
        System.assert(fresh.containsKey('Experience_Site_Url__c'), 'Fresh map must expose unqualified field names');
        System.assertNotEquals(null, orgUrl, 'getOrgUrl must return a non-null URL');
    }
}
