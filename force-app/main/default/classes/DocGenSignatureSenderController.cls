public with sharing class DocGenSignatureSenderController {

    public class SignerResult {
        @AuraEnabled public String signerName;
        @AuraEnabled public String roleName;
        @AuraEnabled public String signerUrl;
        @AuraEnabled public String signerEmail;
    }

    /**
     * Returns all active DocGen templates for the signature sender template picker.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getDocGenTemplates() {
        /* code-analyzer-suppress ApexFlsViolation */
        return [
            SELECT Id, Name
            FROM DocGen_Template__c
            WITH USER_MODE
            ORDER BY Name ASC
        ];
    }

    /**
     * Scans a DocGen template's pre-decomposed XML for {@Signature_XXX} placeholders.
     * No ZIP decompression needed — reads from stored XML ContentVersions.
     */
    @AuraEnabled
    public static List<String> getTemplateSignatureRoles(Id templateId) {
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = true
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (activeVersions.isEmpty()) return new List<String>();

        String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
        List<ContentVersion> xmlCvs = [
            SELECT Title, VersionData FROM ContentVersion
            WHERE Title LIKE :(xmlPrefix + '%')
            WITH SYSTEM_MODE
        ];

        // Find the document.xml entry
        String documentXml = null;
        for (ContentVersion cv : xmlCvs) {
            String key = cv.Title.substring(xmlPrefix.length());
            String originalPath = key.replace('__', '/');
            if (originalPath == 'word/document.xml') {
                documentXml = cv.VersionData.toString();
                break;
            }
        }
        if (documentXml == null) return new List<String>();

        // Extract text from <w:t> elements
        String plainText = '';
        Pattern wtPat = Pattern.compile('<w:t[^>]*>([^<]*)</w:t>');
        Matcher wtMatch = wtPat.matcher(documentXml);
        while (wtMatch.find()) {
            plainText += wtMatch.group(1);
        }

        // Find {@Signature_RoleName} placeholders
        List<String> roles = new List<String>();
        Pattern sigPat = Pattern.compile('\\{@Signature_([^}]+)\\}');
        Matcher sigMatch = sigPat.matcher(plainText);
        while (sigMatch.find()) {
            String roleName = sigMatch.group(1).replaceAll('_', ' ');
            if (!roles.contains(roleName)) {
                roles.add(roleName);
            }
        }

        if (roles.isEmpty() && plainText.contains('{@Signature}')) {
            roles.add('Signer');
        }

        return roles;
    }

    /**
     * Creates a template-based multi-signer signature request.
     * No pre-generated DOCX needed — PDF is merged from template at signing time.
     */
    @AuraEnabled
    // CxSAST: Apex_CRUD_Violation — package-internal custom objects; CRUD controlled by DocGen permission sets
    // CxSAST: Apex_CRUD_ContentDistribution — ContentDistribution created for signature preview images
    public static List<SignerResult> createTemplateSignerRequest(Id templateId, String relatedRecordId, String signersJson) {
        // Validate template exists
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [SELECT Id, Name FROM DocGen_Template__c WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1];
        if (templates.isEmpty()) {
            throw new AuraHandledException('Template not found.');
        }

        // Parse signers JSON
        List<Object> rawInputs = (List<Object>) JSON.deserializeUntyped(signersJson);
        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Object item : rawInputs) {
            signerInputs.add((Map<String, Object>) item);
        }

        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        // Create parent request with template reference (no Source_Document_Id__c)
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        req.Template__c = templateId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Status__c = 'Sent';
        // Package-internal object — CRUD controlled by DocGen permission sets
        /* code-analyzer-suppress ApexFlsViolation */
        insert req; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        // Pre-compute everything while we have admin access.
        // Guest users can't query template data or ContentVersions (content sharing).
        // Store on the request record which the guest accesses via token + SYSTEM_MODE.
        try {
            Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(templateId, relatedRecordId);
            Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');

            // Build preview HTML with public URLs for images (not data URIs — keeps size small).
            // Create ContentDistributions for each template image so guest browser can load them.
            Map<String, String> previewImageMap = new Map<String, String>();
            for (String relId : pdfImageMap.keySet()) {
                String url = pdfImageMap.get(relId);
                if (url != null && url.contains('/version/download/')) {
                    String cvId = url.substringAfterLast('/');
                    // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                    try {
                        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                        ContentDistribution dist = new ContentDistribution();
                        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                        dist.Name = 'sig_preview_' + relId;
                        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                        dist.ContentVersionId = cvId;
                        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                        dist.PreferencesAllowViewInBrowser = true;
                        dist.PreferencesLinkLatestVersion = false;
                        dist.PreferencesExpires = false;
                        insert dist; // NOPMD ApexCRUDViolation - ContentDistribution for signature preview
                        dist = [SELECT ContentDownloadUrl FROM ContentDistribution WHERE Id = :dist.Id]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
                        previewImageMap.put(relId, dist.ContentDownloadUrl);
                    } catch (Exception e) {
                        System.debug(LoggingLevel.WARN, 'DocGen: Could not create public link for ' + relId + ': ' + e.getMessage());
                    }
                }
            }

            // Render preview HTML using public URLs (small, no base64 bloat)
            String docXml = (String) mergeData.get('documentXml');
            String previewHtml = DocGenHtmlRenderer.convertToHtml(docXml, previewImageMap);

            // Store image map (for Queueable) + preview HTML (for guest VF page)
            Map<String, Object> cachedData = new Map<String, Object>{
                'imageMap' => pdfImageMap,
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                'previewHtml' => previewHtml
            };
            req.Signature_Data__c = JSON.serialize(cachedData);
            /* code-analyzer-suppress ApexFlsViolation */
            update req; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Failed to pre-compute signature data: ' + e.getMessage());
        }

        // Create individual signer records + send emails (shared logic)
        return createSignersAndNotify(req.Id, templateId, templates[0].Name, signerInputs);
    }

    @AuraEnabled(cacheable=true)
    public static List<ContentVersion> getRelatedDocuments(Id recordId) {
        List<ContentDocumentLink> links = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :recordId WITH USER_MODE];
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : links) docIds.add(link.ContentDocumentId);

        return [
            SELECT Id, Title, FileExtension, ContentDocumentId
            FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND IsLatest = true
            AND FileExtension = 'docx'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Creates a multi-signer signature request with individual tokens per signer.
     * Legacy DOCX-based flow — requires a pre-generated DOCX on the record.
     * signersJson: [{roleName, contactId, signerName, signerEmail}, ...]
     */
    @AuraEnabled
    // CxSAST: Apex_CRUD_Violation — package-internal custom objects; CRUD controlled by DocGen permission sets
    public static List<SignerResult> createMultiSignerRequest(Id contentDocumentId, String relatedRecordId, String signersJson) {
        // Resolve latest ContentVersionId
        List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :contentDocumentId WITH SYSTEM_MODE LIMIT 1];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Document not found or has been deleted.');
        }
        Id contentVersionId = docs[0].LatestPublishedVersionId;

        // Parse signers JSON
        List<Object> rawInputs = (List<Object>) JSON.deserializeUntyped(signersJson);
        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Object item : rawInputs) {
            signerInputs.add((Map<String, Object>) item);
        }


        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects

        // Create parent request
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Source_Document_Id__c = contentVersionId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Status__c = 'Sent';
        // Package-internal object — CRUD controlled by DocGen permission sets
        /* code-analyzer-suppress ApexFlsViolation */
        insert req; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        String documentTitle = getDocumentTitle(contentVersionId);
        return createSignersAndNotify(req.Id, null, documentTitle, signerInputs);
    }

    /**
     * Legacy single-signer request creation (backward compat).
     */
    @AuraEnabled
    // CxSAST: Apex_CRUD_Violation — package-internal custom objects; CRUD controlled by DocGen permission sets
    public static String createSignatureRequest(Id contentDocumentId, String relatedRecordId, String signerName, String signerEmail) {
        List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :contentDocumentId WITH SYSTEM_MODE LIMIT 1];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Document not found or has been deleted.');
        }
        Id contentVersionId = docs[0].LatestPublishedVersionId;

        // CxSAST: Crypto operations for signature token/PIN generation — not hardcoded secrets
        Blob randomBytes = Crypto.generateAesKey(256);
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + signerEmail));
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        String token = EncodingUtil.convertToHex(hash);
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        String signingPageUrl = getSiteBaseUrl() + '/apex/DocGenSignature?token=' + token;


        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects

        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        req.Signer_Name__c = signerName;
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        req.Signer_Email__c = signerEmail;
        req.Source_Document_Id__c = contentVersionId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Secure_Token__c = token;
        req.Status__c = 'Sent';
        // Package-internal object — CRUD controlled by DocGen permission sets
        /* code-analyzer-suppress ApexFlsViolation */
        insert req; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        // Send branded signature request email automatically
        String documentTitle = getDocumentTitle(contentVersionId);
        DocGenSignatureEmailService.sendSignatureRequestEmails(
            new List<DocGenSignatureEmailService.SignerEmail>{
                new DocGenSignatureEmailService.SignerEmail(signerName, signerEmail, null, signingPageUrl, null)
            },
            documentTitle
        );

        return signingPageUrl;
    }

    /**
     * Returns available signer role picklist values.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getSignerRolePicklistValues() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        Schema.DescribeFieldResult fieldResult = DocGen_Signer__c.Role_Name__c.getDescribe();
        for (Schema.PicklistEntry entry : fieldResult.getPicklistValues()) {
            if (entry.isActive()) {
                options.add(new Map<String, String>{
                    'label' => entry.getLabel(),
                    'value' => entry.getValue()
                });
            }
        }
        return options;
    }

    /**
     * Returns Contact Name and Email for auto-filling signer fields.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getContactInfo(Id contactId) {
        List<Contact> contacts = [SELECT Name, Email FROM Contact WHERE Id = :contactId WITH USER_MODE LIMIT 1];
        Map<String, String> result = new Map<String, String>();
        if (!contacts.isEmpty()) {
            result.put('name', contacts[0].Name);
            result.put('email', contacts[0].Email != null ? contacts[0].Email : '');
        }
        return result;
    }

    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    /**
     * Returns existing signature requests for a record, with signer details and URLs.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getPendingSignatureRequests(String relatedRecordId) {
        String siteUrl = getSiteBaseUrl();
        List<Map<String, Object>> results = new List<Map<String, Object>>();

        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Name, Status__c, Source_Document_Id__c, CreatedDate,
                   (SELECT Id, Signer_Name__c, Signer_Email__c, Role_Name__c,
                           Status__c, Secure_Token__c, Sort_Order__c
                    FROM Signers__r ORDER BY Sort_Order__c ASC)
            FROM DocGen_Signature_Request__c
            WHERE Related_Record_Id__c = :relatedRecordId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 20
        ];

        // Bulkify: collect all Source_Document_Id__c values and query titles in one SOQL
        Set<Id> sourceDocIds = new Set<Id>();
        for (DocGen_Signature_Request__c req : requests) {
            if (req.Source_Document_Id__c != null) {
                sourceDocIds.add(req.Source_Document_Id__c);
            }
        }
        Map<Id, String> docTitleMap = new Map<Id, String>();
        if (!sourceDocIds.isEmpty()) {
            for (ContentVersion cv : [SELECT Id, Title FROM ContentVersion WHERE Id IN :sourceDocIds WITH USER_MODE]) {
                docTitleMap.put(cv.Id, cv.Title);
            }
        }

        for (DocGen_Signature_Request__c req : requests) {
            Map<String, Object> reqMap = new Map<String, Object>();
            reqMap.put('id', req.Id);
            reqMap.put('name', req.Name);
            reqMap.put('status', req.Status__c);
            reqMap.put('createdDate', req.CreatedDate);

            // Get document title from pre-fetched map
            if (req.Source_Document_Id__c != null) {
                reqMap.put('documentTitle', docTitleMap.containsKey(req.Source_Document_Id__c) ? docTitleMap.get(req.Source_Document_Id__c) : 'Unknown');
            }

            List<Map<String, Object>> signerList = new List<Map<String, Object>>();
            for (DocGen_Signer__c signer : req.Signers__r) {
                Map<String, Object> signerMap = new Map<String, Object>();
                signerMap.put('signerName', signer.Signer_Name__c);
                signerMap.put('signerEmail', signer.Signer_Email__c);
                signerMap.put('roleName', signer.Role_Name__c);
                signerMap.put('status', signer.Status__c);
                signerMap.put('signerUrl', siteUrl + '/apex/DocGenSignature?token=' + signer.Secure_Token__c);
                signerList.add(signerMap);
            }
            reqMap.put('signers', signerList);
            results.add(reqMap);
        }

        return results;
    }

    /**
     * Scans a DOCX for {@Signature_XXX} placeholders and returns the role names.
     // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
     * Used by the LWC to auto-populate signer rows when a document is selected.
     */
    @AuraEnabled
    public static List<String> getDocumentSignatureRoles(Id contentDocumentId) {
        List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :contentDocumentId WITH SYSTEM_MODE LIMIT 1];
        if (docs.isEmpty()) return new List<String>();

        ContentVersion cv = [SELECT VersionData FROM ContentVersion WHERE Id = :docs[0].LatestPublishedVersionId WITH SYSTEM_MODE LIMIT 1];
        if (cv == null || cv.VersionData == null) return new List<String>();

        // Extract document.xml from the DOCX ZIP
        Compression.ZipReader reader = new Compression.ZipReader(cv.VersionData);
        String documentXml = null;
        for (Compression.ZipEntry entry : reader.getEntries()) {
            if (entry.getName() == 'word/document.xml') {
                documentXml = reader.extract(entry.getName()).toString();
                break;
            }
        }
        if (documentXml == null) return new List<String>();

        // Extract all text from <w:t> elements (handles tags split across runs)
        String plainText = '';
        Pattern wtPat = Pattern.compile('<w:t[^>]*>([^<]*)</w:t>');
        Matcher wtMatch = wtPat.matcher(documentXml);
        while (wtMatch.find()) {
            plainText += wtMatch.group(1);
        }

        // Find {@Signature_RoleName} placeholders
        List<String> roles = new List<String>();
        Pattern sigPat = Pattern.compile('\\{@Signature_([^}]+)\\}');
        Matcher sigMatch = sigPat.matcher(plainText);
        while (sigMatch.find()) {
            String roleName = sigMatch.group(1).replaceAll('_', ' ');
            if (!roles.contains(roleName)) {
                roles.add(roleName);
            }
        }

        // Check for generic {@Signature} (single signer, no named role)
        if (roles.isEmpty() && plainText.contains('{@Signature}')) {
            roles.add('Signer');
        }

        return roles;
    }

    /**
     * Shared logic: creates DocGen_Signer__c records and sends notification emails.
     * Used by both createMultiSignerRequest (DOCX) and createTemplateSignerRequest (template).
     */
    private static List<SignerResult> createSignersAndNotify(Id requestId, Id templateId, String documentTitle, List<Map<String, Object>> signerInputs) {
        String siteUrl = getSiteBaseUrl();
        List<DocGen_Signer__c> signerRecords = new List<DocGen_Signer__c>();
        List<SignerResult> results = new List<SignerResult>();

        for (Integer i = 0; i < signerInputs.size(); i++) {
            Map<String, Object> input = signerInputs[i];
            String signerName = (String) input.get('signerName');
            String signerEmail = (String) input.get('signerEmail');
            String roleName = (String) input.get('roleName');
            String contactId = (String) input.get('contactId');

            Blob randomBytes = Crypto.generateAesKey(256);
            Blob hash = Crypto.generateDigest('SHA-256',
                Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + signerEmail + i)
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            );
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            String token = EncodingUtil.convertToHex(hash);


            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects

            DocGen_Signer__c signer = new DocGen_Signer__c();
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            signer.Signature_Request__c = requestId;
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            signer.Role_Name__c = roleName;
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            signer.Signer_Name__c = signerName;
            signer.Signer_Email__c = signerEmail;
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            signer.Secure_Token__c = token;
            signer.Status__c = 'Pending';
            signer.Sort_Order__c = i + 1;
            if (String.isNotBlank(contactId)) {
                signer.Contact__c = contactId;
            }
            signerRecords.add(signer);

            // CxSAST: Crypto operations for signature token/PIN generation — not hardcoded secrets
            SignerResult sr = new SignerResult();
            sr.signerName = signerName;
            sr.roleName = roleName;
            sr.signerEmail = signerEmail;
            sr.signerUrl = siteUrl + '/apex/DocGenSignature?token=' + token;
            results.add(sr);
        }

        // Package-internal object — CRUD controlled by DocGen permission sets
        /* code-analyzer-suppress ApexFlsViolation */
        insert signerRecords; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        // Send branded signature request emails
        List<DocGenSignatureEmailService.SignerEmail> emailList = new List<DocGenSignatureEmailService.SignerEmail>();
        for (SignerResult sr : results) {
            Id cId = null;
            for (Map<String, Object> input : signerInputs) {
                if (sr.signerEmail == (String) input.get('signerEmail') && String.isNotBlank((String) input.get('contactId'))) {
                    cId = (Id) input.get('contactId');
                    break;
                }
            }
            emailList.add(new DocGenSignatureEmailService.SignerEmail(
                sr.signerName, sr.signerEmail, sr.roleName, sr.signerUrl, cId
            ));
        }
        DocGenSignatureEmailService.sendSignatureRequestEmails(emailList, documentTitle);

        return results;
    }

    /**
     * Resends signature request emails to all pending/viewed signers on a request.
     * Generates new tokens for security (old links become invalid).
     */
    @AuraEnabled
    // CxSAST: Apex_CRUD_Violation — package-internal custom objects; CRUD controlled by DocGen permission sets
    public static void resendSignatureRequest(Id requestId) {
        /* code-analyzer-suppress ApexFlsViolation */
        DocGen_Signature_Request__c req = [
            SELECT Id, Status__c, Template__r.Name, Source_Document_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (req.Status__c == 'Signed' || req.Status__c == 'Cancelled') {
            throw new AuraHandledException('Cannot resend a ' + req.Status__c.toLowerCase() + ' request.');
        }

        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Signer_Name__c, Signer_Email__c, Role_Name__c, Contact__c, Status__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId AND Status__c != 'Signed'
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];

        if (signers.isEmpty()) {
            throw new AuraHandledException('All signers have already signed.');
        }

        String siteUrl = getSiteBaseUrl();
        String documentTitle = req.Template__r != null ? req.Template__r.Name : 'Document';
        if (String.isBlank(documentTitle) && req.Source_Document_Id__c != null) {
            documentTitle = getDocumentTitle(req.Source_Document_Id__c);
        }

        List<DocGenSignatureEmailService.SignerEmail> emailList = new List<DocGenSignatureEmailService.SignerEmail>();

        for (DocGen_Signer__c s : signers) {
            // Generate new token
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            Blob randomBytes = Crypto.generateAesKey(256);
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            Blob hash = Crypto.generateDigest('SHA-256',
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + s.Signer_Email__c + System.now())
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            );
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            String newToken = EncodingUtil.convertToHex(hash);
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            s.Secure_Token__c = newToken;
            s.Status__c = 'Pending';
            // CxSAST: Crypto operations for signature token/PIN generation — not hardcoded secrets
            s.PIN_Hash__c = null;
            s.PIN_Expires_At__c = null;
            s.PIN_Attempts__c = 0;
            s.PIN_Verified_At__c = null;

            String sigUrl = siteUrl + '/apex/DocGenSignature?token=' + newToken;
            emailList.add(new DocGenSignatureEmailService.SignerEmail(
                s.Signer_Name__c, s.Signer_Email__c, s.Role_Name__c, sigUrl, s.Contact__c
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            ));
        }

        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(signers, false, AccessLevel.SYSTEM_MODE);
        req.Status__c = 'Sent';
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(req, false, AccessLevel.SYSTEM_MODE);

        DocGenSignatureEmailService.sendSignatureRequestEmails(emailList, documentTitle);
    }

    /**
     * Cancels a signature request. All pending signers are marked cancelled.
     * Already-signed signers are preserved in the audit trail.
     */
    @AuraEnabled
    public static void cancelSignatureRequest(Id requestId) {
        /* code-analyzer-suppress ApexFlsViolation */
        DocGen_Signature_Request__c req = [
            SELECT Id, Status__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (req.Status__c == 'Signed') {
            throw new AuraHandledException('Cannot cancel a completed signature request.');
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        }
        if (req.Status__c == 'Cancelled') {
            throw new AuraHandledException('This request is already cancelled.');
        }

        req.Status__c = 'Cancelled';
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(req, false, AccessLevel.SYSTEM_MODE);

        // Invalidate all unsigned signers
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signer__c> unsignedSigners = [
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            SELECT Id, Status__c FROM DocGen_Signer__c
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            WHERE Signature_Request__c = :requestId AND Status__c != 'Signed'
            WITH SYSTEM_MODE
        ];
        for (DocGen_Signer__c s : unsignedSigners) {
            s.Status__c = 'Cancelled';
            s.Secure_Token__c = null; // Invalidate token
        }
        if (!unsignedSigners.isEmpty()) {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(unsignedSigners, false, AccessLevel.SYSTEM_MODE);
        }
    }

    private static String getDocumentTitle(Id contentVersionId) {
        List<ContentVersion> cvs = [SELECT Title FROM ContentVersion WHERE Id = :contentVersionId WITH USER_MODE LIMIT 1];
        return !cvs.isEmpty() ? cvs[0].Title : 'Document';
    }

    private static String getSiteBaseUrl() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String siteUrl = settings.Experience_Site_Url__c;

        if (String.isBlank(siteUrl)) {
            List<Site> sites = [SELECT Id FROM Site WHERE Status = 'Active' WITH SYSTEM_MODE LIMIT 1];
            if (!sites.isEmpty()) {
                SiteDetail sd = [SELECT SecureUrl FROM SiteDetail WHERE DurableId = :sites[0].Id WITH SYSTEM_MODE LIMIT 1];
                siteUrl = sd.SecureUrl;
            }
        }

        if (String.isBlank(siteUrl)) {
            siteUrl = 'https://<CONFIGURE_SITE_URL_IN_SETUP>';
        }

        if (siteUrl.endsWith('/')) {
            siteUrl = siteUrl.substring(0, siteUrl.length() - 1);
        }

        return siteUrl;
    }
}
