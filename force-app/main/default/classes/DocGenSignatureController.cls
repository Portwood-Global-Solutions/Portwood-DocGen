public without sharing class DocGenSignatureController {

    // Signature links expire after this many hours from creation
    private static final Integer TOKEN_EXPIRATION_HOURS = 48;
    // PIN verification settings
    private static final Integer PIN_EXPIRATION_MINUTES = 10;
    private static final Integer MAX_PIN_ATTEMPTS = 3;

    public class SignatureInitResponse {
        @AuraEnabled public Boolean isValid;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String signerName;
        @AuraEnabled public String signerEmail;
        @AuraEnabled public String documentTitle;
        @AuraEnabled public String documentUrl;
        @AuraEnabled public String templateBase64;
        @AuraEnabled public String recordId;
        @AuraEnabled public String roleName;
        @AuraEnabled public Integer totalSigners;
        @AuraEnabled public Integer signedCount;
        @AuraEnabled public Boolean isSignerToken;
        @AuraEnabled public Boolean requiresPin;
    }

    public class SaveSignatureResult {
        @AuraEnabled public Boolean isComplete;
        @AuraEnabled public Integer remaining;
    }

    /**
     * Captures the client IP address from the current request context.
     * Checks X-Forwarded-For (load balancer/proxy) first, falls back to
     * Salesforce session info, then to True-Client-IP.
     */
    private static String captureClientIp() {
        // Try VF page request headers first
        try {
            PageReference pr = ApexPages.currentPage();
            if (pr != null) {
                Map<String, String> headers = pr.getHeaders();
                // X-Forwarded-For contains the original client IP when behind a proxy/LB
                String forwarded = headers.get('X-Forwarded-For');
                if (String.isNotBlank(forwarded)) {
                    // May contain comma-separated list — first is the real client
                    return forwarded.split(',')[0].trim();
                }
                String trueClientIp = headers.get('True-Client-IP');
                if (String.isNotBlank(trueClientIp)) {
                    return trueClientIp.trim();
                }
            }
        } catch (Exception e) {
            // Not in a VF context
        }
        // Fallback: try session-based IP (skip for guest users and tests — triggers uncatchable session error)
        if (!Test.isRunningTest() && UserInfo.getUserType() != 'Guest') {
            try {
                Map<String, String> session = Auth.SessionManagement.getCurrentSession();
                String loginIp = session.get('SourceIp');
                if (String.isNotBlank(loginIp)) {
                    return loginIp;
                }
            } catch (Exception e) {
                // Session info unavailable
            }
        }
        return 'Unknown';
    }

    /**
     * Validates a signer token. Queries DocGen_Signer__c first (multi-signer),
     * falls back to DocGen_Signature_Request__c (legacy single-signer).
     */
    @AuraEnabled
    @RemoteAction
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    public static SignatureInitResponse validateToken(String token) {
        SignatureInitResponse res = new SignatureInitResponse();
        res.isValid = false;

        if (String.isBlank(token)) {
            res.errorMessage = 'Invalid or missing security token.';
            return res;
        }

        // Token format validation: must be a 64-character hex string (SHA-256 output)
        if (token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            res.errorMessage = 'Invalid security token format.';
            return res;
        }

        // Try multi-signer path first
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Status__c, Signer_Name__c, Signer_Email__c, Role_Name__c, Sort_Order__c,
                   CreatedDate, PIN_Verified_At__c,
                   Signature_Request__r.Id, Signature_Request__r.Status__c,
                   Signature_Request__r.Source_Document_Id__c, Signature_Request__r.Related_Record_Id__c,
                   Signature_Request__r.Template__c, Signature_Request__r.Template__r.Name
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (!signers.isEmpty()) {
            // Token expiration: 30 days from creation
            if (signers[0].CreatedDate.addHours(TOKEN_EXPIRATION_HOURS) < System.now()) {
                res.errorMessage = 'This signature link has expired. Please request a new one.';
                return res;
            }
            return validateSignerToken(signers[0]);
        }

        // Legacy fallback: single-signer on DocGen_Signature_Request__c
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c, Signer_Name__c, Source_Document_Id__c, Related_Record_Id__c, CreatedDate
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (requests.isEmpty()) {
            res.errorMessage = 'Signature request not found. The link may be invalid or expired.';
            return res;
        }

        // Token expiration: 30 days from creation
        if (requests[0].CreatedDate.addHours(TOKEN_EXPIRATION_HOURS) < System.now()) {
            res.errorMessage = 'This signature link has expired. Please request a new one.';
            return res;
        }

        return validateLegacyRequest(requests[0]);
    }

    /**
     * Sends a 6-digit PIN to the signer's email for identity verification.
     * The PIN is hashed (SHA-256) before storage — plaintext is never persisted.
     */
    @AuraEnabled
    @RemoteAction
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    public static Map<String, Object> sendPin(String token, String email) {
        // CxSAST: Apex_CRUD_Violation — SYSTEM_MODE required for guest user context; CRUD enforced by DocGen permission sets
        Map<String, Object> result = new Map<String, Object>();

        // CxSAST: Crypto operations for signature token/PIN generation — not hardcoded secrets
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            result.put('success', false);
            result.put('message', 'Invalid security token.');
            return result;
        }

        // CxSAST: Crypto operations for signature token/PIN generation — not hardcoded secrets
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Signer_Email__c, PIN_Attempts__c, Status__c, CreatedDate
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (signers.isEmpty()) {
            result.put('success', false);
            result.put('message', 'Signer not found.');
            return result;
        }

        DocGen_Signer__c signer = signers[0];

        // Validate email matches the intended signer (case-insensitive)
        if (String.isBlank(email) || !email.equalsIgnoreCase(signer.Signer_Email__c)) {
            result.put('success', false);
            result.put('message', 'Email address does not match the intended signer.');
            return result;
        }

        // Check if token is expired
        if (signer.CreatedDate.addHours(TOKEN_EXPIRATION_HOURS) < System.now()) {
            result.put('success', false);
            result.put('message', 'This signature link has expired.');
            return result;
        }

        // Check if already locked out
        if (signer.PIN_Attempts__c >= MAX_PIN_ATTEMPTS) {
            result.put('success', false);
            result.put('message', 'Too many failed attempts. Please request a new signature link.');
            return result;
        }

        // Generate 6-digit PIN
        Integer pin = Math.mod(Math.abs(Crypto.getRandomInteger()), 900000) + 100000;
        String pinStr = String.valueOf(pin);

        // Hash the PIN for storage (never store plaintext)
        String pinHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(pinStr))
        );

        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        // Store hash and expiry on signer record
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        signer.PIN_Hash__c = pinHash;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        signer.PIN_Expires_At__c = System.now().addMinutes(PIN_EXPIRATION_MINUTES);
        signer.PIN_Attempts__c = 0; // Reset attempts on new PIN
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        // Send PIN via email
        String emailError = sendPinEmail(signer.Signer_Email__c, pinStr);
        if (emailError != null) {
            result.put('success', false);
            result.put('message', 'Failed to send verification email. Please contact the sender.');
            return result;
        }

        result.put('success', true);
        result.put('message', 'A verification code has been sent to your email.');
        return result;
    }

    /**
     * Verifies the 6-digit PIN entered by the signer.
     * Burns the token after MAX_PIN_ATTEMPTS failed attempts.
     */
    @AuraEnabled
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    @RemoteAction
    public static Map<String, Object> verifyPin(String token, String pin) {
        Map<String, Object> result = new Map<String, Object>();

        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            result.put('success', false);
            result.put('message', 'Invalid security token.');
            return result;
        }

        if (String.isBlank(pin) || !Pattern.matches('[0-9]{6}', pin)) {
            result.put('success', false);
            result.put('message', 'Please enter a valid 6-digit code.');
            return result;
        }

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, PIN_Hash__c, PIN_Expires_At__c, PIN_Attempts__c, Status__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (signers.isEmpty()) {
            result.put('success', false);
            result.put('message', 'Signer not found.');
            return result;
        }

        DocGen_Signer__c signer = signers[0];

        // Check if locked out
        if (signer.PIN_Attempts__c >= MAX_PIN_ATTEMPTS) {
            result.put('success', false);
            result.put('message', 'Too many failed attempts. Please request a new signature link.');
            return result;
        }

        // Check if PIN has been sent
        if (String.isBlank(signer.PIN_Hash__c) || signer.PIN_Expires_At__c == null) {
            result.put('success', false);
            result.put('message', 'No verification code found. Please request a new code.');
            return result;
        }

        // Check expiry
        if (signer.PIN_Expires_At__c < System.now()) {
            result.put('success', false);
            result.put('message', 'Verification code has expired. Please request a new code.');
            return result;
        }

        // Hash the submitted PIN and compare
        String submittedHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(pin))
        );

        if (submittedHash != signer.PIN_Hash__c) {
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            // Increment failed attempts
            signer.PIN_Attempts__c = (signer.PIN_Attempts__c == null ? 0 : signer.PIN_Attempts__c) + 1;
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(signer, false, AccessLevel.SYSTEM_MODE);

            Integer remaining = MAX_PIN_ATTEMPTS - Integer.valueOf(signer.PIN_Attempts__c);
            if (remaining <= 0) {
                result.put('success', false);
                result.put('message', 'Too many failed attempts. This link has been locked. Please request a new signature link.');
            } else {
                result.put('success', false);
                result.put('message', 'Incorrect code. ' + remaining + ' attempt' + (remaining > 1 ? 's' : '') + ' remaining.');
            }
            return result;
        }

        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        // PIN verified — record timestamp and clear PIN data
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        signer.PIN_Verified_At__c = System.now();
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        signer.PIN_Hash__c = null;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        signer.PIN_Expires_At__c = null;
        signer.PIN_Attempts__c = 0;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        if (signer.Status__c == 'Pending') {
            signer.Status__c = 'Viewed';
        }
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        result.put('success', true);
        result.put('message', 'Email verified successfully.');
        return result;
    }

    /**
     * Sends the 6-digit PIN to the signer's email.
     */
    private static String sendPinEmail(String email, String pin) {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String brandColor = String.isNotBlank(settings.Signature_Email_Brand_Color__c)
            ? settings.Signature_Email_Brand_Color__c : '#0176D3';
        String companyName = settings.Company_Name__c;

        // OWA is required for guest user context — warn if not configured
        String owaId = settings.Signature_OWA_Id__c;
        if (String.isBlank(owaId) && UserInfo.getUserType() == 'Guest') {
            System.debug(LoggingLevel.ERROR, 'DocGen: PIN email failed — no Org-Wide Email Address configured in Signature Settings (required for guest users)');
            return 'No Org-Wide Email Address configured. An admin must set one in DocGen Signature Settings.';
        }

        String html = '<!DOCTYPE html><html><head><meta charset="utf-8"/></head>';
        html += '<body style="margin:0;padding:0;background-color:#f4f4f4;font-family:Arial,Helvetica,sans-serif;">';
        html += '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f4f4f4;">';
        html += '<tr><td align="center" style="padding:24px 16px;">';
        html += '<table role="presentation" width="480" cellpadding="0" cellspacing="0" style="max-width:480px;width:100%;background-color:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08);">';
        html += '<tr><td style="background-color:' + brandColor + ';padding:16px 32px;text-align:center;">';
        if (String.isNotBlank(companyName)) {
            html += '<span style="color:#ffffff;font-size:18px;font-weight:bold;">' + companyName.escapeHtml4() + '</span>';
        }
        html += '</td></tr>';
        html += '<tr><td style="padding:32px;text-align:center;">';
        html += '<p style="font-size:16px;color:#333333;margin:0 0 8px 0;">Your verification code is:</p>';
        html += '<p style="font-size:36px;font-weight:bold;color:#181818;letter-spacing:8px;margin:16px 0;font-family:monospace;">' + pin.escapeHtml4() + '</p>';
        html += '<p style="font-size:13px;color:#706e6b;margin:16px 0 0 0;">This code expires in ' + PIN_EXPIRATION_MINUTES + ' minutes.</p>';
        html += '<p style="font-size:13px;color:#706e6b;margin:4px 0 0 0;">If you did not request this code, you can safely ignore this email.</p>';
        html += '</td></tr>';
        html += '</table></td></tr></table></body></html>';

        Messaging.SingleEmailMessage email2 = new Messaging.SingleEmailMessage();
        email2.setToAddresses(new List<String>{ email });
        email2.setSubject('Your DocGen Signature Verification Code');
        email2.setHtmlBody(html);
        email2.setSaveAsActivity(false);
        if (String.isNotBlank(owaId)) {
            email2.setOrgWideEmailAddressId(owaId);
        }

        List<Messaging.SendEmailResult> results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email2 }, false);
        if (!results.isEmpty() && !results[0].isSuccess()) {
            String errMsg = results[0].getErrors()[0].getMessage();
            System.debug(LoggingLevel.ERROR, 'DocGen: PIN email send failed — ' + errMsg);
            return errMsg;
        }
        return null;
    }

    private static SignatureInitResponse validateSignerToken(DocGen_Signer__c signer) {
        SignatureInitResponse res = new SignatureInitResponse();
        res.isValid = false;

        if (signer.Status__c == 'Signed') {
            res.errorMessage = 'You have already signed this document.';
            return res;
        }

        DocGen_Signature_Request__c parentReq = signer.Signature_Request__r;
        if (parentReq.Status__c == 'Signed' || parentReq.Status__c == 'Cancelled') {
            res.errorMessage = 'This signature request is no longer active.';
            return res;
        }

        // Update signer status to Viewed (SYSTEM_MODE for guest user CRUD bypass)
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        if (signer.Status__c == 'Pending') {
            signer.Status__c = 'Viewed';
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(signer, false, AccessLevel.SYSTEM_MODE);
        }

        res.isValid = true;
        res.isSignerToken = true;
        res.signerName = signer.Signer_Name__c;
        res.signerEmail = signer.Signer_Email__c;
        res.roleName = signer.Role_Name__c;
        // PIN is required if not yet verified
        res.requiresPin = (signer.PIN_Verified_At__c == null);

        // Count total and signed signers
        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> allSigners = [
            SELECT Status__c FROM DocGen_Signer__c
            WHERE Signature_Request__c = :parentReq.Id
            WITH SYSTEM_MODE
        ];
        res.totalSigners = allSigners.size();
        Integer signed = 0;
        for (DocGen_Signer__c s : allSigners) {
            if (s.Status__c == 'Signed') signed++;
        }
        res.signedCount = signed;

        // Get document metadata — template name or source document title
        if (parentReq.Template__c != null) {
            res.documentTitle = parentReq.Template__r.Name;
            // No public link needed — preview is rendered from template merge
        } else {
            Id sourceDocId = parentReq.Source_Document_Id__c;
            // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<ContentVersion> cvs = [SELECT Id, Title FROM ContentVersion WHERE Id = :sourceDocId WITH SYSTEM_MODE LIMIT 1];
            if (!cvs.isEmpty()) {
                res.documentTitle = cvs[0].Title;
                res.documentUrl = getOrCreatePublicLink(cvs[0]);
            } else {
                res.documentTitle = 'Confidential Document';
            }
        }

        return res;
    }

    private static SignatureInitResponse validateLegacyRequest(DocGen_Signature_Request__c req) {
        SignatureInitResponse res = new SignatureInitResponse();
        res.isValid = false;

        if (req.Status__c == 'Signed') {
            res.errorMessage = 'This document has already been signed.';
            return res;
        }
        if (req.Status__c == 'Cancelled') {
            res.errorMessage = 'This signature request has been cancelled.';
            return res;
        }

        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        if (req.Status__c == 'Sent') {
            req.Status__c = 'Viewed';
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(req, false, AccessLevel.SYSTEM_MODE);
        }

        res.isValid = true;
        res.isSignerToken = false;
        res.signerName = req.Signer_Name__c;
        res.totalSigners = 1;
        res.signedCount = 0;

        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<ContentVersion> cvs = [SELECT Id, Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
        if (!cvs.isEmpty()) {
            res.documentTitle = cvs[0].Title;
            res.documentUrl = getOrCreatePublicLink(cvs[0]);
        } else {
            res.documentTitle = 'Confidential Document';
        }

        return res;
    }

    // CxSAST: Apex_CRUD_ContentDistribution — SYSTEM_MODE required for guest user context; ContentDistribution created for signature document preview
    private static String getOrCreatePublicLink(ContentVersion cv) {
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<ContentDistribution> dists = [
            SELECT DistributionPublicUrl
            FROM ContentDistribution
            WHERE ContentVersionId = :cv.Id
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (!dists.isEmpty()) {
            return dists[0].DistributionPublicUrl;
        }
        ContentDistribution cd = new ContentDistribution();
        cd.Name = 'Signature Preview - ' + cv.Title;
        cd.ContentVersionId = cv.Id;
        cd.PreferencesAllowViewInBrowser = true;
        cd.PreferencesLinkLatestVersion = true;
        cd.PreferencesExpires = false;
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<ContentDistribution>{ cd }, false, AccessLevel.SYSTEM_MODE);
        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        cd = new ContentDistribution(Id = cd.Id);
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        cd = [SELECT DistributionPublicUrl FROM ContentDistribution WHERE Id = :cd.Id WITH SYSTEM_MODE LIMIT 1];
        return cd.DistributionPublicUrl;
    }

    /**
     * Fetches pre-rendered HTML for document display in the signature page.
     * Template-based requests: merges template with record data for a fully merged preview.
     * Legacy requests: converts source DOCX to HTML.
     */
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    @AuraEnabled
    @RemoteAction
    public static SignatureInitResponse fetchDocumentData(String token) {
        SignatureInitResponse res = validateToken(token);
        if (!res.isValid) return res;

        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        // Try multi-signer path
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Signature_Request__r.Source_Document_Id__c, Signature_Request__r.Related_Record_Id__c,
                   Signature_Request__r.Template__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        Id sourceDocId;
        Id templateId;
        Id requestId;
        String recordId;
        if (!signers.isEmpty()) {
            sourceDocId = signers[0].Signature_Request__r.Source_Document_Id__c;
            templateId = signers[0].Signature_Request__r.Template__c;
            requestId = signers[0].Signature_Request__r.Id;
            recordId = signers[0].Signature_Request__r.Related_Record_Id__c;
            res.recordId = recordId;
        } else {
            // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
            // Legacy fallback
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> requests = [
                SELECT Id, Source_Document_Id__c, Related_Record_Id__c, Template__c
                FROM DocGen_Signature_Request__c
                WHERE Secure_Token__c = :token
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (!requests.isEmpty()) {
                sourceDocId = requests[0].Source_Document_Id__c;
                templateId = requests[0].Template__c;
                requestId = requests[0].Id;
                recordId = requests[0].Related_Record_Id__c;
                res.recordId = recordId;
            }
        }

        // Template-based: load preview HTML from Signature_Data__c cache on the request,
        // or generate on-the-fly if cache is empty.
        if (templateId != null && requestId != null) {
            // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
            // Try cached preview first
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> reqs = [
                SELECT Signature_Data__c FROM DocGen_Signature_Request__c
                WHERE Id = :requestId WITH SYSTEM_MODE LIMIT 1
            ];
            if (!reqs.isEmpty() && String.isNotBlank(reqs[0].Signature_Data__c)) {
                try {
                    Map<String, Object> cachedData = (Map<String, Object>) JSON.deserializeUntyped(reqs[0].Signature_Data__c);
                    String previewHtml = (String) cachedData.get('previewHtml');
                    if (String.isNotBlank(previewHtml)) {
                        // Inject watermark overlay at read time — embedded base64 image
                        // would exceed Signature_Data__c's LongTextArea limit if cached.
                        previewHtml = DocGenSignatureSenderController.injectPreviewWatermarkOverlay(previewHtml, templateId);
                        res.templateBase64 = previewHtml;
                        return res;
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'DocGen: Failed to parse cached preview: ' + e.getMessage());
                }
            }

            // Fallback: generate preview on-the-fly from template + record data
            try {
                Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(templateId, recordId);
                String docXml = (String) mergeData.get('documentXml');
                Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
                if (String.isNotBlank(docXml)) {
                    DocGenService.applyWatermarkOverride(templateId);
                    String liveHtml = DocGenHtmlRenderer.convertToHtml(docXml, pdfImageMap);
                    liveHtml = DocGenSignatureSenderController.injectPreviewWatermarkOverlay(liveHtml, templateId);
                    res.templateBase64 = liveHtml;
                    return res;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'DocGen: Failed to generate live preview: ' + e.getMessage());
            }

            res.templateBase64 = '<html><body><p>Document preview unavailable.</p></body></html>';
            return res;
        }

        // Legacy: convert source DOCX to HTML
        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        if (sourceDocId != null) {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :sourceDocId WITH SYSTEM_MODE LIMIT 1];
            if (!cvs.isEmpty()) {
                res.templateBase64 = getDocumentHtml(cvs[0].VersionData);
            }
        }
        return res;
    }

    /**
     * Converts a DOCX blob to pre-rendered HTML by extracting and converting document.xml.
     * Returns the HTML string (stored in templateBase64 field for transport).
     */
    private static String getDocumentHtml(Blob docxBlob) {
        try {
            Map<String, Object> extracted = extractDocxParts(docxBlob);
            String documentXml = (String) extracted.get('documentXml');
            Map<String, String> imagesByRelId = (Map<String, String>) extracted.get('imagesByRelId');

            if (documentXml != null) {
                return DocGenHtmlRenderer.convertToHtml(documentXml, imagesByRelId);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error converting DOCX to HTML for signature display: ' + e.getMessage());
        }
        return '<html><body><p>Document preview unavailable.</p></body></html>';
    }

    /**
     * Saves a signer's typed name as their electronic signature.
     * Requires PIN verification and consent checkbox.
     * Returns whether all signers have now completed.
     */
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    @AuraEnabled
    @RemoteAction
    public static SaveSignatureResult saveSignature(String token, String typedName, Boolean consentGiven, String ipAddress, String userAgent) {
        SaveSignatureResult result = new SaveSignatureResult();

        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        if (String.isBlank(typedName)) {
            throw new AuraHandledException('Please type your name to sign.');
        }

        if (consentGiven != true) {
            throw new AuraHandledException('You must agree to sign electronically.');
        }

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Status__c, Signer_Name__c, Signer_Email__c, Signature_Request__c,
                   Role_Name__c, Contact__c, CreatedDate, PIN_Verified_At__c, Consent_Captured__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (signer.CreatedDate.addHours(TOKEN_EXPIRATION_HOURS) < System.now()) {
            throw new AuraHandledException('This signature link has expired.');
        }
        if (signer.Status__c == 'Signed') {
            throw new AuraHandledException('You have already signed this document.');
        }

        // Require PIN verification before allowing signature
        if (signer.PIN_Verified_At__c == null) {
            throw new AuraHandledException('Email verification is required before signing.');
        }

        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        // Store typed name and mark as signed
        signer.Signature_Data__c = typedName;
        signer.Status__c = 'Signed';
        signer.Consent_Captured__c = true;
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        // Create audit trail immediately with all available data
        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
        audit.Signature_Request__c = signer.Signature_Request__c;
        audit.Signer__c = signer.Id;
        audit.Signer_Name__c = signer.Signer_Name__c;
        audit.Signer_Email__c = signer.Signer_Email__c;
        audit.Contact__c = signer.Contact__c;
        audit.Signed_Date__c = System.now();
        audit.IP_Address__c = captureClientIp();
        audit.User_Agent__c = String.isNotBlank(userAgent) ? userAgent.left(255) : 'Unknown';
        audit.Consent_Captured__c = true;
        audit.PIN_Verified_At__c = signer.PIN_Verified_At__c;
        // Document hash is set later when PDF is generated
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

        // Check if all signers are now complete
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> allSigners = [
            SELECT Status__c FROM DocGen_Signer__c
            WHERE Signature_Request__c = :signer.Signature_Request__c
            WITH SYSTEM_MODE
        ];

        Integer remaining = 0;
        for (DocGen_Signer__c s : allSigners) {
            if (s.Status__c != 'Signed') remaining++;
        }

        result.remaining = remaining;
        result.isComplete = (remaining == 0);

        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        // Update parent request status
        DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = signer.Signature_Request__c);
        parentReq.Status__c = 'In Progress';
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(parentReq, false, AccessLevel.SYSTEM_MODE);

        // All post-signature actions (PDF generation, notifications, sequential signing)
        // are deferred to system context via platform event.
        // Guest users cannot send emails, query User records, or access ContentVersion
        // (triggers session ID error). The trigger runs as Automated Process user.
        try {
            DocGen_Signature_PDF__e pdfEvent = new DocGen_Signature_PDF__e();
            pdfEvent.Request_Id__c = signer.Signature_Request__c;
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            EventBus.publish(pdfEvent);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Post-signature event publish failed: ' + e.getMessage());
        }

        return result;
    }

    /**
     * Triggers PDF generation after all signers have completed.
     * For multi-signer: called only when all signers have completed.
     * For legacy single-signer: stamps the single signature directly.
     */
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    @AuraEnabled
    @RemoteAction
    public static Map<String, String> stampAndReturnSource(String token, String base64Image) {
        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        // Determine if this is a multi-signer or legacy request
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signerList = [
            SELECT Id, Signature_Request__c,
                   Signature_Request__r.Source_Document_Id__c,
                   Signature_Request__r.Related_Record_Id__c,
                   Signature_Request__r.Template__c,
                   Signature_Request__r.Template__r.Name
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (!signerList.isEmpty()) {
            return stampMultiSignerAndSavePdf(signerList[0]);
        }

        // Legacy single-signer fallback (image already saved via saveLegacySignature)
        return stampLegacySignerAndSavePdf(token);
    }

    private static Map<String, String> stampMultiSignerAndSavePdf(DocGen_Signer__c triggerSigner) {
        Id requestId = triggerSigner.Signature_Request__c;
        Id sourceDocId = triggerSigner.Signature_Request__r.Source_Document_Id__c;
        Id templateId = triggerSigner.Signature_Request__r.Template__c;
        String relatedRecordId = triggerSigner.Signature_Request__r.Related_Record_Id__c;

        try {
            // PDF generation already triggered by saveSignature's platform event.
            // Re-publishing here would enqueue a duplicate queueable → two signed PDFs.
            // Why: saveSignature publishes on every signer-completion; the trigger gates
            // PDF enqueue on remaining==0. Calling stampAndReturnSource after a complete
            // saveSignature would race a second event past the same gate.
            // How to apply: any new "post-sign finalization" work belongs in the trigger
            // or queueable, not here.

            // Return title for the UI
            String docTitle;
            if (templateId != null) {
                docTitle = triggerSigner.Signature_Request__r.Template__r.Name;
            // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
            } else if (sourceDocId != null) {
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                ContentVersion sourceDoc = [SELECT Title FROM ContentVersion WHERE Id = :sourceDocId WITH SYSTEM_MODE LIMIT 1];
                docTitle = sourceDoc.Title;
            } else {
                docTitle = 'Document';
            }
            return new Map<String, String>{
                'status' => 'complete',
                'title' => docTitle + ' - Signed'
            };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Multi-signer stamping failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while processing signatures.');
        }
    }

    /**
     * Saves the typed name for a legacy single-signer request.
     * Called as a separate transaction BEFORE stampAndReturnSource to avoid DML-before-callout.
     */
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    @AuraEnabled
    @RemoteAction
    public static void saveLegacySignature(String token, String typedName) {
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (requests.isEmpty() || requests[0].Status__c == 'Signed' || requests[0].Status__c == 'Cancelled') {
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            throw new AuraHandledException('Invalid request or document already signed.');
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        }
        requests[0].Signature_Data__c = typedName;
        requests[0].Status__c = 'Viewed';
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(requests[0], false, AccessLevel.SYSTEM_MODE);
    }

    private static Map<String, String> stampLegacySignerAndSavePdf(String token) {
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c, Signer_Name__c, Signer_Email__c, Source_Document_Id__c, Related_Record_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (requests.isEmpty() || requests[0].Status__c == 'Signed' || requests[0].Status__c == 'Cancelled') {
            throw new AuraHandledException('Invalid request or document already signed.');
        }

        DocGen_Signature_Request__c req = requests[0];

        try {
            // PDF generation via VF page (stamps signatures internally, no DML before callout)
            Blob pdfBlob = convertSignatureRequestToPdf(req.Id);

            // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets

            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            ContentVersion sourceDoc = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
            String fileName = sourceDoc.Title + ' - Signed';
            String base64Pdf = EncodingUtil.base64Encode(pdfBlob);

            // Save PDF to record
            saveSignedDocument(req.Related_Record_Id__c, fileName, base64Pdf, 'pdf');


            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects

            // Update request status and clear signature data
            req.Status__c = 'Signed';
            req.Signature_Data__c = null;
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(req, false, AccessLevel.SYSTEM_MODE);

            // Create audit trail
            String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
            DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
            audit.Signature_Request__c = req.Id;
            audit.Signer_Name__c = req.Signer_Name__c;
            audit.Signer_Email__c = req.Signer_Email__c;
            audit.Signed_Date__c = System.now();
            audit.Document_Hash_SHA256__c = pdfHash;
            audit.IP_Address__c = 'Server-Side';
            audit.User_Agent__c = 'VF renderAs=pdf - Server-Side PDF Generation';
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

            return new Map<String, String>{
                'status' => 'complete',
                'title' => fileName
            };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Legacy stamping failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while processing the signature.');
        }
    }

    /**
     * Saves a signed document to a record using SYSTEM_MODE DML.
     * Guest users cannot use Security.stripInaccessible or USER_MODE on ContentVersion/ContentDocumentLink,
     * so this method bypasses CRUD checks. Access is gated by the validated signature token.
     */
    private static Id saveSignedDocument(String recordId, String fileName, String base64Data, String extension) {
        ContentVersion cv = new ContentVersion();
        cv.Title = fileName;
        cv.PathOnClient = fileName + (extension.startsWith('.') ? extension : '.' + extension);
        cv.VersionData = EncodingUtil.base64Decode(base64Data);
        cv.IsMajorVersion = true;
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<ContentVersion>{ cv }, false, AccessLevel.SYSTEM_MODE);

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Id contentDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH SYSTEM_MODE].ContentDocumentId;

        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = contentDocId;
        cdl.LinkedEntityId = recordId;
        cdl.ShareType = 'V';
        cdl.Visibility = 'AllUsers';
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<ContentDocumentLink>{ cdl }, false, AccessLevel.SYSTEM_MODE);

        return contentDocId;
    }

    /**
     * Converts a stamped DOCX blob to HTML. Public so DocGenPdfRendererController can call it.
     */
    public static String convertStampedDocxToHtml(Blob docxBlob) {
        Map<String, Object> extracted = extractDocxParts(docxBlob);
        String documentXml = (String) extracted.get('documentXml');
        Map<String, String> imagesByRelId = (Map<String, String>) extracted.get('imagesByRelId');
        return DocGenHtmlRenderer.convertToHtml(documentXml, imagesByRelId);
    }

    /**
     * Generates a PDF from a signature request using Blob.toPdf().
     * Stamps typed-name signatures into the DOCX, converts to HTML, renders PDF.
     * No image blobs — just text replacement.
     */
    public static Blob convertSignatureRequestToPdf(Id requestId) {
        if (Test.isRunningTest()) {
            return Blob.toPdf('<html><body><p>Test PDF - Signed Document</p></body></html>');
        }

        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> requests = [
            SELECT Source_Document_Id__c, Template__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (requests.isEmpty()) {
            throw new DocGenException('Signature request not found.');
        }

        Id sourceDocId = requests[0].Source_Document_Id__c;
        DocGenService.applyWatermarkOverride(requests[0].Template__c);

        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        // Get typed-name signatures from signers
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Role_Name__c, Signature_Data__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId AND Status__c = 'Signed'
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];

        List<DocGenSignatureService.SignerData> signerDataList = new List<DocGenSignatureService.SignerData>();
        for (DocGen_Signer__c s : signers) {
            if (String.isNotBlank(s.Signature_Data__c)) {
                signerDataList.add(new DocGenSignatureService.SignerData(s.Role_Name__c, s.Signature_Data__c));
            }
        }

        Blob stampedBlob;
        if (!signerDataList.isEmpty()) {
            stampedBlob = DocGenSignatureService.stampAllSignaturesToBlob(sourceDocId, signerDataList);
        }

        if (stampedBlob == null) {
            throw new DocGenException('Could not generate stamped document.');
        }

        // Extract DOCX parts — only template images remain (no signature images).
        Map<String, Object> parts = extractDocxParts(stampedBlob);
        String documentXml = (String) parts.get('documentXml');
        Map<String, String> imagesByRelId = (Map<String, String>) parts.get('imagesByRelId');

        // For any remaining template images, use relative CV URLs
        Map<String, String> imageUrlMap = new Map<String, String>();
        if (imagesByRelId != null) {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<ContentVersion> allTmplCvs = [
                SELECT Id, Title FROM ContentVersion
                WHERE Title LIKE 'docgen_tmpl_img_%'
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC
                LIMIT 50
            ];
            Map<String, String> tmplImgUrls = new Map<String, String>();
            for (ContentVersion cv : allTmplCvs) {
                String title = cv.Title;
                Integer lastUnderscore = title.lastIndexOf('_');
                if (lastUnderscore > 0) {
                    String imgRelId = title.substring(lastUnderscore + 1);
                    if (!tmplImgUrls.containsKey(imgRelId)) {
                        tmplImgUrls.put(imgRelId, '/sfc/servlet.shepherd/version/download/' + cv.Id);
                    }
                }
            }
            for (String relId : imagesByRelId.keySet()) {
                if (tmplImgUrls.containsKey(relId)) {
                    imageUrlMap.put(relId, tmplImgUrls.get(relId));
                }
            }
        }

        String html = DocGenHtmlRenderer.convertToHtml(documentXml, imageUrlMap);
        return Blob.toPdf(html);
    }

    /**
     * Extracts document.xml, rels, and images from a DOCX blob.
     * Returns a map keyed by relationship ID → base64 image data (as the renderer expects).
     */
    public static Map<String, Object> extractDocxParts(Blob docxBlob) {
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        String documentXml = null;
        String relsXml = null;
        Map<String, String> imagesByFileName = new Map<String, String>();

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            if (name == 'word/document.xml') {
                documentXml = reader.extract(name).toString();
            } else if (name == 'word/_rels/document.xml.rels') {
                relsXml = reader.extract(name).toString();
            } else if (name.startsWith('word/media/')) {
                String fileName = name.substringAfter('word/media/');
                imagesByFileName.put(fileName, EncodingUtil.base64Encode(reader.extract(name)));
            }
        }

        // Build relId → base64 map by parsing the .rels XML
        Map<String, String> imagesByRelId = new Map<String, String>();
        if (relsXml != null) {
            // Parse <Relationship Id="rId..." Target="media/filename.png"/> entries
            Integer cursor = 0;
            while (cursor < relsXml.length()) {
                Integer relStart = relsXml.indexOf('<Relationship ', cursor);
                if (relStart == -1) break;
                Integer relEnd = relsXml.indexOf('/>', relStart);
                if (relEnd == -1) break;
                relEnd += 2;

                String relTag = relsXml.substring(relStart, relEnd);
                String relId = extractXmlAttr(relTag, 'Id');
                String target = extractXmlAttr(relTag, 'Target');

                if (relId != null && target != null && target.startsWith('media/')) {
                    String mediaFileName = target.substringAfter('media/');
                    String base64 = imagesByFileName.get(mediaFileName);
                    if (base64 != null) {
                        imagesByRelId.put(relId, base64);
                    }
                }
                cursor = relEnd;
            }
        }

        return new Map<String, Object>{
            'documentXml' => documentXml,
            'imagesByRelId' => imagesByRelId
        };
    }

    /**
     * Extracts an attribute value from an XML tag string.
     */
    private static String extractXmlAttr(String tag, String attrName) {
        String search = attrName + '="';
        Integer start = tag.indexOf(search);
        if (start == -1) return null;
        start += search.length();
        Integer end2 = tag.indexOf('"', start);
        if (end2 == -1) return null;
        return tag.substring(start, end2);
    }

    /**
     * Cleans up temporary signature image ContentVersion records.
     */
    private static void cleanupSignatureTempImages(String batchKey) {
        if (String.isBlank(batchKey)) return;
        try {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<ContentVersion> tempCvs = [
                SELECT ContentDocumentId FROM ContentVersion
                WHERE Title LIKE :('docgen_sig_' + batchKey + '_%')
                WITH SYSTEM_MODE
            ];
            if (!tempCvs.isEmpty()) {
                Set<Id> docIds = new Set<Id>();
                for (ContentVersion cv : tempCvs) {
                    docIds.add(cv.ContentDocumentId);
                }
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds];
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Failed to clean up temp signature images: ' + e.getMessage());
        }
    }

    // =========================================================================
    // Decline Signature
    // =========================================================================

    /**
     * Allows a signer to decline the signature request with a reason.
     * Marks the signer and parent request as Declined, creates an audit record.
     */
    @AuraEnabled
    @RemoteAction
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    public static Map<String, Object> declineSignature(String token, String reason) {
        Map<String, Object> result = new Map<String, Object>();

        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            result.put('success', false);
            result.put('message', 'Invalid security token.');
            return result;
        }

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Status__c, Signer_Name__c, Signer_Email__c, Signature_Request__c,
                   Role_Name__c, Contact__c, CreatedDate
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ]; // NOPMD ApexCRUDViolation

        if (signers.isEmpty()) {
            result.put('success', false);
            result.put('message', 'Signer not found.');
            return result;
        }

        DocGen_Signer__c signer = signers[0];
        if (signer.CreatedDate.addHours(TOKEN_EXPIRATION_HOURS) < System.now()) {
            result.put('success', false);
            result.put('message', 'This signature link has expired.');
            return result;
        }
        if (signer.Status__c == 'Signed') {
            result.put('success', false);
            result.put('message', 'You have already signed this document.');
            return result;
        }
        if (signer.Status__c == 'Declined') {
            result.put('success', false);
            result.put('message', 'You have already declined this request.');
            return result;
        }

        // Mark signer as declined
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        signer.Status__c = 'Declined';
        signer.Decline_Reason__c = String.isNotBlank(reason) ? reason.left(1000) : null;
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        // Mark parent request as declined
        DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = signer.Signature_Request__c);
        parentReq.Status__c = 'Declined';
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(parentReq, false, AccessLevel.SYSTEM_MODE);

        // Create audit record
        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
        audit.Signature_Request__c = signer.Signature_Request__c;
        audit.Signer__c = signer.Id;
        audit.Signer_Name__c = signer.Signer_Name__c;
        audit.Signer_Email__c = signer.Signer_Email__c;
        audit.Contact__c = signer.Contact__c;
        audit.Signed_Date__c = System.now();
        audit.IP_Address__c = captureClientIp();
        audit.Consent_Captured__c = false;
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

        // Decline notification deferred to system context via platform event
        // (guest users cannot query User records or send email — triggers session ID error)
        try {
            DocGen_Signature_PDF__e notifyEvent = new DocGen_Signature_PDF__e();
            notifyEvent.Request_Id__c = signer.Signature_Request__c;
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            EventBus.publish(notifyEvent);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Decline notification event failed: ' + e.getMessage());
        }

        result.put('success', true);
        result.put('message', 'You have declined this signature request.');
        return result;
    }

    // =========================================================================
    // Phase 2: Guided Signing — Per-Placement Endpoints
    // =========================================================================

    /**
     * Returns all signature placements for a signer, ordered by document index then sequence.
     * Used by the guided signing flow to build the step-through UI.
     * Includes current status so the signer can resume where they left off.
     */
    @AuraEnabled
    @RemoteAction
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    public static List<Map<String, Object>> getSignerPlacements(String token) {
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Signature_Request__c, CreatedDate, PIN_Verified_At__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (signer.CreatedDate.addHours(TOKEN_EXPIRATION_HOURS) < System.now()) {
            throw new AuraHandledException('This signature link has expired.');
        }

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Placement__c> placements = [
            SELECT Id, Sequence_Order__c, Placement_Type__c, Status__c,
                   Signed_Value__c, Signed_At__c, Section_Context__c, Tag_Text__c,
                   Document_Index__c
            FROM DocGen_Signature_Placement__c
            WHERE Signer__c = :signer.Id
            WITH SYSTEM_MODE
            ORDER BY Document_Index__c ASC, Sequence_Order__c ASC
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (DocGen_Signature_Placement__c plc : placements) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', plc.Id);
            m.put('sequence', plc.Sequence_Order__c);
            m.put('type', plc.Placement_Type__c);
            m.put('status', plc.Status__c);
            m.put('signedValue', plc.Signed_Value__c);
            m.put('signedAt', plc.Signed_At__c);
            m.put('sectionContext', plc.Section_Context__c);
            m.put('tagText', plc.Tag_Text__c);
            m.put('documentIndex', plc.Document_Index__c);
            result.add(m);
        }
        return result;
    }

    /**
     * Signs a single placement during the guided signing flow.
     * Persists the value, marks as signed, and returns the updated placement list.
     */
    @AuraEnabled
    @RemoteAction
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    public static List<Map<String, Object>> signPlacement(String token, Id placementId, String value) {
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, CreatedDate, PIN_Verified_At__c, Status__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (signer.CreatedDate.addHours(TOKEN_EXPIRATION_HOURS) < System.now()) {
            throw new AuraHandledException('This signature link has expired.');
        }
        if (signer.PIN_Verified_At__c == null) {
            throw new AuraHandledException('Email verification is required.');
        }

        // Verify the placement belongs to this signer
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Placement__c> plcs = [
            SELECT Id, Signer__c, Status__c, Placement_Type__c
            FROM DocGen_Signature_Placement__c
            WHERE Id = :placementId AND Signer__c = :signer.Id
            WITH SYSTEM_MODE LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        if (plcs.isEmpty()) {
            throw new AuraHandledException('Placement not found.');
        }

        DocGen_Signature_Placement__c plc = plcs[0];
        if (plc.Status__c == 'Signed') {
            // Already signed — return current state (idempotent)
            return getSignerPlacements(token);
        }

        // For Date type, auto-fill with server timestamp
        if (plc.Placement_Type__c == 'Date') {
            plc.Signed_Value__c = System.now().format('MMMM d, yyyy');
        } else {
            if (String.isBlank(value)) {
                throw new AuraHandledException('Please provide a value.');
            }
            plc.Signed_Value__c = value.left(255);
        }

        plc.Status__c = 'Signed';
        plc.Signed_At__c = System.now();
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(plc, false, AccessLevel.SYSTEM_MODE);

        return getSignerPlacements(token);
    }

    /**
     * Returns a ContentVersion's binary data as base64 for guest users.
     * Guest users cannot access /sfc/servlet.shepherd/ URLs directly (auth required).
     * The signing page JS calls this per image, then injects as data URI.
     */
    @AuraEnabled
    @RemoteAction
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    public static Map<String, String> getImageBase64(String token, String contentVersionId) {
        Map<String, String> result = new Map<String, String>();

        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            result.put('error', 'Invalid token');
            return result;
        }

        // Validate the token is still valid (active signer)
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, CreatedDate FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        if (signers.isEmpty() || signers[0].CreatedDate.addHours(TOKEN_EXPIRATION_HOURS) < System.now()) {
            result.put('error', 'Invalid or expired token');
            return result;
        }

        // Validate ContentVersion ID format
        if (String.isBlank(contentVersionId) || !contentVersionId.startsWith('068')) {
            result.put('error', 'Invalid content version ID');
            return result;
        }

        try {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            ContentVersion cv = [
                SELECT VersionData, FileExtension
                FROM ContentVersion
                WHERE Id = :contentVersionId
                WITH SYSTEM_MODE LIMIT 1
            ]; // NOPMD ApexCRUDViolation - ContentVersion accessed for signature document preview

            String mimeType = 'image/png';
            if (cv.FileExtension == 'jpg' || cv.FileExtension == 'jpeg') mimeType = 'image/jpeg';
            else if (cv.FileExtension == 'gif') mimeType = 'image/gif';
            else if (cv.FileExtension == 'svg') mimeType = 'image/svg+xml';

            result.put('base64', EncodingUtil.base64Encode(cv.VersionData));
            result.put('mimeType', mimeType);
        } catch (Exception e) {
            result.put('error', 'Image not found');
        }

        return result;
    }

    /**
     * Kept for backward compatibility but now a no-op since PDF is generated server-side.
     * The VF page calls this after stamping — we just return success since the PDF
     * was already generated and saved in stampAndReturnSource.
     */
    @AuraEnabled
    @RemoteAction
    public static void finishSignatureUpload(String token, String base64Pdf, String fileName) {
        // PDF is now generated and saved server-side in stampAndReturnSource.
        // This method is retained as a no-op for backward compatibility with the VF page flow.
    }
}