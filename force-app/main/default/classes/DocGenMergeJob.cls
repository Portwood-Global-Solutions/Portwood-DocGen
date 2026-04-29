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
                SELECT VersionData, ContentDocumentId
                FROM ContentVersion
                WHERE Title LIKE :(prefix + '%')
                WITH USER_MODE
                ORDER BY Title
            ];

            if (snippets.isEmpty()) {
                update new DocGen_Job__c(Id = jobId, Status__c = 'Completed'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
                return;
            }

            // Get job + template details (template type drives the merge strategy)
            DocGen_Job__c job = [
                SELECT Label__c, Name, CreatedById, Success_Count__c, Total_Records__c, Template__r.Type__c
                FROM DocGen_Job__c
                WHERE Id = :jobId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            Boolean isHtmlTemplate = job.Template__r != null && job.Template__r.Type__c == 'HTML';

            // Concatenate snippets. For DOCX-source snippets, naive concat of
            // full HTML documents works (Flying Saucer tolerates nested <html>
            // up to a few docs). For HTML-source snippets, each snippet is 10+ KB
            // of full <html>/<head>/<body> and Flying Saucer aborts render after
            // ~10 documents — causing the "blank pages / most records missing"
            // issue. So for HTML templates we strip wrappers per-snippet and
            // concatenate only body content + deduped styles, then wrap once.
            String fullHtml;
            Set<Id> docIdsToDelete = new Set<Id>();
            Integer snippetCount = snippets.size();
            if (isHtmlTemplate) {
                String combinedStyles = '';
                String combinedBody = '';
                Set<String> seenStyles = new Set<String>();
                for (Integer i = 0; i < snippets.size(); i++) {
                    docIdsToDelete.add(snippets[i].ContentDocumentId);
                    String raw = snippets[i].VersionData.toString();
                    String styles = DocGenService.extractHtmlStyleBlocks(raw);
                    String body = DocGenService.extractHtmlBodyContent(raw);
                    if (String.isNotBlank(styles) && !seenStyles.contains(styles)) {
                        combinedStyles += styles + '\n';
                        seenStyles.add(styles);
                    }
                    if (i > 0) {
                        combinedBody += '<div style="page-break-before:always"></div>';
                    }
                    combinedBody += body;
                }
                fullHtml =
                    '<html><head><meta charset="utf-8"/><style>' +
                    combinedStyles +
                    '</style></head><body>' +
                    combinedBody +
                    '</body></html>';
            } else {
                fullHtml = '';
                for (Integer i = 0; i < snippets.size(); i++) {
                    if (i > 0) {
                        fullHtml += '<div style="page-break-before:always"></div>';
                    }
                    fullHtml += snippets[i].VersionData.toString();
                    docIdsToDelete.add(snippets[i].ContentDocumentId);
                }
            }
            snippets = null; // free heap before Blob.toPdf

            // Render one merged PDF
            Blob pdfBlob = Blob.toPdf(fullHtml);
            String fileName = String.isNotBlank(job.Label__c) ? job.Label__c : 'Bulk Generation ' + job.Name;

            // Save merged PDF linked to the Job record
            ContentVersion pdfCv = new ContentVersion(
                Title = fileName,
                PathOnClient = fileName + '.pdf',
                VersionData = pdfBlob,
                IsMajorVersion = true,
                FirstPublishLocationId = jobId
            );
            SObjectAccessDecision cvDec = Security.stripInaccessible(
                AccessType.CREATABLE,
                new List<ContentVersion>{ pdfCv }
            );
            insert cvDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
            pdfCv.Id = cvDec.getRecords()[0].Id;

            // Update Job with merged PDF CV Id
            update new DocGen_Job__c(Id = jobId, Status__c = 'Completed', Merged_PDF_CV__c = pdfCv.Id); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets

            // Clean up HTML snippets
            List<ContentDocument> docsToDelete = new List<ContentDocument>();
            for (Id docId : docIdsToDelete) {
                docsToDelete.add(new ContentDocument(Id = docId));
            }
            if (Schema.sObjectType.ContentDocument.isDeletable()) {
                delete docsToDelete; // NOPMD ApexCRUDViolation — CRUD checked above
            }

            // Send bell + push notification to the job submitter
            sendCompletionNotification(job, fileName, snippetCount);
        } catch (Exception e) {
            update new DocGen_Job__c(Id = jobId, Status__c = 'Completed with Errors'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
        }
    }

    private void sendCompletionNotification(DocGen_Job__c job, String fileName, Integer pageCount) {
        try {
            // Look up the custom notification type
            List<CustomNotificationType> types = [
                SELECT Id
                FROM CustomNotificationType
                WHERE DeveloperName = 'DocGen_Job_Complete'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (types.isEmpty()) {
                return;
            }

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(types[0].Id);
            notification.setTargetId(jobId);
            notification.setTitle('DocGen: ' + fileName + ' is ready');
            notification.setBody(
                pageCount + ' pages merged from ' + Integer.valueOf(job.Success_Count__c) + ' records. Tap to view.'
            );
            notification.send(new Set<String>{ job.CreatedById });
        } catch (Exception e) {
            // Intentionally swallowed — notification failure is non-fatal
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
        }
    }

    public with sharing class DocGenMergeJobFinalizer implements Finalizer {
        private Id jobId;
        public DocGenMergeJobFinalizer(Id jobId) {
            this.jobId = jobId;
        }
        public void execute(FinalizerContext ctx) {
            if (ctx.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
                try {
                    update new DocGen_Job__c(Id = jobId, Status__c = 'Failed'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
                } catch (Exception e) {
                    // Intentionally swallowed — best-effort; job record may not exist
                    String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                }
            }
        }
    }
}
