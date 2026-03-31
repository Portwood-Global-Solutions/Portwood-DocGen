/**
 * Controller for the DocGen landing page and community signup.
 * Handles install links, help request form submissions, and
 * automated Chatter Free user creation for community signups.
 * Deploy to partner org only — runs on VF Site with guest user profile.
 */
public without sharing class DocGenLandingController {

    private static final String DEMO_USER_ID = '005di00000GkOuFAAV';
    private static final String DEMO_RET_URL = '/lightning/app/portwoodglobal__DocGen/page/portwoodglobal__DocGen_Command_Hub';
    private static final String CHATTER_PROFILE_NAME = 'Chatter Free User';

    private String packageVersionId;

    private String getPackageVersionId() {
        if (packageVersionId == null) {
            List<DocGen_Landing_Config__mdt> configs = [
                SELECT Package_Version_Id__c FROM DocGen_Landing_Config__mdt
                WHERE DeveloperName = 'Current' LIMIT 1
            ];
            packageVersionId = configs.isEmpty() ? '' : configs[0].Package_Version_Id__c;
        }
        return packageVersionId;
    }

    public String installLinkProd {
        get { return 'https://login.salesforce.com/packaging/installPackage.apexp?p0=' + getPackageVersionId(); }
    }
    public String installLinkSandbox {
        get { return 'https://test.salesforce.com/packaging/installPackage.apexp?p0=' + getPackageVersionId(); }
    }

    public String demoUrl {
        get {
            try {
                List<DocGen_Demo_Config__c> configs = [
                    SELECT Access_Token__c, Instance_Url__c
                    FROM DocGen_Demo_Config__c
                    WHERE SetupOwnerId = :UserInfo.getOrganizationId()
                    WITH SYSTEM_MODE LIMIT 1
                ];
                if (!configs.isEmpty() && String.isNotBlank(configs[0].Access_Token__c) && String.isNotBlank(configs[0].Instance_Url__c)) {
                    return configs[0].Instance_Url__c + '/secur/frontdoor.jsp?sid=' + configs[0].Access_Token__c
                        + '&retURL=' + EncodingUtil.urlEncode(DEMO_RET_URL, 'UTF-8');
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'demoUrl getter failed: ' + e.getMessage());
            }
            return null;
        }
    }

    public Integer installCount {
        get {
            try {
                // PackageSubscriber tracks all orgs that have installed the managed package
                return [SELECT COUNT() FROM PackageSubscriber WHERE InstalledStatus = 'i'];
            } catch (Exception e) {
                return 0;
            }
        }
    }

    public DocGenLandingController() {}

    @RemoteAction
    public static String submitHelpRequest(String name, String email, String company, String message) {
        if (String.isBlank(name) || String.isBlank(email)) {
            throw new AuraHandledException('Name and email are required.');
        }

        // Check for existing Lead with same email to avoid duplicates
        List<Lead> existing = [SELECT Id, Description FROM Lead WHERE Email = :email WITH SYSTEM_MODE LIMIT 1];
        if (!existing.isEmpty()) {
            Lead existingLead = existing[0];
            existingLead.Description = 'Follow-up request (' + Datetime.now().format() + '):\n' + message
                + (String.isNotBlank(existingLead.Description) ? '\n\n---\n' + existingLead.Description : '');
            update existingLead; // NOPMD ApexCRUDViolation — landing page: updating existing Lead with follow-up message
            return 'updated';
        }

        String firstName = '';
        String lastName = name;
        if (name.contains(' ')) {
            Integer spaceIdx = name.indexOf(' ');
            firstName = name.substring(0, spaceIdx);
            lastName = name.substring(spaceIdx + 1);
        }

        Lead newLead = new Lead(
            FirstName = firstName,
            LastName = lastName,
            Email = email,
            Company = String.isNotBlank(company) ? company : '[Not Provided]',
            Description = message,
            LeadSource = 'DocGen Website',
            Status = 'New'
        );
        insert newLead; // NOPMD ApexCRUDViolation — landing page: creating Lead from help request form
        return 'created';
    }

    /**
     * Creates a Chatter Free user and adds them to all DocGen community groups.
     * Salesforce automatically sends a welcome email with login credentials
     * (platform email — not an org email send).
     */
    @RemoteAction
    public static String createChatterUser(String name, String email, String company) {
        if (String.isBlank(name) || String.isBlank(email)) {
            throw new AuraHandledException('Name and email are required.');
        }
        email = email.trim().toLowerCase();

        // Check if a User with this email already exists
        List<User> existingUsers = [SELECT Id, IsActive FROM User WHERE Email = :email WITH SYSTEM_MODE LIMIT 1];
        if (!existingUsers.isEmpty()) {
            if (existingUsers[0].IsActive) {
                throw new AuraHandledException('An account with this email already exists. Log in at portwoodglobalsolutions.my.salesforce.com.');
            }
            // Reactivate inactive user
            User inactive = existingUsers[0];
            inactive.IsActive = true;
            update inactive; // NOPMD ApexCRUDViolation — reactivating existing Chatter user
            addToChatterGroups(inactive.Id);
            return 'reactivated';
        }

        // Parse name
        String firstName = '';
        String lastName = name.trim();
        if (lastName.contains(' ')) {
            Integer spaceIdx = lastName.indexOf(' ');
            firstName = lastName.substring(0, spaceIdx);
            lastName = lastName.substring(spaceIdx + 1);
        }

        // Build unique username: email + .docgen suffix (must be globally unique)
        String username = email + '.docgen';
        List<User> usernameTaken = [SELECT Id FROM User WHERE Username = :username WITH SYSTEM_MODE LIMIT 1];
        if (!usernameTaken.isEmpty()) {
            // Add random suffix if taken
            username = email.substringBefore('@') + '.' + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(6)
                + '@' + email.substringAfter('@') + '.docgen';
        }

        // Build alias (max 8 chars)
        String alias = (String.isNotBlank(firstName) ? firstName.left(1) : '') + lastName.left(7);
        alias = alias.left(8);

        // Get Chatter Free profile
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name = :CHATTER_PROFILE_NAME LIMIT 1];
        if (profiles.isEmpty()) {
            throw new AuraHandledException('Chatter Free profile not found. Please contact support.');
        }

        User newUser = new User(
            FirstName = firstName,
            LastName = lastName,
            Email = email,
            Username = username,
            Alias = alias,
            CompanyName = String.isNotBlank(company) ? company : null,
            ProfileId = profiles[0].Id,
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Chicago',
            IsActive = true
        );
        insert newUser; // NOPMD ApexCRUDViolation — creating Chatter Free user from community signup

        // Add to groups async (mixed DML: User + non-setup object)
        addToChatterGroups(newUser.Id);

        return 'created';
    }

    /**
     * Adds a user to all DocGen Chatter groups. Uses @future to avoid
     * mixed DML errors (User is a setup object).
     */
    @future
    private static void addToChatterGroups(Id userId) {
        List<CollaborationGroup> groups = [
            SELECT Id FROM CollaborationGroup
            WHERE Name LIKE 'DocGen -%'
            WITH SYSTEM_MODE
        ];
        List<CollaborationGroupMember> members = new List<CollaborationGroupMember>();
        for (CollaborationGroup g : groups) {
            members.add(new CollaborationGroupMember(
                CollaborationGroupId = g.Id,
                MemberId = userId,
                NotificationFrequency = 'P' // Each post
            ));
        }
        if (!members.isEmpty()) {
            insert members; // NOPMD ApexCRUDViolation — adding new Chatter user to community groups
        }
    }
}
