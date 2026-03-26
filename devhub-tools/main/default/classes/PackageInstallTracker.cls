/**
 * Controller for the Package Install Tracker LWC.
 * Queries MetadataPackage and PackageSubscriber to show install data.
 * Deploy to DevHub org only — not part of the distributed package.
 */
public with sharing class PackageInstallTracker {

    @AuraEnabled(cacheable=true)
    public static List<PackageInfo> getPackages() {
        List<PackageInfo> packages = new List<PackageInfo>();
        for (MetadataPackage pkg : [SELECT Id, Name, NamespacePrefix FROM MetadataPackage ORDER BY Name]) {
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

        for (PackageSubscriber sub : Database.query(query)) {
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
            subs.add(si);
        }
        return subs;
    }

    @AuraEnabled(cacheable=true)
    public static List<VersionInfo> getVersions(String metadataPackageId) {
        Map<String, String> versionMap = getVersionMap();
        List<VersionInfo> versions = new List<VersionInfo>();

        for (MetadataPackageVersion mpv : [
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
        for (MetadataPackageVersion mpv : [
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
    public static void sendInstallNotification(String orgName, String orgType, String versionLabel) {
        try {
            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setTitle('New DocGen Install');
            notification.setBody(orgName + ' (' + orgType + ') installed ' + versionLabel);
            notification.setNotificationTypeId(getNotificationTypeId());
            notification.setTargetId(UserInfo.getUserId());
            notification.send(new Set<String>{ UserInfo.getUserId() });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Install notification failed: ' + e.getMessage());
        }
    }

    private static String getNotificationTypeId() {
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType WHERE DeveloperName = 'DocGen_Job_Complete' LIMIT 1
        ];
        if (!types.isEmpty()) { return types[0].Id; }
        // Fallback: use any available notification type
        types = [SELECT Id FROM CustomNotificationType LIMIT 1];
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

        for (PackageSubscriber sub : Database.query(query)) {
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
    }

    public class VersionInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String version;
        @AuraEnabled public String releaseState;
        @AuraEnabled public Datetime publishedDate;
    }
}
