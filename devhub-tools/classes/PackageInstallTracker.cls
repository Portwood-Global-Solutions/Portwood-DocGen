/**
 * Controller for the Package Install Tracker LWC.
 * Queries MetadataPackage and PackageSubscriber to show install data.
 * Deploy to DevHub org only — not part of the distributed package.
 */
public with sharing class PackageInstallTracker {

    @AuraEnabled(cacheable=true)
    public static List<PackageInfo> getPackages() {
        List<PackageInfo> packages = new List<PackageInfo>();
        for (MetadataPackage pkg : [SELECT Id, Name, NamespacePrefix FROM MetadataPackage ORDER BY Name]) { // NOPMD ApexCRUDViolation — MetadataPackage is a system object; CRUD checks not applicable
            PackageInfo pi = new PackageInfo();
            pi.id = pkg.Id;
            pi.name = pkg.Name;
            pi.namespacePrefix = pkg.NamespacePrefix;
            packages.add(pi);
        }
        return packages;
    }

    @AuraEnabled(cacheable=true)
    public static List<SubscriberInfo> getSubscribers(String metadataPackageId) {
        List<SubscriberInfo> subs = new List<SubscriberInfo>();
        String query = 'SELECT Id, MetadataPackageId, MetadataPackageVersionId, OrgKey, OrgName, OrgType, InstalledStatus, SystemModstamp FROM PackageSubscriber';
        if (String.isNotBlank(metadataPackageId)) {
            query += ' WHERE MetadataPackageId = :metadataPackageId';
        }
        query += ' ORDER BY SystemModstamp DESC';

        // Build version ID → version number map
        Map<String, String> versionMap = getVersionMap();

        // Build orgKey → subscriber org record map (for Account links)
        Map<String, DocGen_Subscriber_Org__c> subOrgMap = new Map<String, DocGen_Subscriber_Org__c>();
        for (DocGen_Subscriber_Org__c so : [
            SELECT Org_Id__c, Account__c, Account__r.Name FROM DocGen_Subscriber_Org__c WITH SYSTEM_MODE LIMIT 50000
        ]) {
            subOrgMap.put(so.Org_Id__c, so);
        }

        for (PackageSubscriber sub : Database.query(query)) { // NOPMD ApexCRUDViolation — PackageSubscriber is a system object; CRUD checks not applicable
            SubscriberInfo si = new SubscriberInfo();
            si.id = sub.Id;
            si.orgKey = sub.OrgKey;
            si.orgName = sub.OrgName;
            si.orgType = sub.OrgType;
            si.installedStatus = sub.InstalledStatus == 'i' ? 'Installed' : sub.InstalledStatus == 'u' ? 'Uninstalled' : sub.InstalledStatus;
            si.versionId = sub.MetadataPackageVersionId;
            si.versionLabel = versionMap.containsKey(sub.MetadataPackageVersionId)
                ? versionMap.get(sub.MetadataPackageVersionId)
                : sub.MetadataPackageVersionId;
            si.installedDate = sub.SystemModstamp;
            // Account link from subscriber org record
            DocGen_Subscriber_Org__c so = subOrgMap.get(sub.OrgKey);
            if (so != null) {
                si.subscriberOrgId = so.Id;
                si.accountId = so.Account__c;
                si.accountName = so.Account__r != null ? so.Account__r.Name : null;
            }
            subs.add(si);
        }
        return subs;
    }

    @AuraEnabled(cacheable=true)
    public static List<VersionInfo> getVersions(String metadataPackageId) {
        List<VersionInfo> versions = new List<VersionInfo>();

        for (MetadataPackageVersion mpv : [ // NOPMD ApexCRUDViolation — MetadataPackageVersion is a system object
            SELECT Id, Name, MajorVersion, MinorVersion, PatchVersion, BuildNumber, ReleaseState, SystemModstamp
            FROM MetadataPackageVersion
            WHERE MetadataPackageId = :metadataPackageId
            ORDER BY MajorVersion DESC, MinorVersion DESC, PatchVersion DESC, BuildNumber DESC
            LIMIT 50
        ]) {
            VersionInfo vi = new VersionInfo();
            vi.id = mpv.Id;
            vi.name = mpv.Name;
            vi.version = mpv.MajorVersion + '.' + mpv.MinorVersion + '.' + mpv.PatchVersion + '.' + mpv.BuildNumber;
            vi.releaseState = mpv.ReleaseState;
            vi.publishedDate = mpv.SystemModstamp;
            versions.add(vi);
        }
        return versions;
    }

    private static Map<String, String> getVersionMap() {
        Map<String, String> versionMap = new Map<String, String>();
        for (MetadataPackageVersion mpv : [ // NOPMD ApexCRUDViolation — system object
            SELECT Id, MajorVersion, MinorVersion, PatchVersion, BuildNumber, Name
            FROM MetadataPackageVersion
            ORDER BY SystemModstamp DESC
            LIMIT 200
        ]) {
            String label = 'v' + mpv.MajorVersion + '.' + mpv.MinorVersion + '.' + mpv.PatchVersion;
            if (String.isNotBlank(mpv.Name)) {
                label += ' — ' + mpv.Name;
            }
            versionMap.put(mpv.Id, label);
        }
        return versionMap;
    }

    @AuraEnabled
    public static void sendInstallNotification(String orgName, String orgType, String versionLabel, String orgKey) {
        try {
            // Find or create the subscriber org record so the notification links to it
            Id targetId = UserInfo.getUserId(); // fallback
            if (String.isNotBlank(orgKey)) {
                List<DocGen_Subscriber_Org__c> subOrgs = [
                    SELECT Id FROM DocGen_Subscriber_Org__c WHERE Org_Id__c = :orgKey WITH SYSTEM_MODE LIMIT 1
                ];
                if (subOrgs.isEmpty()) {
                    // Auto-create subscriber org record for the new install
                    DocGen_Subscriber_Org__c so = new DocGen_Subscriber_Org__c(
                        Org_Id__c = orgKey,
                        Name = String.isNotBlank(orgName) ? orgName : orgKey,
                        Org_Type__c = orgType,
                        Install_Status__c = 'Installed',
                        Install_Date__c = Datetime.now()
                    );
                    insert so; // NOPMD ApexCRUDViolation — DevHub admin operation
                    targetId = so.Id;
                } else {
                    targetId = subOrgs[0].Id;
                }
            }

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setTitle('New DocGen Install');
            notification.setBody(orgName + ' (' + orgType + ') installed ' + versionLabel);
            notification.setNotificationTypeId(getNotificationTypeId());
            notification.setTargetId(targetId);
            notification.send(new Set<String>{ UserInfo.getUserId() });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Install notification failed: ' + e.getMessage());
        }
    }

    private static String getNotificationTypeId() {
        List<CustomNotificationType> types = [ // NOPMD ApexCRUDViolation — system object
            SELECT Id FROM CustomNotificationType WHERE DeveloperName = 'DocGen_Job_Complete' LIMIT 1
        ];
        if (!types.isEmpty()) { return types[0].Id; }
        // Fallback: use any available notification type
        types = [ // NOPMD ApexCRUDViolation — system object
            SELECT Id FROM CustomNotificationType LIMIT 1];
        return types.isEmpty() ? null : types[0].Id;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getStats(String metadataPackageId) {
        Map<String, Object> stats = new Map<String, Object>();
        String query = 'SELECT Id, OrgType, InstalledStatus FROM PackageSubscriber';
        if (String.isNotBlank(metadataPackageId)) {
            query += ' WHERE MetadataPackageId = :metadataPackageId';
        }

        Integer total = 0;
        Integer production = 0;
        Integer sandbox = 0;
        Integer installed = 0;
        Integer uninstalled = 0;

        for (PackageSubscriber sub : Database.query(query)) { // NOPMD ApexCRUDViolation — PackageSubscriber is a system object
            total++;
            if (sub.OrgType == 'Production') { production++; }
            else { sandbox++; }
            if (sub.InstalledStatus == 'i') { installed++; }
            else { uninstalled++; }
        }

        stats.put('total', total);
        stats.put('production', production);
        stats.put('sandbox', sandbox);
        stats.put('installed', installed);
        stats.put('uninstalled', uninstalled);
        return stats;
    }

    /**
     * Links a subscriber org to an existing Account.
     */
    @AuraEnabled
    public static void linkOrgToAccount(String orgKey, Id accountId) {
        List<DocGen_Subscriber_Org__c> orgs = [
            SELECT Id, Account__c FROM DocGen_Subscriber_Org__c WHERE Org_Id__c = :orgKey WITH SYSTEM_MODE LIMIT 1
        ];
        if (orgs.isEmpty()) {
            // Create the subscriber org record first
            DocGen_Subscriber_Org__c so = new DocGen_Subscriber_Org__c(
                Org_Id__c = orgKey,
                Name = orgKey,
                Account__c = accountId
            );
            insert so; // NOPMD ApexCRUDViolation — DevHub admin operation
        } else {
            orgs[0].Account__c = accountId;
            update orgs[0]; // NOPMD ApexCRUDViolation — DevHub admin operation
        }
    }

    /**
     * Creates a new Account for a subscriber org and links them.
     */
    @AuraEnabled
    public static Id createAccountForOrg(String orgKey, String accountName) {
        Account a = new Account(Name = accountName);
        List<RecordType> rts = [
            SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' WITH SYSTEM_MODE LIMIT 1
        ];
        if (!rts.isEmpty()) { a.RecordTypeId = rts[0].Id; }
        insert a; // NOPMD ApexCRUDViolation — DevHub admin operation

        linkOrgToAccount(orgKey, a.Id);
        return a.Id;
    }

    /**
     * Searches Accounts by name for the link-to-account lookup.
     */
    @AuraEnabled(cacheable=true)
    public static List<Account> searchAccounts(String searchTerm) {
        if (String.isBlank(searchTerm) || searchTerm.length() < 2) {
            return new List<Account>();
        }
        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [SELECT Id, Name FROM Account WHERE Name LIKE :term WITH SYSTEM_MODE ORDER BY Name LIMIT 20];
    }

    public class PackageInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String namespacePrefix;
    }

    public class SubscriberInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String orgKey;
        @AuraEnabled public String orgName;
        @AuraEnabled public String orgType;
        @AuraEnabled public String installedStatus;
        @AuraEnabled public String versionId;
        @AuraEnabled public String versionLabel;
        @AuraEnabled public Datetime installedDate;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Id subscriberOrgId;
    }

    public class VersionInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String version;
        @AuraEnabled public String releaseState;
        @AuraEnabled public Datetime publishedDate;
    }
}
