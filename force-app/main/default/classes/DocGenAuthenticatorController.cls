public without sharing class DocGenAuthenticatorController {
    
    @AuraEnabled
    public static VerificationResult verifyDocument(String fileHash) {
        // We use without sharing to query the Audit table securely for public users
        List<DocGen_Signature_Audit__c> audits = [
            SELECT Id, Signed_Date__c, IP_Address__c, Signature_Request__r.Signer_Name__c, Signature_Request__r.Signer_Email__c
            FROM DocGen_Signature_Audit__c
            WHERE Document_Hash_SHA256__c = :fileHash
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        VerificationResult res = new VerificationResult();
        if (!audits.isEmpty()) {
            DocGen_Signature_Audit__c audit = audits[0];
            res.isValid = true;
            res.signerName = audit.Signature_Request__r.Signer_Name__c;
            res.signerEmail = audit.Signature_Request__r.Signer_Email__c;
            res.signedDate = audit.Signed_Date__c;
            res.ipAddress = audit.IP_Address__c;
            res.message = 'Authentic Document Verified';
        } else {
            res.isValid = false;
            res.message = 'Document could not be verified. It may have been modified after signing or was not signed through this system.';
        }
        return res;
    }

    public class VerificationResult {
        @AuraEnabled public Boolean isValid { get; set; }
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public String signerName { get; set; }
        @AuraEnabled public String signerEmail { get; set; }
        @AuraEnabled public Datetime signedDate { get; set; }
        @AuraEnabled public String ipAddress { get; set; }
    }
}
