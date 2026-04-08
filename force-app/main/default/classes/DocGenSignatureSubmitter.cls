public without sharing class DocGenSignatureSubmitter {

    public class FlowInput {
        @InvocableVariable(label='Secure Token' required=true)
        public String token;
        @InvocableVariable(label='Signature Data (Base64)' required=true)
        public String signatureData;
    }

    public class FlowOutput {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(label='Submit Signed Signature' category='DocGen')
    public static List<FlowOutput> submitSignature(List<FlowInput> inputs) {
        List<FlowOutput> results = new List<FlowOutput>();
        for (FlowInput input : inputs) {
            FlowOutput out = new FlowOutput();
            try {
                // Call the privileged submission handler directly
                DocGenSignatureService.handleSignatureSubmission(input.token, input.signatureData);
                out.isSuccess = true;
            } catch (Exception e) {
                out.isSuccess = false;
                out.errorMessage = e.getMessage();
            }
            results.add(out);
        }
        return results;
    }
}