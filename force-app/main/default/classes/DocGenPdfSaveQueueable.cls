/**
 * Runs DocGenService.generateDocument (full render + ContentVersion insert +
 * ContentDocumentLink) in an async Queueable so the LWC's Aura request can
 * return immediately. Big image-heavy PDFs that would otherwise trip
 * Salesforce's ~30s Aura CSRF timeout now complete without user-visible errors.
 *
 * Triggered by DocGenController.generatePdfAsync. If generation fails, the
 * exception is logged via System.debug with the record/template IDs so admins
 * can diagnose from the AsyncApexJob log.
 */
public with sharing class DocGenPdfSaveQueueable implements Queueable {
    private final Id templateId;
    private final Id recordId;

    public DocGenPdfSaveQueueable(Id templateId, Id recordId) {
        this.templateId = templateId;
        this.recordId = recordId;
    }

    public void execute(QueueableContext ctx) {
        try {
            DocGenService.generateDocument(templateId, recordId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'DocGenPdfSaveQueueable failed. templateId=' + templateId +
                ' recordId=' + recordId + ' error=' + e.getMessage() +
                ' stack=' + e.getStackTraceString());
            throw e;
        }
    }
}
