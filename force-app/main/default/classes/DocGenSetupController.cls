public with sharing class DocGenSetupController {
    /**
     * Returns the org's domain URL for configuration display.
     * @return The external form of the org domain URL
     */
    @AuraEnabled(cacheable=true)
    public static String getOrgUrl() {
        // Return the core my.salesforce.com URL, not the Lightning domain
        return Url.getOrgDomainUrl().toExternalForm();
    }

    /**
     * Returns the org-level DocGen settings custom setting.
     * @return The DocGen_Settings__c org defaults record
     */
    @AuraEnabled(cacheable=true)
    public static DocGen_Settings__c getSettings() {
        return DocGen_Settings__c.getOrgDefaults();
    }

    /**
     * Returns fresh (non-cached) settings as a plain map with unqualified field names.
     * In managed packages, SObject field names are returned with the namespace prefix
     * (e.g., portwoodglobal__Experience_Site_Url__c), which breaks LWC property access.
     * This method strips the prefix so the LWC can use simple field names.
     */
    @AuraEnabled
    public static Map<String, Object> getSettingsFresh() {
        DocGen_Settings__c s = DocGen_Settings__c.getOrgDefaults();
        Map<String, Object> result = new Map<String, Object>();
        result.put('Experience_Site_Url__c', s.Experience_Site_Url__c);
        result.put('Company_Name__c', s.Company_Name__c);
        result.put('Signature_Email_Brand_Color__c', s.Signature_Email_Brand_Color__c);
        result.put('Signature_Email_Logo_Url__c', s.Signature_Email_Logo_Url__c);
        result.put('Signature_Email_Subject__c', s.Signature_Email_Subject__c);
        result.put('Signature_Email_Message__c', s.Signature_Email_Message__c);
        result.put('Signature_Email_Footer_Text__c', s.Signature_Email_Footer_Text__c);
        result.put('Signature_OWA_Id__c', s.Signature_OWA_Id__c);
        result.put('Signature_Reminder_Enabled__c', s.Signature_Reminder_Enabled__c);
        result.put('Signature_Reminder_Hours__c', s.Signature_Reminder_Hours__c);
        return result;
    }

    /**
     * Saves the Experience Site URL to DocGen settings.
     * @param experienceSiteUrl The Experience Site base URL to store
     */
    @AuraEnabled
    public static void saveSettings(String experienceSiteUrl) {
        // Only allow users with Customize Application or DocGen_Admin permission set
        if (
            !FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()
        ) {
            throw DocGenService.ahe('Insufficient privileges to modify DocGen settings.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        settings.Experience_Site_Url__c = experienceSiteUrl;
        // Package-internal object — CRUD controlled by DocGen permission sets
        upsert settings; // NOPMD ApexCRUDViolation - package-internal custom setting; CRUD checked on lines 15-18 above
    }

    /**
     * Saves signature-specific settings (email branding, site URL).
     */
    /**
     * Returns available Org-Wide Email Addresses for the signature email sender picker.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getOrgWideEmailAddresses() {
        List<Map<String, String>> results = new List<Map<String, String>>();
        results.add(new Map<String, String>{ 'label' => '-- Running User (default) --', 'value' => '' });
        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        for (OrgWideEmailAddress owa : [
            SELECT Id, Address, DisplayName
            FROM OrgWideEmailAddress
            ORDER BY DisplayName
        ]) {
            // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
            String label = String.isNotBlank(owa.DisplayName)
                ? owa.DisplayName + ' <' + owa.Address + '>'
                : owa.Address;
            results.add(new Map<String, String>{ 'label' => label, 'value' => owa.Id });
        }
        return results;
    }

    /**
     * Validates the signature setup configuration and returns a list of check results.
     * Each result has: name, passed, message, fixUrl.
     */
    @AuraEnabled
    public static List<Map<String, Object>> validateSignatureSetup() {
        List<Map<String, Object>> checks = new List<Map<String, Object>>();
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();

        // 1. Site URL configured
        Boolean siteUrlOk = String.isNotBlank(settings.Experience_Site_Url__c);
        checks.add(
            buildCheck(
                'Site URL Configured',
                siteUrlOk,
                siteUrlOk
                    ? 'Signature Site URL is set.'
                    : 'No Signature Site URL configured. Enter your Salesforce Site URL below.',
                null
            )
        );

        // 2. Salesforce Site exists and is active
        Boolean siteActive = false;
        String siteName = '';
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            List<Site> sites = [SELECT Id, Name, Status FROM Site WHERE Status = 'Active' WITH SYSTEM_MODE LIMIT 10]; // NOPMD
            siteActive = !sites.isEmpty();
            if (siteActive) {
                siteName = sites[0].Name;
            }
        } catch (Exception e) {
            // Site query may fail in some contexts
        }
        checks.add(
            buildCheck(
                'Salesforce Site Active',
                siteActive,
                siteActive
                    ? 'Active site found: ' + siteName
                    : 'No active Salesforce Site found. Create one in Setup > Sites.',
                '/lightning/setup/CustomDomain/home'
            )
        );

        // 3. Org-Wide Email Address configured
        Boolean owaOk = false;
        String owaDisplay = '';
        if (String.isNotBlank(settings.Signature_OWA_Id__c)) {
            try {
                /* code-analyzer-suppress ApexFlsViolation */
                List<OrgWideEmailAddress> owas = [
                    SELECT Id, DisplayName, Address
                    FROM OrgWideEmailAddress
                    WHERE Id = :settings.Signature_OWA_Id__c
                    WITH SYSTEM_MODE
                    LIMIT 1
                ]; // NOPMD
                owaOk = !owas.isEmpty();
                if (owaOk) {
                    owaDisplay = owas[0].DisplayName + ' <' + owas[0].Address + '>';
                }
            } catch (Exception e) {
                // OWA query failed
            }
        }
        checks.add(
            buildCheck(
                'Org-Wide Email Address',
                owaOk,
                owaOk
                    ? 'Email sender configured: ' + owaDisplay
                    : 'No Org-Wide Email Address selected. Required for PIN verification emails. Create one in Setup > Organization-Wide Email Addresses, then select it below.',
                '/lightning/setup/OrgWideEmailAddresses/home'
            )
        );

        // 4. Guest user permission set check
        Boolean guestPermOk = false;
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            List<PermissionSet> ps = [
                SELECT Id
                FROM PermissionSet
                WHERE Name = 'DocGen_Guest_Signature'
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD
            if (!ps.isEmpty()) {
                /* code-analyzer-suppress ApexFlsViolation */
                List<PermissionSetAssignment> psa = [
                    SELECT Id
                    FROM PermissionSetAssignment
                    WHERE PermissionSetId = :ps[0].Id
                    WITH SYSTEM_MODE
                    LIMIT 1
                ]; // NOPMD
                guestPermOk = !psa.isEmpty();
            }
        } catch (Exception e) {
            // Permission query failed
        }
        checks.add(
            buildCheck(
                'Guest Permission Set Assigned',
                guestPermOk,
                guestPermOk
                    ? 'DocGen Guest Signature permission set is assigned.'
                    : 'The DocGen Guest Signature permission set is not assigned to any user. Assign it to the Site guest user via Site > Public Access Settings.',
                null
            )
        );

        // 5. VF pages accessible check — verify the key pages exist in the org
        Boolean vfPagesOk = false;
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            List<ApexPage> pages = [
                SELECT Name
                FROM ApexPage
                WHERE Name IN ('DocGenSign', 'DocGenSignature', 'DocGenVerify')
                WITH SYSTEM_MODE
            ]; // NOPMD
            vfPagesOk = pages.size() >= 3;
        } catch (Exception e) {
            // ApexPage query may not be available
        }
        checks.add(
            buildCheck(
                'Visualforce Pages Deployed',
                vfPagesOk,
                vfPagesOk
                    ? 'DocGenSign, DocGenSignature, and DocGenVerify pages are deployed.'
                    : 'Required Visualforce pages are missing. Ensure the DocGen package is fully deployed.',
                null
            )
        );

        return checks;
    }

    private static Map<String, Object> buildCheck(String name, Boolean passed, String message, String fixUrl) {
        Map<String, Object> check = new Map<String, Object>();
        check.put('name', name);
        check.put('passed', passed);
        check.put('message', message);
        if (fixUrl != null) {
            check.put('fixUrl', fixUrl);
        }
        return check;
    }

    @AuraEnabled
    public static void saveSignatureSettings(
        String brandColor,
        String logoUrl,
        String emailSubject,
        String emailMessage,
        String footerText,
        String companyName,
        String owaId
    ) {
        if (
            !FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()
        ) {
            throw DocGenService.ahe('Insufficient privileges to modify DocGen settings.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        settings.Signature_Email_Brand_Color__c = brandColor;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        settings.Signature_Email_Logo_Url__c = logoUrl;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        settings.Signature_Email_Subject__c = emailSubject;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        settings.Signature_Email_Message__c = emailMessage;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        settings.Signature_Email_Footer_Text__c = footerText;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        settings.Company_Name__c = companyName;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        settings.Signature_OWA_Id__c = owaId;
        upsert settings; // NOPMD ApexCRUDViolation - package-internal custom setting
    }

    /**
     * Saves reminder settings and auto-schedules/unschedules the reminder job.
     * When enabled, schedules DocGenSignatureReminderSchedulable to run hourly.
     * When disabled, aborts the scheduled job.
     */
    @AuraEnabled
    public static void saveReminderSettings(Boolean enabled, Integer hours) {
        if (
            !FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()
        ) {
            throw DocGenService.ahe('Insufficient privileges to modify DocGen settings.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Signature_Reminder_Enabled__c = enabled;
        settings.Signature_Reminder_Hours__c = hours != null && hours > 0 ? hours : 24;
        upsert settings; // NOPMD ApexCRUDViolation - package-internal custom setting

        // Auto-schedule or abort the reminder job
        String jobName = 'DocGen Signature Reminders';
        try {
            // Abort existing job if any
            /* code-analyzer-suppress ApexFlsViolation */
            List<CronTrigger> existing = [
                SELECT Id
                FROM CronTrigger
                WHERE CronJobDetail.Name = :jobName
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD
            for (CronTrigger ct : existing) {
                System.abortJob(ct.Id);
            }

            // Schedule new job if enabled
            if (enabled) {
                System.schedule(jobName, '0 0 * * * ?', new DocGenSignatureReminderSchedulable());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Failed to schedule/abort reminder job: ' + e.getMessage());
        }
    }
}
