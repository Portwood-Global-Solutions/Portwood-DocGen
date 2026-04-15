/**
 * Flow-invocable action to create a DocGen signature request and return signing links.
 *
 * Uses the full v3 signature pipeline — guided signing, placement creation,
 * OWA-based emails, signing order, email status tracking.
 *
 * PREREQUISITES:
 * 1. A DocGen template with {@Signature_Role} tags in the active version
 * 2. An Org-Wide Email Address configured in DocGen > Signatures settings
 * 3. A Salesforce Site configured for the signing page
 *
 * QUICK START:
 * 1. In your Flow, use Assignment elements to build a collection of DocGen Signers
 * 2. Drag "DocGen: Create Signature Request" into your Flow
 * 3. Set Template Id, Related Record Id, and the Signers collection
 * 4. The action returns signing URLs and a request ID for downstream automation
 */
global with sharing class DocGenSignatureFlowAction { // NOPMD AvoidGlobalModifier - required for @InvocableMethod visibility in subscriber orgs

    /**
     * Represents one signer in a signature request.
     * In Flow, create a collection of these and pass it to the Signers input.
     */
    global class Signer {
        @InvocableVariable(required=true label='Name'
            description='The signer\'s full legal name. This is what appears on the signed document.')
        global String name;

        @InvocableVariable(required=true label='Email'
            description='The signer\'s email address. They will receive the signing link at this address.')
        global String email;

        @InvocableVariable(label='Role'
            description='Matches the {@Signature_Role} tag in your template. Example: "Buyer" matches {@Signature_Buyer}. Defaults to "Signer" if blank.')
        global String role;

        @InvocableVariable(label='Contact Id'
            description='Optional. The Salesforce Contact record Id for this signer. Links the signature audit trail to the Contact for reporting.')
        global Id contactId;
    }

    global class Request {
        @InvocableVariable(required=true label='Template Id'
            description='The Id of the DocGen Template to use. The template must have an active version with {@Signature_Role} tags. Example: Use a Get Records element to find the template, then pass its Id here.')
        global Id templateId;

        @InvocableVariable(required=true label='Related Record Id'
            description='The record this signature request is for. In a record-triggered Flow, use {!$Record.Id}. The signed PDF will be attached to this record when all signers complete.')
        global Id relatedRecordId;

        @InvocableVariable(required=true label='Signers'
            description='A collection of DocGen Signers. Each signer needs a Name and Email. Optionally set Role (to match template tags) and Contact Id (for audit linking). Build the collection using Assignment elements in your Flow.')
        global List<Signer> signers;

        // Keep legacy inputs for backward compatibility with existing Flows
        @InvocableVariable(label='Signer Names (Legacy)'
            description='DEPRECATED — use Signers collection instead. A list of names, one per signer.')
        global List<String> signerNames;

        @InvocableVariable(label='Signer Emails (Legacy)'
            description='DEPRECATED — use Signers collection instead. A list of emails matching Signer Names.')
        global List<String> signerEmails;

        @InvocableVariable(label='Signer Roles (Legacy)'
            description='DEPRECATED — use Signers collection instead.')
        global List<String> signerRoles;

        @InvocableVariable(label='Signer Contact Ids (Legacy)'
            description='DEPRECATED — use Signers collection instead.')
        global List<String> signerContactIds;

        @InvocableVariable(label='Send Branded Emails'
            description='Set to TRUE to have DocGen send branded invitation emails automatically (requires Org-Wide Email Address in DocGen settings). Set to FALSE (default) if your Flow sends its own emails using the Signer URLs output.')
        global Boolean sendEmails;

        @InvocableVariable(label='Signing Order'
            description='Enter "Parallel" (default) to email all signers at once, or "Sequential" to send one at a time — each signer is emailed only after the previous one completes.')
        global String signingOrder;
    }

    global class Result {
        @InvocableVariable(label='Signature Request Id'
            description='The Id of the created DocGen Signature Request record. Use this to track status, create related records, or link in downstream Flow elements.')
        global Id signatureRequestId;

        @InvocableVariable(label='Signer URLs'
            description='A collection of unique signing URLs — one per signer, in the same order as the Signers input. Each URL is valid for 48 hours. Use these in Send Email actions, Slack posts, or custom notifications.')
        global List<String> signerUrls;

        @InvocableVariable(label='Signer Names'
            description='The resolved signer names, in order. Useful for building email templates in your Flow.')
        global List<String> signerNames;

        @InvocableVariable(label='Signer Emails'
            description='The resolved signer emails, in order.')
        global List<String> signerEmails;

        @InvocableVariable(label='Signer Roles'
            description='The resolved role names per signer. Shows "Signer" for any role not specified.')
        global List<String> signerRoles;

        @InvocableVariable(label='Email Status'
            description='Shows the email delivery result. If signers report not receiving their link, check this. Common issues: no OWA configured, email deliverability set to System Only, daily limit exceeded, or OWA not set to All Profiles.')
        global String emailStatus;

        @InvocableVariable(label='Success'
            description='TRUE if the signature request was created successfully. FALSE if there was an error — check Error Message.')
        global Boolean success;

        @InvocableVariable(label='Error Message'
            description='Error details if Success is FALSE. Common: template not found, missing signer data, or permission issues.')
        global String errorMessage;
    }

    @InvocableMethod(
        label='DocGen: Create Signature Request'
        description='Creates a signature request with guided signing. Pass a collection of Signers (Name + Email + Role). Returns signing URLs. Supports sequential signing, initials, dates, and all v3 tag types.'
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
        Result r = new Result();
        r.success = false;
        r.signerUrls = new List<String>();
        r.signerNames = new List<String>();
        r.signerEmails = new List<String>();
        r.signerRoles = new List<String>();

        // Validation throws (preserves existing Flow behavior where bad input stops the Flow)
        if (req == null) {
            throw new DocGenException('Request is null');
        }
        if (req.templateId == null) {
            throw new DocGenException('Template Id is required — pass the Id of a DocGen Template record.');
        }
        if (req.relatedRecordId == null) {
            throw new DocGenException('Related Record Id is required — pass the record this signature is for.');
        }
        // Build signer inputs — prefer the new Signer collection, fall back to legacy lists
        // buildSignerInputs throws on validation errors (blank names/emails, length mismatch)
        List<Map<String, Object>> signerInputs = buildSignerInputs(req);
        if (signerInputs.isEmpty()) {
            throw new DocGenException('At least one signer is required. Pass a Signers collection or Signer Names + Emails.');
        }

        // Runtime errors (template not found, DML failures) are caught and returned in Result
        try {

            // Resolve signing order
            String signingOrder = String.isNotBlank(req.signingOrder) ? req.signingOrder : 'Parallel';
            if (signingOrder != 'Parallel' && signingOrder != 'Sequential') {
                signingOrder = 'Parallel';
            }

            // Use the v3 path — creates request, placements, preview, and optionally sends emails
            String signersJson = JSON.serialize(signerInputs);
            List<DocGenSignatureSenderController.SignerResult> signerResults =
                DocGenSignatureSenderController.createTemplateSignerRequestWithOrder(
                    req.templateId, req.relatedRecordId, signersJson, signingOrder
                );

            // Find the request ID
            if (!signerResults.isEmpty()) {
                String firstEmail = (String) signerInputs[0].get('signerEmail');
                /* code-analyzer-suppress ApexFlsViolation */
                List<DocGen_Signer__c> createdSigners = [
                    SELECT Signature_Request__c FROM DocGen_Signer__c
                    WHERE Signer_Email__c = :firstEmail
                    AND Signature_Request__r.Template__c = :req.templateId
                    AND Signature_Request__r.Related_Record_Id__c = :req.relatedRecordId
                    WITH SYSTEM_MODE
                    ORDER BY CreatedDate DESC LIMIT 1
                ]; // NOPMD ApexCRUDViolation - package-internal
                if (!createdSigners.isEmpty()) {
                    r.signatureRequestId = createdSigners[0].Signature_Request__c;
                }
            }

            // Populate result
            for (DocGenSignatureSenderController.SignerResult sr : signerResults) {
                r.signerUrls.add(sr.signerUrl);
                r.signerNames.add(sr.signerName);
                r.signerEmails.add(sr.signerEmail);
                r.signerRoles.add(sr.roleName);
            }

            // Read email status
            if (r.signatureRequestId != null) {
                /* code-analyzer-suppress ApexFlsViolation */
                DocGen_Signature_Request__c reqRecord = [
                    SELECT Email_Status__c FROM DocGen_Signature_Request__c
                    WHERE Id = :r.signatureRequestId WITH SYSTEM_MODE LIMIT 1
                ]; // NOPMD
                r.emailStatus = reqRecord.Email_Status__c;
            }

            r.success = true;

        } catch (Exception e) {
            r.errorMessage = e.getMessage();
            r.success = false;
        }

        return r;
    }

    /**
     * Builds signer input maps from either the new Signer collection or legacy parallel lists.
     * New Signer collection takes priority.
     */
    private static List<Map<String, Object>> buildSignerInputs(Request req) {
        List<Map<String, Object>> inputs = new List<Map<String, Object>>();

        // Prefer the new Signer apex type collection
        if (req.signers != null && !req.signers.isEmpty()) {
            for (Signer s : req.signers) {
                if (String.isBlank(s.name)) {
                    throw new DocGenException('Each signer must have a Name.');
                }
                if (String.isBlank(s.email)) {
                    throw new DocGenException('Each signer must have an Email. Signer "' + s.name + '" is missing an email.');
                }
                inputs.add(new Map<String, Object>{
                    'signerName' => s.name,
                    'signerEmail' => s.email,
                    'roleName' => String.isNotBlank(s.role) ? s.role : 'Signer',
                    'contactId' => s.contactId
                });
            }
            return inputs;
        }

        // Fall back to legacy parallel lists
        if (req.signerNames != null && !req.signerNames.isEmpty()) {
            if (req.signerEmails == null || req.signerEmails.size() != req.signerNames.size()) {
                throw new DocGenException('Signer Emails must match Signer Names. Got '
                    + (req.signerEmails == null ? 0 : req.signerEmails.size())
                    + ' emails for ' + req.signerNames.size() + ' names.');
            }
            for (Integer i = 0; i < req.signerNames.size(); i++) {
                if (String.isBlank(req.signerNames[i])) {
                    throw new DocGenException('Signer Name at position ' + (i + 1) + ' is blank.');
                }
                if (String.isBlank(req.signerEmails[i])) {
                    throw new DocGenException('Signer Email at position ' + (i + 1) + ' is blank.');
                }
                String role = (req.signerRoles != null && i < req.signerRoles.size() && String.isNotBlank(req.signerRoles[i]))
                    ? req.signerRoles[i] : 'Signer';
                String contactId = (req.signerContactIds != null && i < req.signerContactIds.size())
                    ? req.signerContactIds[i] : null;
                inputs.add(new Map<String, Object>{
                    'signerName' => req.signerNames[i],
                    'signerEmail' => req.signerEmails[i],
                    'roleName' => role,
                    'contactId' => contactId
                });
            }
        }

        return inputs;
    }
}
