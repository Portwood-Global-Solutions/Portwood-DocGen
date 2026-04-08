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
     * Saves the Experience Site URL to DocGen settings.
     * @param experienceSiteUrl The Experience Site base URL to store
     */
    @AuraEnabled
    public static void saveSettings(String experienceSiteUrl) {
        // Only allow users with Customize Application or DocGen_Admin permission set
        if (!FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()) {
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
        for (OrgWideEmailAddress owa : [SELECT Id, Address, DisplayName FROM OrgWideEmailAddress ORDER BY DisplayName LIMIT 1000]) { // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
            String label = String.isNotBlank(owa.DisplayName)
                ? owa.DisplayName + ' <' + owa.Address + '>'
                : owa.Address;
            results.add(new Map<String, String>{ 'label' => label, 'value' => owa.Id });
        }
        return results;
    }

    @AuraEnabled
    public static void saveSignatureSettings(String brandColor, String logoUrl, String emailSubject,
                                              String emailMessage, String footerText, String companyName,
                                              String owaId) {
        if (!FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()) {
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
}