/**
 * Queueable that assembles Giant Query fragments into a final document.
 * Chained from DocGenGiantQueryBatch.finish() after all child record
 * fragments have been harvested.
 *
 * Flow:
 * 1. Queries all fragment CVs by title prefix (ordered by sequence)
 * 2. Concatenates all fragment content into one pre-rendered loop body
 * 3. Calls mergeTemplateWithPreRenderedLoops() to produce the final document
 * 4. Cleans up fragment CVs
 * 5. Updates job status to 'Completed'
 */
public with sharing class DocGenGiantQueryStitchJob implements Queueable {

    private Id jobId;
    private Id templateId;
    private Id recordId;
    private String relationshipName;
    private String outputFormat;

    /**
     * Constructs a stitch job for assembling Giant Query fragments.
     * @param jobId The DocGen_Job__c record tracking this generation
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The parent record ID
     * @param relationshipName The child relationship that was harvested
     * @param outputFormat The desired output format (PDF or Native)
     */
    public DocGenGiantQueryStitchJob(Id jobId, Id templateId, Id recordId, String relationshipName, String outputFormat) {
        this.jobId = jobId;
        this.templateId = templateId;
        this.recordId = recordId;
        this.relationshipName = relationshipName;
        this.outputFormat = outputFormat;
    }

    /**
     * Assembles fragments, generates the final document, cleans up, and updates status.
     * @param ctx The queueable context provided by the platform
     */
    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new DocGenGiantQueryStitchFinalizer(this.jobId));
        try {
            // Update status to Stitching
            update new DocGen_Job__c(Id = jobId, Status__c = 'Stitching'); // NOPMD ApexCRUDViolation — package-internal object; CRUD controlled by permission set

            // Query all fragment CVs in order
            String prefix = 'docgen_giant_' + jobId + '_';
            List<ContentVersion> fragments = [
                SELECT VersionData, ContentDocumentId FROM ContentVersion
                WHERE Title LIKE :(prefix + '%')
                WITH SYSTEM_MODE
                ORDER BY Title
            ];

            // Concatenate all fragment content
            String preRenderedContent = '';
            Set<Id> docIdsToDelete = new Set<Id>();
            for (ContentVersion cv : fragments) {
                preRenderedContent += cv.VersionData.toString();
                docIdsToDelete.add(cv.ContentDocumentId);
            }

            // Build pre-rendered loops map and generate final document
            Map<String, String> preRenderedLoops = new Map<String, String>();
            preRenderedLoops.put(relationshipName, preRenderedContent);

            Id docId = DocGenService.mergeTemplateWithPreRenderedLoops(
                templateId, recordId, preRenderedLoops, outputFormat
            );

            // Clean up fragment CVs
            if (!docIdsToDelete.isEmpty()) {
                List<ContentDocument> docsToDelete = new List<ContentDocument>();
                for (Id fragDocId : docIdsToDelete) {
                    docsToDelete.add(new ContentDocument(Id = fragDocId));
                }
                delete docsToDelete; // NOPMD ApexCRUDViolation — cleaning up internal temp fragment files
            }

            // Update job status
            update new DocGen_Job__c(Id = jobId, Status__c = 'Completed'); // NOPMD ApexCRUDViolation — package-internal object; CRUD controlled by permission set

            // Send notification
            sendCompletionNotification();

        } catch (Exception e) {
            update new DocGen_Job__c(Id = jobId, Status__c = 'Failed'); // NOPMD ApexCRUDViolation — package-internal object; CRUD controlled by permission set
        }
    }

    private void sendCompletionNotification() {
        try {
            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'DocGen_Job_Complete'
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (types.isEmpty()) { return; }

            DocGen_Job__c job = [SELECT CreatedById, Label__c, Name, Total_Records__c FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE LIMIT 1];
            String jobName = String.isNotBlank(job.Label__c) ? job.Label__c : job.Name;

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(types[0].Id);
            notification.setTargetId(jobId);
            notification.setTitle('DocGen: ' + jobName + ' is ready');
            notification.setBody('Giant Query document generated from ' + Integer.valueOf(job.Total_Records__c) + ' child records. Tap to view.');
            notification.send(new Set<String>{ job.CreatedById });
        } catch (Exception e) {
            // Intentionally swallowed — notification failure is non-fatal
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
        }
    }

    /**
     * Finalizer to mark job as Failed if the Queueable throws an unhandled exception.
     */
    public class DocGenGiantQueryStitchFinalizer implements Finalizer {
        private Id jobId;
        public DocGenGiantQueryStitchFinalizer(Id jobId) { this.jobId = jobId; }
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
