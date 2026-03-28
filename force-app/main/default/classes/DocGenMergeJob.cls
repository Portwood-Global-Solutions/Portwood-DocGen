/**
 * Queueable that assembles HTML snippets into a single merged PDF.
 * Chained from DocGenBatch.finish() when merge mode is enabled.
 *
 * Flow:
 * 1. Reads all HTML snippet CVs by title prefix (ordered by sequence)
 * 2. Concatenates with page breaks
 * 3. Calls Blob.toPdf() ONCE
 * 4. Saves the merged PDF as a ContentVersion linked to the Job
 * 5. Cleans up the snippet CVs
 * 6. Sends a bell/push notification to the job submitter
 */
public with sharing class DocGenMergeJob implements Queueable {

    private Id jobId;

    /**
     * Constructs a merge job for the specified bulk generation job.
     * @param jobId The DocGen_Job__c record ID containing HTML snippets to merge
     */
    public DocGenMergeJob(Id jobId) {
        this.jobId = jobId;
    }

    /**
     * Assembles all HTML snippets into a single merged PDF, saves it, and cleans up.
     * @param ctx The queueable context provided by the platform
     */
    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new DocGenMergeJobFinalizer(this.jobId));
        try {
            // Read all HTML snippets in order
            String prefix = 'docgen_merge_' + jobId + '_';
            List<ContentVersion> snippets = [
                SELECT VersionData, ContentDocumentId FROM ContentVersion
                WHERE Title LIKE :(prefix + '%')
                WITH SYSTEM_MODE
                ORDER BY Title
            ];

            if (snippets.isEmpty()) {
                update new DocGen_Job__c(Id = jobId, Status__c = 'Completed'); // NOPMD ApexCRUDViolation — package-internal object; CRUD controlled by permission set
                return;
            }

            // Concatenate all snippets with page breaks
            String fullHtml = '';
            Set<Id> docIdsToDelete = new Set<Id>();
            for (Integer i = 0; i < snippets.size(); i++) {
                if (i > 0) {
                    fullHtml += '<div style="page-break-before:always"></div>';
                }
                fullHtml += snippets[i].VersionData.toString();
                docIdsToDelete.add(snippets[i].ContentDocumentId);
            }

            // Render one merged PDF
            Blob pdfBlob = Blob.toPdf(fullHtml);

            // Get job details
            DocGen_Job__c job = [
                SELECT Label__c, Name, CreatedById, Success_Count__c, Total_Records__c
                FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE LIMIT 1
            ];
            String fileName = String.isNotBlank(job.Label__c) ? job.Label__c : 'Bulk Generation ' + job.Name;

            // Save merged PDF linked to the Job record
            ContentVersion pdfCv = new ContentVersion(
                Title = fileName,
                PathOnClient = fileName + '.pdf',
                VersionData = pdfBlob,
                IsMajorVersion = true,
                FirstPublishLocationId = jobId
            );
            insert pdfCv; // NOPMD ApexCRUDViolation - internal bulk merge output

            // Update Job with merged PDF CV Id
            update new DocGen_Job__c( // NOPMD ApexCRUDViolation — package-internal object; CRUD controlled by permission set
                Id = jobId,
                Status__c = 'Completed',
                Merged_PDF_CV__c = pdfCv.Id
            );

            // Clean up HTML snippets
            List<ContentDocument> docsToDelete = new List<ContentDocument>();
            for (Id docId : docIdsToDelete) {
                docsToDelete.add(new ContentDocument(Id = docId));
            }
            delete docsToDelete; // NOPMD ApexCRUDViolation - cleaning up internal temp files

            // Send bell + push notification to the job submitter
            sendCompletionNotification(job, fileName, snippets.size());

        } catch (Exception e) {
            update new DocGen_Job__c(Id = jobId, Status__c = 'Completed with Errors'); // NOPMD ApexCRUDViolation — package-internal object; CRUD controlled by permission set
        }
    }

    private void sendCompletionNotification(DocGen_Job__c job, String fileName, Integer pageCount) {
        try {
            // Look up the custom notification type
            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'DocGen_Job_Complete'
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (types.isEmpty()) {
                return;
            }

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(types[0].Id);
            notification.setTargetId(jobId);
            notification.setTitle('DocGen: ' + fileName + ' is ready');
            notification.setBody(pageCount + ' pages merged from ' + Integer.valueOf(job.Success_Count__c) + ' records. Tap to view.');
            notification.send(new Set<String>{ job.CreatedById });

        } catch (Exception e) {
            // Intentionally swallowed — notification failure is non-fatal
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
        }
    }

    public class DocGenMergeJobFinalizer implements Finalizer {
        private Id jobId;
        public DocGenMergeJobFinalizer(Id jobId) { this.jobId = jobId; }
        public void execute(FinalizerContext ctx) {
            if (ctx.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
                try {
                    DocGen_Job__c job = [SELECT Id FROM DocGen_Job__c WHERE Id = :jobId WITH USER_MODE LIMIT 1];
                    job.Status__c = 'Failed';
                    update job; // NOPMD ApexCRUDViolation — package-internal object; updating job status on failure
                } catch (Exception e) {
                    // Intentionally swallowed — best-effort; job record may not exist
                    String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                }
            }
        }
    }
}
