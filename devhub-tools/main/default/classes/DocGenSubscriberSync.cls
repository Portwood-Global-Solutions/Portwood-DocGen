/**
 * Scheduled job that syncs PackageSubscriber data into DocGen_Subscriber_Org__c
 * records linked to Account records. Runs in the DevHub org only.
 *
 * Schedule: System.schedule('DocGen Subscriber Sync', '0 0 0/6 * * ?', new DocGenSubscriberSync());
 *
 * This class uses without sharing and SYSTEM_MODE because it runs as a scheduled
 * job under the system context — no user session, no sharing rules apply.
 * All DML is internal DevHub data management (Account + Subscriber Org records).
 */
public without sharing class DocGenSubscriberSync implements Schedulable {

    public void execute(SchedulableContext sc) {
        syncSubscribers();
    }

    @AuraEnabled
    public static void syncNow() {
        syncSubscribers();
    }

    private static void syncSubscribers() {
        List<MetadataPackage> packages = [
            SELECT Id FROM MetadataPackage WHERE NamespacePrefix = 'portwoodglobal' WITH SYSTEM_MODE LIMIT 1
        ];
        if (packages.isEmpty()) return;
        String packageId = packages[0].Id;

        Map<String, String> versionMap = new Map<String, String>();
        for (MetadataPackageVersion mpv : [
            SELECT Id, MajorVersion, MinorVersion, PatchVersion, Name
            FROM MetadataPackageVersion WHERE MetadataPackageId = :packageId WITH SYSTEM_MODE
        ]) {
            versionMap.put(mpv.Id, 'v' + mpv.MajorVersion + '.' + mpv.MinorVersion + '.' + mpv.PatchVersion);
        }

        List<PackageSubscriber> subscribers = [
            SELECT OrgKey, OrgName, OrgType, InstalledStatus, MetadataPackageVersionId, SystemModstamp
            FROM PackageSubscriber WHERE MetadataPackageId = :packageId WITH SYSTEM_MODE
        ];
        if (subscribers.isEmpty()) return;

        Set<String> orgIds = new Set<String>();
        for (PackageSubscriber sub : subscribers) { orgIds.add(sub.OrgKey); }

        Map<String, DocGen_Subscriber_Org__c> existingOrgs = new Map<String, DocGen_Subscriber_Org__c>();
        for (DocGen_Subscriber_Org__c so : [
            SELECT Id, Org_Id__c, Account__c FROM DocGen_Subscriber_Org__c WHERE Org_Id__c IN :orgIds WITH SYSTEM_MODE
        ]) {
            existingOrgs.put(so.Org_Id__c, so);
        }

        Set<String> orgNames = new Set<String>();
        for (PackageSubscriber sub : subscribers) {
            if (String.isNotBlank(sub.OrgName)) orgNames.add(sub.OrgName);
        }
        Map<String, Account> accountsByName = new Map<String, Account>();
        for (Account a : [SELECT Id, Name FROM Account WHERE Name IN :orgNames WITH SYSTEM_MODE]) {
            accountsByName.put(a.Name, a);
        }

        Id customerRtId;
        List<RecordType> rts = [
            SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND DeveloperName = 'Customer' WITH SYSTEM_MODE LIMIT 1
        ];
        if (!rts.isEmpty()) customerRtId = rts[0].Id;

        List<Account> newAccounts = new List<Account>();
        for (PackageSubscriber sub : subscribers) {
            String orgName = String.isNotBlank(sub.OrgName) ? sub.OrgName : sub.OrgKey;
            if (!accountsByName.containsKey(orgName)) {
                Account a = new Account(Name = orgName);
                if (customerRtId != null) a.RecordTypeId = customerRtId;
                newAccounts.add(a);
                accountsByName.put(orgName, a);
            }
        }

        if (!newAccounts.isEmpty()) {
            Map<String, Account> deduped = new Map<String, Account>();
            for (Account a : newAccounts) { deduped.put(a.Name, a); }
            newAccounts = deduped.values();
            insert newAccounts; // NOPMD ApexCRUDViolation — scheduled sync: auto-creating Account records for subscriber orgs
            for (Account a : newAccounts) { accountsByName.put(a.Name, a); }
        }

        List<DocGen_Subscriber_Org__c> upsertOrgs = new List<DocGen_Subscriber_Org__c>();
        for (PackageSubscriber sub : subscribers) {
            String orgName = String.isNotBlank(sub.OrgName) ? sub.OrgName : sub.OrgKey;
            String statusLabel = sub.InstalledStatus == 'i' ? 'Installed' : sub.InstalledStatus == 'u' ? 'Uninstalled' : sub.InstalledStatus;

            DocGen_Subscriber_Org__c so;
            if (existingOrgs.containsKey(sub.OrgKey)) {
                so = existingOrgs.get(sub.OrgKey);
            } else {
                so = new DocGen_Subscriber_Org__c();
                so.Org_Id__c = sub.OrgKey;
            }

            so.Name = orgName;
            so.Org_Type__c = sub.OrgType;
            so.Install_Status__c = statusLabel;
            so.Install_Date__c = sub.SystemModstamp;
            so.Last_Synced__c = Datetime.now();
            if (versionMap.containsKey(sub.MetadataPackageVersionId)) {
                so.Package_Version__c = versionMap.get(sub.MetadataPackageVersionId);
            }
            if (so.Account__c == null && accountsByName.containsKey(orgName)) {
                so.Account__c = accountsByName.get(orgName).Id;
            }
            upsertOrgs.add(so);
        }

        if (!upsertOrgs.isEmpty()) {
            upsert upsertOrgs Org_Id__c; // NOPMD ApexCRUDViolation — scheduled sync: upserting Subscriber Org records
        }
    }
}
