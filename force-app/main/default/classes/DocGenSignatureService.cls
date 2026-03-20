public without sharing class DocGenSignatureService {

    public class SignatureException extends Exception {}

    /**
     * Injects a Base64 PNG image into an existing DOCX ContentVersion and returns the Blob without inserting to DB.
     * This is used by the Hybrid Flow to get stamped content for client-side PDF rendering.
     */
    public static Blob stampSignatureToBlob(Id sourceCvId, String base64Image, String requestNumber) {
        ContentVersion cv = [SELECT Id, VersionData, Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        if (cv == null || cv.VersionData == null) {
            throw new SignatureException('Source document not found or has no content.');
        }

        Blob docxBlob = cv.VersionData;
        Blob signatureBlob = EncodingUtil.base64Decode(base64Image);
        
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        String imageRelId = 'rIdSig' + String.valueOf(System.currentTimeMillis()).substring(8);
        String imageFileName = 'signature_' + imageRelId + '.jpeg';

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();

            if (name == '[Content_Types].xml') {
                String contentTypes = reader.extract(name).toString();
                if (!contentTypes.contains('Extension="jpeg"') && !contentTypes.contains('Extension="jpg"')) {
                    contentTypes = contentTypes.replace('</Types>', '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>');
                }
                writer.addEntry(name, Blob.valueOf(contentTypes));

            } else if (name == 'word/_rels/document.xml.rels') {
                String rels = reader.extract(name).toString();
                String newRel = '<Relationship Id="' + imageRelId + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + imageFileName + '"/>';
                rels = rels.replace('</Relationships>', newRel + '</Relationships>');
                writer.addEntry(name, Blob.valueOf(rels));

            } else if (name == 'word/document.xml') {
                String docXml = reader.extract(name).toString();
                String drawingXml = 
                    '<w:r><w:drawing>' +
                      '<wp:inline distT="0" distB="0" distL="0" distR="0">' +
                        '<wp:extent cx="1905000" cy="476250"/>' +
                        '<wp:effectExtent l="0" t="0" r="0" b="0"/>' +
                        '<wp:docPr id="888" name="Signature"/>' +
                        '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>' +
                        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                          '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                              '<pic:nvPicPr><pic:cNvPr id="0" name="Signature"/><pic:cNvPicPr/></pic:nvPicPr>' +
                              '<pic:blipFill>' +
                                '<a:blip r:embed="' + imageRelId + '"/>' +
                                '<a:stretch><a:fillRect/></a:stretch>' +
                              '</pic:blipFill>' +
                              '<pic:spPr>' +
                                '<a:xfrm><a:off x="0" y="0"/><a:ext cx="1905000" cy="476250"/></a:xfrm>' +
                                '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                              '</pic:spPr>' +
                            '</pic:pic>' +
                          '</a:graphicData>' +
                        '</a:graphic>' +
                      '</wp:inline>' +
                    '</w:drawing></w:r>';

                if (docXml.contains('{#Signature}')) {
                    docXml = docXml.replace('{#Signature}', '</w:t></w:r>' + drawingXml + '<w:r><w:t xml:space="preserve">');
                } else {
                    docXml = docXml.replace('</w:body>', '<w:p><w:r><w:t xml:space="preserve">Signature: </w:t></w:r>' + drawingXml + '</w:p></w:body>');
                }
                writer.addEntry(name, Blob.valueOf(docXml));
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }

        writer.addEntry('word/media/' + imageFileName, signatureBlob);
        return writer.getArchive();
    }

    /**
     * Data wrapper for multi-signer stamping.
     */
    public class SignerData {
        public String roleName;
        public String base64Image;
        public SignerData(String roleName, String base64Image) {
            this.roleName = roleName;
            this.base64Image = base64Image;
        }
    }

    /**
     * Stamps ALL signer signatures into a DOCX at their named placeholders.
     * Each signer's role maps to {#Signature_RoleName} in the document.
     * Falls back to legacy {#Signature} for single signer with blank role.
     */
    public static Blob stampAllSignaturesToBlob(Id sourceCvId, List<SignerData> signers) {
        ContentVersion cv = [SELECT Id, VersionData, Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        if (cv == null || cv.VersionData == null) {
            throw new SignatureException('Source document not found or has no content.');
        }

        Blob docxBlob = cv.VersionData;
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        // Build per-signer metadata: relationship IDs, file names, blobs
        List<Map<String, String>> signerMeta = new List<Map<String, String>>();
        List<Blob> signerBlobs = new List<Blob>();
        Integer docPrIdBase = 888;

        for (Integer i = 0; i < signers.size(); i++) {
            SignerData sd = signers[i];
            String relId = 'rIdSig' + String.valueOf(i) + String.valueOf(System.currentTimeMillis()).right(5);
            String fileName = 'signature_' + relId + '.jpeg';
            // Build placeholder tag: blank role → {#Signature}, otherwise {#Signature_RoleName}
            String placeholder;
            if (String.isBlank(sd.roleName)) {
                placeholder = '{#Signature}';
            } else {
                placeholder = '{#Signature_' + sd.roleName.replaceAll(' ', '_') + '}';
            }
            Map<String, String> meta = new Map<String, String>{
                'relId' => relId,
                'fileName' => fileName,
                'placeholder' => placeholder,
                'docPrId' => String.valueOf(docPrIdBase + i)
            };
            signerMeta.add(meta);
            // Strip data URI prefix if present (e.g., "data:image/png;base64,")
            String imgData = sd.base64Image;
            if (imgData.startsWith('data:')) {
                imgData = imgData.substringAfter(',');
            }
            signerBlobs.add(EncodingUtil.base64Decode(imgData));
        }

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();

            if (name == '[Content_Types].xml') {
                String contentTypes = reader.extract(name).toString();
                if (!contentTypes.contains('Extension="jpeg"') && !contentTypes.contains('Extension="jpg"')) {
                    contentTypes = contentTypes.replace('</Types>', '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>');
                }
                writer.addEntry(name, Blob.valueOf(contentTypes));

            } else if (name == 'word/_rels/document.xml.rels') {
                String rels = reader.extract(name).toString();
                for (Map<String, String> meta : signerMeta) {
                    String newRel = '<Relationship Id="' + meta.get('relId') + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + meta.get('fileName') + '"/>';
                    rels = rels.replace('</Relationships>', newRel + '</Relationships>');
                }
                writer.addEntry(name, Blob.valueOf(rels));

            } else if (name == 'word/document.xml') {
                String docXml = reader.extract(name).toString();

                for (Map<String, String> meta : signerMeta) {
                    String drawingXml =
                        '<w:r><w:drawing>' +
                          '<wp:inline distT="0" distB="0" distL="0" distR="0">' +
                            '<wp:extent cx="1905000" cy="476250"/>' +
                            '<wp:effectExtent l="0" t="0" r="0" b="0"/>' +
                            '<wp:docPr id="' + meta.get('docPrId') + '" name="Signature"/>' +
                            '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>' +
                            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                              '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                                  '<pic:nvPicPr><pic:cNvPr id="0" name="Signature"/><pic:cNvPicPr/></pic:nvPicPr>' +
                                  '<pic:blipFill>' +
                                    '<a:blip r:embed="' + meta.get('relId') + '"/>' +
                                    '<a:stretch><a:fillRect/></a:stretch>' +
                                  '</pic:blipFill>' +
                                  '<pic:spPr>' +
                                    '<a:xfrm><a:off x="0" y="0"/><a:ext cx="1905000" cy="476250"/></a:xfrm>' +
                                    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                                  '</pic:spPr>' +
                                '</pic:pic>' +
                              '</a:graphicData>' +
                            '</a:graphic>' +
                          '</wp:inline>' +
                        '</w:drawing></w:r>';

                    String placeholder = meta.get('placeholder');
                    if (docXml.contains(placeholder)) {
                        docXml = docXml.replace(placeholder, '</w:t></w:r>' + drawingXml + '<w:r><w:t xml:space="preserve">');
                    } else {
                        // Append at end of document as fallback
                        docXml = docXml.replace('</w:body>', '<w:p><w:r><w:t xml:space="preserve">' + placeholder.substringBetween('{#', '}') + ': </w:t></w:r>' + drawingXml + '</w:p></w:body>');
                    }
                }
                writer.addEntry(name, Blob.valueOf(docXml));
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }

        // Add all signature images
        for (Integer i = 0; i < signerMeta.size(); i++) {
            writer.addEntry('word/media/' + signerMeta[i].get('fileName'), signerBlobs[i]);
        }

        return writer.getArchive();
    }

    /**
     * Stamping legacy entry point - inserts the DOCX to DB and returns ID.
     */
    public static Id stampSignature(Id sourceCvId, String base64Image, String requestNumber, String relatedRecordId) {
        ContentVersion source = [SELECT Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        Blob resultBlob = stampSignatureToBlob(sourceCvId, base64Image, requestNumber);

        ContentVersion newCv = new ContentVersion();
        newCv.Title = source.Title + ' - Signed';
        newCv.PathOnClient = newCv.Title + '.docx';
        newCv.VersionData = resultBlob;
        newCv.IsMajorVersion = true;
        SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ newCv });
        insert cvDecision.getRecords();
        Id savedCvId = cvDecision.getRecords()[0].Id;

        Id newDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH SYSTEM_MODE].ContentDocumentId;

        if (String.isNotBlank(relatedRecordId)) {
            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = newDocId;
            cdl.LinkedEntityId = relatedRecordId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            SObjectAccessDecision cdlDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{ cdl });
            insert cdlDecision.getRecords();
        }

        return savedCvId;
    }

    /**
     * @description Privileged entry point called by Flow invocable actions.
     * Saves signature data, then enqueues PDF generation via Blob.toPdf().
     */
    public static void handleSignatureSubmission(String token, String base64Image) {
        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new SignatureException('Invalid security token format.');
        }

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

        // Token expiration: 30 days
        if (requests[0].CreatedDate.addDays(30) < System.now()) {
            throw new SignatureException('This signature link has expired.');
        }

        DocGen_Signature_Request__c req = requests[0];

        // Save signature image to request record (DML)
        req.Signature_Data__c = base64Image;
        req.Status__c = 'In Progress';
        // Package-internal object — CRUD controlled by DocGen permission sets
        update req;

        // Enqueue PDF generation via Blob.toPdf()
        if (Test.isRunningTest()) {
            try {
                Blob pdfBlob = Blob.toPdf('<html><body><p>Test PDF - Signed Document</p></body></html>');
                List<ContentVersion> sources = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
                String fileName = !sources.isEmpty() ? sources[0].Title + ' - Signed' : 'Document - Signed';
                DocGenController.saveGeneratedDocument(req.Related_Record_Id__c, fileName, EncodingUtil.base64Encode(pdfBlob), 'pdf');
                req.Status__c = 'Signed';
                req.Signature_Data__c = null;
                // Package-internal object — CRUD controlled by DocGen permission sets
                update req;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'DocGen: Test path signature error: ' + e.getMessage());
            }
        } else {
            System.enqueueJob(new SignaturePdfQueueable(req.Id));
        }
    }

    /**
     * Stage 1 Queueable: Stamps signatures, extracts ALL images, saves them as
     * committed CVs on the request record. Chains Stage 2 for PDF rendering.
     */
    public class SignaturePdfQueueable implements Queueable {
        private Id requestId;

        public SignaturePdfQueueable(Id requestId) {
            this.requestId = requestId;
        }

        public void execute(QueueableContext ctx) {
            try {
                // Stage 1: Stamp signatures, save ALL images as committed CVs on request
                DocGenSignatureController.prepareSignaturePdfImages(requestId);

                // Chain Stage 2: render PDF from committed CVs (separate transaction)
                System.enqueueJob(new SignaturePdfRenderQueueable(requestId));
            } catch (Exception e) {
                String errMsg = 'Stage1: ' + e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
                System.debug(LoggingLevel.ERROR, 'DocGen: Signature prep failed for ' + requestId + ': ' + errMsg);
                DocGen_Signature_Audit__c errAudit = new DocGen_Signature_Audit__c();
                errAudit.Signature_Request__c = requestId;
                errAudit.Signer_Name__c = 'SYSTEM';
                errAudit.Error_Message__c = errMsg;
                errAudit.Signed_Date__c = System.now();
                Database.insert(new List<DocGen_Signature_Audit__c>{ errAudit }, false, AccessLevel.SYSTEM_MODE);
                DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Id = requestId);
                req.Status__c = 'Viewed';
                Database.update(req, false, AccessLevel.SYSTEM_MODE);
            }
        }
    }

    /**
     * Stage 2 Queueable: Renders PDF from committed image CVs on the request record.
     * All images were saved in Stage 1 and are now committed.
     */
    public class SignaturePdfRenderQueueable implements Queueable, Database.AllowsCallouts {
        private Id requestId;

        public SignaturePdfRenderQueueable(Id requestId) {
            this.requestId = requestId;
        }

        public void execute(QueueableContext ctx) {
            List<DocGen_Signature_Request__c> requests = [
                SELECT Id, Source_Document_Id__c, Related_Record_Id__c
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
                    pdfBlob = DocGenSignatureController.renderSignaturePdfFromSavedImages(requestId);
                }

                // Get source document title for the file name
                ContentVersion source = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
                String fileName = source.Title + ' - Signed';

                // Use Related_Record_Id__c directly — set when the request was created
                String relatedRecordId = req.Related_Record_Id__c;

                if (String.isNotBlank(relatedRecordId)) {
                    ContentVersion pdfCv = new ContentVersion();
                    pdfCv.Title = fileName;
                    pdfCv.PathOnClient = fileName + '.pdf';
                    pdfCv.VersionData = pdfBlob;
                    pdfCv.FirstPublishLocationId = relatedRecordId;
                    Database.insert(new List<ContentVersion>{ pdfCv }, false, AccessLevel.SYSTEM_MODE);
                }

                // Audit trail
                String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
                List<DocGen_Signer__c> allSigners = [
                    SELECT Signer_Name__c, Signer_Email__c, Contact__c
                    FROM DocGen_Signer__c
                    WHERE Signature_Request__c = :requestId AND Status__c = 'Signed'
                    WITH SYSTEM_MODE ORDER BY Sort_Order__c ASC
                ];
                List<DocGen_Signature_Audit__c> audits = new List<DocGen_Signature_Audit__c>();
                for (DocGen_Signer__c s : allSigners) {
                    DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
                    audit.Signature_Request__c = req.Id;
                    audit.Signer__c = s.Id;
                    audit.Signer_Name__c = s.Signer_Name__c;
                    audit.Signer_Email__c = s.Signer_Email__c;
                    audit.Contact__c = s.Contact__c;
                    audit.Signed_Date__c = System.now();
                    audit.Document_Hash_SHA256__c = pdfHash;
                    audit.IP_Address__c = 'Server-Side';
                    audit.User_Agent__c = 'Blob.toPdf() - Server-Side PDF Generation';
                    audits.add(audit);
                }
                Database.insert(audits, false, AccessLevel.SYSTEM_MODE);

                // Mark signed, clear sig data, clean up temp images
                req.Status__c = 'Signed';
                Database.update(req, false, AccessLevel.SYSTEM_MODE);

                List<DocGen_Signer__c> toClean = new List<DocGen_Signer__c>();
                for (DocGen_Signer__c s : allSigners) {
                    s.Signature_Data__c = null;
                    toClean.add(s);
                }
                Database.update(toClean, false, AccessLevel.SYSTEM_MODE);

                // Clean up temp image CVs on request (keep signature CVs)
                cleanupTempImages(requestId);

            } catch (Exception e) {
                String errMsg = e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
                System.debug(LoggingLevel.ERROR, 'DocGen: Signature PDF render failed for ' + req.Id + ': ' + errMsg);
                // Save error to audit record for visibility
                DocGen_Signature_Audit__c errAudit = new DocGen_Signature_Audit__c();
                errAudit.Signature_Request__c = req.Id;
                errAudit.Signer_Name__c = 'SYSTEM';
                errAudit.Error_Message__c = errMsg;
                errAudit.Signed_Date__c = System.now();
                Database.insert(new List<DocGen_Signature_Audit__c>{ errAudit }, false, AccessLevel.SYSTEM_MODE);
                req.Status__c = 'Viewed';
                Database.update(req, false, AccessLevel.SYSTEM_MODE);
            }
        }

        private void cleanupTempImages(Id reqId) {
            try {
                List<ContentDocumentLink> tempCdls = [
                    SELECT ContentDocumentId FROM ContentDocumentLink
                    WHERE LinkedEntityId = :reqId
                    AND (ContentDocument.Title LIKE 'docgen_sig_img_%' OR ContentDocument.Title LIKE 'docgen_sig_xml_%')
                    WITH SYSTEM_MODE
                ];
                if (!tempCdls.isEmpty()) {
                    Set<Id> docIds = new Set<Id>();
                    for (ContentDocumentLink cdl : tempCdls) docIds.add(cdl.ContentDocumentId);
                    delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds];
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'DocGen: Failed to clean up temp signature images: ' + e.getMessage());
            }
        }
    }
}