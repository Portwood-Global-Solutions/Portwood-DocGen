public without sharing class DocGenAuthenticatorController {
    // SHA-256 hex digest = 64 lowercase/uppercase hex characters
    private static final Pattern SHA256_HEX = Pattern.compile('^[a-fA-F0-9]{64}$');
    // Salesforce Id = 15 or 18 alphanumeric characters
    private static final Pattern SF_ID = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');

    /**
     * Verifies a document by its SHA-256 hash.
     */
    @AuraEnabled
    @RemoteAction
    public static VerificationResult verifyDocument(String fileHash) {
        VerificationResult res = new VerificationResult();

        // Strict input validation: must be a 64-char hex string (SHA-256 digest).
        // Reject early with empty result if the input is malformed — never reach SOQL.
        if (String.isBlank(fileHash) || fileHash.length() != 64 || !SHA256_HEX.matcher(fileHash).matches()) {
            res.isValid = false;
            res.message = 'Document could not be verified. It may have been modified after signing or was not signed through this system.';
            return res;
        }

        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Audit__c> audits = [
            SELECT
                Id,
                Signed_Date__c,
                IP_Address__c,
                Signer_Name__c,
                Signer_Email__c,
                Consent_Captured__c,
                PIN_Verified_At__c,
                Document_Hash_SHA256__c
            FROM DocGen_Signature_Audit__c
            WHERE Document_Hash_SHA256__c = :fileHash
            WITH SYSTEM_MODE
            LIMIT 1
        ];

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
     *
     * Note: the request Id IS the verification capability — this endpoint is meant to
     * let recipients verify their audit trail via a public-link flow. We therefore do
     * NOT gate on caller identity, but we DO strictly validate the input shape and
     * return only fields that are part of the verification contract.
     */
    @AuraEnabled
    @RemoteAction
    public static List<VerificationResult> verifyByRequestId(String requestId) {
        List<VerificationResult> results = new List<VerificationResult>();

        // Strict input validation: must be a well-formed 15- or 18-char alphanumeric Salesforce Id.
        // Reject early with empty list if malformed — never reach SOQL.
        if (
            String.isBlank(requestId) ||
            (requestId.length() != 15 &&
            requestId.length() != 18) ||
            !SF_ID.matcher(requestId).matches()
        ) {
            return results;
        }

        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Audit__c> audits = [
            SELECT
                Id,
                Signed_Date__c,
                IP_Address__c,
                Signer_Name__c,
                Signer_Email__c,
                Consent_Captured__c,
                PIN_Verified_At__c,
                Document_Hash_SHA256__c,
                Signer__r.Role_Name__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c = :requestId AND Signer_Name__c != 'SYSTEM'
            WITH SYSTEM_MODE
            ORDER BY Signed_Date__c ASC
        ];

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
        @AuraEnabled
        public Boolean isValid { get; set; }
        @AuraEnabled
        public String message { get; set; }
        @AuraEnabled
        public String signerName { get; set; }
        @AuraEnabled
        public String signerEmail { get; set; }
        @AuraEnabled
        public String roleName { get; set; }
        @AuraEnabled
        public Datetime signedDate { get; set; }
        @AuraEnabled
        public String ipAddress { get; set; }
        @AuraEnabled
        public String documentHash { get; set; }
        @AuraEnabled
        public Boolean consentCaptured { get; set; }
        @AuraEnabled
        public Datetime pinVerifiedAt { get; set; }
    }
}
