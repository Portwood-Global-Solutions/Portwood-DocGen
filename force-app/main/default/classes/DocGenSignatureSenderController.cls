public with sharing class DocGenSignatureSenderController {

    public class SignerResult {
        @AuraEnabled public String signerName;
        @AuraEnabled public String roleName;
        @AuraEnabled public String signerUrl;
        @AuraEnabled public String signerEmail;
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
     * signersJson: [{roleName, contactId, signerName, signerEmail}, ...]
     */
    @AuraEnabled
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

        // Create parent request
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Source_Document_Id__c = contentVersionId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Status__c = 'Sent';
        SObjectAccessDecision reqDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<DocGen_Signature_Request__c>{ req });
        insert reqDecision.getRecords();
        req.Id = reqDecision.getRecords()[0].Id;

        // Create individual signer records
        String siteUrl = getSiteBaseUrl();
        List<DocGen_Signer__c> signerRecords = new List<DocGen_Signer__c>();
        List<SignerResult> results = new List<SignerResult>();

        for (Integer i = 0; i < signerInputs.size(); i++) {
            Map<String, Object> input = signerInputs[i];
            String signerName = (String) input.get('signerName');
            String signerEmail = (String) input.get('signerEmail');
            String roleName = (String) input.get('roleName');
            String contactId = (String) input.get('contactId');

            // Generate unique token per signer using cryptographic randomness
            Blob randomBytes = Crypto.generateAesKey(256);
            Blob hash = Crypto.generateDigest('SHA-256',
                Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + signerEmail + i)
            );
            String token = EncodingUtil.convertToHex(hash);

            DocGen_Signer__c signer = new DocGen_Signer__c();
            signer.Signature_Request__c = req.Id;
            signer.Role_Name__c = roleName;
            signer.Signer_Name__c = signerName;
            signer.Signer_Email__c = signerEmail;
            signer.Secure_Token__c = token;
            signer.Status__c = 'Pending';
            signer.Sort_Order__c = i + 1;
            if (String.isNotBlank(contactId)) {
                signer.Contact__c = contactId;
            }
            signerRecords.add(signer);

            SignerResult sr = new SignerResult();
            sr.signerName = signerName;
            sr.roleName = roleName;
            sr.signerEmail = signerEmail;
            sr.signerUrl = siteUrl + '/apex/DocGenSignature?token=' + token;
            results.add(sr);
        }

        SObjectAccessDecision signersDecision = Security.stripInaccessible(AccessType.CREATABLE, signerRecords);
        insert signersDecision.getRecords();

        // Send branded signature request emails automatically
        String documentTitle = getDocumentTitle(contentVersionId);
        List<DocGenSignatureEmailService.SignerEmail> emailList = new List<DocGenSignatureEmailService.SignerEmail>();
        for (SignerResult sr : results) {
            Id cId = null;
            // Find matching contactId from inputs
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
     * Legacy single-signer request creation (backward compat).
     */
    @AuraEnabled
    public static String createSignatureRequest(Id contentDocumentId, String relatedRecordId, String signerName, String signerEmail) {
        List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :contentDocumentId WITH SYSTEM_MODE LIMIT 1];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Document not found or has been deleted.');
        }
        Id contentVersionId = docs[0].LatestPublishedVersionId;

        Blob randomBytes = Crypto.generateAesKey(256);
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + signerEmail));
        String token = EncodingUtil.convertToHex(hash);
        String signatureUrl = getSiteBaseUrl() + '/apex/DocGenSignature?token=' + token;

        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Signer_Name__c = signerName;
        req.Signer_Email__c = signerEmail;
        req.Source_Document_Id__c = contentVersionId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Secure_Token__c = token;
        req.Status__c = 'Sent';
        SObjectAccessDecision reqDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<DocGen_Signature_Request__c>{ req });
        insert reqDecision.getRecords();

        // Send branded signature request email automatically
        String documentTitle = getDocumentTitle(contentVersionId);
        DocGenSignatureEmailService.sendSignatureRequestEmails(
            new List<DocGenSignatureEmailService.SignerEmail>{
                new DocGenSignatureEmailService.SignerEmail(signerName, signerEmail, null, signatureUrl, null)
            },
            documentTitle
        );

        return signatureUrl;
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
     * Returns all saved signature templates.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Signature_Template__c> getSignatureTemplates() {
        return [SELECT Id, Name, Description__c FROM DocGen_Signature_Template__c WITH SYSTEM_MODE ORDER BY Name ASC];
    }

    /**
     * Returns roles for a specific template.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Signature_Template_Role__c> getTemplateRoles(Id templateId) {
        return [
            SELECT Id, Role_Name__c, Sort_Order__c
            FROM DocGen_Signature_Template_Role__c
            WHERE Signature_Template__c = :templateId
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];
    }

    /**
     * Saves a set of roles as a reusable template.
     * rolesJson: [{roleName: "Husband"}, {roleName: "Wife"}, ...]
     */
    @AuraEnabled
    public static Id saveSignatureTemplate(String templateName, String rolesJson) {
        DocGen_Signature_Template__c tmpl = new DocGen_Signature_Template__c();
        tmpl.Name = templateName;
        SObjectAccessDecision tmplDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<DocGen_Signature_Template__c>{ tmpl });
        insert tmplDecision.getRecords();
        tmpl.Id = tmplDecision.getRecords()[0].Id;

        List<Object> roleInputs = (List<Object>) JSON.deserializeUntyped(rolesJson);
        List<DocGen_Signature_Template_Role__c> roles = new List<DocGen_Signature_Template_Role__c>();

        for (Integer i = 0; i < roleInputs.size(); i++) {
            Map<String, Object> input = (Map<String, Object>) roleInputs[i];
            DocGen_Signature_Template_Role__c role = new DocGen_Signature_Template_Role__c();
            role.Signature_Template__c = tmpl.Id;
            role.Role_Name__c = (String) input.get('roleName');
            role.Sort_Order__c = i + 1;
            roles.add(role);
        }

        SObjectAccessDecision rolesDecision = Security.stripInaccessible(AccessType.CREATABLE, roles);
        insert rolesDecision.getRecords();
        return tmpl.Id;
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

    /**
     * Returns existing signature requests for a record, with signer details and URLs.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getPendingSignatureRequests(String relatedRecordId) {
        String siteUrl = getSiteBaseUrl();
        List<Map<String, Object>> results = new List<Map<String, Object>>();

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
     * Scans a DOCX for {#Signature_XXX} placeholders and returns the role names.
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

        // Find {#Signature_RoleName} placeholders
        List<String> roles = new List<String>();
        Pattern sigPat = Pattern.compile('\\{#Signature_([^}]+)\\}');
        Matcher sigMatch = sigPat.matcher(plainText);
        while (sigMatch.find()) {
            String roleName = sigMatch.group(1).replaceAll('_', ' ');
            if (!roles.contains(roleName)) {
                roles.add(roleName);
            }
        }

        // Check for generic {#Signature} (single signer, no named role)
        if (roles.isEmpty() && plainText.contains('{#Signature}')) {
            roles.add('Signer');
        }

        return roles;
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
