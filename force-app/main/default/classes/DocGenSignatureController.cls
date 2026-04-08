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
        // Fallback: try session-based IP (skip in test context — throws uncatchable exception)
        if (!Test.isRunningTest()) {
            try {
                Map<String, String> session = Auth.SessionManagement.getCurrentSession();
                String loginIp = session.get('SourceIp');
                if (String.isNotBlank(loginIp)) {
                    return loginIp;
                }
            } catch (Exception e) {
                // Guest users may not have session info
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
    public static Map<String, Object> sendPin(String token, String email) {
        Map<String, Object> result = new Map<String, Object>();

        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            result.put('success', false);
            result.put('message', 'Invalid security token.');
            return result;
        }

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

        // Store hash and expiry on signer record
        signer.PIN_Hash__c = pinHash;
        signer.PIN_Expires_At__c = System.now().addMinutes(PIN_EXPIRATION_MINUTES);
        signer.PIN_Attempts__c = 0; // Reset attempts on new PIN
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        // Send PIN via email
        sendPinEmail(signer.Signer_Email__c, pinStr);

        result.put('success', true);
        result.put('message', 'A verification code has been sent to your email.');
        return result;
    }

    /**
     * Verifies the 6-digit PIN entered by the signer.
     * Burns the token after MAX_PIN_ATTEMPTS failed attempts.
     */
    @AuraEnabled
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
            // Increment failed attempts
            signer.PIN_Attempts__c = (signer.PIN_Attempts__c == null ? 0 : signer.PIN_Attempts__c) + 1;
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

        // PIN verified — record timestamp and clear PIN data
        signer.PIN_Verified_At__c = System.now();
        signer.PIN_Hash__c = null;
        signer.PIN_Expires_At__c = null;
        signer.PIN_Attempts__c = 0;
        if (signer.Status__c == 'Pending') {
            signer.Status__c = 'Viewed';
        }
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        result.put('success', true);
        result.put('message', 'Email verified successfully.');
        return result;
    }

    /**
     * Sends the 6-digit PIN to the signer's email.
     */
    private static void sendPinEmail(String email, String pin) {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String brandColor = String.isNotBlank(settings.Signature_Email_Brand_Color__c)
            ? settings.Signature_Email_Brand_Color__c : '#0176D3';
        String companyName = settings.Company_Name__c;

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

        // Use Org-Wide Email Address if configured
        String owaId = settings.Signature_OWA_Id__c;
        if (String.isNotBlank(owaId)) {
            email2.setOrgWideEmailAddressId(owaId);
        }

        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email2 }, false);
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
        if (signer.Status__c == 'Pending') {
            signer.Status__c = 'Viewed';
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

        if (req.Status__c == 'Sent') {
            req.Status__c = 'Viewed';
            Database.update(req, false, AccessLevel.SYSTEM_MODE);
        }

        res.isValid = true;
        res.isSignerToken = false;
        res.signerName = req.Signer_Name__c;
        res.totalSigners = 1;
        res.signedCount = 0;

        List<ContentVersion> cvs = [SELECT Id, Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
        if (!cvs.isEmpty()) {
            res.documentTitle = cvs[0].Title;
            res.documentUrl = getOrCreatePublicLink(cvs[0]);
        } else {
            res.documentTitle = 'Confidential Document';
        }

        return res;
    }

    private static String getOrCreatePublicLink(ContentVersion cv) {
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
        Database.insert(new List<ContentDistribution>{ cd }, false, AccessLevel.SYSTEM_MODE);
        cd = new ContentDistribution(Id = cd.Id);
        cd = [SELECT DistributionPublicUrl FROM ContentDistribution WHERE Id = :cd.Id WITH SYSTEM_MODE LIMIT 1];
        return cd.DistributionPublicUrl;
    }

    /**
     * Fetches pre-rendered HTML for document display in the signature page.
     * Template-based requests: merges template with record data for a fully merged preview.
     * Legacy requests: converts source DOCX to HTML.
     */
    @AuraEnabled
    @RemoteAction
    public static SignatureInitResponse fetchDocumentData(String token) {
        SignatureInitResponse res = validateToken(token);
        if (!res.isValid) return res;

        // Try multi-signer path
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
            // Legacy fallback
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
            // Try cached preview first
            List<DocGen_Signature_Request__c> reqs = [
                SELECT Signature_Data__c FROM DocGen_Signature_Request__c
                WHERE Id = :requestId WITH SYSTEM_MODE LIMIT 1
            ];
            if (!reqs.isEmpty() && String.isNotBlank(reqs[0].Signature_Data__c)) {
                try {
                    Map<String, Object> cachedData = (Map<String, Object>) JSON.deserializeUntyped(reqs[0].Signature_Data__c);
                    String previewHtml = (String) cachedData.get('previewHtml');
                    if (String.isNotBlank(previewHtml)) {
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
                    res.templateBase64 = DocGenHtmlRenderer.convertToHtml(docXml, pdfImageMap);
                    return res;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'DocGen: Failed to generate live preview: ' + e.getMessage());
            }

            res.templateBase64 = '<html><body><p>Document preview unavailable.</p></body></html>';
            return res;
        }

        // Legacy: convert source DOCX to HTML
        if (sourceDocId != null) {
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

        // Store typed name and mark as signed
        signer.Signature_Data__c = typedName;
        signer.Status__c = 'Signed';
        signer.Consent_Captured__c = true;
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
        Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

        // Check if all signers are now complete
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

        // Update parent request status
        DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = signer.Signature_Request__c);
        parentReq.Status__c = 'In Progress';
        Database.update(parentReq, false, AccessLevel.SYSTEM_MODE);

        return result;
    }

    /**
     * Triggers PDF generation after all signers have completed.
     * For multi-signer: called only when all signers have completed.
     * For legacy single-signer: stamps the single signature directly.
     */
    @AuraEnabled
    @RemoteAction
    public static Map<String, String> stampAndReturnSource(String token, String base64Image) {
        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        // Determine if this is a multi-signer or legacy request
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
            // Publish Platform Event to trigger PDF generation in system context.
            // The event trigger runs as Automated Process user, bypassing guest user
            // limitations on ContentVersion access for image URLs.
            DocGen_Signature_PDF__e pdfEvent = new DocGen_Signature_PDF__e();
            pdfEvent.Request_Id__c = requestId;
            EventBus.publish(pdfEvent);

            // Return title for the UI
            String docTitle;
            if (templateId != null) {
                docTitle = triggerSigner.Signature_Request__r.Template__r.Name;
            } else if (sourceDocId != null) {
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
    @AuraEnabled
    @RemoteAction
    public static void saveLegacySignature(String token, String typedName) {
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (requests.isEmpty() || requests[0].Status__c == 'Signed' || requests[0].Status__c == 'Cancelled') {
            throw new AuraHandledException('Invalid request or document already signed.');
        }
        requests[0].Signature_Data__c = typedName;
        requests[0].Status__c = 'Viewed';
        Database.update(requests[0], false, AccessLevel.SYSTEM_MODE);
    }

    private static Map<String, String> stampLegacySignerAndSavePdf(String token) {
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

            ContentVersion sourceDoc = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
            String fileName = sourceDoc.Title + ' - Signed';
            String base64Pdf = EncodingUtil.base64Encode(pdfBlob);

            // Save PDF to record
            saveSignedDocument(req.Related_Record_Id__c, fileName, base64Pdf, 'pdf');

            // Update request status and clear signature data
            req.Status__c = 'Signed';
            req.Signature_Data__c = null;
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
        Database.insert(new List<ContentVersion>{ cv }, false, AccessLevel.SYSTEM_MODE);

        Id contentDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH SYSTEM_MODE].ContentDocumentId;

        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = contentDocId;
        cdl.LinkedEntityId = recordId;
        cdl.ShareType = 'V';
        cdl.Visibility = 'AllUsers';
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

        List<DocGen_Signature_Request__c> requests = [
            SELECT Source_Document_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (requests.isEmpty()) {
            throw new DocGenException('Signature request not found.');
        }

        Id sourceDocId = requests[0].Source_Document_Id__c;

        // Get typed-name signatures from signers
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
                delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds];
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Failed to clean up temp signature images: ' + e.getMessage());
        }
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