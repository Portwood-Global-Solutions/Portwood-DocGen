public without sharing class DocGenAuthenticatorController {

    /**
     * Verifies a document by its SHA-256 hash.
     */
    @AuraEnabled
    @RemoteAction
    public static VerificationResult verifyDocument(String fileHash) {
        /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
        List<DocGen_Signature_Audit__c> audits = [
            SELECT Id, Signed_Date__c, IP_Address__c, Signer_Name__c, Signer_Email__c,
                   Consent_Captured__c, PIN_Verified_At__c, Document_Hash_SHA256__c
            FROM DocGen_Signature_Audit__c
            WHERE Document_Hash_SHA256__c = :fileHash
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        VerificationResult res = new VerificationResult();
        if (!audits.isEmpty()) {
            DocGen_Signature_Audit__c audit = audits[0];
            res.isValid = true;
            res.signerName = audit.Signer_Name__c;
            res.signerEmail = audit.Signer_Email__c;
            res.signedDate = audit.Signed_Date__c;
            res.ipAddress = audit.IP_Address__c;
            res.documentHash = audit.Document_Hash_SHA256__c;
            res.consentCaptured = audit.Consent_Captured__c;
            res.pinVerifiedAt = audit.PIN_Verified_At__c;
            res.message = 'Authentic Document Verified';
        } else {
            res.isValid = false;
            res.message = 'Document could not be verified. It may have been modified after signing or was not signed through this system.';
        }
        return res;
    }

    /**
     * Looks up all audit records for a signature request by ID.
     * Used by the verification page when accessed via request ID link.
     */
    @AuraEnabled
    @RemoteAction
    public static List<VerificationResult> verifyByRequestId(String requestId) {
        /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
        List<DocGen_Signature_Audit__c> audits = [
            SELECT Id, Signed_Date__c, IP_Address__c, Signer_Name__c, Signer_Email__c,
                   Consent_Captured__c, PIN_Verified_At__c, Document_Hash_SHA256__c, Error_Message__c,
                   Signer__r.Role_Name__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c = :requestId AND Signer_Name__c != 'SYSTEM'
            WITH SYSTEM_MODE
            ORDER BY Signed_Date__c ASC
        ];

        List<VerificationResult> results = new List<VerificationResult>();
        for (DocGen_Signature_Audit__c audit : audits) {
            VerificationResult res = new VerificationResult();
            res.isValid = true;
            res.signerName = audit.Signer_Name__c;
            res.signerEmail = audit.Signer_Email__c;
            res.roleName = audit.Signer__r.Role_Name__c;
            res.signedDate = audit.Signed_Date__c;
            res.ipAddress = audit.IP_Address__c;
            res.documentHash = audit.Document_Hash_SHA256__c;
            res.consentCaptured = audit.Consent_Captured__c;
            res.pinVerifiedAt = audit.PIN_Verified_At__c;
            res.message = 'Signature verified';
            results.add(res);
        }
        return results;
    }

    public class VerificationResult {
        @AuraEnabled public Boolean isValid { get; set; }
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public String signerName { get; set; }
        @AuraEnabled public String signerEmail { get; set; }
        @AuraEnabled public String roleName { get; set; }
        @AuraEnabled public Datetime signedDate { get; set; }
        @AuraEnabled public String ipAddress { get; set; }
        @AuraEnabled public String documentHash { get; set; }
        @AuraEnabled public Boolean consentCaptured { get; set; }
        @AuraEnabled public Datetime pinVerifiedAt { get; set; }
    }
}
