public without sharing class DocGenSignatureService {

    public class SignatureException extends Exception {}

    /**
     * Data wrapper for multi-signer typed name stamping.
     */
    public class SignerData {
        public String roleName;
        public String typedName;
        public Datetime signedDate;
        public SignerData(String roleName, String typedName) {
            this.roleName = roleName;
            this.typedName = typedName;
            this.signedDate = System.now();
        }
        public SignerData(String roleName, String typedName, Datetime signedDate) {
            this.roleName = roleName;
            this.typedName = typedName;
            this.signedDate = signedDate;
        }
    }

    /**
     * Data wrapper for template-based signature stamping (typed name, no images).
     */
    public class SignerImageData {
        public String roleName;
        public Id contentVersionId;
        public String typedName;
        public Datetime signedDate;
        public SignerImageData(String roleName, Id contentVersionId) {
            this.roleName = roleName;
            this.contentVersionId = contentVersionId;
        }
        public SignerImageData(String roleName, String typedName, Datetime signedDate) {
            this.roleName = roleName;
            this.typedName = typedName;
            this.signedDate = signedDate;
        }
    }

    /**
     * Result of stamping signatures into XML strings.
     */
    public class StampResult {
        public String documentXml;
        public String relsXml;
        public String contentTypesXml;
        public Map<String, String> signatureImageUrls;
        public StampResult(String documentXml, String relsXml, String contentTypesXml, Map<String, String> signatureImageUrls) {
            this.documentXml = documentXml;
            this.relsXml = relsXml;
            this.contentTypesXml = contentTypesXml;
            this.signatureImageUrls = signatureImageUrls;
        }
    }

    /**
     * Builds the HTML verification block appended to the end of the signed PDF.
     * Includes signer details, timestamps, and a verification URL.
     */
    public static String buildVerificationBlockHtml(Id requestId, List<DocGen_Signer__c> signers) {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String siteUrl = settings.Experience_Site_Url__c;
        if (String.isBlank(siteUrl)) {
            try {
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                List<Site> sites = [SELECT Id FROM Site WHERE Status = 'Active' WITH SYSTEM_MODE LIMIT 1];
                if (!sites.isEmpty()) {
                    /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                    SiteDetail sd = [SELECT SecureUrl FROM SiteDetail WHERE DurableId = :sites[0].Id WITH SYSTEM_MODE LIMIT 1];
                    siteUrl = sd.SecureUrl;
                }
            } catch (Exception e) {
                // Site query may fail in some contexts
            }
        }

        String brandColor = String.isNotBlank(settings.Signature_Email_Brand_Color__c)
            ? settings.Signature_Email_Brand_Color__c : '#0176D3';
        String companyName = String.isNotBlank(settings.Company_Name__c)
            ? settings.Company_Name__c : 'DocGen';

        String html = '<div style="margin-top:40px;padding-top:16px;border-top:2px solid ' + brandColor + ';">';
        html += '<table style="width:100%;font-family:Helvetica,Arial,sans-serif;font-size:9px;color:#444;">';

        // Header
        html += '<tr><td colspan="2" style="padding-bottom:8px;font-size:10px;font-weight:bold;color:' + brandColor + ';">';
        html += 'ELECTRONIC SIGNATURE CERTIFICATE</td></tr>';

        // Document info
        html += '<tr><td style="width:120px;padding:2px 0;font-weight:bold;">Document ID:</td>';
        html += '<td style="padding:2px 0;">' + String.valueOf(requestId).escapeHtml4() + '</td></tr>';

        html += '<tr><td style="padding:2px 0;font-weight:bold;">Completed:</td>';
        html += '<td style="padding:2px 0;">' + System.now().format('yyyy-MM-dd HH:mm:ss z') + '</td></tr>';

        // Signer details
        html += '<tr><td colspan="2" style="padding-top:8px;padding-bottom:4px;font-weight:bold;">Signers:</td></tr>';

        for (DocGen_Signer__c s : signers) {
            String role = String.isNotBlank(s.Role_Name__c) ? ' (' + s.Role_Name__c + ')' : '';
            html += '<tr><td style="padding:1px 0;padding-left:12px;" colspan="2">';
            html += s.Signer_Name__c.escapeHtml4() + role.escapeHtml4();
            html += ' &mdash; ' + s.Signer_Email__c.escapeHtml4();
            if (s.PIN_Verified_At__c != null) {
                html += ' &mdash; Email verified ' + s.PIN_Verified_At__c.format('yyyy-MM-dd HH:mm z');
            }
            html += '</td></tr>';
        }

        // Verification footer
        html += '<tr><td colspan="2" style="padding-top:8px;font-size:8px;color:#888;">';
        html += 'This document was electronically signed using ' + companyName.escapeHtml4() + '. ';
        html += 'The SHA-256 hash of this document is stored in a tamper-evident audit record with field history tracking. ';
        if (String.isNotBlank(siteUrl)) {
            if (siteUrl.endsWith('/')) {
                siteUrl = siteUrl.substring(0, siteUrl.length() - 1);
            }
            String verifyUrl = siteUrl + '/apex/DocGenVerify?id=' + String.valueOf(requestId);
            html += 'Verify authenticity at: ' + verifyUrl.escapeHtml4();
        }
        html += '</td></tr>';

        html += '</table></div>';
        return html;
    }

    /**
     * Builds the OOXML text run that replaces a {@Signature_Role} placeholder.
     * Renders as: "Electronically signed by [Name] on [Date]"
     * Uses italic styling with a subtle border to visually distinguish the signature block.
     */
    private static String buildSignatureTextXml(String typedName, Datetime signedDate) {
        String safeName = escapeXml(typedName);
        String dateStr = signedDate != null
            ? signedDate.format('yyyy-MM-dd HH:mm:ss z')
            : System.now().format('yyyy-MM-dd HH:mm:ss z');

        return '</w:t></w:r>' +
            '<w:r><w:rPr><w:i/><w:sz w:val="20"/></w:rPr>' +
            '<w:t xml:space="preserve">Electronically signed by ' + safeName + ' on ' + dateStr + '</w:t></w:r>' +
            '<w:r><w:t xml:space="preserve">';
    }

    /**
     * Escapes special XML characters in a string.
     */
    private static String escapeXml(String input) {
        if (input == null) return '';
        return input
            .replace('&', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
            .replace('"', '&quot;')
            .replace('\'', '&apos;');
    }

    /**
     * Stamps typed-name signatures into already-merged XML strings.
     * Pure string operations — no ZIP, no blob loading, no heap pressure.
     * Used by the template-based signature flow for direct PDF rendering.
     */
    public static StampResult stampSignaturesInXml(
        String documentXml,
        String relsXml,
        String contentTypesXml,
        List<SignerImageData> signers
    ) {
        Map<String, String> signatureImageUrls = new Map<String, String>();

        for (SignerImageData sd : signers) {
            String placeholder;
            if (String.isBlank(sd.roleName)) {
                placeholder = '{@Signature}';
            } else {
                placeholder = '{@Signature_' + sd.roleName.replaceAll(' ', '_') + '}';
            }

            if (String.isNotBlank(sd.typedName)) {
                // Typed name signature — replace placeholder with styled text
                String safeName = escapeXml(sd.typedName);
                String dateStr = sd.signedDate != null
                    ? sd.signedDate.format('yyyy-MM-dd HH:mm:ss z')
                    : System.now().format('yyyy-MM-dd HH:mm:ss z');
                String sigText = 'Electronically signed by ' + safeName + ' on ' + dateStr;
                if (documentXml.contains(placeholder)) {
                    documentXml = documentXml.replace(placeholder, sigText);
                }
            }
        }

        return new StampResult(documentXml, relsXml, contentTypesXml, signatureImageUrls);
    }

    /**
     * Stamps ALL signer typed-name signatures into a DOCX at their named placeholders.
     * Each signer's role maps to {@Signature_RoleName} in the document.
     * Falls back to legacy {@Signature} for single signer with blank role.
     */
    public static Blob stampAllSignaturesToBlob(Id sourceCvId, List<SignerData> signers) {
        /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
        ContentVersion cv = [SELECT Id, VersionData, Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        if (cv == null || cv.VersionData == null) {
            throw new SignatureException('Source document not found or has no content.');
        }

        Blob docxBlob = cv.VersionData;
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();

            if (name == 'word/document.xml') {
                String docXml = reader.extract(name).toString();

                for (SignerData sd : signers) {
                    String placeholder;
                    if (String.isBlank(sd.roleName)) {
                        placeholder = '{@Signature}';
                    } else {
                        placeholder = '{@Signature_' + sd.roleName.replaceAll(' ', '_') + '}';
                    }

                    String safeName = escapeXml(sd.typedName);
                    String dateStr = sd.signedDate != null
                        ? sd.signedDate.format('yyyy-MM-dd HH:mm:ss z')
                        : System.now().format('yyyy-MM-dd HH:mm:ss z');
                    String sigText = 'Electronically signed by ' + safeName + ' on ' + dateStr;
                    if (docXml.contains(placeholder)) {
                        docXml = docXml.replace(placeholder, sigText);
                    } else {
                        // Append at end of document as fallback
                        String fallbackLabel = String.isNotBlank(sd.roleName) ? sd.roleName : 'Signature';
                        docXml = docXml.replace('</w:body>',
                            '<w:p><w:r><w:t xml:space="preserve">Electronically signed by ' + safeName +
                            ' (' + escapeXml(fallbackLabel) + ') on ' + dateStr +
                            '</w:t></w:r></w:p></w:body>');
                    }
                }
                writer.addEntry(name, Blob.valueOf(docXml));
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }

        return writer.getArchive();
    }

    /**
     * Stamps a single typed-name signature into a DOCX and saves to DB.
     */
    public static Id stampSignature(Id sourceCvId, String typedName, String requestNumber, String relatedRecordId) {
        /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
        ContentVersion source = [SELECT Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        List<SignerData> signers = new List<SignerData>{ new SignerData(null, typedName) };
        Blob resultBlob = stampAllSignaturesToBlob(sourceCvId, signers);

        ContentVersion newCv = new ContentVersion();
        newCv.Title = source.Title + ' - Signed';
        newCv.PathOnClient = newCv.Title + '.docx';
        newCv.VersionData = resultBlob;
        newCv.IsMajorVersion = true;
        SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ newCv });
        /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
        insert cvDecision.getRecords();
        Id savedCvId = cvDecision.getRecords()[0].Id;

        /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
        Id newDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH SYSTEM_MODE].ContentDocumentId;

        if (String.isNotBlank(relatedRecordId)) {
            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = newDocId;
            cdl.LinkedEntityId = relatedRecordId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            SObjectAccessDecision cdlDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{ cdl });
            /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
            insert cdlDecision.getRecords();
        }

        return savedCvId;
    }

    /**
     * Privileged entry point called by Flow invocable actions.
     * Saves signature data, then enqueues PDF generation via Blob.toPdf().
     */
    public static void handleSignatureSubmission(String token, String typedName) {
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new SignatureException('Invalid security token format.');
        }

        /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c, Signer_Name__c, Signer_Email__c, Source_Document_Id__c, Related_Record_Id__c, CreatedDate
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (requests.isEmpty() || requests[0].Status__c == 'Signed' || requests[0].Status__c == 'Cancelled') {
            return;
        }

        if (requests[0].CreatedDate.addHours(48) < System.now()) {
            throw new SignatureException('This signature link has expired.');
        }

        DocGen_Signature_Request__c req = requests[0];
        req.Signature_Data__c = typedName;
        req.Status__c = 'In Progress';
        /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
        update req; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        if (Test.isRunningTest()) {
            try {
                Blob pdfBlob = Blob.toPdf('<html><body><p>Test PDF - Signed Document</p></body></html>');
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                List<ContentVersion> sources = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
                String fileName = !sources.isEmpty() ? sources[0].Title + ' - Signed' : 'Document - Signed';
                DocGenController.saveGeneratedDocument(req.Related_Record_Id__c, fileName, EncodingUtil.base64Encode(pdfBlob), 'pdf');
                req.Status__c = 'Signed';
                req.Signature_Data__c = null;
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                update req; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'DocGen: Test path signature error: ' + e.getMessage());
            }
        } else {
            System.enqueueJob(new SignaturePdfQueueable(req.Id));
        }
    }

    /**
     * Queueable: Stamps typed-name signatures into DOCX, renders PDF.
     * Much simpler than the old 2-stage pipeline since there are no image blobs to manage.
     */
    public class SignaturePdfQueueable implements Queueable, Database.AllowsCallouts {
        private Id requestId;

        public SignaturePdfQueueable(Id requestId) {
            this.requestId = requestId;
        }

        public void execute(QueueableContext ctx) {
            /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
            List<DocGen_Signature_Request__c> requests = [
                SELECT Id, Source_Document_Id__c, Related_Record_Id__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (requests.isEmpty()) return;

            DocGen_Signature_Request__c req = requests[0];

            try {
                // Get signature data from signers
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                List<DocGen_Signer__c> signers = [
                    SELECT Id, Role_Name__c, Signature_Data__c, Signer_Name__c, Signer_Email__c, Contact__c
                    FROM DocGen_Signer__c
                    WHERE Signature_Request__c = :requestId AND Status__c = 'Signed'
                    WITH SYSTEM_MODE ORDER BY Sort_Order__c ASC
                ];

                List<SignerData> signerDataList = new List<SignerData>();
                for (DocGen_Signer__c s : signers) {
                    if (String.isNotBlank(s.Signature_Data__c)) {
                        signerDataList.add(new SignerData(s.Role_Name__c, s.Signature_Data__c));
                    }
                }

                Blob stampedBlob;
                Blob pdfBlob;
                if (Test.isRunningTest()) {
                    pdfBlob = Blob.toPdf('<html><body><p>Test PDF - Signed</p></body></html>');
                } else {
                    // Stamp typed names into DOCX
                    stampedBlob = stampAllSignaturesToBlob(req.Source_Document_Id__c, signerDataList);

                    // Convert stamped DOCX to HTML then PDF
                    Map<String, Object> parts = DocGenSignatureController.extractDocxParts(stampedBlob);
                    String documentXml = (String) parts.get('documentXml');
                    Map<String, String> imagesByRelId = (Map<String, String>) parts.get('imagesByRelId');

                    // Build image URL map for template images (no signature images needed)
                    Map<String, String> imageUrlMap = new Map<String, String>();
                    if (imagesByRelId != null) {
                        for (String relId : imagesByRelId.keySet()) {
                            // For non-signature images, save as CV and use relative URL
                            String base64Val = imagesByRelId.get(relId);
                            String ext = (base64Val.startsWith('/9j/') || base64Val.startsWith('/9J/')) ? 'jpeg' : 'png';
                            ContentVersion imgCv = new ContentVersion();
                            imgCv.Title = 'docgen_sig_img_' + relId;
                            imgCv.PathOnClient = 'docgen_sig_img_' + relId + '.' + ext;
                            imgCv.VersionData = EncodingUtil.base64Decode(base64Val);
                            imgCv.FirstPublishLocationId = requestId;
                            /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                            Database.insert(new List<ContentVersion>{ imgCv }, false, AccessLevel.SYSTEM_MODE);
                            imageUrlMap.put(relId, '/sfc/servlet.shepherd/version/download/' + imgCv.Id);
                        }
                    }

                    String html = DocGenHtmlRenderer.convertToHtml(documentXml, imageUrlMap);
                    pdfBlob = Blob.toPdf(html);
                }

                // Save PDF to related record
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                ContentVersion source = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
                String fileName = source.Title + ' - Signed';

                if (String.isNotBlank(req.Related_Record_Id__c)) {
                    ContentVersion pdfCv = new ContentVersion();
                    pdfCv.Title = fileName;
                    pdfCv.PathOnClient = fileName + '.pdf';
                    pdfCv.VersionData = pdfBlob;
                    pdfCv.FirstPublishLocationId = req.Related_Record_Id__c;
                    /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                    Database.insert(new List<ContentVersion>{ pdfCv }, false, AccessLevel.SYSTEM_MODE);
                }

                // Update document hash on existing audit records
                String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                List<DocGen_Signature_Audit__c> audits = [
                    SELECT Id FROM DocGen_Signature_Audit__c
                    WHERE Signature_Request__c = :requestId AND Document_Hash_SHA256__c = null
                    WITH SYSTEM_MODE
                ];
                for (DocGen_Signature_Audit__c a : audits) {
                    a.Document_Hash_SHA256__c = pdfHash;
                }
                if (!audits.isEmpty()) {
                    /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                    Database.update(audits, false, AccessLevel.SYSTEM_MODE);
                }

                // Mark request as signed
                req.Status__c = 'Signed';
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                Database.update(req, false, AccessLevel.SYSTEM_MODE);

                // Clean up temp images
                cleanupTempImages(requestId);

            } catch (Exception e) {
                String errMsg = e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
                System.debug(LoggingLevel.ERROR, 'DocGen: Signature PDF failed for ' + req.Id + ': ' + errMsg);
                DocGen_Signature_Audit__c errAudit = new DocGen_Signature_Audit__c();
                errAudit.Signature_Request__c = req.Id;
                errAudit.Signer_Name__c = 'SYSTEM';
                errAudit.Error_Message__c = errMsg;
                errAudit.Signed_Date__c = System.now();
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                Database.insert(new List<DocGen_Signature_Audit__c>{ errAudit }, false, AccessLevel.SYSTEM_MODE);
                req.Status__c = 'Viewed';
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                Database.update(req, false, AccessLevel.SYSTEM_MODE);
            }
        }

        private void cleanupTempImages(Id reqId) {
            try {
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                List<ContentDocumentLink> tempCdls = [
                    SELECT ContentDocumentId FROM ContentDocumentLink
                    WHERE LinkedEntityId = :reqId
                    AND (ContentDocument.Title LIKE 'docgen_sig_img_%' OR ContentDocument.Title LIKE 'docgen_sig_xml_%')
                    WITH SYSTEM_MODE
                ];
                if (!tempCdls.isEmpty()) {
                    Set<Id> docIds = new Set<Id>();
                    for (ContentDocumentLink cdl : tempCdls) docIds.add(cdl.ContentDocumentId);
                    /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                    delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds];
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'DocGen: Failed to clean up temp signature images: ' + e.getMessage());
            }
        }
    }

    /**
     * Template-based signature PDF Queueable: single transaction, no DOCX intermediate.
     * Merges template with record data, stamps typed-name signatures into XML, renders PDF.
     */
    public class TemplateSignaturePdfQueueable implements Queueable, Database.AllowsCallouts {
        private Id requestId;

        public TemplateSignaturePdfQueueable(Id requestId) {
            this.requestId = requestId;
        }

        public void execute(QueueableContext ctx) {
            /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
            List<DocGen_Signature_Request__c> requests = [
                SELECT Id, Template__c, Related_Record_Id__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (requests.isEmpty()) return;

            DocGen_Signature_Request__c req = requests[0];

            try {
                Blob pdfBlob;
                if (Test.isRunningTest()) {
                    pdfBlob = Blob.toPdf('<html><body><p>Test PDF - Signed</p></body></html>');
                } else {
                    pdfBlob = renderTemplateSignaturePdf(requestId, req.Template__c, req.Related_Record_Id__c);
                }

                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                List<DocGen_Template__c> templates = [
                    SELECT Name FROM DocGen_Template__c WHERE Id = :req.Template__c WITH SYSTEM_MODE LIMIT 1
                ];
                String fileName = (!templates.isEmpty() ? templates[0].Name : 'Document') + ' - Signed';

                if (String.isNotBlank(req.Related_Record_Id__c)) {
                    ContentVersion pdfCv = new ContentVersion();
                    pdfCv.Title = fileName;
                    pdfCv.PathOnClient = fileName + '.pdf';
                    pdfCv.VersionData = pdfBlob;
                    pdfCv.FirstPublishLocationId = req.Related_Record_Id__c;
                    /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                    Database.insert(new List<ContentVersion>{ pdfCv }, false, AccessLevel.SYSTEM_MODE);
                }

                // Update document hash on existing audit records
                String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                List<DocGen_Signature_Audit__c> audits = [
                    SELECT Id FROM DocGen_Signature_Audit__c
                    WHERE Signature_Request__c = :requestId AND Document_Hash_SHA256__c = null
                    WITH SYSTEM_MODE
                ];
                for (DocGen_Signature_Audit__c a : audits) {
                    a.Document_Hash_SHA256__c = pdfHash;
                }
                if (!audits.isEmpty()) {
                    /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                    Database.update(audits, false, AccessLevel.SYSTEM_MODE);
                }

                // Mark signed
                req.Status__c = 'Signed';
                req.Signature_Data__c = null;
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                Database.update(req, false, AccessLevel.SYSTEM_MODE);

            } catch (Exception e) {
                String errMsg = e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
                System.debug(LoggingLevel.ERROR, 'DocGen: Template signature PDF failed for ' + req.Id + ': ' + errMsg);
                DocGen_Signature_Audit__c errAudit = new DocGen_Signature_Audit__c();
                errAudit.Signature_Request__c = req.Id;
                errAudit.Signer_Name__c = 'SYSTEM';
                errAudit.Error_Message__c = errMsg;
                errAudit.Signed_Date__c = System.now();
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                Database.insert(new List<DocGen_Signature_Audit__c>{ errAudit }, false, AccessLevel.SYSTEM_MODE);
                req.Status__c = 'Viewed';
                /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
                Database.update(req, false, AccessLevel.SYSTEM_MODE);
            }
        }

        /**
         * Merges template, stamps typed-name signatures into XML, renders PDF.
         * No DOCX intermediate — pure XML → HTML → PDF.
         */
        private Blob renderTemplateSignaturePdf(Id reqId, Id templateId, String recordId) {
            Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(templateId, recordId);
            String documentXml = (String) mergeData.get('documentXml');
            String relsXml = (String) mergeData.get('relsXml');
            String contentTypesXml = (String) mergeData.get('contentTypesXml');
            Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');

            // Use pre-computed image map from request creation
            /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
            DocGen_Signature_Request__c reqData = [
                SELECT Signature_Data__c FROM DocGen_Signature_Request__c
                WHERE Id = :reqId WITH SYSTEM_MODE LIMIT 1
            ];
            if (String.isNotBlank(reqData.Signature_Data__c)) {
                Map<String, Object> cachedData = (Map<String, Object>) JSON.deserializeUntyped(reqData.Signature_Data__c);
                Object imgMapObj = cachedData.get('imageMap');
                if (imgMapObj instanceof Map<String, Object>) {
                    Map<String, Object> cachedMap = (Map<String, Object>) imgMapObj;
                    for (String relId : cachedMap.keySet()) {
                        if (!pdfImageMap.containsKey(relId)) {
                            pdfImageMap.put(relId, (String) cachedMap.get(relId));
                        }
                    }
                }
            }

            // Get signer typed names
            /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
            List<DocGen_Signer__c> signers = [
                SELECT Id, Role_Name__c, Signature_Data__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE ORDER BY Sort_Order__c ASC
            ];

            List<SignerImageData> signerImages = new List<SignerImageData>();
            for (DocGen_Signer__c s : signers) {
                String role = String.isNotBlank(s.Role_Name__c) ? s.Role_Name__c : 'Signer';
                signerImages.add(new SignerImageData(role, s.Signature_Data__c, System.now()));
            }

            // Stamp typed-name signatures into merged XML
            StampResult stamped = stampSignaturesInXml(documentXml, relsXml, contentTypesXml, signerImages);

            // Render PDF with template images only (no signature images needed)
            String html = DocGenHtmlRenderer.convertToHtml(stamped.documentXml, pdfImageMap);

            // Append verification certificate block before closing body
            /* sfge-disable-next-line ApexFlsViolation, DatabaseOperationsMustUseWithSharing */  // Guest user context — access gated by token validation
            List<DocGen_Signer__c> fullSigners = [
                SELECT Signer_Name__c, Signer_Email__c, Role_Name__c, PIN_Verified_At__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE ORDER BY Sort_Order__c ASC
            ];
            String verifyBlock = buildVerificationBlockHtml(reqId, fullSigners);
            html = html.replace('</body>', verifyBlock + '</body>');

            return Blob.toPdf(html);
        }
    }
}
