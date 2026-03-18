/**
 * Platform Event trigger for signature PDF generation.
 * Runs as Automated Process user (system context), bypassing guest user
 * limitations on ContentVersion access. Published by the guest user VF page
 * after all signatures are collected.
 */
trigger DocGenSignaturePdfTrigger on DocGen_Signature_PDF__e (after insert) {
    for (DocGen_Signature_PDF__e evt : Trigger.New) {
        try {
            Id requestId = evt.Request_Id__c;
            System.enqueueJob(new DocGenSignatureService.SignaturePdfQueueable(requestId));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Signature PDF event trigger error: ' + e.getMessage());
        }
    }
}
