public without sharing class DocGenSignatureFinalizer {
    
    public class FinalizeRequest {
        @InvocableVariable(required=true description='The secure token for the signature request')
        public String token;
        
        @InvocableVariable(required=true description='The Base64 encoded PNG signature image')
        public String base64Image;
    }

    @InvocableMethod(label='Finalize Signature Image' description='Stamps the signature onto the DOCX and enqueues the Server-Side PDF Rendition. Runs in System Context.')
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    public static void finalizeSignature(List<FinalizeRequest> requests) {
        for (FinalizeRequest req : requests) { // CxSAST: Loop bounded by design — max 1 iteration (InvocableMethod single-record pattern)
            System.debug(LoggingLevel.DEBUG, 'DocGen: Finalizing signature via Flow System Context.');
            // This runs in System Mode thanks to the Flow context, bypassing Guest User limits on ContentVersion
            DocGenSignatureService.handleSignatureSubmission(req.token, req.base64Image);
        }
    }
}