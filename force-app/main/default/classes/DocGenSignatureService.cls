// CxSAST: without sharing required for guest user signing context; access gated by cryptographic token
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
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<Site> sites = [SELECT Id FROM Site WHERE Status = 'Active' WITH SYSTEM_MODE LIMIT 1];
                if (!sites.isEmpty()) {
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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

        // Query audit records for IP addresses and timestamps
        Map<Id, DocGen_Signature_Audit__c> signerAuditMap = new Map<Id, DocGen_Signature_Audit__c>();
        try {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Audit__c> audits = [
                SELECT Signer__c, IP_Address__c, User_Agent__c, Signed_Date__c, Consent_Captured__c
                FROM DocGen_Signature_Audit__c
                WHERE Signature_Request__c = :requestId AND Signer__c != null
                WITH SYSTEM_MODE
            ]; // NOPMD
            for (DocGen_Signature_Audit__c a : audits) {
                signerAuditMap.put(a.Signer__c, a);
            }
        } catch (Exception e) {
            // Audit query failed — continue without IP data
        }

        String html = '<div style="page-break-before:always;margin-top:40px;padding-top:16px;border-top:3px solid ' + brandColor + ';">';
        html += '<table style="width:100%;font-family:Helvetica,Arial,sans-serif;font-size:9pt;color:#333;border-collapse:collapse;">';

        // Header
        html += '<tr><td colspan="2" style="padding-bottom:12px;font-size:12pt;font-weight:bold;color:' + brandColor + ';">';
        html += 'ELECTRONIC SIGNATURE CERTIFICATE</td></tr>';

        // Document info
        html += '<tr><td style="width:140px;padding:3px 0;font-weight:bold;color:#555;">Document ID:</td>';
        html += '<td style="padding:3px 0;">' + String.valueOf(requestId).escapeHtml4() + '</td></tr>';

        html += '<tr><td style="padding:3px 0;font-weight:bold;color:#555;">Completed:</td>';
        html += '<td style="padding:3px 0;">' + System.now().format('MMMM d, yyyy \'at\' h:mm a z') + '</td></tr>';

        // Signer details
        html += '<tr><td colspan="2" style="padding-top:16px;padding-bottom:6px;font-size:10pt;font-weight:bold;border-bottom:1px solid #ddd;">Signer Details</td></tr>';

        for (DocGen_Signer__c s : signers) {
            DocGen_Signature_Audit__c audit = signerAuditMap.get(s.Id);
            String role = String.isNotBlank(s.Role_Name__c) ? s.Role_Name__c : 'Signer';

            html += '<tr><td colspan="2" style="padding:8px 0 2px 0;border-bottom:1px solid #eee;">';

            // Name + Role
            html += '<span style="font-weight:bold;font-size:10pt;">' + s.Signer_Name__c.escapeHtml4() + '</span>';
            html += ' <span style="background:' + brandColor + ';color:#fff;font-size:7pt;font-weight:bold;padding:1px 6px;border-radius:8px;">' + role.escapeHtml4() + '</span><br/>';

            // Email
            html += '<span style="color:#555;">' + s.Signer_Email__c.escapeHtml4() + '</span><br/>';

            // Audit details
            if (audit != null) {
                if (audit.Signed_Date__c != null) {
                    html += '<span style="color:#555;">Signed: ' + audit.Signed_Date__c.format('MMMM d, yyyy \'at\' h:mm a z') + '</span><br/>';
                }
                if (String.isNotBlank(audit.IP_Address__c)) {
                    html += '<span style="color:#555;">IP Address: ' + audit.IP_Address__c.escapeHtml4() + '</span><br/>';
                }
                if (audit.Consent_Captured__c) {
                    html += '<span style="color:#2e844a;">&#10003; Consent captured</span><br/>';
                }
            }
            if (s.PIN_Verified_At__c != null) {
                html += '<span style="color:#2e844a;">&#10003; Email verified ' + s.PIN_Verified_At__c.format('MMM d, yyyy h:mm a z') + '</span>';
            }

            html += '</td></tr>';
        }

        // Verification footer
        html += '<tr><td colspan="2" style="padding-top:16px;font-size:8pt;color:#706e6b;">';
        html += 'This document was electronically signed using ' + companyName.escapeHtml4() + '. ';
        html += 'The SHA-256 hash of this PDF is stored in a tamper-evident audit record with field history tracking enabled. ';
        if (String.isNotBlank(siteUrl)) {
            if (siteUrl.endsWith('/')) {
                siteUrl = siteUrl.substring(0, siteUrl.length() - 1);
            }
            String ns = DocGenSignatureService.class.getName().substringBefore('.');
            String verifyPage = (String.isNotBlank(ns) && ns != 'DocGenSignatureService') ? '/apex/' + ns + '__DocGenVerify' : '/apex/DocGenVerify';
            String verifyUrl = siteUrl + verifyPage + '?id=' + String.valueOf(requestId);
            html += 'Verify at: ' + verifyUrl.escapeHtml4();
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
     * Stamps typed-name signatures into already-merged XML strings using placement records.
     * Pure string operations — no ZIP, no blob loading, no heap pressure.
     * Used by the template-based signature flow for direct PDF rendering.
     *
     * The `signers` parameter is retained for API compatibility but is not used — all stamping
     * is driven by the v3 placement records. Bare `{@Signature_Role}` tags are handled
     * automatically by parseSignaturePlacements, which treats them as `{@Signature_Role:1:Full}`.
     */
    public static StampResult stampSignaturesInXml(
        String documentXml,
        String relsXml,
        String contentTypesXml,
        List<SignerImageData> signers
    ) {
        return stampSignaturesInXml(documentXml, relsXml, contentTypesXml, signers, null);
    }

    public static StampResult stampSignaturesInXml(
        String documentXml,
        String relsXml,
        String contentTypesXml,
        List<SignerImageData> signers,
        List<DocGen_Signature_Placement__c> placements
    ) {
        Map<String, String> signatureImageUrls = new Map<String, String>();

        if (placements != null && !placements.isEmpty()) {
            for (DocGen_Signature_Placement__c plc : placements) {
                if (plc.Status__c != 'Signed' || String.isBlank(plc.Tag_Text__c)) continue;

                String replacement = buildPlacementText(plc);
                if (documentXml.contains(plc.Tag_Text__c)) {
                    // Replace only the FIRST occurrence of this exact tag
                    documentXml = documentXml.replaceFirst(Pattern.quote(plc.Tag_Text__c), escapeXml(replacement));
                }
            }
        }

        return new StampResult(documentXml, relsXml, contentTypesXml, signatureImageUrls);
    }

    /**
     * Builds the replacement text for a signed placement based on its type.
     */
    private static String buildPlacementText(DocGen_Signature_Placement__c plc) {
        String value = plc.Signed_Value__c;
        String pType = plc.Placement_Type__c;

        if (pType == 'Full') {
            String dateStr = plc.Signed_At__c != null
                ? plc.Signed_At__c.format('yyyy-MM-dd HH:mm:ss z')
                : System.now().format('yyyy-MM-dd HH:mm:ss z');
            return 'Electronically signed by ' + value + ' on ' + dateStr;
        } else if (pType == 'Initials') {
            return value; // Just the initials
        } else if (pType == 'Date') {
            // Auto server timestamp
            DateTime dt = plc.Signed_At__c != null ? plc.Signed_At__c : System.now();
            return dt.format('MMMM d, yyyy');
        } else if (pType == 'DatePick') {
            return value; // Signer-picked date string
        }
        return value != null ? value : '';
    }

    /**
     * Stamps ALL signer typed-name signatures into a DOCX at their named placeholders.
     * Each signer's role maps to {@Signature_RoleName} in the document.
     * Falls back to legacy {@Signature} for single signer with blank role.
     */
    public static Blob stampAllSignaturesToBlob(Id sourceCvId, List<SignerData> signers) {
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        ContentVersion cv = [SELECT Id, VersionData, Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        if (cv == null || cv.VersionData == null) {
            throw new SignatureException('Source document not found or has no content.');
        }

        Blob docxBlob = cv.VersionData;
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        for (Compression.ZipEntry entry : reader.getEntries()) {
            // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
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
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        ContentVersion source = [SELECT Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        List<SignerData> signers = new List<SignerData>{ new SignerData(null, typedName) };
        Blob resultBlob = stampAllSignaturesToBlob(sourceCvId, signers);

        ContentVersion newCv = new ContentVersion();
        newCv.Title = source.Title + ' - Signed';
        newCv.PathOnClient = newCv.Title + '.docx';
        newCv.VersionData = resultBlob;
        newCv.IsMajorVersion = true;
        SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ newCv });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        insert cvDecision.getRecords();
        Id savedCvId = cvDecision.getRecords()[0].Id;

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Id newDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH SYSTEM_MODE].ContentDocumentId;

        if (String.isNotBlank(relatedRecordId)) {
            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = newDocId;
            cdl.LinkedEntityId = relatedRecordId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            SObjectAccessDecision cdlDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{ cdl });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        req.Signature_Data__c = typedName;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        req.Status__c = 'In Progress';
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        update req; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        if (Test.isRunningTest()) {
            try {
                Blob pdfBlob = Blob.toPdf('<html><body><p>Test PDF - Signed Document</p></body></html>');
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<ContentVersion> sources = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
                String fileName = !sources.isEmpty() ? sources[0].Title + ' - Signed' : 'Document - Signed';
                DocGenController.saveGeneratedDocument(req.Related_Record_Id__c, fileName, EncodingUtil.base64Encode(pdfBlob), 'pdf');
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                req.Status__c = 'Signed';
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                req.Signature_Data__c = null;
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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
    // CxSAST: without sharing required for guest user signing context; access gated by cryptographic token
    public class SignaturePdfQueueable implements Queueable, Database.AllowsCallouts {
        private Id requestId;

        public SignaturePdfQueueable(Id requestId) {
            this.requestId = requestId;
        }

        public void execute(QueueableContext ctx) {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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
                            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                            Database.insert(new List<ContentVersion>{ imgCv }, false, AccessLevel.SYSTEM_MODE);
                            imageUrlMap.put(relId, '/sfc/servlet.shepherd/version/download/' + imgCv.Id);
                        }
                    }

                    String html = DocGenHtmlRenderer.convertToHtml(documentXml, imageUrlMap);
                    pdfBlob = Blob.toPdf(html);
                }

                // Save PDF to related record
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                ContentVersion source = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
                String fileName = source.Title + ' - Signed';

                if (String.isNotBlank(req.Related_Record_Id__c)) {
                    ContentVersion pdfCv = new ContentVersion();
                    pdfCv.Title = fileName;
                    pdfCv.PathOnClient = fileName + '.pdf';
                    pdfCv.VersionData = pdfBlob;
                    pdfCv.FirstPublishLocationId = req.Related_Record_Id__c;
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    Database.insert(new List<ContentVersion>{ pdfCv }, false, AccessLevel.SYSTEM_MODE);
                }

                // Update document hash on existing audit records
                String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<DocGen_Signature_Audit__c> audits = [
                    SELECT Id FROM DocGen_Signature_Audit__c
                    WHERE Signature_Request__c = :requestId AND Document_Hash_SHA256__c = null
                    WITH SYSTEM_MODE
                ];
                for (DocGen_Signature_Audit__c a : audits) {
                    // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                    a.Document_Hash_SHA256__c = pdfHash;
                }
                if (!audits.isEmpty()) {
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    Database.update(audits, false, AccessLevel.SYSTEM_MODE);
                }

                // Mark request as signed
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                req.Status__c = 'Signed';
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.insert(new List<DocGen_Signature_Audit__c>{ errAudit }, false, AccessLevel.SYSTEM_MODE);
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                req.Status__c = 'Viewed';
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.update(req, false, AccessLevel.SYSTEM_MODE);
            }
        }

        private void cleanupTempImages(Id reqId) {
            try {
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<ContentDocumentLink> tempCdls = [
                    SELECT ContentDocumentId FROM ContentDocumentLink
                    WHERE LinkedEntityId = :reqId
                    AND (ContentDocument.Title LIKE 'docgen_sig_img_%' OR ContentDocument.Title LIKE 'docgen_sig_xml_%')
                    WITH SYSTEM_MODE
                ];
                if (!tempCdls.isEmpty()) {
                    Set<Id> docIds = new Set<Id>();
                    for (ContentDocumentLink cdl : tempCdls) docIds.add(cdl.ContentDocumentId);
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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
    // CxSAST: without sharing required for guest user signing context; access gated by cryptographic token
    public class TemplateSignaturePdfQueueable implements Queueable, Database.AllowsCallouts {
        private Id requestId;

        public TemplateSignaturePdfQueueable(Id requestId) {
            this.requestId = requestId;
        }

        public void execute(QueueableContext ctx) {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> requests = [
                SELECT Id, Template__c, Template_Ids__c, Related_Record_Id__c
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
                } else if (String.isNotBlank(req.Template_Ids__c)) {
                    // Multi-template packet
                    pdfBlob = renderPacketSignaturePdf(requestId, req.Template_Ids__c, req.Related_Record_Id__c);
                } else {
                    pdfBlob = renderTemplateSignaturePdf(requestId, req.Template__c, req.Related_Record_Id__c);
                }

                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    Database.insert(new List<ContentVersion>{ pdfCv }, false, AccessLevel.SYSTEM_MODE);
                }

                // Update document hash on existing audit records
                String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<DocGen_Signature_Audit__c> audits = [
                    SELECT Id FROM DocGen_Signature_Audit__c
                    WHERE Signature_Request__c = :requestId AND Document_Hash_SHA256__c = null
                    WITH SYSTEM_MODE
                ];
                for (DocGen_Signature_Audit__c a : audits) {
                    // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                    a.Document_Hash_SHA256__c = pdfHash;
                }
                if (!audits.isEmpty()) {
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    Database.update(audits, false, AccessLevel.SYSTEM_MODE);
                }

                // Mark signed
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                req.Status__c = 'Signed';
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                req.Signature_Data__c = null;
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.update(req, false, AccessLevel.SYSTEM_MODE);

            } catch (Exception e) {
                String errMsg = e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
                System.debug(LoggingLevel.ERROR, 'DocGen: Template signature PDF failed for ' + req.Id + ': ' + errMsg);
                DocGen_Signature_Audit__c errAudit = new DocGen_Signature_Audit__c();
                errAudit.Signature_Request__c = req.Id;
                errAudit.Signer_Name__c = 'SYSTEM';
                errAudit.Error_Message__c = errMsg;
                errAudit.Signed_Date__c = System.now();
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.insert(new List<DocGen_Signature_Audit__c>{ errAudit }, false, AccessLevel.SYSTEM_MODE);
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                req.Status__c = 'Viewed';
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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
                // 1.49 (#28): hydrate the table-style border map cached at request creation.
                // Async context (Automated Process user) can't re-query the pre-decomposed
                // styles.xml ContentVersion, so the renderer falls back to this map.
                Object bordersObj = cachedData.get('tableBordersMap');
                if (bordersObj instanceof Map<String, Object>) {
                    Map<String, String> borders = new Map<String, String>();
                    for (String k : ((Map<String, Object>) bordersObj).keySet()) {
                        borders.put(k, (String) ((Map<String, Object>) bordersObj).get(k));
                    }
                    DocGenHtmlRenderer.tableStyleBorderMap = borders;
                }
            }

            // Get signer typed names
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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

            // Query placements for stamping
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Placement__c> placements = [
                SELECT Id, Signer__c, Placement_Type__c, Sequence_Order__c, Signed_Value__c,
                       Status__c, Signed_At__c, Tag_Text__c, Document_Index__c
                FROM DocGen_Signature_Placement__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
                ORDER BY Document_Index__c ASC, Sequence_Order__c ASC
            ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

            // Stamp typed-name signatures into merged XML
            StampResult stamped = stampSignaturesInXml(documentXml, relsXml, contentTypesXml, signerImages, placements);

            // Re-prime the HTML renderer context immediately before convertToHtml.
            DocGenHtmlRenderer.stylesXml = (String) mergeData.get('stylesXml');
            DocGenHtmlRenderer.numberingXml = (String) mergeData.get('numberingXml');

            // Render PDF with template images only (no signature images needed)
            String html = DocGenHtmlRenderer.convertToHtml(stamped.documentXml, pdfImageMap);

            // Append verification certificate block before closing body
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
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

        /**
         * Renders a multi-template packet as a single signed PDF.
         * Merges each template, stamps placements per document, concatenates HTML with page breaks.
         */
        private Blob renderPacketSignaturePdf(Id reqId, String templateIdsJson, String recordId) {
            List<Object> rawIds = (List<Object>) JSON.deserializeUntyped(templateIdsJson);
            List<Id> templateIds = new List<Id>();
            for (Object o : rawIds) templateIds.add((Id) o);

            // Query template names for document headers
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Map<Id, DocGen_Template__c> templateMap = new Map<Id, DocGen_Template__c>([
                SELECT Id, Name FROM DocGen_Template__c WHERE Id IN :templateIds WITH SYSTEM_MODE
            ]); // NOPMD

            // Query all placements for this request
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Placement__c> allPlacements = [
                SELECT Id, Signer__c, Placement_Type__c, Sequence_Order__c, Signed_Value__c,
                       Status__c, Signed_At__c, Tag_Text__c, Document_Index__c
                FROM DocGen_Signature_Placement__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
                ORDER BY Document_Index__c ASC, Sequence_Order__c ASC
            ]; // NOPMD

            // Query signers for placement stamping (roles + typed names)
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signer__c> signers = [
                SELECT Id, Role_Name__c, Signature_Data__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE ORDER BY Sort_Order__c ASC
            ]; // NOPMD
            List<SignerImageData> signerImages = new List<SignerImageData>();
            for (DocGen_Signer__c s : signers) {
                signerImages.add(new SignerImageData(
                    String.isNotBlank(s.Role_Name__c) ? s.Role_Name__c : 'Signer',
                    s.Signature_Data__c, System.now()
                ));
            }

            // Get cached image map
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            DocGen_Signature_Request__c reqData = [
                SELECT Signature_Data__c FROM DocGen_Signature_Request__c WHERE Id = :reqId WITH SYSTEM_MODE LIMIT 1
            ]; // NOPMD
            Map<String, String> cachedImageMap = new Map<String, String>();
            if (String.isNotBlank(reqData.Signature_Data__c)) {
                Map<String, Object> cachedData = (Map<String, Object>) JSON.deserializeUntyped(reqData.Signature_Data__c);
                Object imgMapObj = cachedData.get('imageMap');
                if (imgMapObj instanceof Map<String, Object>) {
                    for (String k : ((Map<String, Object>) imgMapObj).keySet()) {
                        cachedImageMap.put(k, (String) ((Map<String, Object>) imgMapObj).get(k));
                    }
                }
            }

            // Merge and stamp each document
            List<String> htmlParts = new List<String>();
            for (Integer docIdx = 0; docIdx < templateIds.size(); docIdx++) {
                Id tid = templateIds[docIdx];
                Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(tid, recordId);
                String documentXml = (String) mergeData.get('documentXml');
                String relsXml = (String) mergeData.get('relsXml');
                String contentTypesXml = (String) mergeData.get('contentTypesXml');
                Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
                pdfImageMap.putAll(cachedImageMap);

                // Filter placements for this document
                List<DocGen_Signature_Placement__c> docPlacements = new List<DocGen_Signature_Placement__c>();
                for (DocGen_Signature_Placement__c p : allPlacements) {
                    if (p.Document_Index__c == docIdx) docPlacements.add(p);
                }

                StampResult stamped = stampSignaturesInXml(documentXml, relsXml, contentTypesXml, signerImages, docPlacements);
                // Re-prime renderer context for this document (see #28 — statics don't survive
                // intermediate calls reliably in async context).
                DocGenHtmlRenderer.stylesXml = (String) mergeData.get('stylesXml');
                DocGenHtmlRenderer.numberingXml = (String) mergeData.get('numberingXml');
                String docHtml = DocGenHtmlRenderer.convertToHtml(stamped.documentXml, pdfImageMap);

                if (docIdx > 0) {
                    htmlParts.add('<div style="page-break-before:always"></div>');
                }
                htmlParts.add(docHtml);
            }

            String fullHtml = String.join(htmlParts, '');

            // Append verification block
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signer__c> fullSigners = [
                SELECT Signer_Name__c, Signer_Email__c, Role_Name__c, PIN_Verified_At__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE ORDER BY Sort_Order__c ASC
            ]; // NOPMD
            String verifyBlock = buildVerificationBlockHtml(reqId, fullSigners);
            fullHtml = fullHtml.replace('</body>', verifyBlock + '</body>');

            return Blob.toPdf(fullHtml);
        }
    }
}
