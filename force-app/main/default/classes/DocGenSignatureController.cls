public without sharing class DocGenSignatureController {

    // Signature links expire after this many days from creation
    private static final Integer TOKEN_EXPIRATION_DAYS = 30;

    public class SignatureInitResponse {
        @AuraEnabled public Boolean isValid;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String signerName;
        @AuraEnabled public String documentTitle;
        @AuraEnabled public String documentUrl;
        @AuraEnabled public String templateBase64;
        @AuraEnabled public String recordId;
        @AuraEnabled public String mergeDataJson;
        @AuraEnabled public String roleName;
        @AuraEnabled public Integer totalSigners;
        @AuraEnabled public Integer signedCount;
    }

    public class SaveSignatureResult {
        @AuraEnabled public Boolean isComplete;
        @AuraEnabled public Integer remaining;
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
            SELECT Id, Status__c, Signer_Name__c, Role_Name__c, Sort_Order__c, CreatedDate,
                   Signature_Request__r.Id, Signature_Request__r.Status__c,
                   Signature_Request__r.Source_Document_Id__c, Signature_Request__r.Related_Record_Id__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (!signers.isEmpty()) {
            // Token expiration: 30 days from creation
            if (signers[0].CreatedDate.addDays(TOKEN_EXPIRATION_DAYS) < System.now()) {
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
        if (requests[0].CreatedDate.addDays(TOKEN_EXPIRATION_DAYS) < System.now()) {
            res.errorMessage = 'This signature link has expired. Please request a new one.';
            return res;
        }

        return validateLegacyRequest(requests[0]);
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
        res.signerName = signer.Signer_Name__c;
        res.roleName = signer.Role_Name__c;

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

        // Get document metadata
        Id sourceDocId = parentReq.Source_Document_Id__c;
        List<ContentVersion> cvs = [SELECT Id, Title FROM ContentVersion WHERE Id = :sourceDocId WITH SYSTEM_MODE LIMIT 1];
        if (!cvs.isEmpty()) {
            res.documentTitle = cvs[0].Title;
            res.documentUrl = getOrCreatePublicLink(cvs[0]);
        } else {
            res.documentTitle = 'Confidential Document';
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
     * Converts the source DOCX to HTML server-side using DocGenHtmlRenderer.
     */
    @AuraEnabled
    @RemoteAction
    public static SignatureInitResponse fetchDocumentData(String token) {
        SignatureInitResponse res = validateToken(token);
        if (!res.isValid) return res;

        // Try multi-signer path
        List<DocGen_Signer__c> signers = [
            SELECT Signature_Request__r.Source_Document_Id__c, Signature_Request__r.Related_Record_Id__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        Id sourceDocId;
        if (!signers.isEmpty()) {
            sourceDocId = signers[0].Signature_Request__r.Source_Document_Id__c;
            res.recordId = signers[0].Signature_Request__r.Related_Record_Id__c;
        } else {
            // Legacy fallback
            List<DocGen_Signature_Request__c> requests = [
                SELECT Source_Document_Id__c, Related_Record_Id__c
                FROM DocGen_Signature_Request__c
                WHERE Secure_Token__c = :token
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (!requests.isEmpty()) {
                sourceDocId = requests[0].Source_Document_Id__c;
                res.recordId = requests[0].Related_Record_Id__c;
            }
        }

        if (sourceDocId != null) {
            List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :sourceDocId WITH SYSTEM_MODE LIMIT 1];
            if (!cvs.isEmpty()) {
                // Convert DOCX to HTML for display
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
     * Saves a signer's signature PNG without generating the final PDF.
     * Returns whether all signers have now completed.
     */
    @AuraEnabled
    @RemoteAction
    public static SaveSignatureResult saveSignature(String token, String base64Image) {
        SaveSignatureResult result = new SaveSignatureResult();

        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        List<DocGen_Signer__c> signers = [
            SELECT Id, Status__c, Signature_Request__c, Role_Name__c, CreatedDate
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (signer.CreatedDate.addDays(TOKEN_EXPIRATION_DAYS) < System.now()) {
            throw new AuraHandledException('This signature link has expired.');
        }
        if (signer.Status__c == 'Signed') {
            throw new AuraHandledException('You have already signed this document.');
        }

        // Store signature data and mark as signed (SYSTEM_MODE for guest user CRUD bypass)
        signer.Signature_Data__c = base64Image;
        signer.Status__c = 'Signed';
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        // Save signature image as a ContentVersion linked to the REQUEST record.
        // Named by role so the Queueable (Automated Process user) can find it via
        // ContentDocumentLink on the request. This ensures visibility regardless of
        // which user runs the PDF generation.
        try {
            String base64Data = base64Image;
            if (base64Data.contains(',')) {
                base64Data = base64Data.substringAfter(',');
            }
            String roleName = String.isNotBlank(signer.Role_Name__c) ? signer.Role_Name__c : 'Signer';
            ContentVersion sigCv = new ContentVersion();
            sigCv.Title = 'docgen_signature_' + roleName;
            sigCv.PathOnClient = 'docgen_signature_' + roleName + '.png';
            sigCv.VersionData = EncodingUtil.base64Decode(base64Data);
            sigCv.FirstPublishLocationId = signer.Signature_Request__c;
            Database.insert(new List<ContentVersion>{ sigCv }, false, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Failed to save signature image file: ' + e.getMessage());
        }

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

        // Update parent request status (SYSTEM_MODE for guest user CRUD bypass)
        DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = signer.Signature_Request__c);
        parentReq.Status__c = 'In Progress';
        Database.update(parentReq, false, AccessLevel.SYSTEM_MODE);

        return result;
    }

    /**
     * Stamps ALL signatures into the DOCX, generates PDF server-side via Blob.toPdf(),
     * saves it, and returns the result. No client-side PDF rendering needed.
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
                   Signature_Request__r.Related_Record_Id__c
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
        String relatedRecordId = triggerSigner.Signature_Request__r.Related_Record_Id__c;

        try {
            // Publish Platform Event to trigger PDF generation in system context.
            // The event trigger runs as Automated Process user, bypassing guest user
            // limitations on ContentVersion access for image URLs.
            DocGen_Signature_PDF__e pdfEvent = new DocGen_Signature_PDF__e();
            pdfEvent.Request_Id__c = requestId;
            EventBus.publish(pdfEvent);

            // PDF generation, audit trail, status updates, and cleanup all happen
            // in the Queueable (runs as system user with full Content access).
            ContentVersion sourceDoc = [SELECT Title FROM ContentVersion WHERE Id = :sourceDocId WITH SYSTEM_MODE LIMIT 1];
            return new Map<String, String>{
                'status' => 'complete',
                'title' => sourceDoc.Title + ' - Signed'
            };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Multi-signer stamping failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while processing signatures.');
        }
    }

    /**
     * Saves the signature image for a legacy single-signer request.
     * Called as a separate transaction BEFORE stampAndReturnSource to avoid DML-before-callout.
     */
    @AuraEnabled
    @RemoteAction
    public static void saveLegacySignature(String token, String base64Image) {
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
        requests[0].Signature_Data__c = base64Image;
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
     * Generates a PDF from a signature request using Blob.toPdf() with data URI images.
     * Stamps all signatures into the DOCX, converts to HTML, and renders via Blob.toPdf().
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

        // Stamp signatures into the DOCX.
        // Signature data may be in Signature_Data__c field on Signer OR in the committed CV
        // (saveSignature saves a CV, and the field is cleared after PDF generation).
        List<DocGen_Signer__c> signers = [
            SELECT Id, Role_Name__c, Signature_Data__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId AND Status__c = 'Signed'
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];

        Blob stampedBlob;
        if (!signers.isEmpty()) {
            List<DocGenSignatureService.SignerData> signerDataList = new List<DocGenSignatureService.SignerData>();
            for (DocGen_Signer__c s : signers) {
                String sigBase64 = s.Signature_Data__c;
                // Fall back to committed CV if field was cleared
                if (String.isBlank(sigBase64)) {
                    List<ContentVersion> sigCvs = [
                        SELECT VersionData FROM ContentVersion
                        WHERE Title = :('docgen_signature_' + s.Id)
                        WITH SYSTEM_MODE LIMIT 1
                    ];
                    if (!sigCvs.isEmpty()) {
                        sigBase64 = EncodingUtil.base64Encode(sigCvs[0].VersionData);
                    }
                }
                if (String.isNotBlank(sigBase64)) {
                    signerDataList.add(new DocGenSignatureService.SignerData(s.Role_Name__c, sigBase64));
                }
            }
            if (!signerDataList.isEmpty()) {
                stampedBlob = DocGenSignatureService.stampAllSignaturesToBlob(sourceDocId, signerDataList);
            }
        }

        if (stampedBlob == null) {
            throw new DocGenException('Could not generate stamped document.');
        }

        // Extract DOCX parts. Build image URL map using committed CVs.
        // Blob.toPdf() cannot render data URIs — all images must be absolute URLs.
        Map<String, Object> parts = extractDocxParts(stampedBlob);
        String documentXml = (String) parts.get('documentXml');
        Map<String, String> imagesByRelId = (Map<String, String>) parts.get('imagesByRelId');

        Map<String, String> imageUrlMap = new Map<String, String>();
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();

        // Look up committed signature image CVs linked to the request record.
        // Named by role (e.g., docgen_signature_Buyer) and linked via FirstPublishLocationId.
        List<DocGen_Signer__c> signedSigners = [
            SELECT Id, Role_Name__c FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId AND Status__c = 'Signed'
            WITH SYSTEM_MODE ORDER BY Sort_Order__c ASC
        ];
        // Query all signature CVs linked to this request in one query
        List<ContentDocumentLink> requestLinks = [
            SELECT ContentDocument.LatestPublishedVersionId, ContentDocument.Title
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :requestId
            AND ContentDocument.Title LIKE 'docgen_signature_%'
            WITH SYSTEM_MODE
        ];
        Map<String, String> sigCvUrlsByRole = new Map<String, String>();
        for (ContentDocumentLink cdl : requestLinks) {
            String title = cdl.ContentDocument.Title;
            String role = title.substringAfter('docgen_signature_');
            sigCvUrlsByRole.put(role, baseUrl + '/sfc/servlet.shepherd/version/download/' + cdl.ContentDocument.LatestPublishedVersionId);
        }
        // Build ordered list matching signer sort order
        List<String> sigCvUrls = new List<String>();
        for (DocGen_Signer__c s : signedSigners) {
            String role = String.isNotBlank(s.Role_Name__c) ? s.Role_Name__c : 'Signer';
            if (sigCvUrlsByRole.containsKey(role)) {
                sigCvUrls.add(sigCvUrlsByRole.get(role));
            }
        }

        // Also look up template images from the source document's template
        DocGen_Signature_Request__c req2 = [
            SELECT Source_Document_Id__c FROM DocGen_Signature_Request__c
            WHERE Id = :requestId WITH SYSTEM_MODE LIMIT 1
        ];

        // Look up committed template image CVs from the active version.
        // The source document was generated from a template — find that template's version images.
        // Query all docgen_tmpl_img CVs and match by relId.
        List<ContentVersion> allTmplCvs = [
            SELECT Id, Title FROM ContentVersion
            WHERE Title LIKE 'docgen_tmpl_img_%'
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
        Map<String, String> tmplImgUrls = new Map<String, String>();
        for (ContentVersion cv : allTmplCvs) {
            // Title format: docgen_tmpl_img_{versionId}_{relId}
            String title = cv.Title;
            Integer lastUnderscore = title.lastIndexOf('_');
            if (lastUnderscore > 0) {
                String imgRelId = title.substring(lastUnderscore + 1);
                if (!tmplImgUrls.containsKey(imgRelId)) {
                    tmplImgUrls.put(imgRelId, baseUrl + '/sfc/servlet.shepherd/version/download/' + cv.Id);
                }
            }
        }

        // Map all images
        Integer sigIdx = 0;
        if (imagesByRelId != null) {
            for (String relId : imagesByRelId.keySet()) {
                String base64Val = imagesByRelId.get(relId);
                Boolean isJpeg = base64Val.startsWith('/9j/') || base64Val.startsWith('/9J/');

                if (isJpeg && sigIdx < sigCvUrls.size()) {
                    // Signature image — use committed CV URL
                    imageUrlMap.put(relId, sigCvUrls[sigIdx]);
                    sigIdx++;
                } else if (tmplImgUrls.containsKey(relId)) {
                    // Template image — use committed version CV URL
                    imageUrlMap.put(relId, tmplImgUrls.get(relId));
                } else {
                    // Dynamic image (e.g., from {%Title} CV ID) — try to find existing CV
                    // The base64 is the image data; check if any committed CV matches
                    // For now, these won't render in the signature PDF (known limitation)
                    System.debug(LoggingLevel.WARN, 'DocGen: Signature PDF - no URL for image relId=' + relId);
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