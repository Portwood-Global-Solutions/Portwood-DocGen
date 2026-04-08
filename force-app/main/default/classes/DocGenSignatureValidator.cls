public without sharing class DocGenSignatureValidator {

    public class FlowInput {
        @InvocableVariable(label='Secure Token' required=true)
        public String token;
    }

    public class FlowOutput {
        @InvocableVariable(label='Is Valid')
        public Boolean isValid;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
        @InvocableVariable(label='Signer Name')
        public String signerName;
        @InvocableVariable(label='Document Title')
        public String documentTitle;
        @InvocableVariable(label='Document Preview URL')
        public String documentUrl;
    }

    @InvocableMethod(label='Validate Signature Token' category='DocGen')
    public static List<FlowOutput> validateToken(List<FlowInput> inputs) {
        List<FlowOutput> results = new List<FlowOutput>();
        for (FlowInput input : inputs) {
            DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(input.token);
            FlowOutput out = new FlowOutput();
            out.isValid = res.isValid;
            out.errorMessage = res.errorMessage;
            out.signerName = res.signerName;
            out.documentTitle = res.documentTitle;
            out.documentUrl = res.documentUrl;
            results.add(out);
        }
        return results;
    }
}