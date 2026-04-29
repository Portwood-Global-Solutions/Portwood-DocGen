public with sharing class DocGenSignatureSenderController {
    public class SignerResult {
        @AuraEnabled
        public String signerName;
        @AuraEnabled
        public String roleName;
        @AuraEnabled
        public String signerUrl;
        @AuraEnabled
        public String signerEmail;
        @AuraEnabled
        public Id signerId; // 1.49 — LWC uses this for in-person PIN bypass
    }

    /**
     * Returns all active DocGen templates for the signature sender template picker.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getDocGenTemplates() {
        return getDocGenTemplatesForRecord(null);
    }

    /**
     * Returns templates filtered by audience (Required_Permission_Sets__c) and optionally
     * by per-record visibility (Specific_Record_Ids__c). Pass relatedRecordId to enable
     * per-record filtering; pass null to apply only the audience filter.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getDocGenTemplatesForRecord(String relatedRecordId) {
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> all = [
            SELECT
                Id,
                Name,
                Category__c,
                Sort_Order__c,
                Specific_Record_Ids__c,
                Required_Permission_Sets__c,
                Record_Filter__c,
                Base_Object_API__c
            FROM DocGen_Template__c
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC NULLS LAST, Name ASC
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        return DocGenController.filterTemplatesForSender(all, relatedRecordId);
    }

    /**
     * Data class for a parsed signature placement from template tags.
     */
    public class PlacementInfo implements Comparable {
        @AuraEnabled
        public String role;
        @AuraEnabled
        public Integer sequence;
        @AuraEnabled
        public String placementType; // Full, Initials, Date, DatePick
        @AuraEnabled
        public String tagText; // Original tag for reference

        public PlacementInfo(String role, Integer sequence, String placementType, String tagText) {
            this.role = role;
            this.sequence = sequence;
            this.placementType = placementType;
            this.tagText = tagText;
        }

        public Integer compareTo(Object other) {
            PlacementInfo o = (PlacementInfo) other;
            return this.sequence - o.sequence;
        }
    }

    /**
     * Scans a DocGen template's pre-decomposed XML for {@Signature_XXX} placeholders.
     * Returns deduplicated role names (backward-compatible).
     */
    @AuraEnabled
    public static List<String> getTemplateSignatureRoles(Id templateId) {
        List<PlacementInfo> placements = getTemplateSignaturePlacements(templateId);
        List<String> roles = new List<String>();
        for (PlacementInfo p : placements) {
            if (!roles.contains(p.role)) {
                roles.add(p.role);
            }
        }
        return roles;
    }

    /**
     * Scans a DocGen template for all v3 signature placements.
     * Supports both v2 ({@Signature_Role}) and v3 ({@Signature_Role:Order:Type}) syntax.
     * Returns ordered list of PlacementInfo with role, sequence, type, and original tag.
     */
    @AuraEnabled
    public static List<PlacementInfo> getTemplateSignaturePlacements(Id templateId) {
        String plainText = extractTemplatePlainText(templateId);
        if (plainText == null)
            return new List<PlacementInfo>();
        return parseSignaturePlacements(plainText);
    }

    /**
     * Extracts concatenated plain text from a template's pre-decomposed document.xml.
     * Reads from stored XML ContentVersions — no ZIP decompression needed.
     */
    private static String extractTemplatePlainText(Id templateId) {
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (activeVersions.isEmpty())
            return null;

        String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> xmlCvs = [
            SELECT Title, VersionData
            FROM ContentVersion
            WHERE Title LIKE :(xmlPrefix + '%')
            WITH SYSTEM_MODE
        ];

        String documentXml = null;
        for (ContentVersion cv : xmlCvs) {
            String key = cv.Title.substring(xmlPrefix.length());
            String originalPath = key.replace('__', '/');
            if (originalPath == 'word/document.xml') {
                documentXml = cv.VersionData.toString();
                break;
            }
        }
        if (documentXml == null)
            return null;

        // Extract text from <w:t> elements
        String plainText = '';
        Pattern wtPat = Pattern.compile('<w:t[^>]*>([^<]*)</w:t>');
        Matcher wtMatch = wtPat.matcher(documentXml);
        while (wtMatch.find()) {
            plainText += wtMatch.group(1);
        }
        return plainText;
    }

    /**
     * Parses signature placement tags from plain text.
     * v2: {@Signature_Role} → role="Role", sequence=1, type="Full"
     * v3: {@Signature_Role:Order:Type} → role="Role", sequence=Order, type=Type
     * Generic: {@Signature} → role="Signer", sequence=1, type="Full"
     */
    @TestVisible
    private static List<PlacementInfo> parseSignaturePlacements(String plainText) {
        List<PlacementInfo> placements = new List<PlacementInfo>();

        // v3 regex: captures role, optional :order, optional :type
        Pattern sigPat = Pattern.compile('\\{@Signature_([^:}]+)(?::(\\d+))?(?::([^}]+))?\\}');
        Matcher sigMatch = sigPat.matcher(plainText);
        while (sigMatch.find()) {
            String roleName = sigMatch.group(1).replaceAll('_', ' ');
            Integer seq = sigMatch.group(2) != null ? Integer.valueOf(sigMatch.group(2)) : 1;
            String pType = sigMatch.group(3) != null ? sigMatch.group(3) : 'Full';

            // Normalize type
            if (pType != 'Full' && pType != 'Initials' && pType != 'Date' && pType != 'DatePick') {
                pType = 'Full';
            }

            placements.add(new PlacementInfo(roleName, seq, pType, sigMatch.group(0)));
        }

        // Fallback: generic {@Signature} tag (no role)
        if (placements.isEmpty() && plainText.contains('{@Signature}')) {
            placements.add(new PlacementInfo('Signer', 1, 'Full', '{@Signature}'));
        }

        // Sort by sequence order
        placements.sort();

        return placements;
    }

    /**
     * Replaces {@Signature_*} tags in preview HTML with interactive styled spans.
     * Each span carries data attributes for the guided signing JS to find and manipulate.
     * Inline styles ensure the highlights render in both browser preview and Blob.toPdf() unsigned PDF.
     */
    /**
     * Browsers do NOT honor CSS @page background-image (paged-media spec only fires
     * during PDF rendering). For signature previews — both the sender modal and the
     * customer signing page — we inject a screen-only overlay so the watermark is
     * visible before signing. The overlay is suppressed via @media print so
     * Blob.toPdf() doesn't double-render it on top of the @page background.
     *
     * Two non-obvious constraints drove the implementation:
     *   1. The sender LWC injects preview HTML via innerHTML (no iframe), so a
     *      position:fixed overlay would escape the modal and cover the whole page.
     *      We wrap content in .docgen-preview-wrap (position:relative) and position
     *      the overlay absolutely inside it.
     *   2. The customer signing page runs as guest user; /sfc/ URLs don't resolve
     *      and the page's image proxy only rewrites <img src>, not CSS background-image.
     *      We embed the watermark as a base64 data URI so it loads in any context.
     */
    /**
     * without-sharing helper so guest signers (who have no sharing access to the watermark
     * CV or the template version field) can still resolve the watermark bytes. The outer
     * class is `with sharing` for AppExchange compliance — only this CV/version lookup
     * needs to bypass sharing, gated by the request token validation upstream.
     */
    private without sharing class WatermarkResolver {
        public Map<String, Object> resolve(Id templateId) {
            Map<String, Object> out = new Map<String, Object>();
            try {
                List<DocGen_Template_Version__c> vs = [
                    SELECT Watermark_Image_CV_Id__c
                    FROM DocGen_Template_Version__c
                    WHERE Template__c = :templateId AND Is_Active__c = TRUE
                    LIMIT 1
                ];
                if (vs.isEmpty() || String.isBlank(vs[0].Watermark_Image_CV_Id__c))
                    return null;
                Id wmCvId = vs[0].Watermark_Image_CV_Id__c;
                List<ContentVersion> cvs = [
                    SELECT VersionData, FileExtension
                    FROM ContentVersion
                    WHERE Id = :wmCvId
                    LIMIT 1
                ];
                if (cvs.isEmpty())
                    return null;
                out.put('data', cvs[0].VersionData);
                out.put('ext', String.isNotBlank(cvs[0].FileExtension) ? cvs[0].FileExtension.toLowerCase() : 'png');
                return out;
            } catch (Exception e) {
                return null;
            }
        }
    }

    @TestVisible
    public static String injectPreviewWatermarkOverlay(String html, Id templateId) {
        if (String.isBlank(html) || templateId == null)
            return html;

        Map<String, Object> wm = new WatermarkResolver().resolve(templateId);
        if (wm == null)
            return html;
        Blob wmData = (Blob) wm.get('data');
        String wmExt = (String) wm.get('ext');
        if (wmData == null)
            return html;

        String mime = (wmExt == 'jpg' || wmExt == 'jpeg') ? 'image/jpeg' : (wmExt == 'gif') ? 'image/gif' : 'image/png';
        String dataUri = 'data:' + mime + ';base64,' + EncodingUtil.base64Encode(wmData);

        // Render the watermark as a real <img> element with explicit max-height. Using a
        // CSS background-image inside an absolutely-positioned overlay collapses to the
        // wrap's content height — a one-line preview leaves the image rendered at ~50px,
        // effectively invisible. An <img> sizes from its intrinsic dimensions and respects
        // max-height, so it shows at a usable size regardless of how short the document is.
        String overlay =
            '<style>' +
            '@media screen {' +
            ' .docgen-preview-wrap { position: relative; min-height: 400px; }' +
            ' .docgen-preview-watermark { position: absolute; top: 0; left: 0; right: 0; ' +
            'text-align: center; opacity: 0.35; pointer-events: none; z-index: 0; }' +
            ' .docgen-preview-watermark img { width: 90% !important; max-width: 90% !important; ' +
            'height: auto !important; max-height: none !important; display: inline-block !important; }' +
            ' .docgen-preview-wrap > *:not(.docgen-preview-watermark) { position: relative; z-index: 1; }' +
            '}' +
            '@media print { .docgen-preview-watermark { display: none !important; } }' +
            '</style>';

        String overlayDiv =
            '<div class="docgen-preview-watermark" aria-hidden="true">' +
            '<img src="' +
            dataUri +
            '" alt=""/>' +
            '</div>';

        Integer bodyOpen = html.indexOf('<body');
        Integer bodyClose = html.lastIndexOf('</body>');
        if (bodyOpen >= 0 && bodyClose > bodyOpen) {
            Integer openEnd = html.indexOf('>', bodyOpen);
            if (openEnd > bodyOpen) {
                String prefix = html.substring(0, openEnd + 1);
                String middle = html.substring(openEnd + 1, bodyClose);
                String suffix = html.substring(bodyClose);
                return prefix + overlay + '<div class="docgen-preview-wrap">' + overlayDiv + middle + '</div>' + suffix;
            }
        }
        return overlay + '<div class="docgen-preview-wrap">' + overlayDiv + html + '</div>';
    }

    @TestVisible
    private static String injectPlacementSpans(String html) {
        if (String.isBlank(html))
            return html;

        // Match v3 tags: {@Signature_Role:Order:Type} and v2: {@Signature_Role}
        Pattern sigPat = Pattern.compile('\\{@Signature_([^:}]+)(?::(\\d+))?(?::([^}]+))?\\}');
        Matcher sigMatch = sigPat.matcher(html);

        // Track per-role occurrence count for unique span IDs
        Map<String, Integer> roleCounters = new Map<String, Integer>();
        String result = html;

        // Process matches in reverse order to preserve string positions
        List<Integer[]> matchPositions = new List<Integer[]>();
        List<String[]> matchData = new List<String[]>();

        // Reset matcher to scan all matches
        sigMatch.reset();
        while (sigMatch.find()) {
            matchPositions.add(new List<Integer>{ sigMatch.start(), sigMatch.end() });
            String role = sigMatch.group(1).replaceAll('_', ' ');
            String order = sigMatch.group(2) != null ? sigMatch.group(2) : '1';
            String pType = sigMatch.group(3) != null ? sigMatch.group(3) : 'Full';
            matchData.add(new List<String>{ role, order, pType, sigMatch.group(0) });
        }

        // Replace in reverse order so positions stay valid
        for (Integer i = matchPositions.size() - 1; i >= 0; i--) {
            Integer startPos = matchPositions[i][0];
            Integer endPos = matchPositions[i][1];
            String role = matchData[i][0];
            String order = matchData[i][1];
            String pType = matchData[i][2];
            String originalTag = matchData[i][3];

            String label;
            if (pType == 'Full')
                label = 'SIGN HERE';
            else if (pType == 'Initials')
                label = 'INITIAL HERE';
            else if (pType == 'Date' || pType == 'DatePick')
                label = 'DATE';
            else
                label = 'SIGN HERE';

            String span =
                '<span class="docgen-sig"' +
                ' data-role="' +
                role.escapeHtml4() +
                '"' +
                ' data-order="' +
                order +
                '"' +
                ' data-type="' +
                pType +
                '"' +
                ' data-tag="' +
                originalTag.escapeHtml4() +
                '"' +
                ' style="display:inline-block;background:#fff8c5;border:2px dashed #f59e0b;' +
                'padding:2px 10px;border-radius:4px;font-weight:bold;color:#92400e;font-size:0.85em;">' +
                label +
                ' — ' +
                role.escapeHtml4() +
                '</span>';

            result = result.substring(0, startPos) + span + result.substring(endPos);
        }

        // Also handle bare {@Signature} tag
        if (result.contains('{@Signature}')) {
            String span =
                '<span class="docgen-sig"' +
                ' data-role="Signer" data-order="1" data-type="Full" data-tag="{@Signature}"' +
                ' style="display:inline-block;background:#fff8c5;border:2px dashed #f59e0b;' +
                'padding:2px 10px;border-radius:4px;font-weight:bold;color:#92400e;font-size:0.85em;">' +
                'SIGN HERE — Signer</span>';
            result = result.replace('{@Signature}', span);
        }

        return result;
    }

    /**
     * Creates a template-based multi-signer signature request.
     * No pre-generated DOCX needed — PDF is merged from template at signing time.
     */
    @AuraEnabled
    // CxSAST: Apex_CRUD_Violation — package-internal custom objects; CRUD controlled by DocGen permission sets
    // CxSAST: Apex_CRUD_ContentDistribution — ContentDistribution created for signature preview images
    public static List<SignerResult> createTemplateSignerRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson
    ) {
        return createTemplateSignerRequestWithOrder(templateId, relatedRecordId, signersJson, 'Parallel');
    }

    @AuraEnabled
    // CxSAST: Apex_CRUD_Violation — package-internal custom objects; CRUD controlled by DocGen permission sets
    // CxSAST: Apex_CRUD_ContentDistribution — ContentDistribution created for signature preview images
    public static List<SignerResult> createTemplateSignerRequestWithOrder(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder
    ) {
        // Validate template exists
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT Id, Name
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
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
        req.Signing_Order__c = String.isNotBlank(signingOrder) ? signingOrder : 'Parallel';
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
                        System.debug(
                            LoggingLevel.WARN,
                            'DocGen: Could not create public link for ' + relId + ': ' + e.getMessage()
                        );
                    }
                }
            }

            // Render preview HTML using public URLs (small, no base64 bloat)
            String docXml = (String) mergeData.get('documentXml');
            DocGenService.applyWatermarkOverride(templateId);
            String previewHtml = DocGenHtmlRenderer.convertToHtml(docXml, previewImageMap);

            // Inject interactive placement spans for the guided signing UI.
            // Watermark overlay is NOT injected here — base64-embedded image would blow
            // past Signature_Data__c's LongTextArea limit. Overlay is added at read time
            // in DocGenSignatureController.fetchDocumentData instead.
            previewHtml = injectPlacementSpans(previewHtml);

            // 1.49 (#28): pre-extract compact style maps while we're in admin context.
            // The signed-PDF queueable runs as Automated Process which can't query the
            // pre-decomposed styles.xml ContentVersion regardless of sharing model — so we
            // cache just the attributes the renderer needs for async fallback.
            Map<String, String> tableBordersMap = DocGenHtmlRenderer.extractTableStyleBorderMap(
                DocGenHtmlRenderer.stylesXml
            );
            Map<String, Map<String, String>> textAttrsMap = DocGenHtmlRenderer.extractStyleTextAttributeMap(
                DocGenHtmlRenderer.stylesXml
            );

            // Store image map (for Queueable) + preview HTML (for guest VF page) + style maps (for async render)
            Map<String, Object> cachedData = new Map<String, Object>{
                'imageMap' => pdfImageMap,
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                'previewHtml' => previewHtml,
                'tableBordersMap' => tableBordersMap,
                'styleTextAttrsMap' => textAttrsMap
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

    /**
     * Creates a multi-template packet signature request.
     * All templates are merged, preview HTML is concatenated with page breaks,
     * and placements are created across documents with Document_Index__c.
     */
    @AuraEnabled
    // CxSAST: Apex_CRUD_Violation — package-internal custom objects; CRUD controlled by DocGen permission sets
    public static List<SignerResult> createPacketSignerRequest(
        String templateIdsJson,
        String relatedRecordId,
        String signersJson,
        String signingOrder
    ) {
        List<Object> rawTemplateIds = (List<Object>) JSON.deserializeUntyped(templateIdsJson);
        List<Id> templateIds = new List<Id>();
        for (Object t : rawTemplateIds)
            templateIds.add((Id) t);

        if (templateIds.isEmpty()) {
            throw new AuraHandledException('At least one template is required.');
        }

        // Single template — delegate to existing method
        if (templateIds.size() == 1) {
            return createTemplateSignerRequestWithOrder(templateIds[0], relatedRecordId, signersJson, signingOrder);
        }

        // Validate all templates exist
        /* code-analyzer-suppress ApexFlsViolation */
        Map<Id, DocGen_Template__c> templateMap = new Map<Id, DocGen_Template__c>(
            [SELECT Id, Name FROM DocGen_Template__c WHERE Id IN :templateIds WITH SYSTEM_MODE]
        ); // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
        for (Id tid : templateIds) {
            if (!templateMap.containsKey(tid)) {
                throw new AuraHandledException('Template not found: ' + tid);
            }
        }

        // Parse signers
        List<Object> rawInputs = (List<Object>) JSON.deserializeUntyped(signersJson);
        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Object item : rawInputs) {
            signerInputs.add((Map<String, Object>) item);
        }

        // Create parent request with multi-template reference
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Template__c = templateIds[0]; // Primary template for backward compat
        req.Template_Ids__c = JSON.serialize(templateIds);
        req.Related_Record_Id__c = relatedRecordId;
        req.Status__c = 'Sent';
        req.Signing_Order__c = String.isNotBlank(signingOrder) ? signingOrder : 'Parallel';
        /* code-analyzer-suppress ApexFlsViolation */
        insert req; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        // Pre-compute merged preview for all templates
        try {
            Map<String, String> combinedPdfImageMap = new Map<String, String>();
            List<String> previewHtmlParts = new List<String>();
            List<List<PlacementInfo>> allPlacements = new List<List<PlacementInfo>>();

            for (Integer docIdx = 0; docIdx < templateIds.size(); docIdx++) {
                Id tid = templateIds[docIdx];
                Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(tid, relatedRecordId);
                Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
                combinedPdfImageMap.putAll(pdfImageMap);

                // Build preview HTML for this document
                Map<String, String> previewImageMap = new Map<String, String>();
                for (String relId : pdfImageMap.keySet()) {
                    String url = pdfImageMap.get(relId);
                    if (url != null && url.contains('/version/download/')) {
                        String cvId = url.substringAfterLast('/');
                        try {
                            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                            ContentDistribution dist = new ContentDistribution();
                            dist.Name = 'sig_preview_' + relId;
                            dist.ContentVersionId = cvId;
                            dist.PreferencesAllowViewInBrowser = true;
                            dist.PreferencesLinkLatestVersion = false;
                            dist.PreferencesExpires = false;
                            insert dist; // NOPMD ApexCRUDViolation
                            dist = [SELECT ContentDownloadUrl FROM ContentDistribution WHERE Id = :dist.Id]; // NOPMD
                            previewImageMap.put(relId, dist.ContentDownloadUrl);
                        } catch (Exception e) {
                            System.debug(LoggingLevel.WARN, 'DocGen: Could not create public link for ' + relId);
                        }
                    }
                }

                String docXml = (String) mergeData.get('documentXml');
                DocGenService.applyWatermarkOverride(tid);
                String docHtml = DocGenHtmlRenderer.convertToHtml(docXml, previewImageMap);
                docHtml = injectPlacementSpans(docHtml);
                // Watermark overlay deferred to read time (cache size constraint).

                // Add document title header
                String docTitle = templateMap.get(tid).Name;
                String titleHtml =
                    '<div style="background:#f8fafc;border:1px solid #e5e5e5;border-radius:6px;padding:12px 16px;margin-bottom:16px;text-align:center;">' +
                    '<strong style="font-size:14px;color:#3e3e3c;">Document ' +
                    (docIdx + 1) +
                    ' of ' +
                    templateIds.size() +
                    ': ' +
                    docTitle.escapeHtml4() +
                    '</strong></div>';

                if (docIdx > 0) {
                    previewHtmlParts.add('<div style="page-break-before:always"></div>');
                }
                previewHtmlParts.add(titleHtml + docHtml);

                // Collect placements for this document
                allPlacements.add(getTemplateSignaturePlacements(tid));
            }

            // Store combined data
            Map<String, Object> cachedData = new Map<String, Object>{
                'imageMap' => combinedPdfImageMap,
                'previewHtml' => String.join(previewHtmlParts, '')
            };
            req.Signature_Data__c = JSON.serialize(cachedData);
            /* code-analyzer-suppress ApexFlsViolation */
            update req; // NOPMD ApexCRUDViolation

            // Create signers first
            String documentTitle = templateMap.get(templateIds[0]).Name;
            if (templateIds.size() > 1) {
                documentTitle += ' (+' + (templateIds.size() - 1) + ' more)';
            }
            List<SignerResult> results = createSignersAndNotifyWithoutPlacements(
                req.Id,
                templateIds[0],
                documentTitle,
                signerInputs
            );

            // Now create placements per document
            // Re-query signer records to get IDs
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Signer__c> signerRecords = [
                SELECT Id, Role_Name__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :req.Id
                WITH SYSTEM_MODE
                ORDER BY Sort_Order__c ASC
            ]; // NOPMD

            Map<String, DocGen_Signer__c> roleSignerMap = new Map<String, DocGen_Signer__c>();
            for (Integer i = 0; i < signerRecords.size(); i++) {
                String roleName = (String) signerInputs[i].get('roleName');
                if (String.isNotBlank(roleName)) {
                    roleSignerMap.put(roleName, signerRecords[i]);
                }
            }

            List<DocGen_Signature_Placement__c> placementRecords = new List<DocGen_Signature_Placement__c>();
            for (Integer docIdx = 0; docIdx < allPlacements.size(); docIdx++) {
                for (PlacementInfo p : allPlacements[docIdx]) {
                    DocGen_Signer__c signer = roleSignerMap.get(p.role);
                    if (signer == null)
                        continue;

                    DocGen_Signature_Placement__c plc = new DocGen_Signature_Placement__c();
                    plc.Signer__c = signer.Id;
                    plc.Signature_Request__c = req.Id;
                    plc.Document_Index__c = docIdx;
                    plc.Sequence_Order__c = p.sequence;
                    plc.Placement_Type__c = p.placementType;
                    plc.Status__c = 'Pending';
                    plc.Tag_Text__c = p.tagText;
                    placementRecords.add(plc);
                }
            }

            if (!placementRecords.isEmpty()) {
                /* code-analyzer-suppress ApexFlsViolation */
                insert placementRecords; // NOPMD
            }

            return results;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Packet request creation failed: ' + e.getMessage());
            throw new AuraHandledException('Failed to create packet request: ' + e.getMessage());
        }
    }

    /**
     * Creates signers and sends emails WITHOUT creating placements.
     * Used by packet flow which creates placements separately per document.
     */
    private static List<SignerResult> createSignersAndNotifyWithoutPlacements(
        Id requestId,
        Id templateId,
        String documentTitle,
        List<Map<String, Object>> signerInputs
    ) {
        // Temporarily null the templateId to skip placement creation in createSignersAndNotify
        return createSignersAndNotify(requestId, null, documentTitle, signerInputs, true);
    }

    @AuraEnabled
    public static List<ContentVersion> getRelatedDocuments(Id recordId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
            WITH USER_MODE
        ];
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : links)
            docIds.add(link.ContentDocumentId);

        return [
            SELECT Id, Title, FileExtension, ContentDocumentId
            FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND IsLatest = TRUE AND FileExtension = 'docx'
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
    public static List<SignerResult> createMultiSignerRequest(
        Id contentDocumentId,
        String relatedRecordId,
        String signersJson
    ) {
        // Resolve latest ContentVersionId
        List<ContentDocument> docs = [
            SELECT LatestPublishedVersionId
            FROM ContentDocument
            WHERE Id = :contentDocumentId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
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
    public static String createSignatureRequest(
        Id contentDocumentId,
        String relatedRecordId,
        String signerName,
        String signerEmail
    ) {
        List<ContentDocument> docs = [
            SELECT LatestPublishedVersionId
            FROM ContentDocument
            WHERE Id = :contentDocumentId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Document not found or has been deleted.');
        }
        Id contentVersionId = docs[0].LatestPublishedVersionId;

        // CxSAST: Crypto operations for signature token/PIN generation — not hardcoded secrets
        Blob randomBytes = Crypto.generateAesKey(256);
        Blob hash = Crypto.generateDigest(
            'SHA-256',
            Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + signerEmail)
        );
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        String token = EncodingUtil.convertToHex(hash);
        // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
        String signingPageUrl = getSiteBaseUrl() + getSigningPagePath() + '?token=' + token;

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
                options.add(new Map<String, String>{ 'label' => entry.getLabel(), 'value' => entry.getValue() });
            }
        }
        return options;
    }

    /**
     * Marks a signer's PIN as verified without requiring email PIN entry.
     * Admin-only — gated by the DocGen_Admin permission set assignment. Intended for
     * in-person signing: the admin has verified the signer's identity face-to-face,
     * so the email PIN step is redundant. Writes a signature audit record capturing
     * who bypassed, when, and the attestation string so compliance has a trail.
     *
     * @param signerId The DocGen_Signer__c record Id to mark verified
     * @return Signing URL (same URL that would arrive via email) ready to use immediately
     */
    @AuraEnabled
    public static String markSignerVerifiedInPerson(Id signerId) {
        // Permission check — only DocGen_Admin users can bypass PIN
        Boolean isAdmin = false;
        for (PermissionSetAssignment psa : [
            SELECT PermissionSet.Name
            FROM PermissionSetAssignment
            WHERE AssigneeId = :UserInfo.getUserId()
            WITH SYSTEM_MODE
        ]) {
            if (psa.PermissionSet.Name == 'DocGen_Admin') {
                isAdmin = true;
                break;
            }
        }
        if (!isAdmin) {
            throw new AuraHandledException('Only DocGen Admin users can mark signers as verified in person.');
        }

        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Signature_Request__c, Signer_Name__c, Signer_Email__c, Secure_Token__c, Status__c
            FROM DocGen_Signer__c
            WHERE Id = :signerId
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }
        DocGen_Signer__c signer = signers[0];
        if (signer.Status__c == 'Signed' || signer.Status__c == 'Cancelled' || signer.Status__c == 'Declined') {
            throw new AuraHandledException('Cannot verify a signer whose status is ' + signer.Status__c + '.');
        }

        signer.PIN_Verified_At__c = System.now();
        signer.Status__c = 'Viewed';
        /* code-analyzer-suppress ApexFlsViolation */
        update signer; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        // Audit record — capture the bypass for compliance
        try {
            DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c(
                Signature_Request__c = signer.Signature_Request__c,
                Signer__c = signer.Id,
                Signer_Name__c = signer.Signer_Name__c,
                Signer_Email__c = signer.Signer_Email__c,
                PIN_Verified_At__c = System.now(),
                IP_Address__c = 'in-person-bypass:' + UserInfo.getUserId(),
                User_Agent__c = 'PIN bypassed for in-person signing by ' +
                    UserInfo.getName() +
                    ' (' +
                    UserInfo.getUserEmail() +
                    ')',
                Consent_Captured__c = true
            );
            /* code-analyzer-suppress ApexFlsViolation */
            insert audit; // NOPMD ApexCRUDViolation - audit record for compliance trail
        } catch (Exception e) {
            // Audit failure shouldn't block the admin's bypass action — log and continue
            System.debug(LoggingLevel.WARN, 'DocGen: In-person audit write failed: ' + e.getMessage());
        }

        return getSiteBaseUrl() + getSigningPagePath() + '?token=' + signer.Secure_Token__c;
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
            SELECT
                Id,
                Name,
                Status__c,
                Source_Document_Id__c,
                CreatedDate,
                (
                    SELECT Id, Signer_Name__c, Signer_Email__c, Role_Name__c, Status__c, Secure_Token__c, Sort_Order__c
                    FROM Signers__r
                    ORDER BY Sort_Order__c ASC
                )
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
                reqMap.put(
                    'documentTitle',
                    docTitleMap.containsKey(req.Source_Document_Id__c)
                        ? docTitleMap.get(req.Source_Document_Id__c)
                        : 'Unknown'
                );
            }

            List<Map<String, Object>> signerList = new List<Map<String, Object>>();
            for (DocGen_Signer__c signer : req.Signers__r) {
                Map<String, Object> signerMap = new Map<String, Object>();
                signerMap.put('signerName', signer.Signer_Name__c);
                signerMap.put('signerEmail', signer.Signer_Email__c);
                signerMap.put('roleName', signer.Role_Name__c);
                signerMap.put('status', signer.Status__c);
                signerMap.put('signerUrl', siteUrl + getSigningPagePath() + '?token=' + signer.Secure_Token__c);
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
        List<ContentDocument> docs = [
            SELECT LatestPublishedVersionId
            FROM ContentDocument
            WHERE Id = :contentDocumentId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (docs.isEmpty())
            return new List<String>();

        ContentVersion cv = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :docs[0].LatestPublishedVersionId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (cv == null || cv.VersionData == null)
            return new List<String>();

        // Extract document.xml from the DOCX ZIP
        Compression.ZipReader reader = new Compression.ZipReader(cv.VersionData);
        String documentXml = null;
        for (Compression.ZipEntry entry : reader.getEntries()) {
            if (entry.getName() == 'word/document.xml') {
                documentXml = reader.extract(entry.getName()).toString();
                break;
            }
        }
        if (documentXml == null)
            return new List<String>();

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
    /**
     * Creates DocGen_Signature_Placement__c records for each signer based on template tags.
     * Maps v3 tags ({@Signature_Role:Order:Type}) to signer records by role name.
     */
    private static void createPlacementsForSigners(
        Id requestId,
        Id templateId,
        List<DocGen_Signer__c> signerRecords,
        List<Map<String, Object>> signerInputs
    ) {
        List<PlacementInfo> placements = getTemplateSignaturePlacements(templateId);
        if (placements.isEmpty())
            return;

        // Build role → signer record map
        Map<String, DocGen_Signer__c> roleSignerMap = new Map<String, DocGen_Signer__c>();
        for (Integer i = 0; i < signerRecords.size(); i++) {
            String roleName = (String) signerInputs[i].get('roleName');
            if (String.isNotBlank(roleName)) {
                roleSignerMap.put(roleName, signerRecords[i]);
            }
        }

        List<DocGen_Signature_Placement__c> placementRecords = new List<DocGen_Signature_Placement__c>();
        for (PlacementInfo p : placements) {
            DocGen_Signer__c signer = roleSignerMap.get(p.role);
            if (signer == null)
                continue; // No signer assigned for this role

            DocGen_Signature_Placement__c plc = new DocGen_Signature_Placement__c();
            // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
            plc.Signer__c = signer.Id;
            plc.Signature_Request__c = requestId;
            plc.Document_Index__c = 0;
            plc.Sequence_Order__c = p.sequence;
            plc.Placement_Type__c = p.placementType;
            plc.Status__c = 'Pending';
            plc.Tag_Text__c = p.tagText;
            placementRecords.add(plc);
        }

        if (!placementRecords.isEmpty()) {
            /* code-analyzer-suppress ApexFlsViolation */
            insert placementRecords; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
        }
    }

    private static List<SignerResult> createSignersAndNotify(
        Id requestId,
        Id templateId,
        String documentTitle,
        List<Map<String, Object>> signerInputs
    ) {
        return createSignersAndNotify(requestId, templateId, documentTitle, signerInputs, true);
    }

    private static List<SignerResult> createSignersAndNotify(
        Id requestId,
        Id templateId,
        String documentTitle,
        List<Map<String, Object>> signerInputs,
        Boolean sendEmails
    ) {
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
            Blob hash = Crypto.generateDigest(
                'SHA-256',
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
            sr.signerUrl = siteUrl + getSigningPagePath() + '?token=' + token;
            results.add(sr);
        }

        // Package-internal object — CRUD controlled by DocGen permission sets
        /* code-analyzer-suppress ApexFlsViolation */
        insert signerRecords; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

        // 1.49 — back-fill signer record Ids onto the SignerResult DTOs so the LWC
        // can use the "Mark Verified (In-Person)" action without a second SOQL.
        for (Integer i = 0; i < signerRecords.size() && i < results.size(); i++) {
            results[i].signerId = signerRecords[i].Id;
        }

        // Create signature placements from template tags (v3 tag support)
        if (templateId != null) {
            createPlacementsForSigners(requestId, templateId, signerRecords, signerInputs);
        }

        // Send branded signature request emails (unless caller opts out, e.g. Flow sending its own emails)
        if (sendEmails) {
            // Check signing order — Sequential sends only to first signer
            Boolean isSequential = false;
            try {
                /* code-analyzer-suppress ApexFlsViolation */
                DocGen_Signature_Request__c reqCheck = [
                    SELECT Signing_Order__c
                    FROM DocGen_Signature_Request__c
                    WHERE Id = :requestId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ]; // NOPMD
                isSequential = reqCheck.Signing_Order__c == 'Sequential';
            } catch (Exception e) {
                // Default to parallel
            }

            List<DocGenSignatureEmailService.SignerEmail> emailList = new List<DocGenSignatureEmailService.SignerEmail>();
            for (Integer i = 0; i < results.size(); i++) {
                // Sequential: only send to first signer (Sort_Order 1)
                if (isSequential && i > 0)
                    break;

                SignerResult sr = results[i];
                Id cId = null;
                for (Map<String, Object> input : signerInputs) {
                    if (
                        sr.signerEmail == (String) input.get('signerEmail') &&
                        String.isNotBlank((String) input.get('contactId'))
                    ) {
                        cId = (Id) input.get('contactId');
                        break;
                    }
                }
                emailList.add(
                    new DocGenSignatureEmailService.SignerEmail(
                        sr.signerName,
                        sr.signerEmail,
                        sr.roleName,
                        sr.signerUrl,
                        cId
                    )
                );
            }
            DocGenSignatureEmailService.sendSignatureRequestEmails(emailList, documentTitle, requestId);
        }

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
            WITH SYSTEM_MODE
            LIMIT 1
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
            Blob hash = Crypto.generateDigest(
                'SHA-256',
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

            String sigUrl = siteUrl + getSigningPagePath() + '?token=' + newToken;
            emailList.add(
                new DocGenSignatureEmailService.SignerEmail(
                    s.Signer_Name__c,
                    s.Signer_Email__c,
                    s.Role_Name__c,
                    sigUrl,
                    s.Contact__c
                    // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                )
            );
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
            WITH SYSTEM_MODE
            LIMIT 1
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
            SELECT Id, Status__c
            FROM DocGen_Signer__c
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
        List<ContentVersion> cvs = [
            SELECT Title
            FROM ContentVersion
            WHERE Id = :contentVersionId
            WITH USER_MODE
            LIMIT 1
        ];
        return !cvs.isEmpty() ? cvs[0].Title : 'Document';
    }

    /**
     * Generates a preview of the merged document HTML for the sender to review before sending.
     * Merges the template with record data, converts to HTML, and injects placement spans.
     * Does NOT create a signature request — purely a read-only preview.
     */
    @AuraEnabled
    public static String getDocumentPreviewHtml(Id templateId, String relatedRecordId) {
        try {
            Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(templateId, relatedRecordId);
            String docXml = (String) mergeData.get('documentXml');
            Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
            DocGenService.applyWatermarkOverride(templateId);
            String html = DocGenHtmlRenderer.convertToHtml(docXml, pdfImageMap);
            html = injectPlacementSpans(html);
            return injectPreviewWatermarkOverlay(html, templateId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Preview generation failed: ' + e.getMessage());
            return null;
        }
    }

    public static String getSigningPagePath() {
        // In managed packages, VF pages need the namespace prefix in subscriber orgs
        String ns = DocGenSignatureSenderController.class.getName().substringBefore('.');
        if (String.isNotBlank(ns) && ns != 'DocGenSignatureSenderController') {
            return '/apex/' + ns + '__DocGenSignature';
        }
        return '/apex/DocGenSignature';
    }

    public static String getSiteBaseUrl() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String siteUrl = settings.Experience_Site_Url__c;

        if (String.isBlank(siteUrl)) {
            List<Site> sites = [SELECT Id FROM Site WHERE Status = 'Active' WITH SYSTEM_MODE LIMIT 1];
            if (!sites.isEmpty()) {
                SiteDetail sd = [
                    SELECT SecureUrl
                    FROM SiteDetail
                    WHERE DurableId = :sites[0].Id
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
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
