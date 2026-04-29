/**
 * Schedulable class that sends reminder emails to pending signers.
 * Runs on a schedule (e.g., hourly) and checks for signers who haven't
 * responded within the configured reminder threshold.
 *
 * Schedule via: System.schedule('DocGen Signature Reminders', '0 0 * * * ?', new DocGenSignatureReminderSchedulable());
 */
public with sharing class DocGenSignatureReminderSchedulable implements Schedulable {
    // Test-injectable threshold override — allows tests to bypass CreatedDate filtering
    @TestVisible
    private static DateTime testThresholdOverride = null;

    public void execute(SchedulableContext ctx) {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();

        // Check if reminders are enabled
        if (settings.Signature_Reminder_Enabled__c != true)
            return;

        Integer reminderHours = settings.Signature_Reminder_Hours__c != null
            ? Integer.valueOf(settings.Signature_Reminder_Hours__c)
            : 24;
        if (reminderHours <= 0)
            return;

        DateTime threshold = testThresholdOverride != null
            ? testThresholdOverride
            : System.now().addHours(-reminderHours);

        // Find pending signers created before the threshold who haven't been reminded yet
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> pendingSigners = [
            SELECT
                Id,
                Signer_Name__c,
                Signer_Email__c,
                Role_Name__c,
                Secure_Token__c,
                Contact__c,
                Reminder_Sent_At__c,
                CreatedDate,
                Signature_Request__c,
                Signature_Request__r.Status__c,
                Signature_Request__r.Template__c,
                Signature_Request__r.Template__r.Name
            FROM DocGen_Signer__c
            WHERE
                Status__c IN ('Pending', 'Viewed')
                AND CreatedDate < :threshold
                AND Reminder_Sent_At__c = NULL
                AND Signature_Request__r.Status__c NOT IN ('Signed', 'Cancelled', 'Declined')
            WITH SYSTEM_MODE
            LIMIT 200
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        if (pendingSigners.isEmpty())
            return;

        String siteUrl = DocGenSignatureSenderController.getSiteBaseUrl();
        String sigPagePath = DocGenSignatureSenderController.getSigningPagePath();

        List<DocGenSignatureEmailService.SignerEmail> emailList = new List<DocGenSignatureEmailService.SignerEmail>();
        for (DocGen_Signer__c s : pendingSigners) {
            // Skip if token is expired (48 hours)
            if (s.CreatedDate.addHours(48) < System.now())
                continue;

            String sigUrl = siteUrl + sigPagePath + '?token=' + s.Secure_Token__c;
            String docTitle = s.Signature_Request__r.Template__r != null
                ? s.Signature_Request__r.Template__r.Name
                : 'Document';

            emailList.add(
                new DocGenSignatureEmailService.SignerEmail(
                    s.Signer_Name__c,
                    s.Signer_Email__c,
                    s.Role_Name__c,
                    sigUrl,
                    s.Contact__c
                )
            );

            s.Reminder_Sent_At__c = System.now();
        }

        if (!emailList.isEmpty()) {
            DocGenSignatureEmailService.sendSignatureRequestEmails(
                emailList,
                'Reminder: Document awaiting your signature'
            );

            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(pendingSigners, false, AccessLevel.SYSTEM_MODE);
        }
    }
}
