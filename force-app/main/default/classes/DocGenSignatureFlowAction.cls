/**
 * Flow-invocable action to create a DocGen signature request and return signing links.
 *
 * Enables end-to-end signature automation from Flow:
 *   - Record-triggered Flow fires on a status change
 *   - This action creates the signature request and returns one signing URL per signer
 *   - Flow can send its own branded emails, post to Slack/Teams, update the record, etc.
 *
 * Notification modes:
 *   - sendEmails = false (default from Flow): Flow is responsible for notifying signers
 *                                              (Send Email action, Slack, custom invocable)
 *   - sendEmails = true                      : the package sends its own branded invitation emails
 *
 * Note: the LWC signature sender path (createTemplateSignerRequest) continues to send
 * branded emails by default — only the Flow entry point defaults to silent.
 */
global with sharing class DocGenSignatureFlowAction { // NOPMD AvoidGlobalModifier - required for @InvocableMethod visibility in subscriber orgs

    global class Request {
        @InvocableVariable(required=true label='Template Id' description='DocGen_Template__c record Id whose active version contains the {@Signature_Role} placeholders.')
        global Id templateId;

        @InvocableVariable(required=true label='Related Record Id' description='Record the signature request is bound to (e.g. Opportunity, Contract).')
        global Id relatedRecordId;

        @InvocableVariable(required=true label='Signer Names' description='Full name for each signer, in signing order.')
        global List<String> signerNames;

        @InvocableVariable(required=true label='Signer Emails' description='Email address for each signer. Must be the same length as Signer Names.')
        global List<String> signerEmails;

        @InvocableVariable(label='Signer Roles' description='Optional role name per signer (matches {@Signature_<Role>} placeholder). Defaults to "Signer" when omitted.')
        global List<String> signerRoles;

        @InvocableVariable(label='Signer Contact Ids' description='Optional Contact Id per signer for audit linkage.')
        global List<String> signerContactIds;

        @InvocableVariable(label='Send Branded Emails' description='Defaults to FALSE in Flow — your Flow is expected to send its own emails (Send Email action, Slack, etc.). Set to true to use the package\'s built-in branded invitation emails.')
        global Boolean sendEmails;
    }

    global class Result {
        @InvocableVariable(label='Signature Request Id' description='Id of the DocGen_Signature_Request__c record that was created.')
        global Id signatureRequestId;

        @InvocableVariable(label='Signer Urls' description='One signing URL per signer, in the same order as Signer Names. Each link is 48-hour single-use.')
        global List<String> signerUrls;

        @InvocableVariable(label='Signer Names' description='Echo of the input signer names, in request order.')
        global List<String> signerNames;

        @InvocableVariable(label='Signer Emails' description='Echo of the input signer emails, in request order.')
        global List<String> signerEmails;

        @InvocableVariable(label='Signer Roles' description='Echo of the resolved role names, in request order.')
        global List<String> signerRoles;
    }

    @InvocableMethod(
        label='DocGen: Create Signature Request'
        description='Creates a DocGen signature request and returns one signing URL per signer. Optionally sends the package\'s branded invitation emails.'
        category='Document Generation'
    )
    global static List<Result> generate(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null) return results;
        for (Request req : requests) {
            results.add(processOne(req));
        }
        return results;
    }

    private static Result processOne(Request req) {
        validate(req);

        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Integer i = 0; i < req.signerNames.size(); i++) {
            String role = (req.signerRoles != null && i < req.signerRoles.size() && String.isNotBlank(req.signerRoles[i]))
                ? req.signerRoles[i]
                : 'Signer';
            String contactId = (req.signerContactIds != null && i < req.signerContactIds.size())
                ? req.signerContactIds[i]
                : null;
            signerInputs.add(new Map<String, Object>{
                'signerName' => req.signerNames[i],
                'signerEmail' => req.signerEmails[i],
                'roleName' => role,
                'contactId' => contactId
            });
        }

        // Default FALSE from Flow: Flow callers are expected to handle their own notification
        // (Send Email action, Slack, custom invocable). LWC path via createTemplateSignerRequest
        // still sends branded emails as before.
        Boolean sendEmails = req.sendEmails == null ? false : req.sendEmails;

        DocGenSignatureSenderController.TemplateSignatureFlowResult flowResult =
            DocGenSignatureSenderController.createTemplateSignatureRequestForFlow(
                req.templateId, req.relatedRecordId, signerInputs, sendEmails
            );

        Result r = new Result();
        r.signatureRequestId = flowResult.signatureRequestId;
        r.signerUrls = new List<String>();
        r.signerNames = new List<String>();
        r.signerEmails = new List<String>();
        r.signerRoles = new List<String>();
        for (DocGenSignatureSenderController.SignerResult sr : flowResult.signers) {
            r.signerUrls.add(sr.signerUrl);
            r.signerNames.add(sr.signerName);
            r.signerEmails.add(sr.signerEmail);
            r.signerRoles.add(sr.roleName);
        }
        return r;
    }

    private static void validate(Request req) {
        if (req == null) {
            throw new DocGenException('Request is null');
        }
        if (req.templateId == null) {
            throw new DocGenException('Template Id is required');
        }
        if (req.relatedRecordId == null) {
            throw new DocGenException('Related Record Id is required');
        }
        if (req.signerNames == null || req.signerNames.isEmpty()) {
            throw new DocGenException('At least one signer name is required');
        }
        if (req.signerEmails == null || req.signerEmails.size() != req.signerNames.size()) {
            throw new DocGenException('Signer Emails must have exactly one entry per Signer Name (got '
                + (req.signerEmails == null ? 0 : req.signerEmails.size())
                + ' emails vs ' + req.signerNames.size() + ' names)');
        }
        for (Integer i = 0; i < req.signerNames.size(); i++) {
            if (String.isBlank(req.signerNames[i])) {
                throw new DocGenException('Signer Name at index ' + i + ' is blank');
            }
            if (String.isBlank(req.signerEmails[i])) {
                throw new DocGenException('Signer Email at index ' + i + ' is blank');
            }
        }
    }
}
