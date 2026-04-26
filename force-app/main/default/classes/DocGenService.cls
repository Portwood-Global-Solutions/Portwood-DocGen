public with sharing class DocGenService {

    // Collector for images to inject after XML processing
    private static List<Map<String, Object>> pendingImages = new List<Map<String, Object>>();
    private static Integer imageCounter = 0;
    private static String currentTemplateType = 'Word'; // Set before processXml calls
    private static String currentOutputFormat = 'Native'; // Set before processXml — PDF skips blob loading for images

    /**
     * Sets the admin-uploaded watermark override on the renderer (if one exists
     * on the active version of the given template). When set, the renderer uses
     * this CV as the @page background-image, ignoring any Word-embedded VML
     * watermark in the headers. Call this before every convertToHtml().
     */
    public static void applyWatermarkOverride(Id templateId) {
        DocGenHtmlRenderer.overrideWatermarkCvId = null;
        if (templateId == null) { return; }
        try {
            List<DocGen_Template_Version__c> vs = [
                SELECT Watermark_Image_CV_Id__c FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId AND Is_Active__c = true
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (!vs.isEmpty() && String.isNotBlank(vs[0].Watermark_Image_CV_Id__c)) {
                DocGenHtmlRenderer.overrideWatermarkCvId = vs[0].Watermark_Image_CV_Id__c;
            }
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable
        }
    }

    // Per-transaction cache of record Id → ordered list of attached image CV IDs.
    // Populated by prefetchImagesForIds() before loops that contain {%Image:N} tags,
    // so in-loop image resolution is O(1) instead of one SOQL per iteration.
    @TestVisible
    private static Map<Id, List<String>> imageCvCache;

    // Thread-local storage for pre-loaded record data. When set, mergeTemplate
    // skips DocGenController.generateDocumentData() and uses this data instead. Cleared after each use.
    private static Map<String, Object> preloadedRecordDataOverride;

    // Static cache for pre-decomposed XML parts — same template, queried once, reused across batch
    private static Id cachedPreDecompTemplateId;
    private static Map<String, String> cachedXmlParts; // key (e.g. 'rels', 'word__document.xml') → raw XML
    private static Boolean cachedPreDecompAvailable;

    // Captured HTML from the last renderPdf() call. Used by bulk batch merge mode
    // to accumulate HTML without re-merging the template. Cleared after reading.
    public static String lastRenderedHtml;

    /**
     * without-sharing helper for loading package-internal pre-decomposed XML ContentVersions.
     * Required because the signature PDF queueable runs as Automated Process user, which
     * can't see ContentVersion records under `with sharing` — no ContentDocumentLink rows
     * associate it with the files. The CVs are internal package metadata (not user data),
     * so bypassing sharing is safe. Template access is still gated by DocGen_Admin/User
     * permsets at the upstream entry points. (#28)
     */
    private without sharing class PreDecompXmlLoader {
        public List<ContentVersion> loadByTitlePrefix(String titlePrefix) {
            String likePattern = titlePrefix + '%';
            return [
                SELECT Id, Title, VersionData FROM ContentVersion
                WHERE Title LIKE :likePattern
                WITH SYSTEM_MODE // NOPMD — package-internal pre-decomposed parts
            ];
        }
    }

    private static final Set<String> AGGREGATE_FUNCTIONS = new Set<String>{
        'SUM', 'COUNT', 'AVG', 'MIN', 'MAX'
    };

    // Heap-pressure routing: check every N loop iterations during sync merge; if
    // we're past HEAP_PRESSURE_RATIO of the limit, throw HeapPressureException so
    // the controller can signal the runner LWC to auto-fallback to the giant path.
    // 60% leaves ~2.4MB for the still-pending HTML conversion + Blob.toPdf()
    // (Flying Saucer DOM parse typically 2-3× the HTML string size).
    @TestVisible
    private static Integer HEAP_CHECK_EVERY_N_ITERS = 50;
    @TestVisible
    private static Decimal HEAP_PRESSURE_RATIO = 0.60;
    // @TestVisible hook — tests set this to force checkHeapPressure into the pressure branch
    @TestVisible
    private static Boolean forceHeapPressureForTest = false;

    private static final Set<String> NUMERIC_FORMATS = new Set<String>{
        'currency', 'percent', 'number'
    };

    // Currency ISO code → display symbol (top ~35 world currencies)
    private static final Map<String, String> CURRENCY_SYMBOLS = new Map<String, String>{
        'USD'=>'$', 'EUR'=>'\u20AC', 'GBP'=>'\u00A3', 'JPY'=>'\u00A5', 'CNY'=>'\u00A5',
        'CHF'=>'CHF ', 'CAD'=>'C$', 'AUD'=>'A$', 'INR'=>'\u20B9', 'KRW'=>'\u20A9',
        'BRL'=>'R$', 'MXN'=>'MX$', 'SEK'=>'kr ', 'NOK'=>'kr ', 'DKK'=>'kr ',
        'PLN'=>'z\u0142', 'CZK'=>'K\u010D', 'HUF'=>'Ft ', 'TRY'=>'\u20BA', 'ZAR'=>'R ',
        'SGD'=>'S$', 'HKD'=>'HK$', 'NZD'=>'NZ$', 'THB'=>'\u0E3F', 'MYR'=>'RM ',
        'PHP'=>'\u20B1', 'IDR'=>'Rp ', 'TWD'=>'NT$', 'ILS'=>'\u20AA', 'RUB'=>'\u20BD',
        'NGN'=>'\u20A6', 'KES'=>'KSh ', 'AED'=>'AED ', 'SAR'=>'SAR ',
        'COP'=>'COL$', 'CLP'=>'CLP$', 'PEN'=>'S/', 'ARS'=>'ARS$',
        'EGP'=>'E\u00A3', 'GHS'=>'GH\u20B5'
    };

    // Currencies that use 0 decimal places
    private static final Set<String> ZERO_DECIMAL_CURRENCIES = new Set<String>{
        'JPY', 'KRW', 'CLP', 'VND', 'HUF', 'ISK', 'TWD'
    };

    /**
     * Creates an AuraHandledException with a user-facing message.
     * Centralizes exception creation for consistent error handling.
     */
    public static AuraHandledException ahe(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }

    /**
     * Creates an AuraHandledException that includes the original exception details
     * for debugging while showing a user-friendly message.
     */
    public static AuraHandledException ahe(Exception cause, String message) {
        String fullMessage = message + ' (' + cause.getMessage() + ')';
        AuraHandledException ex = new AuraHandledException(fullMessage);
        ex.setMessage(fullMessage);
        return ex;
    }

    /**
     * Creates an AuraHandledException from an existing exception, preserving its message.
     */
    public static AuraHandledException ahe(Exception cause) {
        AuraHandledException ex = new AuraHandledException(cause.getMessage());
        ex.setMessage(cause.getMessage());
        return ex;
    }

    /**
     * Public wrapper for processXml — used by e2e tests to validate tag processing.
     * @param xml The XML string containing merge tags
     * @param data The record data map to resolve tags against
     * @return The processed XML with tags replaced by data values
     */
    public static String processXmlForTest(String xml, Map<String, Object> data) {
        return processXml(xml, data);
    }

    /**
     * Intermediate merge result containing processed XML, images, and passthrough ZIP entries.
     */
    private class MergeResult { // NOPMD TooManyFields — data transfer object requires all fields
        String documentXml;                                   // Processed word/document.xml
        Map<String, String> processedXmlEntries;              // All processed XML entries (name → xml)
        Map<String, Blob> passthroughEntries;                 // Non-XML ZIP entries passed through as-is
        String contentTypesXml;                               // [Content_Types].xml
        String relsXml;                                       // word/_rels/document.xml.rels
        String relsPath;                                      // Path to rels file
        String mediaPath;                                     // Path prefix for media files
        Map<String, String> imageBase64ByRelId;               // relId → base64 image data (for DOCX and fallback)
        Map<String, String> imageUrlByRelId;                  // relId → absolute URL (for PDF rendering via Blob.toPdf)
        String templateType;
        String outputFormat;
        String docTitle;

        MergeResult() {
            processedXmlEntries = new Map<String, String>();
            passthroughEntries = new Map<String, Blob>();
            imageBase64ByRelId = new Map<String, String>();
            imageUrlByRelId = new Map<String, String>();
        }
    }

    /**
     * Core merge logic: processes template tags in DOCX/PPTX XML and collects results.
     * Returns structured intermediate data without assembling into a final format.
     */
    private static MergeResult mergeTemplate(Id templateId, Id recordId) {
        return mergeTemplate(templateId, recordId, null, null);
    }

    private static MergeResult mergeTemplate(Id templateId, Id recordId, Map<String, String> resolvedImages) {
        return mergeTemplate(templateId, recordId, resolvedImages, null);
    }

    private static MergeResult mergeTemplate(Id templateId, Id recordId, Map<String, String> resolvedImages, String outputFormatOverride) {
        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        Map<String, Object> dataMap;
        try {
            if (preloadedRecordDataOverride != null) {
                // Use pre-cached data from bulk batch — skips per-record SOQL
                dataMap = DocGenController.generateDocumentDataFromCache(templateId, preloadedRecordDataOverride);
                preloadedRecordDataOverride = null; // Clear after use
            } else {
                dataMap = DocGenController.generateDocumentData(templateId, recordId);
            }
        } catch (Exception e) {
            throw new DocGenException('Error retrieving template data: ' + e.getMessage());
        }

        // Apply LWC-resolved images: replace Salesforce URLs with data URIs in record data.
        // This enables DOCX image embedding without server-side HTTP callouts.
        if (resolvedImages != null && !resolvedImages.isEmpty()) {
            applyResolvedImages(dataMap.get('data'), resolvedImages);
        }

        String base64File = (String) dataMap.get('templateFile');
        Object dataObj = dataMap.get('data');
        String outputFormat = (String) dataMap.get('outputFormat');
        String templateType = (String) dataMap.get('templateType');

        // Allow callers to force PDF output format
        if (outputFormatOverride != null) {
            outputFormat = outputFormatOverride;
        }

        if (base64File == null) {
            throw new DocGenException('Template file content is missing.');
        }

        Map<String, Object> recordDataMap;
        if (dataObj instanceof Map<String, Object>) {
            recordDataMap = (Map<String, Object>) dataObj;
        } else if (dataObj instanceof SObject) {
            recordDataMap = ((SObject)dataObj).getPopulatedFieldsAsMap();
        } else {
            throw new DocGenException('Invalid data format.');
        }

        MergeResult mr = new MergeResult();
        mr.templateType = templateType;
        mr.outputFormat = outputFormat;

        // HTML template type (v1.61+): no ZIP, no DOCX XML — raw HTML body with
        // merge-tag substitution + header/footer fields wrapped via @page CSS
        // running elements. Output is always PDF via Blob.toPdf().
        if (templateType == 'HTML') {
            currentTemplateType = 'HTML';
            currentOutputFormat = 'PDF';
            return mergeHtmlTemplate(
                mr,
                base64File,
                recordDataMap,
                (String) dataMap.get('headerHtml'),
                (String) dataMap.get('footerHtml'),
                (String) dataMap.get('titleFormat')
            );
        }

        // Determine rels path based on template type
        if (templateType == 'PowerPoint') {
            mr.relsPath = 'ppt/_rels/presentation.xml.rels';
            mr.mediaPath = 'ppt/media/';
        } else if (templateType == 'Excel') {
            mr.relsPath = 'xl/_rels/workbook.xml.rels';
            mr.mediaPath = 'xl/media/';
        } else {
            mr.relsPath = 'word/_rels/document.xml.rels';
            mr.mediaPath = 'word/media/';
        }

        // For PDF output, try the heap-efficient path: use pre-decomposed XML parts
        // saved as ContentVersions during template version save, skipping full ZIP decompression.
        // Saves ~1.5-2MB heap by avoiding base64 decode + ZIP reader + passthrough extraction.
        if (outputFormat == 'PDF' && templateType == 'Word') {
            currentOutputFormat = 'PDF';
            MergeResult pdfResult = tryMergeFromPreDecomposed(templateId, recordDataMap, mr);
            if (pdfResult != null) {
                mr = pdfResult;
                mr.docTitle = generateDocTitle((String) dataMap.get('titleFormat'), recordDataMap);
                if (mr.docTitle == null) {
                    mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
                }
                return mr;
            }
        }

        // Full ZIP decompression path — used for DOCX/PPTX/XLSX output or when pre-decomposed parts are unavailable
        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);

        // Excel two-pass: worksheets collected here, processed after shared strings are read
        Map<String, String> pendingExcelSheets = new Map<String, String>();
        String excelSharedStringsXml = null;

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            Boolean isTargetXml = false;
            if (templateType == 'Word') {
                isTargetXml = name == 'word/document.xml' ||
                              (name.startsWith('word/header') && name.endsWith('.xml')) ||
                              (name.startsWith('word/footer') && name.endsWith('.xml'));
            } else if (templateType == 'PowerPoint') {
                isTargetXml = name.startsWith('ppt/slides/slide') && name.endsWith('.xml');
            } else if (templateType == 'Excel') {
                isTargetXml = (name.startsWith('xl/worksheets/sheet') && name.endsWith('.xml')) ||
                              name == 'xl/sharedStrings.xml';
            }

            // Excel: collect worksheets for second pass (shared strings must be read first)
            if (templateType == 'Excel' && isTargetXml && name != 'xl/sharedStrings.xml') {
                pendingExcelSheets.put(name, reader.extract(name).toString());
                continue;
            }

            if (isTargetXml) {
                Blob content = reader.extract(name);
                String xml = content.toString();
                currentTemplateType = templateType;

                // Excel: capture shared strings table (not merged, just stored)
                if (templateType == 'Excel' && name == 'xl/sharedStrings.xml') {
                    excelSharedStringsXml = xml;
                    mr.passthroughEntries.put(name, content); // keep original in ZIP
                    continue;
                }

                if (templateType == 'Word') {
                    xml = mergeRunsInTags(xml);
                }
                xml = processXml(xml, recordDataMap);
                mr.processedXmlEntries.put(name, xml);
                if (name == 'word/document.xml') {
                    mr.documentXml = xml;
                }
            } else if (name == '[Content_Types].xml') {
                mr.contentTypesXml = reader.extract(name).toString();
            } else if (name == mr.relsPath) {
                mr.relsXml = reader.extract(name).toString();
            } else {
                mr.passthroughEntries.put(name, reader.extract(name));
            }
        }

        // Excel second pass: inline shared strings into worksheets, then merge tags
        if (templateType == 'Excel' && !pendingExcelSheets.isEmpty()) {
            currentTemplateType = 'Excel';
            List<String> sharedStrings = parseSharedStrings(excelSharedStringsXml);
            for (String sheetName : pendingExcelSheets.keySet()) {
                String xml = pendingExcelSheets.get(sheetName);
                xml = inlineSharedStrings(xml, sharedStrings);
                xml = processXml(xml, recordDataMap);
                mr.processedXmlEntries.put(sheetName, xml);
            }
            // Remove sharedStrings.xml from passthrough — cells are now inline
            mr.passthroughEntries.remove('xl/sharedStrings.xml');
        }

        // Collect existing template images into imageBase64ByRelId for HTML rendering.
        // Parse rels XML to map relId → media filename, then look up in passthroughEntries.
        if (mr.relsXml != null) {
            Integer relCursor = 0;
            while (relCursor < mr.relsXml.length()) {
                Integer relStart = mr.relsXml.indexOf('<Relationship ', relCursor);
                if (relStart == -1) {
                    break;
                }
                Integer relSelfClose = mr.relsXml.indexOf('/>', relStart);
                Integer relClose = mr.relsXml.indexOf('>', relStart);
                if (relClose == -1) {
                    break;
                }
                Integer relEnd = (relSelfClose != -1 && relSelfClose < relClose) ? relSelfClose + 2 : relClose + 1;

                String relTag = mr.relsXml.substring(relStart, relEnd);
                String relType = extractXmlAttrValue(relTag, 'Type');
                if (relType != null && relType.contains('/image')) {
                    String relId = extractXmlAttrValue(relTag, 'Id');
                    String target = extractXmlAttrValue(relTag, 'Target');
                    if (relId != null && target != null && target.startsWith('media/')) {
                        String fullPath = mr.mediaPath + target.substringAfter('media/');
                        Blob imgBlob = mr.passthroughEntries.get(fullPath);
                        if (imgBlob != null && !mr.imageBase64ByRelId.containsKey(relId)) {
                            mr.imageBase64ByRelId.put(relId, EncodingUtil.base64Encode(imgBlob));
                        }
                    }
                }
                relCursor = relEnd;
            }
        }

        // Process pending images: update content types, rels, and collect base64 for HTML
        applyPendingImages(mr, true);

        // Generate document title
        mr.docTitle = generateDocTitle((String) dataMap.get('titleFormat'), recordDataMap);
        if (mr.docTitle == null) {
            mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
        }

        return mr;
    }

    /**
     * Recursively walks record data and replaces Salesforce image URLs with
     * base64 data URIs from the LWC-resolved image map. This enables DOCX
     * image embedding without server-side callouts.
     */
    private static void applyResolvedImages(Object data, Map<String, String> resolvedImages) {
        if (data instanceof Map<String, Object>) {
            Map<String, Object> mapData = (Map<String, Object>) data;
            for (String key : new List<String>(mapData.keySet())) {
                Object val = mapData.get(key);
                if (val instanceof String) {
                    String strVal = (String) val;
                    if (strVal.containsIgnoreCase('<img')) {
                        for (String originalUrl : resolvedImages.keySet()) {
                            if (strVal.contains(originalUrl)) {
                                strVal = strVal.replace(originalUrl, resolvedImages.get(originalUrl));
                            }
                            // Also handle &amp; encoded version
                            String encodedUrl = originalUrl.replace('&', '&amp;');
                            if (strVal.contains(encodedUrl)) {
                                strVal = strVal.replace(encodedUrl, resolvedImages.get(originalUrl));
                            }
                        }
                        mapData.put(key, strVal);
                    }
                } else {
                    applyResolvedImages(val, resolvedImages);
                }
            }
        } else if (data instanceof List<Object>) {
            for (Object item : (List<Object>) data) {
                applyResolvedImages(item, resolvedImages);
            }
        }
    }

    /**
     * Attempts to build a MergeResult from pre-decomposed XML parts stored as ContentVersions.
     * Skips full ZIP decompression — saves ~1.5-2MB heap for PDF generation.
     * Returns null if pre-decomposed parts are not available (older templates).
     */
    private static MergeResult tryMergeFromPreDecomposed(Id templateId, Map<String, Object> recordDataMap, MergeResult mr) {
        // Cache the template version + XML CV query — identical for every record
        if (cachedPreDecompTemplateId != templateId || cachedXmlParts == null) {
            cachedPreDecompTemplateId = templateId;
            cachedXmlParts = new Map<String, String>();
            cachedPreDecompAvailable = false;

            List<DocGen_Template_Version__c> activeVersions = [
                SELECT Id FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId AND Is_Active__c = true
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (activeVersions.isEmpty()) {
                return null;
            }

            String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
            // Use `without sharing` helper: in async contexts (Automated Process user from
            // platform-event-triggered queueable), `with sharing` + SYSTEM_MODE combined
            // still can't see these ContentVersions due to Salesforce's ContentVersion
            // sharing quirk — the user has no ContentDocumentLink rows. Bypass sharing
            // for this internal package-metadata read. (#28)
            List<ContentVersion> xmlCvs = new PreDecompXmlLoader().loadByTitlePrefix(xmlPrefix);

            if (xmlCvs.isEmpty()) {
                return null;
            }

            for (ContentVersion cv : xmlCvs) {
                String key = cv.Title.substring(xmlPrefix.length());
                cachedXmlParts.put(key, cv.VersionData.toString());
            }
            cachedPreDecompAvailable = true;
        }

        if (!cachedPreDecompAvailable || cachedXmlParts.isEmpty()) {
            return null;
        }

        // Process cached XML parts with this record's data
        for (String key : cachedXmlParts.keySet()) {
            String rawXml = cachedXmlParts.get(key);
            if (key == 'rels') {
                mr.relsXml = rawXml;
            } else if (key == 'word__styles.xml') {
                // Store styles.xml for table style resolution (not merged with record data)
                mr.processedXmlEntries.put('word/styles.xml', rawXml);
            } else if (key == 'word__numbering.xml') {
                // Store numbering.xml for numbered vs bullet list detection
                mr.passthroughEntries.put('word/numbering.xml', Blob.valueOf(rawXml));
            } else {
                // Restore original path: word__document.xml → word/document.xml
                String originalPath = key.replace('__', '/');
                currentTemplateType = mr.templateType;
                String xml = mergeRunsInTags(rawXml);
                xml = processXml(xml, recordDataMap);
                mr.processedXmlEntries.put(originalPath, xml);
                if (originalPath == 'word/document.xml') {
                    mr.documentXml = xml;
                }
                // Headers and footers are already in processedXmlEntries via the put() above
            }
        }

        if (mr.documentXml == null) {
            return null;
        }

        // Process pending images from merge field processing (RTF images, {%Field} images)
        applyPendingImages(mr, true);

        return mr;
    }

    /**
     * Applies pendingImages to the MergeResult:
     *  - Adds PNG/JPEG declarations to [Content_Types].xml (idempotent).
     *  - Adds a <Relationship> entry for each pending image in the rels XML.
     *  - If collectRenderMaps is true, also populates imageBase64ByRelId / imageUrlByRelId
     *    so the HTML renderer and PDF path can resolve each relId.
     *
     * Callers: mergeTemplate (full ZIP path, collectRenderMaps=true),
     *          tryMergeFromPreDecomposed (collectRenderMaps=true),
     *          generateDocumentPartsGiantQuery (collectRenderMaps=false — URL-only, client assembles).
     */
    private static void applyPendingImages(MergeResult mr, Boolean collectRenderMaps) {
        if (pendingImages.isEmpty()) return;

        if (mr.contentTypesXml != null) {
            if (!mr.contentTypesXml.contains('Extension="png"')) {
                mr.contentTypesXml = mr.contentTypesXml.replace('</Types>', '<Default Extension="png" ContentType="image/png"/></Types>');
            }
            if (!mr.contentTypesXml.contains('Extension="jpeg"') && !mr.contentTypesXml.contains('Extension="jpg"')) {
                mr.contentTypesXml = mr.contentTypesXml.replace('</Types>', '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>');
            }
        }

        if (mr.relsXml != null) {
            for (Map<String, Object> img : pendingImages) {
                String relId = (String) img.get('relId');
                String fName = (String) img.get('fileName');
                String newRel = '<Relationship Id="' + relId + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + fName + '"/>';
                mr.relsXml = mr.relsXml.replace('</Relationships>', newRel + '</Relationships>');
            }
        }

        if (collectRenderMaps) {
            for (Map<String, Object> img : pendingImages) {
                String relId = (String) img.get('relId');
                if (img.containsKey('blob')) {
                    Blob imgBlob = (Blob) img.get('blob');
                    mr.imageBase64ByRelId.put(relId, EncodingUtil.base64Encode(imgBlob));
                }
                if (img.containsKey('url')) {
                    mr.imageUrlByRelId.put(relId, (String) img.get('url'));
                    if (!img.containsKey('blob')) {
                        mr.imageBase64ByRelId.put(relId, (String) img.get('url'));
                    }
                }
            }
        }
    }

    /**
     * Assembles a MergeResult into a DOCX/PPTX ZIP Blob.
     */
    private static Blob assembleZip(MergeResult mr) {
        Compression.ZipWriter writer = new Compression.ZipWriter();

        // Add processed XML entries
        for (String name : mr.processedXmlEntries.keySet()) {
            writer.addEntry(name, Blob.valueOf(mr.processedXmlEntries.get(name)));
        }

        // Add passthrough entries
        for (String name : mr.passthroughEntries.keySet()) {
            writer.addEntry(name, mr.passthroughEntries.get(name));
        }

        // Add image blobs (skip URL-only images which are for PDF rendering only)
        for (Map<String, Object> img : pendingImages) {
            if (img.containsKey('blob')) {
                String fName = (String) img.get('fileName');
                Blob imageBlob = (Blob) img.get('blob');
                writer.addEntry(mr.mediaPath + fName, imageBlob);
            }
        }

        // Add content types and rels
        if (mr.contentTypesXml != null) {
            writer.addEntry('[Content_Types].xml', Blob.valueOf(mr.contentTypesXml));
        }
        if (mr.relsXml != null) {
            writer.addEntry(mr.relsPath, Blob.valueOf(mr.relsXml));
        }

        return writer.getArchive();
    }

    /**
     * Processes a template with record data and returns the result as a Map containing
     * the document Blob, title, output format, and template type. Does NOT save to record.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Map with keys: blob, title, outputFormat, templateType
     */
    public static Map<String, Object> processDocument(Id templateId, Id recordId) {
        return processDocument(templateId, recordId, null);
    }

    /**
     * Processes a template with optional pre-resolved images from the LWC.
     * The resolvedImages map contains originalUrl → base64DataUri entries
     * fetched by the browser (which has session access to Salesforce URLs).
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @param resolvedImages Map of originalUrl to base64DataUri for LWC-resolved images
     * @return Map with keys: blob, title, outputFormat, templateType
     */
    public static Map<String, Object> processDocument(Id templateId, Id recordId, Map<String, String> resolvedImages) {
        return processDocument(templateId, recordId, resolvedImages, null);
    }

    /**
     * Processes a template with optional pre-resolved images AND an optional output format override.
     * outputFormatOverride: 'PDF', 'Word', or 'PowerPoint'. Null = use template's Output_Format__c.
     * Throws DocGenException if the override is incompatible with the template type
     * (e.g. PowerPoint template + PDF override) or if the template has Lock_Output_Format__c = true.
     */
    public static Map<String, Object> processDocument(Id templateId, Id recordId, Map<String, String> resolvedImages, String outputFormatOverride) {
        validateOutputFormatOverride(templateId, outputFormatOverride);
        MergeResult mr = mergeTemplate(templateId, recordId, resolvedImages, outputFormatOverride);

        Blob resultBlob;
        if (mr.outputFormat == 'PDF' && (mr.templateType == 'Word' || mr.templateType == 'HTML')) {
            resultBlob = renderPdf(mr, templateId, recordId);
        } else {
            resultBlob = assembleZip(mr);
        }

        return new Map<String, Object>{
            'blob' => resultBlob,
            'title' => mr.docTitle,
            'outputFormat' => mr.outputFormat,
            'templateType' => mr.templateType
        };
    }

    /**
     * Validates that a runtime output-format override is allowed for a given template.
     * Rules:
     *   - If template has Lock_Output_Format__c = true, no override is permitted (must be null).
     *   - PowerPoint templates cannot render to PDF (Blob.toPdf only handles Word source).
     *   - Override values must be one of: 'PDF', 'Word', 'PowerPoint'.
     * Throws DocGenException on violation.
     */
    @TestVisible
    private static void validateOutputFormatOverride(Id templateId, String outputFormatOverride) {
        if (String.isBlank(outputFormatOverride)) return;
        if (outputFormatOverride != 'PDF' && outputFormatOverride != 'Word' && outputFormatOverride != 'PowerPoint' && outputFormatOverride != 'HTML') {
            throw new DocGenException('Invalid output format override: ' + outputFormatOverride + '. Expected PDF, Word, PowerPoint, or HTML.');
        }
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> tpls = [
            SELECT Lock_Output_Format__c, Type__c FROM DocGen_Template__c
            WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1
        ];
        if (tpls.isEmpty()) return; // mergeTemplate will throw a clearer "template not found" error
        DocGen_Template__c t = tpls[0];
        if (t.Lock_Output_Format__c == true) {
            throw new DocGenException('This template locks its output format. Override not permitted.');
        }
        if (t.Type__c == 'PowerPoint' && outputFormatOverride == 'PDF') {
            throw new DocGenException('PowerPoint templates cannot render to PDF.');
        }
    }

    /**
     * Returns merged document parts for client-side DOCX assembly.
     * No ZIP assembly on server — just the merged XML, updated rels/content types,
     * shell CV ID, and pending image CV IDs. The browser fetches the shell ZIP and
     * images by URL, then assembles the final DOCX client-side (zero heap for ZIP).
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Map with keys: allXmlParts, imageBase64Map, imageCvIdMap, title, templateType
     */
    public static Map<String, Object> generateDocumentParts(Id templateId, Id recordId) {
        // Use PDF output format to skip image blob loading during merge.
        // Images are collected as CV URLs only — we deduplicate and load once below.
        currentOutputFormat = 'PDF';
        MergeResult mr = mergeTemplate(templateId, recordId);
        currentOutputFormat = 'Native';

        // Collect ALL XML parts for the client to build the ZIP from scratch.
        // Merged entries (document.xml, headers, footers) come from processXml.
        // Passthrough entries (styles, numbering, theme, etc.) come from the template.
        // All are returned as path→string maps — the client assembles the ZIP.
        Map<String, String> allXmlParts = new Map<String, String>(mr.processedXmlEntries);
        if (mr.contentTypesXml != null) {
            allXmlParts.put('[Content_Types].xml', mr.contentTypesXml);
        }
        if (mr.relsXml != null) {
            allXmlParts.put(mr.relsPath, mr.relsXml);
        }
        // Add passthrough XML entries (styles.xml, numbering.xml, theme, etc.)
        for (String path : mr.passthroughEntries.keySet()) {
            Blob entryBlob = mr.passthroughEntries.get(path);
            if (!path.startsWith(mr.mediaPath)) {
                // Non-media passthrough = XML/text content
                allXmlParts.put(path, entryBlob.toString());
            }
        }

        // Build image map — return CV IDs for client to fetch one at a time.
        // Each client-side Apex call gets its own fresh heap, enabling unlimited images.
        // Template-embedded media from passthrough (small, already in heap)
        Map<String, String> imageBase64Map = new Map<String, String>();
        for (String path : mr.passthroughEntries.keySet()) {
            if (path.startsWith(mr.mediaPath)) {
                imageBase64Map.put(path, EncodingUtil.base64Encode(mr.passthroughEntries.get(path)));
            }
        }

        // Dynamic images: return mediaPath → CV ID mapping (not base64)
        // Client calls getContentVersionBase64() for each unique CV in separate transactions.
        // Server-fetched blobs (e.g., rta image callout for Lightning rich text inline
        // images, ContentReference / 0EM prefix) are inlined as base64 — bytes are
        // already in heap and we avoid a temp-CV + DML + cleanup round-trip.
        Map<String, String> imageCvIdMap = new Map<String, String>();
        Map<String, String> imageUrlMap = new Map<String, String>();
        for (Map<String, Object> img : pendingImages) {
            String fileName = (String) img.get('fileName');
            String mediaPath = 'word/media/' + fileName;
            if (img.containsKey('blob')) {
                imageBase64Map.put(mediaPath, EncodingUtil.base64Encode((Blob) img.get('blob')));
            } else if (img.containsKey('url')) {
                String url = (String) img.get('url');
                if (url.contains('/version/download/')) {
                    imageCvIdMap.put(mediaPath, url.substringAfterLast('/'));
                } else if (url.contains('/servlet/') || url.contains('/sfc/')) {
                    // Client checks each URL: rtaImage URLs (rich text inline images)
                    // route through PDF-extract; others are diagnostics-only.
                    imageUrlMap.put(mediaPath, url);
                }
            }
        }

        return new Map<String, Object>{
            'allXmlParts' => allXmlParts,
            'imageBase64Map' => imageBase64Map,
            'imageCvIdMap' => imageCvIdMap,
            'imageUrlMap' => imageUrlMap,
            'title' => mr.docTitle,
            'templateType' => mr.templateType
        };
    }

    /**
     * Generates document parts for Giant Query DOCX assembly. Merges the template
     * with a placeholder where the giant child loop belongs. The client injects
     * pre-rendered XML fragments from the harvest batch into this placeholder,
     * then assembles the DOCX ZIP.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID for parent-level merge tags
     * @param giantRelationshipName The child relationship processed by the harvest batch
     * @return Map containing allXmlParts (with placeholder), image maps, title, and placeholder token
     */
    public static Map<String, Object> generateDocumentPartsGiantQuery(Id templateId, Id recordId, String giantRelationshipName) {
        // Use PDF output format to skip image blob loading during merge
        currentOutputFormat = 'PDF';

        // Unique placeholder for the giant loop — client replaces with concatenated fragment XML
        String placeholder = '<!--DOCGEN_GIANT_LOOP_PLACEHOLDER-->';

        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        Map<String, Object> dataMap;
        try {
            dataMap = DocGenController.generateDocumentData(templateId, recordId);
        } catch (Exception e) {
            throw new DocGenException('Error retrieving template data: ' + e.getMessage());
        }

        String base64File = (String) dataMap.get('templateFile');
        Object dataObj = dataMap.get('data');
        String templateType = (String) dataMap.get('templateType');
        String titleFormat = (String) dataMap.get('titleFormat');

        if (base64File == null) {
            throw new DocGenException('Template file content is missing.');
        }

        Map<String, Object> recordDataMap;
        if (dataObj instanceof Map<String, Object>) {
            recordDataMap = (Map<String, Object>) dataObj;
        } else if (dataObj instanceof SObject) {
            recordDataMap = ((SObject) dataObj).getPopulatedFieldsAsMap();
        } else {
            throw new DocGenException('Invalid data format.');
        }

        currentTemplateType = templateType;

        MergeResult mr = new MergeResult();
        mr.templateType = templateType;
        mr.outputFormat = 'Native';
        mr.relsPath = 'word/_rels/document.xml.rels';
        mr.mediaPath = 'word/media/';

        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);
        String rawDocumentXml = null;

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            if (name == 'word/document.xml') {
                rawDocumentXml = reader.extract(name).toString();
            } else if (name == '[Content_Types].xml') {
                mr.contentTypesXml = reader.extract(name).toString();
            } else if (name == mr.relsPath) {
                mr.relsXml = reader.extract(name).toString();
            } else {
                Boolean isProcessedXml = (name.startsWith('word/header') && name.endsWith('.xml')) ||
                                         (name.startsWith('word/footer') && name.endsWith('.xml'));
                if (isProcessedXml) {
                    String xml = mergeRunsInTags(reader.extract(name).toString());
                    xml = processXml(xml, recordDataMap);
                    mr.processedXmlEntries.put(name, xml);
                } else {
                    mr.passthroughEntries.put(name, reader.extract(name));
                }
            }
        }

        if (rawDocumentXml == null) {
            throw new DocGenException('Template does not contain word/document.xml.');
        }

        // Merge runs first, then inject placeholder for the giant loop
        rawDocumentXml = mergeRunsInTags(rawDocumentXml);

        Map<String, String> loopParts = extractLoopBody(rawDocumentXml, giantRelationshipName);
        String giantLoopBodyXml = '';
        if (loopParts != null) {
            giantLoopBodyXml = loopParts.get('innerXml');
            rawDocumentXml = loopParts.get('beforeLoop') + placeholder + loopParts.get('afterLoop');
        }

        // Process remaining merge tags (parent-level fields, other loops)
        String processedXml = processXml(rawDocumentXml, recordDataMap);
        mr.documentXml = processedXml;
        mr.processedXmlEntries.put('word/document.xml', processedXml);

        mr.docTitle = generateDocTitle(titleFormat, recordDataMap);
        if (mr.docTitle == null) {
            mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
        }

        // Handle pending images (rels entries needed for DOCX; URL-only for client assembly)
        applyPendingImages(mr, false);

        // Build return maps (same as generateDocumentParts)
        Map<String, String> allXmlParts = new Map<String, String>(mr.processedXmlEntries);
        if (mr.contentTypesXml != null) {
            allXmlParts.put('[Content_Types].xml', mr.contentTypesXml);
        }
        if (mr.relsXml != null) {
            allXmlParts.put(mr.relsPath, mr.relsXml);
        }
        for (String path : mr.passthroughEntries.keySet()) {
            Blob entryBlob = mr.passthroughEntries.get(path);
            if (!path.startsWith(mr.mediaPath)) {
                allXmlParts.put(path, entryBlob.toString());
            }
        }

        Map<String, String> imageBase64Map = new Map<String, String>();
        for (String path : mr.passthroughEntries.keySet()) {
            if (path.startsWith(mr.mediaPath)) {
                imageBase64Map.put(path, EncodingUtil.base64Encode(mr.passthroughEntries.get(path)));
            }
        }

        Map<String, String> imageCvIdMap = new Map<String, String>();
        for (Map<String, Object> img : pendingImages) {
            String fileName = (String) img.get('fileName');
            String mediaPath = 'word/media/' + fileName;
            if (img.containsKey('url')) {
                String url = (String) img.get('url');
                if (url.contains('/version/download/')) {
                    imageCvIdMap.put(mediaPath, url.substringAfterLast('/'));
                }
            }
        }

        currentOutputFormat = 'Native';

        return new Map<String, Object>{
            'allXmlParts' => allXmlParts,
            'imageBase64Map' => imageBase64Map,
            'imageCvIdMap' => imageCvIdMap,
            'title' => mr.docTitle,
            'templateType' => mr.templateType,
            'placeholder' => placeholder,
            'giantLoopBodyXml' => giantLoopBodyXml
        };
    }

    /**
     * Generates a shell PDF for Giant Query: parent data merged, giant loop removed,
     * rendered to PDF via Blob.toPdf(). Also extracts table properties and header row
     * from the template so fragment PDFs can match the table styling.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The parent record ID for merge tag resolution
     * @param giantRelationshipName The child relationship being harvested
     * @param jobId The DocGen_Job__c record ID (for ContentVersion naming)
     * @return Map with shellCvId, tablePropertiesXml, headerRowXml
     */
    /**
     * Lightweight extraction of table properties, header row, and styles.xml from
     * the template for Giant Query PDF fragment rendering. No record data, no PDF
     * rendering — just reads pre-decomposed XML and extracts structural elements.
     * Shell PDF generation is deferred to a future enhancement.
     */
    public static Map<String, Object> extractGiantQueryFragmentConfig(Id templateId, String giantRelationshipName) {
        // Load only document.xml and styles.xml from pre-decomposed parts
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = true
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (activeVersions.isEmpty()) {
            throw new DocGenException('No active template version found.');
        }

        String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
        String docKey = xmlPrefix + 'word__document.xml';
        String stylesKey = xmlPrefix + 'word__styles.xml';

        String rawDocumentXml = null;
        String capturedStylesXml = null;

        List<ContentVersion> xmlCvs = [
            SELECT Title, VersionData FROM ContentVersion
            WHERE Title IN (:docKey, :stylesKey) WITH USER_MODE // NOPMD — internal pre-decomposed parts
        ];
        for (ContentVersion cv : xmlCvs) {
            if (cv.Title == docKey) {
                rawDocumentXml = cv.VersionData.toString();
            } else if (cv.Title == stylesKey) {
                capturedStylesXml = cv.VersionData.toString();
            }
        }
        xmlCvs = null;

        if (rawDocumentXml == null) {
            throw new DocGenException('Pre-decomposed template parts not found. Please re-save the template.');
        }

        // Extract <w:sectPr> for page dimensions before mergeRunsInTags modifies content
        String sectPrXml = '';
        Integer sectPrStart = rawDocumentXml.lastIndexOf('<w:sectPr');
        if (sectPrStart != -1) {
            Integer sectPrEnd = rawDocumentXml.indexOf('</w:sectPr>', sectPrStart);
            if (sectPrEnd != -1) {
                sectPrXml = rawDocumentXml.substring(sectPrStart, sectPrEnd + 11);
            }
        }

        rawDocumentXml = mergeRunsInTags(rawDocumentXml);

        Map<String, String> loopParts = extractLoopBody(rawDocumentXml, giantRelationshipName);
        rawDocumentXml = null;
        String tablePropertiesXml = '';
        String headerRowXml = '';

        if (loopParts != null) {
            String beforeLoop = loopParts.get('beforeLoop');

            // Extract <w:tblPr> for fragment table styling
            Integer tblPrStart = beforeLoop.lastIndexOf('<w:tblPr');
            if (tblPrStart != -1) {
                Integer tblPrEnd = beforeLoop.indexOf('</w:tblPr>', tblPrStart);
                if (tblPrEnd != -1) {
                    tablePropertiesXml = beforeLoop.substring(tblPrStart, tblPrEnd + 10);
                }
            }

            // Extract <w:tblGrid> for column widths
            Integer tblGridStart = beforeLoop.lastIndexOf('<w:tblGrid');
            if (tblGridStart != -1) {
                Integer tblGridEnd = beforeLoop.indexOf('</w:tblGrid>', tblGridStart);
                if (tblGridEnd != -1) {
                    tablePropertiesXml += beforeLoop.substring(tblGridStart, tblGridEnd + 12);
                }
            }

            // Extract last <w:tr> as header row (column labels)
            Integer lastTrStart = beforeLoop.lastIndexOf('<w:tr');
            if (lastTrStart != -1) {
                Integer trEnd = beforeLoop.indexOf('</w:tr>', lastTrStart);
                if (trEnd != -1) {
                    headerRowXml = beforeLoop.substring(lastTrStart, trEnd + 7);
                }
            }
        }

        // Extract per-column CSS from the loop row's formatting
        String columnCss = '';
        if (loopParts != null) {
            columnCss = DocGenGiantQueryBatch.extractColumnCss(loopParts.get('innerXml'));
        }

        return new Map<String, Object>{
            'tablePropertiesXml' => tablePropertiesXml,
            'headerRowXml' => headerRowXml,
            'stylesXml' => capturedStylesXml,
            'sectPrXml' => sectPrXml,
            'columnCss' => columnCss
        };
    }

    /**
     * Merges the full template with parent record data, removes the giant loop,
     * converts to HTML, and injects a placeholder where the table rows should go.
     * Called by DocGenGiantQueryAssembler (Queueable, 12MB heap) to produce
     * a complete HTML document with before/after content, headers, footers, images.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The parent record ID for merge tag resolution
     * @param giantRelationshipName The child relationship being harvested
     * @param placeholder String to inject where the giant loop table rows go
     * @return Complete HTML string with placeholder for table row injection
     */
    public static String mergeTemplateForGiantQueryPdf(Id templateId, Id recordId, String giantRelationshipName, String placeholder) {
        currentOutputFormat = 'PDF';
        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        // Get parent-only record data (strip all children from config)
        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        List<DocGen_Template__c> templates = [
            SELECT Base_Object_API__c, Query_Config__c, Type__c, Document_Title_Format__c
            FROM DocGen_Template__c WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1
        ];
        DocGen_Template__c template = templates[0];

        String shellConfig = template.Query_Config__c;
        if (shellConfig != null && shellConfig.trim().startsWith('{')) {
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(shellConfig.trim());
            List<Object> nodes = (List<Object>) configMap.get('nodes');
            if (nodes != null) {
                List<Object> rootOnly = new List<Object>();
                for (Object nodeObj : nodes) {
                    Map<String, Object> node = (Map<String, Object>) nodeObj;
                    if (node.get('parentNode') == null) { rootOnly.add(node); }
                }
                configMap.put('nodes', rootOnly);
                shellConfig = JSON.serialize(configMap);
            }
        } else if (shellConfig != null) {
            shellConfig = shellConfig.replaceAll('\\(\\s*SELECT\\s+[^)]+\\)', '');
            shellConfig = shellConfig.replaceAll(',\\s*,', ',').replaceAll(',\\s*$', '').trim();
        }

        Map<String, Object> recordDataMap = DocGenDataRetriever.getRecordData(
            recordId, template.Base_Object_API__c, shellConfig
        );
        shellConfig = null;

        currentTemplateType = template.Type__c;

        MergeResult mr = new MergeResult();
        mr.templateType = template.Type__c;
        mr.outputFormat = 'PDF';
        mr.relsPath = 'word/_rels/document.xml.rels';
        mr.mediaPath = 'word/media/';

        // Load pre-decomposed XML parts
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = true
            WITH SYSTEM_MODE LIMIT 1
        ];
        String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
        // SYSTEM_MODE is required: this runs in async contexts (signature PDF queueable
        // triggered by platform event → Automated Process user) that don't have FLS access
        // to the package-internal pre-decomposed XML ContentVersions. USER_MODE silently
        // returned empty in that context, which is why the signed PDF path lost table-style
        // borders for guest-triggered signatures (#28). Template access is already gated by
        // DocGen permission sets; reading the pre-decomposed artifacts in system mode is safe.
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> xmlCvs = [
            SELECT Title, VersionData FROM ContentVersion
            WHERE Title LIKE :(xmlPrefix + '%') WITH SYSTEM_MODE // NOPMD — package-internal pre-decomposed parts
        ];

        String rawDocumentXml = null;
        for (ContentVersion cv : xmlCvs) {
            String key = cv.Title.substring(xmlPrefix.length());
            String rawXml = cv.VersionData.toString();
            if (key == 'rels') {
                mr.relsXml = rawXml;
            } else if (key == 'word__styles.xml') {
                mr.processedXmlEntries.put('word/styles.xml', rawXml);
            } else if (key == 'word__document.xml') {
                rawDocumentXml = rawXml;
            } else {
                String originalPath = key.replace('__', '/');
                if (originalPath.startsWith('word/header') || originalPath.startsWith('word/footer')) {
                    rawXml = mergeRunsInTags(rawXml);
                    rawXml = processXml(rawXml, recordDataMap);
                    mr.processedXmlEntries.put(originalPath, rawXml);
                }
            }
        }
        xmlCvs = null;

        rawDocumentXml = mergeRunsInTags(rawDocumentXml);

        // Replace giant loop with placeholder wrapped in a DOCX paragraph so it
        // survives the XML→HTML conversion (XML comments get stripped by the renderer)
        Map<String, String> loopParts = extractLoopBody(rawDocumentXml, giantRelationshipName);
        if (loopParts != null) {
            String xmlPlaceholder = '<w:p><w:r><w:t>' + placeholder + '</w:t></w:r></w:p>';
            rawDocumentXml = loopParts.get('beforeLoop') + xmlPlaceholder + loopParts.get('afterLoop');
        }
        loopParts = null;

        String processedXml = processXml(rawDocumentXml, recordDataMap);
        rawDocumentXml = null;
        recordDataMap = null;
        mr.documentXml = processedXml;
        mr.processedXmlEntries.put('word/document.xml', processedXml);

        // Handle images
        for (Map<String, Object> img : pendingImages) {
            String relId = (String) img.get('relId');
            if (img.containsKey('url')) {
                mr.imageUrlByRelId.put(relId, (String) img.get('url'));
            }
        }

        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);
        if (mr.processedXmlEntries.containsKey('word/styles.xml')) {
            DocGenHtmlRenderer.stylesXml = mr.processedXmlEntries.get('word/styles.xml');
        }
        setNumberingXml(mr);
        applyWatermarkOverride(templateId);
        String html = DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(mr), pdfImages);
        mr = null;
        pdfImages = null;

        currentOutputFormat = 'Native';
        return html;
    }

    /**
     * Extracts images from a template DOCX/PPTX file and saves them as ContentVersion
     * records linked to the template version. These committed CVs provide stable URLs
     * for Blob.toPdf() which cannot render data URI images (Flying Saucer limitation).
     * Each version gets its own set of images — no duplicates or confusion.
     * @param templateId The DocGen_Template__c record ID
     * @param versionId The DocGen_Template_Version__c record ID to link images to
     */
    public static void extractAndSaveTemplateImages(Id templateId, Id versionId) {
        String fileContent = DocGenTemplateManager.getTemplateFileContent(templateId);
        if (fileContent == null) {
            return;
        }

        List<DocGen_Template__c> templates = [
            SELECT Type__c FROM DocGen_Template__c WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1
        ];
        if (templates.isEmpty()) {
            return;
        }
        String templateType = templates[0].Type__c;

        Blob templateBlob = EncodingUtil.base64Decode(fileContent);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);

        // Determine paths based on template type
        String relsPath;
        String mediaPath;
        if (templateType == 'PowerPoint') {
            relsPath = 'ppt/_rels/presentation.xml.rels';
            mediaPath = 'ppt/media/';
        } else {
            relsPath = 'word/_rels/document.xml.rels';
            mediaPath = 'word/media/';
        }

        String relsXml = null;
        Map<String, String> additionalRelsXmls = new Map<String, String>(); // partPrefix → rels XML
        Map<String, Blob> mediaEntries = new Map<String, Blob>();
        Map<String, String> xmlEntries = new Map<String, String>();

        // Extract all entries in one pass — ZipReader may not support multiple extractions
        Map<String, Blob> allEntries = new Map<String, Blob>();
        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            allEntries.put(name, reader.extract(name));
        }

        // Classify entries and build shell ZIP
        Compression.ZipWriter shellWriter = new Compression.ZipWriter();
        Set<String> documentXmlPaths = new Set<String>();

        for (String name : allEntries.keySet()) {
            Blob entryBlob = allEntries.get(name);
            Boolean isDocumentXml = false;

            if (name == relsPath) {
                relsXml = entryBlob.toString();
            } else if (templateType == 'Word' && name.startsWith('word/_rels/') &&
                       (name.contains('header') || name.contains('footer')) && name.endsWith('.rels')) {
                // Header/footer relationship files contain image references
                String partPrefix = name.substringAfterLast('/').substringBefore('.xml.rels');
                additionalRelsXmls.put(partPrefix, entryBlob.toString());
            } else if (name.startsWith(mediaPath)) {
                mediaEntries.put(name, entryBlob);
            }

            // Identify XML parts that get merged/replaced at generation time
            if (templateType == 'Word') {
                if (name == 'word/document.xml' ||
                    name == 'word/styles.xml' ||
                    name == 'word/numbering.xml' ||
                    (name.startsWith('word/header') && name.endsWith('.xml')) ||
                    (name.startsWith('word/footer') && name.endsWith('.xml'))) {
                    xmlEntries.put(name, entryBlob.toString());
                    if (name != 'word/styles.xml' && name != 'word/numbering.xml') {
                        isDocumentXml = true;
                        documentXmlPaths.add(name);
                    }
                }
            } else if (templateType == 'PowerPoint') {
                if (name.startsWith('ppt/slides/slide') && name.endsWith('.xml')) {
                    xmlEntries.put(name, entryBlob.toString());
                    isDocumentXml = true;
                    documentXmlPaths.add(name);
                }
            }

            // Shell gets everything EXCEPT document XML, rels, and [Content_Types].xml
            // (rels and content types may be modified during merge for new images)
            if (!isDocumentXml && name != relsPath && name != '[Content_Types].xml') {
                shellWriter.addEntry(name, entryBlob);
            }
        }

        List<ContentVersion> newCvs = new List<ContentVersion>();

        // Save pre-decomposed XML parts as ContentVersions for heap-efficient PDF generation.
        // At render time, these are queried directly instead of decompressing the full ZIP.
        String xmlPrefix = 'docgen_tmpl_xml_' + versionId + '_';
        for (String xmlName : xmlEntries.keySet()) {
            // Use a safe filename: word/document.xml → word__document.xml
            String safeKey = xmlName.replace('/', '__');
            ContentVersion xmlCv = new ContentVersion();
            xmlCv.Title = xmlPrefix + safeKey;
            xmlCv.PathOnClient = xmlPrefix + safeKey;
            xmlCv.VersionData = Blob.valueOf(xmlEntries.get(xmlName));
            xmlCv.FirstPublishLocationId = versionId;
            newCvs.add(xmlCv);
        }

        // Save rels XML for image relId mapping during PDF generation
        // Combine document rels with header/footer rels so all image relIds are resolvable
        String combinedRels = relsXml != null ? relsXml : '';
        for (String hfRels : additionalRelsXmls.values()) {
            combinedRels += hfRels;
        }
        if (String.isNotBlank(combinedRels)) {
            ContentVersion relsCv = new ContentVersion();
            relsCv.Title = xmlPrefix + 'rels';
            relsCv.PathOnClient = xmlPrefix + 'rels.xml';
            relsCv.VersionData = Blob.valueOf(combinedRels);
            relsCv.FirstPublishLocationId = versionId;
            newCvs.add(relsCv);
        }

        // Parse rels (document + header/footer) and save each image as a ContentVersion
        if (!mediaEntries.isEmpty()) {
            String imgPrefix = 'docgen_tmpl_img_' + versionId + '_';
            Set<String> savedKeys = new Set<String>();

            // Build list of (partPrefix, relsXml) pairs: document gets empty prefix
            List<List<String>> allRelsPairs = new List<List<String>>();
            if (relsXml != null) { allRelsPairs.add(new List<String>{'', relsXml}); }
            for (String partPrefix : additionalRelsXmls.keySet()) {
                allRelsPairs.add(new List<String>{partPrefix, additionalRelsXmls.get(partPrefix)});
            }

            for (List<String> pair : allRelsPairs) {
                String partPrefix = pair[0];
                String currentRels = pair[1];
                Integer relCursor = 0;
                while (relCursor < currentRels.length()) {
                    Integer relStart = currentRels.indexOf('<Relationship ', relCursor);
                    if (relStart == -1) {
                        break;
                    }
                    Integer relSelfClose = currentRels.indexOf('/>', relStart);
                    Integer relClose = currentRels.indexOf('>', relStart);
                    if (relClose == -1) {
                        break;
                    }
                    Integer relEnd = (relSelfClose != -1 && relSelfClose < relClose) ? relSelfClose + 2 : relClose + 1;

                    String relTag = currentRels.substring(relStart, relEnd);
                    String relType = extractXmlAttrValue(relTag, 'Type');
                    if (relType != null && relType.contains('/image')) {
                        String relId = extractXmlAttrValue(relTag, 'Id');
                        String target = extractXmlAttrValue(relTag, 'Target');
                        String saveKey = String.isNotBlank(partPrefix) ? partPrefix + '_' + relId : relId;
                        if (relId != null && target != null && target.startsWith('media/') && !savedKeys.contains(saveKey)) {
                            String fullPath = mediaPath + target.substringAfter('media/');
                            Blob imgBlob = mediaEntries.get(fullPath);
                            if (imgBlob != null) {
                                String ext = target.substringAfterLast('.');
                                ContentVersion cv = new ContentVersion();
                                cv.Title = imgPrefix + saveKey;
                                cv.PathOnClient = imgPrefix + saveKey + '.' + ext;
                                cv.VersionData = imgBlob;
                                cv.FirstPublishLocationId = versionId;
                                newCvs.add(cv);
                                savedKeys.add(saveKey);
                            }
                        }
                    }
                    relCursor = relEnd;
                }
            }
        }

        // Save shell ZIP — the template without document XML entries, rels, or content types.
        // Client-side DOCX assembly fetches this shell, adds the server-merged XML, and produces the final DOCX.
        Blob shellBlob = shellWriter.getArchive();
        ContentVersion shellCv = new ContentVersion();
        shellCv.Title = 'docgen_tmpl_shell_' + versionId;
        shellCv.PathOnClient = 'docgen_tmpl_shell_' + versionId + '.docx';
        shellCv.VersionData = shellBlob;
        shellCv.FirstPublishLocationId = versionId;
        newCvs.add(shellCv);

        // Insert image + XML CVs BEFORE building pre-baked HTML, so buildPdfImageMap
        // can find the image ContentVersions via SOQL.
        if (!newCvs.isEmpty()) {
            SObjectAccessDecision preDec = Security.stripInaccessible(AccessType.CREATABLE, newCvs);
            insert preDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
            newCvs.clear();
        }

        // Pre-bake HTML version of the template for Giant Query PDF.
        // Loop tags ({#Rel}...{/Rel}) are preserved as HTML comments so the
        // assembler can find and replace them with rendered data at generation time.
        // This avoids all DOCX XML parsing at generation time — just string replace + Blob.toPdf().
        if (templateType == 'Word' && xmlEntries.containsKey('word/document.xml')) {
            try {
                String docXml = xmlEntries.get('word/document.xml');
                MergeResult htmlMr = new MergeResult();
                htmlMr.templateType = 'Word';
                htmlMr.outputFormat = 'PDF';
                htmlMr.relsPath = relsPath;
                htmlMr.mediaPath = mediaPath;
                htmlMr.relsXml = relsXml;

                // Add styles, headers, footers to the MergeResult
                for (String xmlName : xmlEntries.keySet()) {
                    if (xmlName == 'word/styles.xml') {
                        htmlMr.processedXmlEntries.put(xmlName, xmlEntries.get(xmlName));
                    } else if (xmlName.startsWith('word/header') || xmlName.startsWith('word/footer')) {
                        htmlMr.processedXmlEntries.put(xmlName, xmlEntries.get(xmlName));
                    }
                }

                // Merge runs so tags are complete, but DON'T process merge fields —
                // leave {Field} tags intact for generation-time replacement
                docXml = mergeRunsInTags(docXml);
                htmlMr.documentXml = docXml;
                htmlMr.processedXmlEntries.put('word/document.xml', docXml);

                // Build image map — image CVs were inserted above so SOQL can find them
                Map<String, String> pdfImages = buildPdfImageMap(htmlMr, templateId);
                if (htmlMr.processedXmlEntries.containsKey('word/styles.xml')) {
                    DocGenHtmlRenderer.stylesXml = htmlMr.processedXmlEntries.get('word/styles.xml');
                }
                setNumberingXml(htmlMr);
                applyWatermarkOverride(templateId);

                String templateHtml = DocGenHtmlRenderer.convertToHtml(
                    combineXmlWithHeadersFooters(htmlMr), pdfImages
                );
                htmlMr = null;

                // Save pre-baked HTML as ContentVersion
                ContentVersion htmlCv = new ContentVersion();
                htmlCv.Title = 'docgen_tmpl_html_' + versionId;
                htmlCv.PathOnClient = 'docgen_tmpl_html_' + versionId + '.html';
                htmlCv.VersionData = Blob.valueOf(templateHtml);
                htmlCv.FirstPublishLocationId = versionId;
                newCvs.add(htmlCv);
            } catch (Exception htmlErr) {
                // Non-fatal — Giant Query will fall back to runtime conversion
                String noop = htmlErr.getMessage(); // NOPMD
            }
        }

        if (!newCvs.isEmpty()) {
            SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, newCvs);
            insert cvDecision.getRecords();
        }

    }

    /**
     * Builds a URL-based image map for PDF rendering via Blob.toPdf().
     * Looks up pre-committed template image ContentVersions (saved at version publish time)
     * and adds RTF/dynamic image URLs. Returns relId → absolute URL map.
     */
    private static Map<String, String> buildPdfImageMap(MergeResult mr, Id templateId) {
        Map<String, String> pdfImages = new Map<String, String>();

        // 1. Template-embedded images: committed CVs linked to active version
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = true
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (!activeVersions.isEmpty()) {
            String prefix = 'docgen_tmpl_img_' + activeVersions[0].Id + '_';
            List<ContentVersion> tmplCvs = [
                SELECT Id, Title FROM ContentVersion
                WHERE Title LIKE :(prefix + '%')
                WITH USER_MODE
            ];
            for (ContentVersion cv : tmplCvs) {
                String relId = cv.Title.substring(prefix.length());
                pdfImages.put(relId, '/sfc/servlet.shepherd/version/download/' + cv.Id);
            }
        }

        // 2. RTF/dynamic images: use relative Salesforce URLs for Blob.toPdf()
        for (String relId : mr.imageUrlByRelId.keySet()) {
            String url = mr.imageUrlByRelId.get(relId);
            // Strip domain if absolute — Blob.toPdf() only resolves relative paths
            if (url.startsWithIgnoreCase('http')) {
                Integer pathStart = url.indexOf('/sfc/');
                if (pathStart == -1) { pathStart = url.indexOf('/servlet/'); }
                if (pathStart != -1) {
                    url = url.substring(pathStart);
                }
            }
            pdfImages.put(relId, url);
        }

        return pdfImages;
    }

    /**
     * Generates a PDF Blob from a MergeResult using the unified image map.
     * Single entry point for all PDF rendering — used by generateDocument()
     * and generatePdfBlob().
     */
    private static Blob renderPdf(MergeResult mr, Id templateId, Id recordId) {
        if (Test.isRunningTest()) {
            lastRenderedHtml = (mr != null && mr.templateType == 'HTML' && String.isNotBlank(mr.documentXml))
                ? mr.documentXml
                : '<html><body><p>Test PDF</p></body></html>';
            return Blob.toPdf(lastRenderedHtml);
        }

        // HTML template type: documentXml is a ready-to-render HTML document —
        // skip the DOCX→HTML conversion entirely.
        if (mr.templateType == 'HTML') {
            lastRenderedHtml = mr.documentXml;
            return Blob.toPdf(mr.documentXml);
        }

        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);
        // Pass styles.xml to renderer for dynamic table style resolution
        if (mr.processedXmlEntries != null && mr.processedXmlEntries.containsKey('word/styles.xml')) {
            DocGenHtmlRenderer.stylesXml = mr.processedXmlEntries.get('word/styles.xml');
        }
        setNumberingXml(mr);
        applyWatermarkOverride(templateId);
        String html = DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(mr), pdfImages);
        lastRenderedHtml = html;

        // Blob.toPdf() with the Spring '26 Release Update resolves relative Salesforce
        // ContentVersion URLs (/sfc/servlet.shepherd/...) natively via the VF rendering engine.
        // Requires: Spring '26 Release Update "Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations"
        return Blob.toPdf(html);
    }

    /**
     * Generates HTML for browser preview with data URI images.
     * Uses the same merge + image pipeline as the PDF generator (forced PDF mode,
     * pre-decomposed XML, buildPdfImageMap), then converts relative CV URLs
     * to base64 data URIs so guest users can view them without a Salesforce session.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Complete HTML string with embedded base64 data URI images
     */
    public static String renderPreviewHtml(Id templateId, Id recordId) {
        // Same merge path as PDF generation — forced PDF mode
        MergeResult mr = mergeTemplate(templateId, recordId, null, 'PDF');

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Preview is only supported for Word and HTML templates.');
        }

        // HTML templates: documentXml is already the full rendered HTML
        if (mr.templateType == 'HTML') {
            return mr.documentXml;
        }

        // Build the same image map the PDF generator uses
        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);

        // Convert relative CV URLs to data URIs for browser rendering
        Map<String, String> previewImages = new Map<String, String>();
        for (String relId : pdfImages.keySet()) {
            String url = pdfImages.get(relId);
            // Extract CV Id from /sfc/servlet.shepherd/version/download/{cvId}
            if (url != null && url.contains('/version/download/')) {
                String cvId = url.substringAfterLast('/');
                try {
                    ContentVersion cv = [SELECT VersionData, FileExtension FROM ContentVersion WHERE Id = :cvId WITH USER_MODE LIMIT 1]; // NOPMD ApexCRUDViolation - ContentVersion read access required for PDF image preview; gated by template ownership
                    String ext = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : 'png';
                    String mime = (ext == 'jpg' || ext == 'jpeg') ? 'image/jpeg' : 'image/png';
                    previewImages.put(relId, 'data:' + mime + ';base64,' + EncodingUtil.base64Encode(cv.VersionData));
                } catch (Exception e) {
                    // Intentionally swallowed — unresolvable image, skip
                    String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                }
            } else if (url != null) {
                previewImages.put(relId, url);
            }
        }

        setNumberingXml(mr);
        applyWatermarkOverride(templateId);
        return DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(mr), previewImages);
    }

    /**
     * Generates a PDF Blob and title without saving to record.
     * Used by DocGenController for download mode.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Map with keys: blob (PDF Blob), title (String)
     */
    public static Map<String, Object> generatePdfBlob(Id templateId, Id recordId) {
        // Force PDF output format so we get the heap-efficient path
        // (pre-decomposed XML, relative image URLs, no blob loading)
        MergeResult mr = mergeTemplate(templateId, recordId, null, 'PDF');

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Server-side PDF generation is only supported for Word and HTML templates.');
        }

        Blob pdfBlob = renderPdf(mr, templateId, recordId);

        return new Map<String, Object>{
            'blob' => pdfBlob,
            'title' => mr.docTitle
        };
    }

    /**
     * Merges a template with record data and returns HTML using a custom image map.
     * Used by the batch PDF renderer to generate HTML with ContentVersion URLs
     * instead of data URIs, allowing Flying Saucer to render images in PDFs.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @param imageMap Map of relId to image URL for PDF rendering
     * @return Map with keys: html, title, outputFormat, templateType
     */
    public static Map<String, Object> processDocumentAsHtmlWithImageMap(Id templateId, Id recordId, Map<String, String> imageMap) {
        MergeResult mr = mergeTemplate(templateId, recordId);

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Server-side PDF generation is only supported for Word templates.');
        }

        // Merge the provided URL map with any URL-only entries from the merge result
        // (e.g., Rich Text field images that are accessed by URL, not base64)
        Map<String, String> mergedMap = new Map<String, String>(imageMap);
        for (String relId : mr.imageBase64ByRelId.keySet()) {
            if (!mergedMap.containsKey(relId)) {
                mergedMap.put(relId, mr.imageBase64ByRelId.get(relId));
            }
        }

        setNumberingXml(mr);
        applyWatermarkOverride(templateId);
        String html = DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(mr), mergedMap);

        return new Map<String, Object>{
            'html' => html,
            'title' => mr.docTitle,
            'outputFormat' => 'PDF',
            'templateType' => mr.templateType
        };
    }

    /**
     * Processes a template and saves the result as a ContentVersion attached to the record.
     * For PDF output, uses the unified renderPdf() path with pre-committed image URLs.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return ContentDocumentId of the saved file
     */
    public static Id generateDocument(Id templateId, Id recordId) {
        return generateDocument(templateId, recordId, null);
    }

    /**
     * Same as generateDocument(templateId, recordId) but honors a runtime output-format override.
     * outputFormatOverride: 'PDF', 'Word', or 'PowerPoint'. Null = use template's Output_Format__c.
     * Throws DocGenException if Lock_Output_Format__c is true on the template, or if PowerPoint→PDF.
     */
    public static Id generateDocument(Id templateId, Id recordId, String outputFormatOverride) {
        validateOutputFormatOverride(templateId, outputFormatOverride);
        MergeResult mr = mergeTemplate(templateId, recordId, null, outputFormatOverride);

        if (mr.outputFormat == 'PDF' && (mr.templateType == 'Word' || mr.templateType == 'HTML')) {
            Blob pdfBlob = renderPdf(mr, templateId, recordId);
            return savePdfFile(pdfBlob, mr.docTitle, recordId);
        }

        // Native DOCX/PPTX path
        Blob resultBlob = assembleZip(mr);
        return saveFile(resultBlob, mr.docTitle, recordId, mr.outputFormat, mr.templateType);
    }

    /**
     * Generates a document using pre-cached record data, bypassing data retrieval SOQL.
     * Sets the static override so mergeTemplate() uses cached data instead of querying.
     * Used by DocGenBatch when bulk data cache is available.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID (used for file attachment)
     * @param preloadedRecordData Pre-fetched record data map to use instead of querying
     * @return ContentDocumentId of the saved file
     */
    public static Id generateDocumentFromData(Id templateId, Id recordId, Map<String, Object> preloadedRecordData) {
        preloadedRecordDataOverride = preloadedRecordData;
        return generateDocument(templateId, recordId);
    }

    /**
     * Combines document XML with header/footer XML from processedXmlEntries.
     * Headers are prepended and footers are appended so the HTML renderer
     * processes all template content (not just the main body).
     * Image relIds in header/footer XML are namespaced to prevent collisions.
     */
    /**
     * Sets DocGenHtmlRenderer.numberingXml from the template's word/numbering.xml
     * passthrough entry, enabling accurate numbered vs bullet list detection.
     */
    private static void setNumberingXml(MergeResult mr) {
        DocGenHtmlRenderer.numberingXml = null;
        if (mr.passthroughEntries != null && mr.passthroughEntries.containsKey('word/numbering.xml')) {
            DocGenHtmlRenderer.numberingXml = mr.passthroughEntries.get('word/numbering.xml').toString();
        }
    }

    private static String combineXmlWithHeadersFooters(MergeResult mr) {
        if (mr.processedXmlEntries == null) { return mr.documentXml; }

        String headers = '';
        String footers = '';
        List<String> keys = new List<String>(mr.processedXmlEntries.keySet());
        keys.sort();
        for (String key : keys) {
            if (key == 'word/styles.xml') { continue; }
            if (key.startsWith('word/header') || key.startsWith('word/footer')) {
                String partPrefix = key.substringAfterLast('/').substringBefore('.xml');
                String partXml = namespaceImageRelIds(mr.processedXmlEntries.get(key), partPrefix);
                if (key.startsWith('word/header')) {
                    headers += partXml;
                } else {
                    footers += partXml;
                }
            }
        }

        // Inject header/footer markers that the HTML renderer can detect and position.
        // Wrap in special XML comments that convertToHtml will transform to CSS-positioned divs.
        String combinedXml = '';
        if (String.isNotBlank(headers)) {
            combinedXml += '<!-- DOCGEN_HEADER_START -->' + headers + '<!-- DOCGEN_HEADER_END -->';
        }
        combinedXml += mr.documentXml;
        if (String.isNotBlank(footers)) {
            combinedXml += '<!-- DOCGEN_FOOTER_START -->' + footers + '<!-- DOCGEN_FOOTER_END -->';
        }
        return combinedXml;
    }

    /**
     * Rewrites image relationship IDs in header/footer XML so they don't collide
     * with document or other part relIds. Handles two reference patterns:
     *   - DrawingML:  <a:blip r:embed="rIdX"/>           → r:embed="prefix_rIdX"
     *   - VML (used by Word watermarks): <v:imagedata r:id="rIdX"/> → r:id="prefix_rIdX"
     * The VML rewrite is scoped to <v:imagedata ...> elements only — rewriting every
     * r:id would also touch hyperlinks and other non-image relationships.
     */
    private static String namespaceImageRelIds(String xml, String partPrefix) {
        String result = namespaceAttrInXml(xml, 'r:embed="', null, partPrefix);
        result = namespaceAttrInXml(result, 'r:id="', '<v:imagedata', partPrefix);
        return result;
    }

    /**
     * Rewrites occurrences of attrMarker (e.g. 'r:embed="') by prepending partPrefix +'_'
     * to the attribute value. If scopeTag is non-null, only rewrites occurrences whose
     * nearest preceding '<' starts with scopeTag (e.g. only inside <v:imagedata ...>).
     */
    private static String namespaceAttrInXml(String xml, String attrMarker, String scopeTag, String partPrefix) {
        String result = xml;
        Integer cursor = 0;
        while (cursor < result.length()) {
            Integer markerStart = result.indexOf(attrMarker, cursor);
            if (markerStart == -1) { break; }
            Integer valStart = markerStart + attrMarker.length();
            Integer valEnd = result.indexOf('"', valStart);
            if (valEnd == -1) { break; }

            Boolean inScope = true;
            if (scopeTag != null) {
                Integer tagOpen = result.lastIndexOf('<', markerStart);
                inScope = (tagOpen != -1 && result.substring(tagOpen).startsWith(scopeTag));
            }

            if (inScope) {
                String relId = result.substring(valStart, valEnd);
                String newRelId = partPrefix + '_' + relId;
                result = result.substring(0, valStart) + newRelId + result.substring(valEnd);
                cursor = valStart + newRelId.length() + 1;
            } else {
                cursor = valEnd + 1;
            }
        }
        return result;
    }

    /**
     * Generates the HTML for a single record without calling Blob.toPdf() or saving a file.
     * Used by bulk batch to accumulate HTML for all records, then render one merged PDF at the end.
     * Accepts optional pre-loaded record data to skip per-record SOQL.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @param preloadedRecordData Optional pre-fetched record data map (null to query fresh)
     * @return HTML string ready for Blob.toPdf() rendering
     */
    public static String generateHtmlForRecord(Id templateId, Id recordId, Map<String, Object> preloadedRecordData) {
        if (preloadedRecordData != null) {
            preloadedRecordDataOverride = preloadedRecordData;
        }
        MergeResult mr = mergeTemplate(templateId, recordId, null, 'PDF');

        // HTML template type: mr.documentXml is already a ready-to-render HTML
        // document — skip the DOCX→HTML conversion (which would return empty
        // since there are no DOCX processedXmlEntries for HTML templates).
        if (mr.templateType == 'HTML') {
            return mr.documentXml == null ? '' : mr.documentXml;
        }

        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);
        setNumberingXml(mr);
        applyWatermarkOverride(templateId);
        return DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(mr), pdfImages);
    }

    /**
     * Preprocesses DOCX XML to merge text runs where template tags {tag} are split
     * across multiple <w:r><w:t> elements by Word's formatting engine.
     * After merging, processXml can find complete tags like {#QuoteLineItems}.
     */
    private static String mergeRunsInTags(String xml) {
        // 1. Find all <w:t...>text</w:t> and <a:t>text</a:t> elements (Word + PowerPoint)
        Pattern wtPattern = Pattern.compile('<[wa]:t(?:\\s[^>]*)?>([^<]*)</[wa]:t>');
        Matcher m = wtPattern.matcher(xml);

        List<Integer> contentStarts = new List<Integer>();
        List<Integer> contentEnds = new List<Integer>();
        List<String> contents = new List<String>();

        while (m.find()) {
            contentStarts.add(m.start(1));
            contentEnds.add(m.end(1));
            contents.add(m.group(1));
        }

        if (contents.isEmpty()) {
            return xml;
        }

        // 2. Build flat text (concatenation of all <w:t> text) and segment offsets
        Integer totalLen = 0;
        List<Integer> flatOffsets = new List<Integer>();
        for (String c : contents) {
            flatOffsets.add(totalLen);
            totalLen += c.length();
        }
        String flatText = String.join(contents, '');

        // 3. Find tags where { and } are in different segments
        Boolean modified = false;
        Integer pos = 0;

        while (pos < flatText.length()) {
            Integer openBrace = flatText.indexOf('{', pos);
            if (openBrace == -1) {
                break;
            }
            Integer closeBrace = flatText.indexOf('}', openBrace);
            if (closeBrace == -1) {
                break;
            }

            // Determine which segments contain the { and }
            Integer openSeg = -1;
            Integer closeSeg = -1;
            for (Integer i = 0; i < contents.size(); i++) {
                Integer segStart = flatOffsets.get(i);
                Integer segEnd = segStart + contents.get(i).length();
                if (openBrace >= segStart && openBrace < segEnd) { openSeg = i; }
                if (closeBrace >= segStart && closeBrace < segEnd) { closeSeg = i; }
            }

            if (openSeg != -1 && closeSeg != -1 && openSeg != closeSeg) {
                modified = true;
                // Merge all text from openSeg through closeSeg into openSeg
                String merged = '';
                for (Integer i = openSeg; i <= closeSeg; i++) {
                    merged += contents.get(i);
                }
                contents.set(openSeg, merged);
                for (Integer i = openSeg + 1; i <= closeSeg; i++) {
                    contents.set(i, '');
                }
                // Recalculate flat offsets after merge
                totalLen = 0;
                for (Integer i = 0; i < contents.size(); i++) {
                    flatOffsets.set(i, totalLen);
                    totalLen += contents.get(i).length();
                }
                flatText = String.join(contents, '');
            }

            pos = closeBrace + 1;
        }

        if (!modified) {
            return xml;
        }

        // 4. Reconstruct XML by replacing text content (work backwards to maintain positions)
        String result = xml;
        for (Integer i = contents.size() - 1; i >= 0; i--) {
            String original = result.substring(contentStarts.get(i), contentEnds.get(i));
            if (!contents.get(i).equals(original)) {
                result = result.substring(0, contentStarts.get(i)) + contents.get(i) + result.substring(contentEnds.get(i));
            }
        }

        return result;
    }

    private static String processXml(String xml, Map<String, Object> data) {
        String output = '';
        Integer len = xml.length();
        Integer cursor = 0;
        
        while (cursor < len) {
            Integer nextTag = xml.indexOf('{', cursor);
            if (nextTag == -1) {
                output += xml.substring(cursor);
                break; 
            }
            output += xml.substring(cursor, nextTag);
            cursor = nextTag;
            
            Integer tagClose = xml.indexOf('}', cursor);
            if (tagClose == -1) {
                throw new DocGenException(
                    'Malformed merge tag: missing closing "}" near position ' + cursor +
                    '. Check for an unclosed tag in the template.'
                );
            }
            
            String rawTag = xml.substring(cursor + 1, tagClose);
            String tagContent = rawTag.trim();

            // Preserve {@Signature_*} tags — handled by the signature service after merge
            if (tagContent.startsWith('@')) {
                output += '{' + rawTag + '}';
                cursor = tagClose + 1;
                continue;
            }

            // Preserve {PageNumber} and {TotalPages} — resolved by the HTML-to-PDF
            // wrap layer via @page CSS counter() rules. Flying Saucer can only
            // resolve counter(page)/counter(pages) inside @page context, so the
            // tokens have to survive processXml intact for wrapHtmlForPdf to see.
            if ('PageNumber'.equalsIgnoreCase(tagContent) || 'TotalPages'.equalsIgnoreCase(tagContent)) {
                output += '{' + rawTag + '}';
                cursor = tagClose + 1;
                continue;
            }

            // Strip Salesforce-style {!Field} prefix — treat {!X} the same as {X}
            if (tagContent.startsWith('!')) {
                tagContent = tagContent.substring(1).trim();
            }

            if (tagContent.startsWith('#')) {
                String key = tagContent.substring(1).trim();
                // For {#IF ...} expressions, the closing tag is {/IF} not {/IF expression}
                String balanceKey = (key.startsWith('IF ') || key.startsWith('if ')) ? 'IF' : key;
                Integer sectionEnd = findBalancedEnd(xml, tagClose + 1, balanceKey);
                if (sectionEnd == -1) {
                    throw new DocGenException(
                        'Malformed loop tag: missing closing "{/' + balanceKey + '}" for "{#' + key + '}".'
                    );
                } else {
                    // Default: Content between tags
                    Integer contentStart = tagClose + 1;
                    Integer contentEnd = sectionEnd;
                    String innerXml = xml.substring(contentStart, contentEnd);
                    
                    // Smart container expansion: repeat the nearest parent container when possible.
                    // Candidate containers:
                    // 1) Table row (<w:tr>...</w:tr>)
                    // 2) Numbered/bulleted paragraph (nearest <w:p> containing <w:numPr>)
                    Integer closeTagEnd = xml.indexOf('}', sectionEnd);
                    Integer chosenContainerStart = -1;
                    Integer chosenContainerEnd = -1;

                    // Candidate: row container
                    Integer rowContainerStart = lastIndexOfTagStart(xml, 'w:tr', cursor);
                    if (rowContainerStart != -1) {
                        Integer rowContainerEnd = xml.indexOf('</w:tr>', rowContainerStart);
                        Boolean rowClosedBeforeCursor = xml.substring(rowContainerStart, cursor).contains('</w:tr>');
                        if (!rowClosedBeforeCursor && rowContainerEnd != -1 && rowContainerEnd > closeTagEnd) {
                            chosenContainerStart = rowContainerStart;
                            chosenContainerEnd = rowContainerEnd + 7; // </w:tr>
                        }
                    }

                    // Candidate: list paragraph container (w:p with w:numPr)
                    Integer numPropsStart = xml.lastIndexOf('<w:numPr', cursor);
                    if (numPropsStart != -1) {
                        Integer paragraphStart = lastIndexOfTagStart(xml, 'w:p', cursor);
                        if (paragraphStart != -1 && paragraphStart <= numPropsStart) {
                            Integer paragraphEndStart = xml.indexOf('</w:p>', paragraphStart);
                            Boolean paragraphClosedBeforeCursor = xml.substring(paragraphStart, cursor).contains('</w:p>');
                            if (!paragraphClosedBeforeCursor && paragraphEndStart != -1 && paragraphEndStart > closeTagEnd && numPropsStart < paragraphEndStart) {
                                Integer paragraphContainerEnd = paragraphEndStart + 6; // </w:p>
                                // Prefer the closest valid parent.
                                if (chosenContainerStart == -1 || paragraphStart > chosenContainerStart) {
                                    chosenContainerStart = paragraphStart;
                                    chosenContainerEnd = paragraphContainerEnd;
                                }
                            }
                        }
                    }

                    // HTML template type (v1.61+): mirror the DOCX auto-expand behavior
                    // for <tr> rows and <li> list items. Only considered when the merge
                    // engine is running in HTML context — leaves DOCX paths untouched.
                    if (currentTemplateType == 'HTML') {
                        // Candidate: HTML <tr> row
                        Integer htmlTrStart = lastIndexOfTagStart(xml, 'tr', cursor);
                        if (htmlTrStart != -1) {
                            Integer htmlTrEnd = xml.indexOf('</tr>', htmlTrStart);
                            Boolean trClosedBeforeCursor = xml.substring(htmlTrStart, cursor).contains('</tr>');
                            if (!trClosedBeforeCursor && htmlTrEnd != -1 && htmlTrEnd > closeTagEnd) {
                                if (chosenContainerStart == -1 || htmlTrStart > chosenContainerStart) {
                                    chosenContainerStart = htmlTrStart;
                                    chosenContainerEnd = htmlTrEnd + 5; // </tr>
                                }
                            }
                        }

                        // Candidate: HTML <li> list item
                        Integer htmlLiStart = lastIndexOfTagStart(xml, 'li', cursor);
                        if (htmlLiStart != -1) {
                            Integer htmlLiEnd = xml.indexOf('</li>', htmlLiStart);
                            Boolean liClosedBeforeCursor = xml.substring(htmlLiStart, cursor).contains('</li>');
                            if (!liClosedBeforeCursor && htmlLiEnd != -1 && htmlLiEnd > closeTagEnd) {
                                if (chosenContainerStart == -1 || htmlLiStart > chosenContainerStart) {
                                    chosenContainerStart = htmlLiStart;
                                    chosenContainerEnd = htmlLiEnd + 5; // </li>
                                }
                            }
                        }
                    }

                    if (chosenContainerStart != -1 && chosenContainerEnd != -1) {
                        contentStart = chosenContainerStart;
                        contentEnd = chosenContainerEnd;
                        innerXml = xml.substring(contentStart, contentEnd);

                        String startTagFull = '{' + rawTag + '}';
                        innerXml = innerXml.replace(startTagFull, '');

                        String endTagFull = xml.substring(sectionEnd, closeTagEnd + 1);
                        innerXml = innerXml.replace(endTagFull, '');

                        // Backtrack output to remove already-emitted prefix for chosen container.
                        Integer overlap = cursor - contentStart;
                        if (overlap > 0) {
                            Integer outputLength = output.length();
                            if (overlap > outputLength) {
                                throw new DocGenException(
                                    'Template loop parsing error for "{#' + key + '}": internal overlap (' + overlap +
                                    ') exceeds output length (' + outputLength + '). ' +
                                    'This usually indicates malformed or mismatched loop tags (missing "{/' + key + '}").'
                                );
                            }
                            output = output.substring(0, outputLength - overlap);
                        }
                        cursor = contentEnd;
                    } else {
                        // Fallback behavior: keep default content-only repetition.
                        cursor = closeTagEnd + 1;
                    }

                    // Split on {:else} if present
                    String trueBranch = innerXml;
                    String elseBranch = null;
                    Integer elsePos = innerXml.indexOf('{:else}');
                    if (elsePos != -1) {
                        trueBranch = innerXml.substring(0, elsePos);
                        elseBranch = innerXml.substring(elsePos + 7); // 7 = '{:else}'.length()
                    }

                    // Check for {#IF Field op Value} comparison conditional
                    if (key.startsWith('IF ') || key.startsWith('if ')) {
                        Boolean ifResult = evaluateIfExpression(key.substring(3).trim(), data);
                        if (ifResult) {
                            output += processXml(trueBranch, data);
                        } else if (elseBranch != null) {
                            output += processXml(elseBranch, data);
                        }
                        cursor = (closeTagEnd != -1 ? closeTagEnd + 1 : sectionEnd);
                        continue;
                    }

                    // Process Data
                    Object val = resolveValue(data, key);
                    String sectionResult = '';
                    Boolean isTruthy = false;
                    if (val instanceof Boolean && (Boolean)val) {
                         isTruthy = true;
                         sectionResult = processXml(trueBranch, data);
                    } else if (val instanceof Map<String, Object>) {
                        isTruthy = true;
                        Map<String, Object> mapVal = (Map<String, Object>) val;
                        if (mapVal.containsKey('records') && mapVal.get('records') instanceof List<Object>) {
                            List<Object> records = (List<Object>) mapVal.get('records');
                            // Pre-fetch attached images for all iteration records if the loop body uses {%Image:N}
                            if (loopBodyHasImageTag(trueBranch) && !records.isEmpty()) {
                                Set<Id> loopIds = new Set<Id>();
                                for (Object item : records) {
                                    if (item instanceof Map<String, Object>) {
                                        Object idVal = ((Map<String, Object>) item).get('Id');
                                        if (idVal != null) { try { loopIds.add(Id.valueOf(String.valueOf(idVal))); } catch (Exception e) {} }
                                    }
                                }
                                prefetchImagesForIds(loopIds);
                            }
                            Integer iterCount = 0;
                            for (Object item : records) {
                                if (item instanceof Map<String, Object>) {
                                    sectionResult += processXml(trueBranch, (Map<String, Object>) item);
                                }
                                iterCount++;
                                if (Math.mod(iterCount, HEAP_CHECK_EVERY_N_ITERS) == 0) { checkHeapPressure(key); }
                            }
                        } else {
                             sectionResult = processXml(trueBranch, mapVal);
                        }
                    } else if (val instanceof List<Object>) {
                         List<Object> listVal = (List<Object>) val;
                         if (!listVal.isEmpty()) { isTruthy = true; }
                         // Pre-fetch attached images for all iteration records if the loop body uses {%Image:N}
                         if (loopBodyHasImageTag(trueBranch) && !listVal.isEmpty()) {
                             Set<Id> loopIds = new Set<Id>();
                             for (Object item : listVal) {
                                 if (item instanceof Map<String, Object>) {
                                     Object idVal = ((Map<String, Object>) item).get('Id');
                                     if (idVal != null) { try { loopIds.add(Id.valueOf(String.valueOf(idVal))); } catch (Exception e) {} }
                                 }
                             }
                             prefetchImagesForIds(loopIds);
                         }
                         Integer iterCount = 0;
                         for (Object item : listVal) {
                              if (item instanceof Map<String, Object>) { sectionResult += processXml(trueBranch, (Map<String, Object>) item); }
                              iterCount++;
                              if (Math.mod(iterCount, HEAP_CHECK_EVERY_N_ITERS) == 0) { checkHeapPressure(key); }
                         }
                    } else if (val != null && !(val instanceof Boolean)) {
                         // Non-null, non-boolean, non-list, non-map value (e.g., non-blank string)
                         isTruthy = true;
                         sectionResult = processXml(trueBranch, data);
                    }

                    if (!isTruthy && elseBranch != null) {
                        sectionResult = processXml(elseBranch, data);
                    }
                    output += sectionResult;
                }
                
            } else if (tagContent.startsWith('^')) {
                // Inverse conditional: {^BoolField}content{/BoolField}
                // Shows content when field is false, null, blank, or empty list
                String key = tagContent.substring(1).trim();
                Integer sectionEnd = findBalancedEnd(xml, tagClose + 1, key);
                if (sectionEnd == -1) {
                    throw new DocGenException(
                        'Malformed inverse tag: missing closing "{/' + key + '}" for "{^' + key + '}".'
                    );
                } else {
                    Integer contentStart = tagClose + 1;
                    Integer contentEnd = sectionEnd;
                    String innerXml = xml.substring(contentStart, contentEnd);
                    Integer closeTagEnd = xml.indexOf('}', sectionEnd);
                    // Split on {:else} if present
                    String inverseTrueBranch = innerXml;
                    String inverseElseBranch = null;
                    Integer inverseElsePos = innerXml.indexOf('{:else}');
                    if (inverseElsePos != -1) {
                        inverseTrueBranch = innerXml.substring(0, inverseElsePos);
                        inverseElseBranch = innerXml.substring(inverseElsePos + 7);
                    }

                    String sectionResult = '';
                    Object val = resolveValue(data, key);
                    Boolean isFalsy = (val == null) ||
                        (val instanceof Boolean && !(Boolean)val) ||
                        (val instanceof String && String.isBlank((String)val)) ||
                        (val instanceof List<Object> && ((List<Object>)val).isEmpty());
                    if (isFalsy) {
                        sectionResult = processXml(inverseTrueBranch, data);
                    } else if (inverseElseBranch != null) {
                        sectionResult = processXml(inverseElseBranch, data);
                    }
                    output += sectionResult;
                    cursor = (closeTagEnd != -1 ? closeTagEnd + 1 : sectionEnd);
                }

            } else if (tagContent.startsWith('/')) {
                output += '{' + rawTag + '}';
                cursor = tagClose + 1;
            } else if (tagContent.startsWith('%')) {
                // Image tag: {%FieldName} or {%FieldName:WxH} or {%Image:N} or {%Image:N:SIZE}
                // PowerPoint: skip image injection (Word-specific DrawingML corrupts PPTX)
                if (currentTemplateType == 'PowerPoint') {
                    cursor = tagClose + 1;
                    continue;
                }
                String imageTagSpec = tagContent.substring(1).trim();

                // Positional record-attached-image tag: {%Image:N} or {%Image:N:SIZE}
                // Renders the Nth oldest image (PNG/JPG/GIF/BMP/TIFF/SVG) attached to the current record.
                String imageTagHead = imageTagSpec.contains(':') ? imageTagSpec.substringBefore(':').trim() : imageTagSpec.trim();
                if ('Image'.equalsIgnoreCase(imageTagHead)) {
                    ImageRenderSpec indexedSpec = resolveImageByIndexTag(imageTagSpec, data);
                    if (indexedSpec != null && String.isNotBlank(indexedSpec.fieldValue)) {
                        String imageXml = buildImageXml(indexedSpec);
                        if (imageXml != null) {
                            output += imageXml;
                        }
                    }
                    cursor = tagClose + 1;
                    continue;
                }

                ImageRenderSpec imageRenderSpec = parseImageTagSpec(imageTagSpec);
                Object val = resolveValue(data, imageRenderSpec.imageField);
                if (val != null) {
                    imageRenderSpec.fieldValue = String.valueOf(val);
                    String imageXml = buildImageXml(imageRenderSpec);
                    if (imageXml != null) {
                        output += imageXml;
                    }
                }
                cursor = tagClose + 1;
            } else if (tagContent.startsWith('*')) {
                // Barcode/QR tag: {*Field}, {*Field:qr}, {*Field:qr:200}, {*Field:code128:300x80}
                // Outputs a marker that DocGenHtmlRenderer renders as CSS for PDF
                String barcodeSpec = tagContent.substring(1).trim();
                List<String> bParts = barcodeSpec.split(':');
                String barcodeField = bParts[0].trim();
                String barcodeType = bParts.size() > 1 ? bParts[1].trim().toLowerCase() : 'code128';
                String barcodeSize = bParts.size() > 2 ? bParts[2].trim() : '';
                Object val = resolveValue(data, barcodeField);
                if (val != null) {
                    String barcodeValue = String.valueOf(val).escapeXml();
                    // Marker format: ##BARCODE:type:size:VALUE##
                    output += '##BARCODE:' + barcodeType + ':' + barcodeSize + ':' + barcodeValue + '##';
                }
                cursor = tagClose + 1;
            } else if (tagContent.contains(':') && isAggregateTag(tagContent)) {
                // Aggregate tag: {SUM:ChildList.Field}, {COUNT:ChildList}, {AVG:...}, {MIN:...}, {MAX:...}
                String aggResult = resolveAggregate(tagContent, data);
                if (aggResult != null) {
                    output += aggResult.escapeXml();
                }
                cursor = tagClose + 1;
            } else {
                // Parse optional date format suffix: {FieldName:format}
                String fieldName = tagContent;
                String dateFormat = null;
                if (tagContent.contains(':')) {
                    Integer colonIdx = tagContent.indexOf(':');
                    fieldName = tagContent.substring(0, colonIdx).trim();
                    dateFormat = tagContent.substring(colonIdx + 1).trim();
                }

                // {Today} and {Now} are built-in special tags — resolve before the
                // data map so users don't need a formula field. Format suffixes
                // (:MM/dd/yyyy, :date, :date:de_DE, etc.) work as with any field.
                // For {Today} we construct the DateTime explicitly from year/month/day
                // so downstream formatting lands on the same calendar day regardless
                // of user timezone (DateTime.newInstance(Date, Time) can shift across
                // midnight when user TZ differs from the scratch default).
                Object val;
                String upperField = fieldName.toUpperCase();
                if (upperField == 'TODAY') {
                    Date td = Date.today();
                    val = DateTime.newInstance(td.year(), td.month(), td.day());
                } else if (upperField == 'NOW') {
                    val = DateTime.now();
                } else {
                    val = resolveValue(data, fieldName);
                }
                if (val != null) {
                    String strVal;
                    // Apply formatting if a format specifier was provided
                    if (dateFormat != null && dateFormat.toLowerCase().trim().startsWith('date') &&
                        (val instanceof DateTime || val instanceof Date)) {
                        // {Field:date} → user's locale default | {Field:date:locale} → explicit locale
                        String dateTrimmed = dateFormat.trim();
                        String dateLocale = dateTrimmed.contains(':')
                            ? dateTrimmed.substring(dateTrimmed.indexOf(':') + 1).trim()
                            : UserInfo.getLocale();
                        String pattern = getLocaleDatePattern(dateLocale);
                        DateTime dt = val instanceof DateTime ? (DateTime) val :
                            DateTime.newInstance((Date) val, Time.newInstance(0, 0, 0, 0));
                        strVal = dt.format(pattern);
                    } else if (dateFormat != null && val instanceof DateTime) {
                        strVal = ((DateTime) val).format(dateFormat);
                    } else if (dateFormat != null && val instanceof Date) {
                        DateTime dt = DateTime.newInstance((Date) val, Time.newInstance(0, 0, 0, 0));
                        strVal = dt.format(dateFormat);
                    } else if (dateFormat != null && dateFormat.toLowerCase().trim() == 'checkbox') {
                        // {IsActive:checkbox} → [X] or [ ]
                        // Uses ASCII representation for universal font compatibility in PDF/DOCX
                        Boolean checked = val instanceof Boolean ? (Boolean) val :
                            String.valueOf(val).equalsIgnoreCase('true');
                        strVal = checked ? '[X]' : '[ ]';
                    } else if (dateFormat != null && isNumericFormat(dateFormat)) {
                        strVal = formatNumber(val, dateFormat);
                    } else {
                        strVal = String.valueOf(val);
                    }
                    // Rich text HTML — convert to DOCX XML preserving formatting, images, and paragraphs
                    // PowerPoint: strip HTML tags and output plain text (Word XML corrupts PPTX)
                    if (strVal.contains('<') && strVal.contains('>') &&
                        (strVal.containsIgnoreCase('<p') || strVal.containsIgnoreCase('<div') ||
                         strVal.containsIgnoreCase('<span') || strVal.containsIgnoreCase('<br') ||
                         strVal.containsIgnoreCase('<img') || strVal.containsIgnoreCase('<b>') ||
                         strVal.containsIgnoreCase('<i>') || strVal.containsIgnoreCase('<u>') ||
                         strVal.containsIgnoreCase('<strong') || strVal.containsIgnoreCase('<em'))) {
                        if (currentTemplateType == 'PowerPoint') {
                            // Strip HTML tags for plain text in PPTX
                            output += strVal.replaceAll('<[^>]+>', ' ').replaceAll('\\s+', ' ').trim().escapeXml();
                        } else {
                            output += convertRichTextToDocxXml(strVal);
                        }
                    }
                    else {
                        if (currentTemplateType == 'PowerPoint') {
                            output += strVal.escapeXml();
                        } else {
                            // Carry forward run properties (font, size, bold, etc.) so formatting
                            // is preserved across line breaks in textarea fields (#32)
                            String rPr = extractCurrentRunProperties(output);
                            output += convertMultilineToXml(strVal, rPr);
                        }
                    }
                }
                cursor = tagClose + 1;
            }
        }
        return output;
    }
    
    private static Integer findBalancedEnd(String xml, Integer startSearch, String key) {
        Integer depth = 1;
        Integer cursor = startSearch;
        while (cursor < xml.length()) {
            Integer nextStart = xml.indexOf('{', cursor);
            if (nextStart == -1) {
                return -1;
            }
            Integer nextClose = xml.indexOf('}', nextStart);
            if (nextClose == -1) {
                return -1;
            }
            String content = xml.substring(nextStart + 1, nextClose).trim();
            if (content.equals('#' + key) || content.equals('^' + key)) {
                depth++;
            }
            else if (content.equals('/' + key)) {
                depth--;
                if (depth == 0) {
                    return nextStart;
                }
            }
            cursor = nextClose + 1;
        }
        return -1;
    }

    /**
     * Evaluates an IF expression like "Amount > 10000" or "Stage = 'Closed Won'".
     * Supports operators: =, !=, >, <, >=, <=
     * Values can be numbers, quoted strings, or field references.
     * Credit: conditional logic approach inspired by @ssk42 (PR #15)
     */
    private static Boolean evaluateIfExpression(String expression, Map<String, Object> data) {
        // Parse: "Field op Value" — find the operator
        String[] operators = new String[]{ '!=', '>=', '<=', '=', '>', '<' };
        String op = null;
        String fieldPart = null;
        String valuePart = null;

        for (String testOp : operators) {
            Integer opIdx = expression.indexOf(testOp);
            if (opIdx > 0) {
                op = testOp;
                fieldPart = expression.substring(0, opIdx).trim();
                valuePart = expression.substring(opIdx + testOp.length()).trim();
                break;
            }
        }

        if (op == null || fieldPart == null || valuePart == null) {
            return false; // Unparseable expression
        }

        // Resolve field value
        Object fieldVal = resolveValue(data, fieldPart);
        String fieldStr = fieldVal != null ? String.valueOf(fieldVal) : '';

        // Strip quotes from value if present
        if (valuePart.startsWith('\'') && valuePart.endsWith('\'')) {
            valuePart = valuePart.substring(1, valuePart.length() - 1);
        }

        // Try numeric comparison first
        try {
            Decimal fieldNum = Decimal.valueOf(fieldStr);
            Decimal valueNum = Decimal.valueOf(valuePart);
            if (op == '=' || op == '==') { return fieldNum == valueNum; }
            if (op == '!=') { return fieldNum != valueNum; }
            if (op == '>') { return fieldNum > valueNum; }
            if (op == '<') { return fieldNum < valueNum; }
            if (op == '>=') { return fieldNum >= valueNum; }
            if (op == '<=') { return fieldNum <= valueNum; }
        } catch (Exception e) {
            // Not numeric — fall through to string comparison
        }

        // String comparison
        if (op == '=' || op == '==') { return fieldStr == valuePart; }
        if (op == '!=') { return fieldStr != valuePart; }
        if (op == '>') { return fieldStr > valuePart; }
        if (op == '<') { return fieldStr < valuePart; }
        if (op == '>=') { return fieldStr >= valuePart; }
        if (op == '<=') { return fieldStr <= valuePart; }

        return false;
    }

    private static Integer lastIndexOfTagStart(String xml, String tagName, Integer fromIndex) {
        if (String.isBlank(xml) || String.isBlank(tagName) || fromIndex == null || fromIndex < 0) {
            return -1;
        }
        Integer searchIndex = Math.min(fromIndex, xml.length());
        Integer withAttributesIndex = xml.lastIndexOf('<' + tagName + ' ', searchIndex);
        Integer bareTagIndex = xml.lastIndexOf('<' + tagName + '>', searchIndex);
        return Math.max(withAttributesIndex, bareTagIndex);
    }

    /**
     * Converts a text value with newlines to Word XML with <w:br/> line breaks.
     * Properly closes and reopens <w:r> runs around each break for valid OOXML.
     * Carries forward run properties (rPr) so formatting is preserved across breaks.
     */
    private static String convertMultilineToXml(String inputText, String rPr) {
        if (inputText == null) {
            return '';
        }
        String normalized = inputText.replace('\r\n', '\n').replace('\r', '\n');
        if (!normalized.contains('\n')) {
            return normalized.escapeXml();
        }
        List<String> lines = normalized.split('\n');
        String result = '';
        String rPrXml = String.isNotBlank(rPr) ? rPr : '';
        String lineBreakXml = '</w:t></w:r><w:r>' + rPrXml + '<w:br/></w:r><w:r>' + rPrXml + '<w:t xml:space="preserve">';
        for (Integer i = 0; i < lines.size(); i++) {
            if (i > 0) {
                result += lineBreakXml;
            }
            result += lines[i].escapeXml();
        }
        return result;
    }

    /**
     * Extracts the <w:rPr>...</w:rPr> block from the current open <w:r> run in the output.
     * Returns empty string if no run properties found.
     */
    @TestVisible
    private static String extractCurrentRunProperties(String output) {
        if (String.isBlank(output)) {
            return '';
        }
        // Find the last <w:r> or <w:r > opening (start of current run)
        Integer lastRunOpen = output.lastIndexOf('<w:r>');
        Integer lastRunOpenAttr = output.lastIndexOf('<w:r ');
        Integer runStart = Math.max(lastRunOpen != null ? lastRunOpen : -1, lastRunOpenAttr != null ? lastRunOpenAttr : -1);
        if (runStart < 0) {
            return '';
        }
        // If there's a </w:r> after this opening, we're not inside an open run
        Integer lastRunClose = output.lastIndexOf('</w:r>');
        if (lastRunClose != null && lastRunClose > runStart) {
            return '';
        }
        // Find <w:rPr>...</w:rPr> within this run
        Integer rPrStart = output.indexOf('<w:rPr>', runStart);
        if (rPrStart < 0) {
            rPrStart = output.indexOf('<w:rPr ', runStart);
        }
        if (rPrStart < 0) {
            return '';
        }
        Integer rPrEnd = output.indexOf('</w:rPr>', rPrStart);
        if (rPrEnd < 0) {
            return '';
        }
        return output.substring(rPrStart, rPrEnd + 8);
    }

    private static Object resolveValue(Map<String, Object> data, String path) {
        if (data == null) {
            return null;
        }
        List<String> parts = path.split('\\.');
        Object current = data;

        for (Integer i = 0; i < parts.size(); i++) {
            String part = parts[i];
            if (current instanceof Map<String, Object>) {
                Map<String, Object> currentMap = (Map<String, Object>) current;
                if (currentMap.containsKey(part)) {
                    current = currentMap.get(part);
                } else {
                    // Try case-insensitive comparison
                    Boolean found = false;
                    for (String key : currentMap.keySet()) {
                        if (key.equalsIgnoreCase(part)) {
                            current = currentMap.get(key);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        // If first segment doesn't match, it may be the base object name
                        // (e.g., "Contact" in {!Contact.FirstName}). Skip it and continue.
                        if (i == 0 && parts.size() > 1 && !part.endsWithIgnoreCase('__r')) {
                            continue;
                        }
                        return null;
                    }
                }
            } else if (current instanceof SObject) {
                 SObject sobj = (SObject) current;
                 try {
                     current = sobj.get(part);
                 } catch(Exception e) {
                     return null;
                 }
            } else {
                return null;
            }
            if (current == null) {
                return null;
            }
        }
        return current;
    }
    
    // ---------------------------------------------------------------------------
    // Aggregate Tags: {SUM:List.Field}, {COUNT:List}, {AVG:...}, {MIN:...}, {MAX:...}
    // ---------------------------------------------------------------------------

    // ---------------------------------------------------------------------------
    // Excel Shared String Inlining
    // ---------------------------------------------------------------------------

    /**
     * Parses xl/sharedStrings.xml and returns an ordered list of string values.
     * Each <si> element at index N is the string referenced by <v>N</v> in cells.
     */
    private static List<String> parseSharedStrings(String xml) {
        List<String> strings = new List<String>();
        if (String.isBlank(xml)) {
            return strings;
        }

        Integer cursor = 0;
        while (cursor < xml.length()) {
            Integer siStart = xml.indexOf('<si>', cursor);
            if (siStart == -1) {
                siStart = xml.indexOf('<si ', cursor);
            }
            if (siStart == -1) {
                break;
            }

            Integer siEnd = xml.indexOf('</si>', siStart);
            if (siEnd == -1) {
                break;
            }

            // Extract all <t> content within this <si>
            String siContent = xml.substring(siStart, siEnd);
            String value = '';
            Integer tCursor = 0;
            while (tCursor < siContent.length()) {
                Integer tStart = siContent.indexOf('<t', tCursor);
                if (tStart == -1) {
                    break;
                }
                Integer tTagEnd = siContent.indexOf('>', tStart);
                if (tTagEnd == -1) {
                    break;
                }
                // Skip self-closing
                if (siContent.substring(tTagEnd - 1, tTagEnd) == '/') {
                    tCursor = tTagEnd + 1;
                    continue;
                }
                Integer tEnd = siContent.indexOf('</t>', tTagEnd);
                if (tEnd == -1) {
                    break;
                }
                value += siContent.substring(tTagEnd + 1, tEnd);
                tCursor = tEnd + 4;
            }
            strings.add(value);
            cursor = siEnd + 5;
        }
        return strings;
    }

    /**
     * Converts cells that reference shared strings (t="s") to inline strings (t="inlineStr").
     * This allows processXml() to find and resolve merge tags inside cell values.
     *
     * Before: <c r="A1" t="s"><v>3</v></c>  (index 3 in shared strings = "{Name}")
     * After:  <c r="A1" t="inlineStr"><is><t>{Name}</t></is></c>
     */
    private static String inlineSharedStrings(String xml, List<String> sharedStrings) {
        if (sharedStrings.isEmpty()) {
            return xml;
        }

        String result = '';
        Integer cursor = 0;

        while (cursor < xml.length()) {
            // Find next cell element
            Integer cStart = xml.indexOf('<c ', cursor);
            if (cStart == -1) {
                result += xml.substring(cursor);
                break;
            }

            // Output everything before this cell
            result += xml.substring(cursor, cStart);

            // Find cell end
            Integer cEnd = xml.indexOf('</c>', cStart);
            if (cEnd == -1) {
                // Self-closing cell
                Integer selfClose = xml.indexOf('/>', cStart);
                if (selfClose == -1) {
                    result += xml.substring(cStart);
                    break;
                }
                result += xml.substring(cStart, selfClose + 2);
                cursor = selfClose + 2;
                continue;
            }

            String cellXml = xml.substring(cStart, cEnd + 4);

            // Check if this is a shared string cell: t="s"
            if (cellXml.contains('t="s"')) {
                // Extract the <v> index
                Integer vStart = cellXml.indexOf('<v>');
                Integer vEnd = cellXml.indexOf('</v>');
                if (vStart != -1 && vEnd != -1) {
                    String indexStr = cellXml.substring(vStart + 3, vEnd).trim();
                    if (indexStr.isNumeric()) {
                        Integer idx = Integer.valueOf(indexStr);
                        if (idx >= 0 && idx < sharedStrings.size()) {
                            String value = sharedStrings[idx];
                            // Rebuild cell as inline string
                            String cellTag = cellXml.substring(0, cellXml.indexOf('>'));
                            cellTag = cellTag.replace('t="s"', 't="inlineStr"');
                            result += cellTag + '><is><t>' + value + '</t></is></c>';
                            cursor = cEnd + 4;
                            continue;
                        }
                    }
                }
            }

            // Not a shared string cell — pass through
            result += cellXml;
            cursor = cEnd + 4;
        }

        return result;
    }

    // ---------------------------------------------------------------------------
    // Number/Currency/Date Formatting with Locale Support
    // {Amount:currency} → $500,000.00  (backward compat)
    // {Amount:currency:EUR} → €500,000.00  (ISO code → symbol)
    // {Amount:currency:EUR:de_DE} → 500.000,00 €  (full locale override)
    // {Amount:number:de_DE} → 500.000  (locale separators)
    // {Rate:percent:de_DE} → 15,5%  (locale decimal)
    // {CloseDate:date} → user locale default date
    // {CloseDate:date:de_DE} → 17.04.2026
    // {Quantity:#,##0} → 1,234  (custom pattern, unchanged)
    // ---------------------------------------------------------------------------

    /** Returns the thousands grouping separator for a locale. */
    private static String getLocaleGroupSep(String locale) {
        if (locale == null) { return ','; }
        String loc = locale.toLowerCase();
        // Dot-as-thousands: German, French, Spanish, Italian, Portuguese, Dutch, Scandinavian
        if (loc.startsWith('de_') || loc.startsWith('fr_') || loc.startsWith('es_') ||
            loc.startsWith('it_') || loc.startsWith('pt_') || loc.startsWith('nl_') ||
            loc.startsWith('da_') || loc.startsWith('sv_') || loc.startsWith('nb_') ||
            loc.startsWith('nn_') || loc.startsWith('pl_') || loc.startsWith('cs_') ||
            loc.startsWith('hu_') || loc.startsWith('tr_') || loc.startsWith('ro_') ||
            loc.startsWith('el_') || loc.startsWith('ru_') || loc.startsWith('uk_') ||
            loc.startsWith('id_') || loc.startsWith('vi_')) {
            return '.';
        }
        // Apostrophe-as-thousands: Swiss French/German
        if (loc == 'fr_ch' || loc == 'de_ch' || loc == 'it_ch') {
            return '\'';
        }
        // Comma-as-thousands: English, Japanese, Chinese, Korean, and default
        return ',';
    }

    /** Returns the decimal separator for a locale. */
    private static String getLocaleDecSep(String locale) {
        if (locale == null) { return '.'; }
        String loc = locale.toLowerCase();
        // Comma-as-decimal: same set that uses dot-as-thousands
        if (loc.startsWith('de_') || loc.startsWith('fr_') || loc.startsWith('es_') ||
            loc.startsWith('it_') || loc.startsWith('pt_') || loc.startsWith('nl_') ||
            loc.startsWith('da_') || loc.startsWith('sv_') || loc.startsWith('nb_') ||
            loc.startsWith('nn_') || loc.startsWith('pl_') || loc.startsWith('cs_') ||
            loc.startsWith('hu_') || loc.startsWith('tr_') || loc.startsWith('ro_') ||
            loc.startsWith('el_') || loc.startsWith('ru_') || loc.startsWith('uk_') ||
            loc.startsWith('id_') || loc.startsWith('vi_')) {
            // Exception: Swiss locales use dot as decimal
            if (loc == 'fr_ch' || loc == 'de_ch' || loc == 'it_ch') {
                return '.';
            }
            return ',';
        }
        return '.';
    }

    /** Returns whether currency symbol goes after the number for a locale. */
    private static Boolean isCurrencyAfter(String locale) {
        if (locale == null) { return false; }
        String loc = locale.toLowerCase();
        return loc.startsWith('de_') || loc.startsWith('fr_') || loc.startsWith('es_') ||
               loc.startsWith('it_') || loc.startsWith('pt_') || loc.startsWith('nl_') ||
               loc.startsWith('da_') || loc.startsWith('sv_') || loc.startsWith('nb_') ||
               loc.startsWith('nn_') || loc.startsWith('pl_') || loc.startsWith('cs_') ||
               loc.startsWith('hu_') || loc.startsWith('tr_') || loc.startsWith('ro_') ||
               loc.startsWith('el_') || loc.startsWith('ru_') || loc.startsWith('uk_');
    }

    /** Returns the default date format pattern for a locale. */
    private static String getLocaleDatePattern(String locale) {
        if (locale == null) { return 'yyyy-MM-dd'; }
        String loc = locale.toLowerCase();
        if (loc.startsWith('en_us')) { return 'MM/dd/yyyy'; }
        if (loc.startsWith('en_gb') || loc.startsWith('en_au') || loc.startsWith('en_nz') ||
            loc.startsWith('en_ie') || loc.startsWith('en_in')) { return 'dd/MM/yyyy'; }
        if (loc.startsWith('de_')) { return 'dd.MM.yyyy'; }
        if (loc.startsWith('fr_')) { return 'dd/MM/yyyy'; }
        if (loc.startsWith('es_')) { return 'dd/MM/yyyy'; }
        if (loc.startsWith('it_')) { return 'dd/MM/yyyy'; }
        if (loc.startsWith('pt_')) { return 'dd/MM/yyyy'; }
        if (loc.startsWith('nl_')) { return 'dd-MM-yyyy'; }
        if (loc.startsWith('ja_')) { return 'yyyy/MM/dd'; }
        if (loc.startsWith('zh_')) { return 'yyyy-MM-dd'; }
        if (loc.startsWith('ko_')) { return 'yyyy. MM. dd'; }
        if (loc.startsWith('ru_')) { return 'dd.MM.yyyy'; }
        if (loc.startsWith('pl_') || loc.startsWith('cs_') || loc.startsWith('hu_')) { return 'dd.MM.yyyy'; }
        if (loc.startsWith('da_') || loc.startsWith('sv_') || loc.startsWith('nb_') || loc.startsWith('nn_')) { return 'yyyy-MM-dd'; }
        if (loc.startsWith('tr_')) { return 'dd.MM.yyyy'; }
        // ISO 8601 as safe default
        return 'yyyy-MM-dd';
    }

    /** Formats a number with locale-aware group and decimal separators. */
    private static String formatNumberLocale(Decimal num, String groupSep, String decSep) {
        Boolean negative = num < 0;
        String raw = (negative ? num.abs() : num).toPlainString();

        String intPart = raw;
        String decPart = '';
        if (raw.contains('.')) {
            intPart = raw.substringBefore('.');
            decPart = decSep + raw.substringAfter('.');
        }

        // Insert group separators every 3 digits from the right
        String result = '';
        Integer count = 0;
        for (Integer i = intPart.length() - 1; i >= 0; i--) {
            if (count > 0 && Math.mod(count, 3) == 0) {
                result = groupSep + result;
            }
            result = intPart.substring(i, i + 1) + result;
            count++;
        }

        return (negative ? '-' : '') + result + decPart;
    }

    private static Boolean isNumericFormat(String fmt) {
        if (fmt == null) {
            return false;
        }
        String lower = fmt.toLowerCase().trim();
        // Check first segment before colon to match extended forms like currency:EUR:de_DE
        String base = lower.contains(':') ? lower.substringBefore(':') : lower;
        return NUMERIC_FORMATS.contains(base) || lower.startsWith('#') || lower.startsWith('0');
    }

    private static String formatNumber(Object val, String fmt) {
        Decimal num;
        try {
            num = Decimal.valueOf(String.valueOf(val));
        } catch (Exception e) {
            return String.valueOf(val); // Not a number — return as-is
        }

        // Split format into segments: currency:EUR:de_DE → ['currency', 'EUR', 'de_DE']
        List<String> segments = fmt.trim().split(':');
        String baseFormat = segments[0].toLowerCase().trim();

        if (baseFormat == 'currency') {
            return formatCurrency(num, segments);
        } else if (baseFormat == 'percent') {
            return formatPercent(num, segments);
        } else if (baseFormat == 'number') {
            return formatPlainNumber(num, segments);
        } else {
            // Custom pattern: #,##0 or #,##0.00 — unchanged behavior, always US separators
            Integer decimals = 0;
            String lower = fmt.toLowerCase().trim();
            if (lower.contains('.')) {
                decimals = lower.substringAfter('.').length();
            }
            return formatNumberLocale(num.setScale(decimals, RoundingMode.HALF_UP), ',', '.');
        }
    }

    /** {Amount:currency} | {Amount:currency:EUR} | {Amount:currency:EUR:de_DE} */
    private static String formatCurrency(Decimal num, List<String> segments) {
        // Bare :currency → backward compat: hardcoded $ with US separators
        if (segments.size() == 1) {
            return '$' + formatNumberLocale(num.setScale(2, RoundingMode.HALF_UP), ',', '.');
        }

        // :currency:ISO or :currency:ISO:locale
        String iso = segments[1].trim().toUpperCase();
        String locale = segments.size() >= 3 ? segments[2].trim() : null;

        // Resolve symbol
        String symbol = CURRENCY_SYMBOLS.containsKey(iso) ? CURRENCY_SYMBOLS.get(iso) : iso + ' ';

        // Determine decimal places (0 for JPY, KRW, etc.)
        Integer scale = ZERO_DECIMAL_CURRENCIES.contains(iso) ? 0 : 2;
        Decimal scaled = num.setScale(scale, RoundingMode.HALF_UP);

        // Determine separators and placement from locale
        String groupSep = getLocaleGroupSep(locale);
        String decSep = getLocaleDecSep(locale);
        Boolean symbolAfter = locale != null && isCurrencyAfter(locale);

        String formatted = formatNumberLocale(scaled, groupSep, decSep);

        if (symbolAfter) {
            return formatted + ' ' + symbol.trim();
        }
        return symbol + formatted;
    }

    /** {Rate:percent} | {Rate:percent:de_DE} */
    private static String formatPercent(Decimal num, List<String> segments) {
        // Bare :percent → backward compat
        if (segments.size() == 1) {
            return num.stripTrailingZeros().toPlainString() + '%';
        }

        // :percent:locale
        String locale = segments[1].trim();
        String decSep = getLocaleDecSep(locale);
        String raw = num.stripTrailingZeros().toPlainString();
        if (decSep != '.') {
            raw = raw.replace('.', decSep);
        }
        return raw + '%';
    }

    /** {Qty:number} | {Qty:number:de_DE} */
    private static String formatPlainNumber(Decimal num, List<String> segments) {
        // Bare :number → backward compat: US commas, no decimals
        if (segments.size() == 1) {
            return formatNumberLocale(num.setScale(0, RoundingMode.HALF_UP), ',', '.');
        }

        // :number:locale
        String locale = segments[1].trim();
        return formatNumberLocale(
            num.setScale(0, RoundingMode.HALF_UP),
            getLocaleGroupSep(locale),
            getLocaleDecSep(locale)
        );
    }

    /** Legacy helper — kept for backward compat with any external callers. */
    private static String formatWithCommas(Decimal num) {
        return formatNumberLocale(num, ',', '.');
    }

    private static Boolean isAggregateTag(String tagContent) {
        Integer colonIdx = tagContent.indexOf(':');
        if (colonIdx <= 0) {
            return false;
        }
        String fn = tagContent.substring(0, colonIdx).trim().toUpperCase();
        return AGGREGATE_FUNCTIONS.contains(fn);
    }

    /**
     * Throws HeapPressureException if the current Apex heap usage is past the
     * configured ratio (default 75% of the limit). Called from processXml's loop
     * expansion every HEAP_CHECK_EVERY_N_ITERS iterations — lets long child-loop
     * expansions bail early instead of failing with an untyped heap OOM, so the
     * controller can signal the runner LWC to auto-fallback to the giant path.
     */
    @TestVisible
    private static void checkHeapPressure(String relationshipName) {
        Integer heap = Limits.getHeapSize();
        Integer heapLimit = Limits.getLimitHeapSize();
        Boolean overThreshold = forceHeapPressureForTest ||
            (heapLimit > 0 && heap >= (Integer) (heapLimit * HEAP_PRESSURE_RATIO));
        if (overThreshold) {
            HeapPressureException e = new HeapPressureException(
                'Heap pressure during sync merge (heap=' + heap + ' of ' + heapLimit + ') — ' +
                'switching to giant-query path for relationship: ' + relationshipName
            );
            e.relationshipName = relationshipName;
            throw e;
        }
    }

    /**
     * Public helper — applies the same numeric-format logic used by in-memory
     * aggregates to a pre-computed Decimal (e.g. from a SOQL aggregate query).
     * Used by DocGenGiantQueryAssembler to resolve grand-total tags.
     */
    public static String formatAggregateValue(Decimal value, String fmt) {
        if (value == null) { return '0'; }
        if (String.isNotBlank(fmt) && isNumericFormat(fmt)) {
            return formatNumber(value, fmt);
        }
        return String.valueOf(value);
    }

    /**
     * Resolves an aggregate tag like {SUM:QuoteLineItems.TotalPrice}.
     * Walks the data map to find the child list, extracts field values, computes.
     */
    private static String resolveAggregate(String tagContent, Map<String, Object> data) {
        Integer colonIdx = tagContent.indexOf(':');
        String fn = tagContent.substring(0, colonIdx).trim().toUpperCase();
        String path = tagContent.substring(colonIdx + 1).trim();

        // Strip optional format specifier: "List.Field:currency" → path="List.Field", fmt="currency"
        String numberFormat = null;
        Integer dotIdx = path.indexOf('.');
        if (dotIdx > 0) {
            // Check for format specifier after the field name: "List.Field:format"
            String afterDot = path.substring(dotIdx + 1);
            Integer fmtColon = afterDot.indexOf(':');
            if (fmtColon > 0) {
                numberFormat = afterDot.substring(fmtColon + 1).trim();
                path = path.substring(0, dotIdx + 1 + fmtColon);
            }
        } else {
            // COUNT:List:format — format on a no-field aggregate
            Integer fmtColon = path.indexOf(':');
            if (fmtColon > 0) {
                numberFormat = path.substring(fmtColon + 1).trim();
                path = path.substring(0, fmtColon);
            }
        }

        // Split path into list name and optional field: "QuoteLineItems.TotalPrice" → ["QuoteLineItems", "TotalPrice"]
        String listName;
        String fieldName = null;
        dotIdx = path.indexOf('.');
        if (dotIdx > 0) {
            listName = path.substring(0, dotIdx);
            fieldName = path.substring(dotIdx + 1);
        } else {
            listName = path;
        }

        // COUNT doesn't require a field
        if (fn == 'COUNT' && fieldName == null) {
            List<Object> records = getChildRecords(data, listName);
            String countResult = records != null ? String.valueOf(records.size()) : '0';
            if (numberFormat != null && isNumericFormat(numberFormat)) {
                return formatNumber(Decimal.valueOf(countResult), numberFormat);
            }
            return countResult;
        }

        if (fieldName == null) {
            return null;
        }

        // Get child records and extract numeric values
        List<Object> records = getChildRecords(data, listName);
        if (records == null || records.isEmpty()) {
            return '0';
        }

        List<Decimal> values = new List<Decimal>();
        for (Object item : records) {
            if (item instanceof Map<String, Object>) {
                Object fieldVal = resolveValue((Map<String, Object>) item, fieldName);
                if (fieldVal != null) {
                    try {
                        values.add(Decimal.valueOf(String.valueOf(fieldVal)));
                    } catch (Exception e) {
                        // Intentionally swallowed — non-numeric value, skip
                        String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                    }
                }
            }
        }

        if (values.isEmpty()) {
            return '0';
        }

        Decimal result;
        if (fn == 'SUM') {
            result = 0;
            for (Decimal v : values) {
                result += v;
            }
        } else if (fn == 'AVG') {
            result = 0;
            for (Decimal v : values) {
                result += v;
            }
            result = result.divide(values.size(), 2, RoundingMode.HALF_UP);
        } else if (fn == 'MIN') {
            result = values[0];
            for (Decimal v : values) {
                if (v < result) {
                    result = v;
                }
            }
        } else if (fn == 'MAX') {
            result = values[0];
            for (Decimal v : values) {
                if (v > result) {
                    result = v;
                }
            }
        } else if (fn == 'COUNT') {
            String countResult = String.valueOf(values.size());
            if (numberFormat != null && isNumericFormat(numberFormat)) {
                return formatNumber(Decimal.valueOf(countResult), numberFormat);
            }
            return countResult;
        } else {
            return null;
        }

        // Apply format specifier if provided, otherwise strip trailing zeros
        if (numberFormat != null && isNumericFormat(numberFormat)) {
            return formatNumber(result, numberFormat);
        }
        return result.stripTrailingZeros().toPlainString();
    }

    /** Extracts the child record list from the data map. */
    private static List<Object> getChildRecords(Map<String, Object> data, String listName) {
        Object val = resolveValue(data, listName);
        if (val instanceof Map<String, Object>) {
            Map<String, Object> mapVal = (Map<String, Object>) val;
            if (mapVal.containsKey('records') && mapVal.get('records') instanceof List<Object>) {
                return (List<Object>) mapVal.get('records');
            }
        } else if (val instanceof List<Object>) {
            return (List<Object>) val;
        }
        return null;
    }

    /**
     * Converts rich text HTML to DOCX XML (w:p, w:r, w:t elements).
     * Preserves text, basic formatting (bold/italic/underline), multiple images, and paragraphs.
     * Returns DOCX XML that closes the current run/paragraph context and reopens it after.
     */
    private static String convertRichTextToDocxXml(String html) {
        // Normalize: replace common entities and whitespace
        html = html.replace('&nbsp;', ' ').replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>');

        // Split into paragraphs by <p>, <div>, and <br> tags
        // First, normalize paragraph boundaries: replace </p><p>, </div><div>, <br>, <br/> with a delimiter
        String delim = '\n__PARA__\n';
        String normalized = html;
        normalized = normalized.replaceAll('(?i)</p>\\s*<p[^>]*>', delim);
        normalized = normalized.replaceAll('(?i)</div>\\s*<div[^>]*>', delim);
        normalized = normalized.replaceAll('(?i)<br\\s*/?>',  delim);
        normalized = normalized.replaceAll('(?i)</?p[^>]*>', delim);
        normalized = normalized.replaceAll('(?i)</?div[^>]*>', delim);

        List<String> paragraphs = normalized.split(delim);

        // Build DOCX XML: close current context, emit paragraphs, reopen context
        String result = '</w:t></w:r>';  // close current run

        Boolean firstPara = true;
        for (String para : paragraphs) {
            String trimmed = para.trim();
            if (String.isBlank(trimmed)) { continue; }

            if (!firstPara) {
                result += '</w:p><w:p>';  // new paragraph
            } else {
                // Continue in the same paragraph as the merge tag
                firstPara = false;
            }

            // Process inline content within this paragraph
            result += processInlineHtml(trimmed);
        }

        // If we never output anything, just return empty text
        if (firstPara) {
            return '';
        }

        // Reopen run/text context for any content after the merge tag
        result += '<w:r><w:t xml:space="preserve">';
        return result;
    }

    /**
     * Processes inline HTML elements within a paragraph into DOCX w:r elements.
     * Handles <b>, <i>, <u>, <strong>, <em>, <span>, <img>, and plain text.
     */
    private static String processInlineHtml(String html) {
        String result = '';
        Integer cursor = 0;

        // Track formatting state
        Boolean isBold = false;
        Boolean isItalic = false;
        Boolean isUnderline = false;

        while (cursor < html.length()) {
            Integer nextTag = html.indexOf('<', cursor);

            if (nextTag == -1) {
                // Remaining plain text
                String text = html.substring(cursor).trim();
                if (String.isNotBlank(text)) {
                    result += buildRun(stripTags(text), isBold, isItalic, isUnderline);
                }
                break;
            }

            // Text before the tag
            if (nextTag > cursor) {
                String text = html.substring(cursor, nextTag);
                if (String.isNotBlank(text)) {
                    result += buildRun(stripTags(text), isBold, isItalic, isUnderline);
                }
            }

            // Find end of tag
            Integer tagEnd = html.indexOf('>', nextTag);
            if (tagEnd == -1) {
                break;
            }
            tagEnd++;

            String tag = html.substring(nextTag, tagEnd).toLowerCase();

            // Handle formatting tags
            if (tag.startsWith('<b>') || tag.startsWith('<b ') || tag.startsWith('<strong')) {
                isBold = true;
            } else if (tag.startsWith('</b>') || tag.startsWith('</strong')) {
                isBold = false;
            } else if (tag.startsWith('<i>') || tag.startsWith('<i ') || tag.startsWith('<em')) {
                isItalic = true;
            } else if (tag.startsWith('</i>') || tag.startsWith('</em')) {
                isItalic = false;
            } else if (tag.startsWith('<u>') || tag.startsWith('<u ')) {
                isUnderline = true;
            } else if (tag.startsWith('</u>')) {
                isUnderline = false;
            } else if (tag.startsWith('<a ') || tag.startsWith('<a>')) {
                // Extract href from anchor tag
                String anchorTag = html.substring(nextTag, tagEnd);
                String href = extractAttribute(anchorTag, 'href');
                // Find the closing </a> and get inner text
                Integer closeA = html.indexOfIgnoreCase('</a>', tagEnd);
                if (closeA != -1) {
                    String linkText = html.substring(tagEnd, closeA);
                    linkText = linkText.replaceAll('<[^>]+>', '').trim();
                    if (String.isBlank(linkText)) { linkText = href; }
                    if (String.isNotBlank(href)) {
                        // Build w:hyperlink with direct URL attribute for PDF rendering
                        result += '<w:hyperlink w:docgen-url="' + href.escapeXml() + '">' +
                            '<w:r><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr>' +
                            '<w:t xml:space="preserve">' + linkText.escapeXml() + '</w:t></w:r>' +
                            '</w:hyperlink>';
                    } else {
                        result += buildRun(linkText, isBold, isItalic, true);
                    }
                    cursor = closeA + 4; // skip past </a>
                    continue;
                }
            } else if (tag.startsWith('<img')) {
                // Extract image from <img> tag
                String imgTag = html.substring(nextTag, tagEnd);
                String imgResult = processRichTextImage(imgTag);
                if (imgResult != null) {
                    result += imgResult;
                }
            }
            // Closing </a> tags and other tags (spans, etc.) are skipped — just process their text content

            cursor = tagEnd;
        }

        return result;
    }

    /**
     * Builds a DOCX w:r (run) element with optional formatting.
     */
    private static String buildRun(String text, Boolean bold, Boolean italic, Boolean underline) {
        if (String.isBlank(text)) {
            return '';
        }
        String rPr = '';
        if (bold || italic || underline) {
            rPr = '<w:rPr>';
            if (bold) { rPr += '<w:b/>'; }
            if (italic) { rPr += '<w:i/>'; }
            if (underline) { rPr += '<w:u w:val="single"/>'; }
            rPr += '</w:rPr>';
        }
        return '<w:r>' + rPr + '<w:t xml:space="preserve">' + text.escapeXml() + '</w:t></w:r>';
    }

    /**
     * Strips any remaining HTML tags from text content.
     */
    private static String stripTags(String text) {
        return text.replaceAll('<[^>]+>', '');
    }

    /**
     * Extracts an attribute value from an HTML tag string.
     * e.g. extractAttribute('<a href="https://example.com">', 'href') => 'https://example.com'
     */
    private static String extractAttribute(String tag, String attrName) {
        Integer attrIdx = tag.indexOfIgnoreCase(attrName + '=');
        if (attrIdx == -1) { return null; }
        Integer valStart = attrIdx + attrName.length() + 1;
        if (valStart >= tag.length()) { return null; }
        String quote = tag.substring(valStart, valStart + 1);
        if (quote == '"' || quote == '\'') {
            valStart++;
            Integer valEnd = tag.indexOf(quote, valStart);
            if (valEnd != -1) {
                return tag.substring(valStart, valEnd).replace('&amp;', '&');
            }
        }
        // Unquoted attribute — read until space or >
        Integer valEnd = tag.indexOf(' ', valStart);
        Integer tagEnd = tag.indexOf('>', valStart);
        if (valEnd == -1 || (tagEnd != -1 && tagEnd < valEnd)) { valEnd = tagEnd; }
        if (valEnd != -1) {
            return tag.substring(valStart, valEnd).replace('&amp;', '&');
        }
        return null;
    }

    /**
     * Processes an <img> tag from rich text, fetches the image, and returns DrawingML XML.
     */
    private static String processRichTextImage(String imgTag) {
        // Extract src attribute
        Integer srcIdx = imgTag.indexOfIgnoreCase('src=');
        if (srcIdx == -1) {
            return null;
        }
        srcIdx += 4;
        while (srcIdx < imgTag.length() && imgTag.substring(srcIdx, srcIdx + 1) == ' ') {
            srcIdx++;
        }
        String quoteChar = imgTag.substring(srcIdx, srcIdx + 1);
        if (quoteChar != '"' && quoteChar != '\'') {
            return null;
        }
        srcIdx++;
        Integer srcEnd = imgTag.indexOf(quoteChar, srcIdx);
        if (srcEnd == -1) {
            return null;
        }
        String src = imgTag.substring(srcIdx, srcEnd).replace('&amp;', '&');

        // Extract optional width/height. Two storage forms exist in rich text HTML:
        //   1. width="200" height="150" attributes — set by older editors
        //   2. style="width: 200px; height: 150px;" — set by Lightning Rich Text
        //      Area when the user drags to resize (which is the common case).
        // Try attribute form first, then fall back to style form so drag-resized
        // images come through at the correct dimensions instead of the default.
        Integer widthPx = null;
        Integer heightPx = null;
        Integer wIdx = imgTag.indexOfIgnoreCase('width=');
        if (wIdx != -1) {
            String wVal = extractHtmlAttrValue(imgTag, wIdx + 6);
            if (wVal != null && wVal.replaceAll('[^0-9]', '').isNumeric()) {
                widthPx = Integer.valueOf(wVal.replaceAll('[^0-9]', ''));
            }
        }
        Integer hIdx = imgTag.indexOfIgnoreCase('height=');
        if (hIdx != -1) {
            String hVal = extractHtmlAttrValue(imgTag, hIdx + 7);
            if (hVal != null && hVal.replaceAll('[^0-9]', '').isNumeric()) {
                heightPx = Integer.valueOf(hVal.replaceAll('[^0-9]', ''));
            }
        }
        // Style fallback: parse `width:Npx` and `height:Npx` from the style attribute.
        if (widthPx == null || heightPx == null) {
            Integer styleIdx = imgTag.indexOfIgnoreCase('style=');
            if (styleIdx != -1) {
                String styleVal = extractHtmlAttrValue(imgTag, styleIdx + 6);
                if (String.isNotBlank(styleVal)) {
                    if (widthPx == null) {
                        widthPx = parseStylePx(styleVal, 'width');
                    }
                    if (heightPx == null) {
                        heightPx = parseStylePx(styleVal, 'height');
                    }
                }
            }
        }

        // Resolve image: decode data URIs to blobs, store Salesforce URLs for PDF rendering.
        // No HTTP callouts or session IDs — AppExchange safe.
        Blob imageBlob = null;
        String ext = 'png';
        try {
            if (src.startsWith('data:image/')) {
                // Data URI — decode to blob (for DOCX embedding)
                String base64Part = src.substringAfter(',');
                if (src.containsIgnoreCase('jpeg') || src.containsIgnoreCase('jpg')) { ext = 'jpeg'; }
                imageBlob = EncodingUtil.base64Decode(base64Part);
            }
            // For Salesforce URLs (servlet, sfc, https), store URL for PDF rendering.
            // Blob.toPdf() resolves Salesforce URLs natively via the VF engine.
            if (src.containsIgnoreCase('.jpg') || src.containsIgnoreCase('.jpeg')) { ext = 'jpeg'; }
        } catch (Exception e) {
            // Intentionally swallowed — image source parsing failed, fall through to URL handling
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
        }

        // Rich Text Field images come back as /servlet/rtaImage?...&refid=<id>.
        // The refid varies: ContentDocument ID (069...) for File-based RTAs, or
        // ContentVersion ID (068...) for some legacy/embedded forms. Try both.
        // Then rewrite src to the /sfc/servlet.shepherd/version/download/<cvId> form
        // that the existing image pipeline handles end-to-end. No HTTP callouts.
        if (imageBlob == null && src != null && src.containsIgnoreCase('rtaImage') && src.containsIgnoreCase('refid=')) {
            Integer refStart = src.toLowerCase().indexOf('refid=') + 6;
            Integer refEnd = src.indexOf('&', refStart);
            if (refEnd == -1) { refEnd = src.length(); }
            String refid = src.substring(refStart, refEnd);
            if (String.isNotBlank(refid) && refid.length() >= 15) {
                Id resolvedId = null;
                try { resolvedId = (Id) refid; } catch (Exception parseE) {
                    String noop = parseE.getMessage(); // NOPMD UnusedLocalVariable
                }
                if (resolvedId != null) {
                    String idPrefix = ((String) resolvedId).substring(0, 3);
                    // Server-side ZIP paths (preview generate, native PPTX) need the
                    // actual bytes for assembleZip(). Client-side parts (DOCX download/
                    // save) sets currentOutputFormat='PDF' as a heap-saving hint —
                    // we then skip VersionData and let the client fetch it via
                    // getContentVersionBase64. Same pattern as buildImageXml's
                    // {%ImageField} CV path (CLAUDE.md).
                    Boolean loadBytes = (currentOutputFormat != 'PDF');
                    List<ContentVersion> rtaCvs = new List<ContentVersion>();
                    try {
                        if (idPrefix == '068') {
                            // refid is already a ContentVersion ID
                            rtaCvs = loadBytes
                                ? [SELECT Id, FileExtension, VersionData FROM ContentVersion WHERE Id = :resolvedId WITH USER_MODE LIMIT 1]
                                : [SELECT Id, FileExtension FROM ContentVersion WHERE Id = :resolvedId WITH USER_MODE LIMIT 1];
                        } else {
                            // Treat as ContentDocument ID (069 prefix)
                            rtaCvs = loadBytes
                                ? [SELECT Id, FileExtension, VersionData FROM ContentVersion WHERE ContentDocumentId = :resolvedId AND IsLatest = true WITH USER_MODE LIMIT 1]
                                : [SELECT Id, FileExtension FROM ContentVersion WHERE ContentDocumentId = :resolvedId AND IsLatest = true WITH USER_MODE LIMIT 1];
                            // Some refid prefixes (like 0EM or 005 — embedded inline images)
                            // aren't ContentDocuments. If first lookup empty, try Id directly.
                            if (rtaCvs.isEmpty()) {
                                rtaCvs = loadBytes
                                    ? [SELECT Id, FileExtension, VersionData FROM ContentVersion WHERE Id = :resolvedId WITH USER_MODE LIMIT 1]
                                    : [SELECT Id, FileExtension FROM ContentVersion WHERE Id = :resolvedId WITH USER_MODE LIMIT 1];
                            }
                        }
                    } catch (Exception qE) {
                        String noop = qE.getMessage(); // NOPMD UnusedLocalVariable
                    }
                    if (!rtaCvs.isEmpty()) {
                        src = '/sfc/servlet.shepherd/version/download/' + rtaCvs[0].Id;
                        if (String.isNotBlank(rtaCvs[0].FileExtension)) {
                            String fext = rtaCvs[0].FileExtension.toLowerCase();
                            if (fext == 'jpg' || fext == 'jpeg') { ext = 'jpeg'; }
                            else if (fext == 'gif' || fext == 'png' || fext == 'bmp') { ext = fext; }
                        }
                        // Server-side ZIP needs the binary for assembleZip()
                        if (loadBytes && rtaCvs[0].VersionData != null) {
                            imageBlob = rtaCvs[0].VersionData;
                        }
                    }
                    // 0EM (Lightning ContentReference) inline rich text images keep
                    // their original rtaImage URL as src. PDF rendering uses it via
                    // Blob.toPdf's internal resolver. DOCX assembly detects the URL
                    // pattern client-side and routes through PDF-extract path
                    // (DocGenController.renderImageAsPdfBase64).
                }
            }
        }

        // Register image — store blob for DOCX and URL for PDF rendering.
        imageCounter++;
        String relId = 'rIdImg' + imageCounter;
        String fileName = 'docgen_image_' + imageCounter + '.' + ext;

        if (imageBlob != null) {
            Map<String, Object> imgData = new Map<String, Object>{
                'relId' => relId,
                'fileName' => fileName,
                'blob' => imageBlob
            };
            // Store source URL for PDF rendering (Blob.toPdf fetches images via URL)
            if (!src.startsWith('data:')) {
                imgData.put('url', src);
            }
            pendingImages.add(imgData);
        } else if (String.isNotBlank(src) && !src.startsWith('data:')) {
            pendingImages.add(new Map<String, Object>{
                'relId' => relId,
                'fileName' => fileName,
                'url' => src
            });
        } else {
            return null; // Can't resolve image at all
        }

        // Build DrawingML. processDrawing in the PDF renderer DEFAULTS to using
        // exact wp:extent dimensions (Word's authoritative size for both
        // template-embedded images and rich text with explicit user sizing).
        // When NEITHER width NOR height was found in the rich text (image
        // pasted with no size info), we mark the drawing with DOCGEN_AUTOSIZE
        // so processDrawing flips to max-width + width:auto — preserves the
        // image's natural aspect rather than stretching to the 4×3 default.
        Boolean noSizeInfo = (widthPx == null && heightPx == null);
        Integer widthEmu = (widthPx != null) ? (widthPx * 9525) : (288 * 12700);
        Integer heightEmu = (heightPx != null) ? (heightPx * 9525) : (216 * 12700);
        String docPrAttrs = 'id="' + imageCounter + '" name="DocGenImage' + imageCounter + '"';
        if (noSizeInfo) { docPrAttrs += ' descr="DOCGEN_AUTOSIZE"'; }

        return '<w:r><w:drawing>' +
            '<wp:inline distT="0" distB="0" distL="0" distR="0" ' +
                'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
              '<wp:extent cx="' + widthEmu + '" cy="' + heightEmu + '"/>' +
              '<wp:docPr ' + docPrAttrs + '/>' +
              '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                  '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                    '<pic:nvPicPr>' +
                      '<pic:cNvPr id="' + imageCounter + '" name="DocGenImage' + imageCounter + '"/>' +
                      '<pic:cNvPicPr/>' +
                    '</pic:nvPicPr>' +
                    '<pic:blipFill>' +
                      '<a:blip r:embed="' + relId + '" ' +
                        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>' +
                      '<a:stretch><a:fillRect/></a:stretch>' +
                    '</pic:blipFill>' +
                    '<pic:spPr>' +
                      '<a:xfrm>' +
                        '<a:off x="0" y="0"/>' +
                        '<a:ext cx="' + widthEmu + '" cy="' + heightEmu + '"/>' +
                      '</a:xfrm>' +
                      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                    '</pic:spPr>' +
                  '</pic:pic>' +
                '</a:graphicData>' +
              '</a:graphic>' +
            '</wp:inline>' +
            '</w:drawing></w:r>';
    }

    /**
     * Extracts an HTML attribute value starting at the given position (after 'attr=').
     */
    /**
     * Pulls a pixel value out of an inline style string for a given property.
     * Examples: parseStylePx('width: 200px; height: 150px', 'width') → 200.
     * Accepts 'px', 'pt' (converted to px @ 96/72), and bare numeric values.
     * Returns null if the property isn't present or value can't be parsed.
     */
    private static Integer parseStylePx(String styleVal, String propName) {
        if (String.isBlank(styleVal) || String.isBlank(propName)) { return null; }
        String lower = styleVal.toLowerCase();
        Integer pIdx = lower.indexOf(propName.toLowerCase() + ':');
        if (pIdx == -1) { return null; }
        Integer valStart = pIdx + propName.length() + 1;
        Integer valEnd = lower.indexOf(';', valStart);
        if (valEnd == -1) { valEnd = lower.length(); }
        String raw = styleVal.substring(valStart, valEnd).trim();
        if (String.isBlank(raw)) { return null; }
        // Strip unit suffix and parse number
        Boolean isPt = raw.toLowerCase().endsWith('pt');
        String numStr = raw.replaceAll('[^0-9.]', '');
        if (String.isBlank(numStr)) { return null; }
        try {
            Decimal n = Decimal.valueOf(numStr);
            if (isPt) { n = n * 96 / 72; }
            return Math.round(n);
        } catch (Exception e) {
            return null;
        }
    }

    private static String extractHtmlAttrValue(String tag, Integer startAfterEquals) {
        Integer pos = startAfterEquals;
        while (pos < tag.length() && tag.substring(pos, pos + 1) == ' ') {
            pos++;
        }
        if (pos >= tag.length()) {
            return null;
        }
        String ch = tag.substring(pos, pos + 1);
        if (ch == '"' || ch == '\'') {
            Integer end2 = tag.indexOf(ch, pos + 1);
            return end2 != -1 ? tag.substring(pos + 1, end2) : null;
        }
        // Unquoted value
        Integer end2 = pos;
        while (end2 < tag.length() && tag.substring(end2, end2 + 1) != ' ' && tag.substring(end2, end2 + 1) != '>') {
            end2++;
        }
        return tag.substring(pos, end2);
    }

    private class ImageDimensionSpec {
        Boolean isMaxConstraint;
        Integer percentValue;
        Integer pixelValue;
    }

    private class ImageRenderSpec {
        String imageField;
        String fieldValue;
        String relationshipId;
        String fileName;
        String fileExtension;
        String sourceUrl;
        String contentVersionImageUrl;
        Blob imageBlobData;

        Integer widthPx;
        Integer heightPx;
        Integer widthPercent;
        Integer heightPercent;
        Integer maxWidthPx;
        Integer maxHeightPx;
        Integer maxWidthPercent;
        Integer maxHeightPercent;
    }

    private static String buildImageXml(String fieldValue) {
        ImageRenderSpec spec = new ImageRenderSpec();
        spec.fieldValue = fieldValue;
        return buildImageXml(spec);
    }

    private static String buildImageXml(String fieldValue, Integer widthPx, Integer heightPx) {
        ImageRenderSpec spec = new ImageRenderSpec();
        spec.fieldValue = fieldValue;
        spec.widthPx = widthPx;
        spec.heightPx = heightPx;
        return buildImageXml(spec);
    }

    private static String buildImageXml(ImageRenderSpec spec) {
        if (spec == null || String.isBlank(spec.fieldValue)) {
            return null;
        }

        String ext = 'png';

        try {
            // 1. Rich text HTML containing <img> tags
            if (spec.fieldValue.containsIgnoreCase('<img')) {
                spec.imageBlobData = extractImageFromHtml(spec.fieldValue);
            }
            // 2. Base64 data URI
            else if (spec.fieldValue.startsWith('data:image/')) {
                String base64Part = spec.fieldValue.substringAfter(',');
                if (spec.fieldValue.containsIgnoreCase('jpeg') || spec.fieldValue.containsIgnoreCase('jpg')) { ext = 'jpeg'; }
                spec.imageBlobData = EncodingUtil.base64Decode(base64Part);
            }
            // 3. Raw base64 (no data URI prefix)
            else if (spec.fieldValue.length() > 100 && !spec.fieldValue.contains('/') && !spec.fieldValue.contains(' ')) {
                spec.imageBlobData = EncodingUtil.base64Decode(spec.fieldValue);
            }
            // 4. ContentVersion ID (starts with 068) — works for both DOCX (blob) and PDF (URL)
            else if (spec.fieldValue.startsWith('068') && spec.fieldValue.length() >= 15) {
                if (currentOutputFormat == 'PDF') {
                    // PDF path: only need the URL — Blob.toPdf() fetches images server-side.
                    // Skip loading the blob entirely to save heap.
                    List<ContentVersion> cvs = [SELECT Id, FileExtension FROM ContentVersion WHERE Id = :spec.fieldValue WITH USER_MODE LIMIT 1];
                    if (!cvs.isEmpty()) {
                        if (cvs[0].FileExtension != null) { ext = cvs[0].FileExtension.toLowerCase(); }
                        spec.contentVersionImageUrl = '/sfc/servlet.shepherd/version/download/' + cvs[0].Id;
                    }
                } else {
                    // DOCX path: need the blob for ZIP embedding
                    List<ContentVersion> cvs = [SELECT Id, VersionData, FileExtension FROM ContentVersion WHERE Id = :spec.fieldValue WITH USER_MODE LIMIT 1];
                    if (!cvs.isEmpty()) {
                        spec.imageBlobData = cvs[0].VersionData;
                        if (cvs[0].FileExtension != null) { ext = cvs[0].FileExtension.toLowerCase(); }
                        spec.contentVersionImageUrl = '/sfc/servlet.shepherd/version/download/' + cvs[0].Id;
                    }
                }
            }
            // 5. Salesforce file URL containing refid (rich text image reference)
            else if (spec.fieldValue.containsIgnoreCase('refid=')) {
                String refId = spec.fieldValue.substringAfterLast('refid=').substringBefore('&');
                if (String.isBlank(refId)) { refId = spec.fieldValue.substringAfterLast('refid='); }
                spec.imageBlobData = fetchSalesforceImage(refId);
            }
            // 6. Salesforce servlet/sfc URL
            else if (spec.fieldValue.containsIgnoreCase('/servlet/') || spec.fieldValue.containsIgnoreCase('/sfc/')) {
                String docId = spec.fieldValue.substringAfterLast('/');
                if (docId.contains('?')) { docId = docId.substringBefore('?'); }
                spec.imageBlobData = fetchSalesforceImage(docId);
            }
            // 7. Generic HTTPS URL — can't fetch without session ID (AppExchange safe).
            // External URL images are skipped — cannot be fetched without session ID.

            // If no blob but we have a URL, store it for PDF rendering
            spec.sourceUrl = spec.contentVersionImageUrl;
            if (spec.imageBlobData == null && spec.sourceUrl == null) {
                if (spec.fieldValue.containsIgnoreCase('<img')) {
                    Integer sIdx = spec.fieldValue.indexOfIgnoreCase('src=');
                    if (sIdx != -1) {
                        sIdx += 4;
                        while (sIdx < spec.fieldValue.length() && spec.fieldValue.substring(sIdx, sIdx + 1) == ' ') { sIdx++; }
                        String qc = spec.fieldValue.substring(sIdx, sIdx + 1);
                        if (qc == '"' || qc == '\'') {
                            sIdx++;
                            Integer sEnd = spec.fieldValue.indexOf(qc, sIdx);
                            if (sEnd != -1) { spec.sourceUrl = spec.fieldValue.substring(sIdx, sEnd).replace('&amp;', '&'); }
                        }
                    }
                } else if (spec.fieldValue.startsWithIgnoreCase('http') || spec.fieldValue.startsWith('/')) {
                    spec.sourceUrl = spec.fieldValue;
                }

                if (String.isBlank(spec.sourceUrl) || spec.sourceUrl.startsWith('data:')) {
                    return null;
                }
            }

            imageCounter++;
            spec.relationshipId = 'rIdImg' + imageCounter;
            spec.fileName = 'docgen_image_' + imageCounter + '.' + ext;
            spec.fileExtension = ext;

            // HTML template (v1.61+): emit an <img> tag with the resolved URL
            // instead of DOCX DrawingML. Blob.toPdf resolves /sfc/ relative URLs
            // natively. Data URIs can't be rendered by Blob.toPdf so blob-only
            // field values (without a resolvable URL) skip to avoid broken img.
            if (currentTemplateType == 'HTML') {
                String imgUrl = (spec.contentVersionImageUrl != null)
                    ? spec.contentVersionImageUrl
                    : spec.sourceUrl;
                if (String.isBlank(imgUrl) || imgUrl.startsWith('data:')) {
                    return '';
                }
                String sizeCss = '';
                if (spec.widthPx != null) { sizeCss += 'width:' + spec.widthPx + 'px;'; }
                if (spec.heightPx != null) { sizeCss += 'height:' + spec.heightPx + 'px;'; }
                if (String.isBlank(sizeCss)) { sizeCss = 'max-width:100%;'; }
                return '<img src="' + imgUrl.escapeHtml4() + '" style="' + sizeCss + '"/>';
            }

            // Register image — blob for DOCX, URL for PDF
            Map<String, Object> imgEntry = new Map<String, Object>{
                'relId' => spec.relationshipId,
                'fileName' => spec.fileName
            };
            if (spec.imageBlobData != null) {
                imgEntry.put('blob', spec.imageBlobData);
            }
            if (spec.contentVersionImageUrl != null) {
                imgEntry.put('url', spec.contentVersionImageUrl);
            } else if (spec.sourceUrl != null) {
                imgEntry.put('url', spec.sourceUrl);
            }
            pendingImages.add(imgEntry);

            // Compute image dimensions in EMU with intrinsic size detection and scaling
            List<Integer> intrinsicSizeEmu = getImageDimensionsInEmu(spec.imageBlobData, ext);
            Integer baseWidthEmu = (intrinsicSizeEmu != null && intrinsicSizeEmu.size() == 2) ? intrinsicSizeEmu[0] : (288 * 12700);
            Integer baseHeightEmu = (intrinsicSizeEmu != null && intrinsicSizeEmu.size() == 2) ? intrinsicSizeEmu[1] : (216 * 12700);

            Integer[] scaledDims = scaleImageDimensionsEmu(baseWidthEmu, baseHeightEmu, spec);
            Integer widthEmu = scaledDims[0];
            Integer heightEmu = scaledDims[1];

            return '</w:t></w:r>' +
                '<w:r><w:drawing>' +
                '<wp:inline distT="0" distB="0" distL="0" distR="0" ' +
                    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                  '<wp:extent cx="' + widthEmu + '" cy="' + heightEmu + '"/>' +
                  '<wp:docPr id="' + imageCounter + '" name="DocGenImage' + imageCounter + '"/>' +
                  '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                      '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                        '<pic:nvPicPr>' +
                          '<pic:cNvPr id="' + imageCounter + '" name="DocGenImage' + imageCounter + '"/>' +
                          '<pic:cNvPicPr/>' +
                        '</pic:nvPicPr>' +
                        '<pic:blipFill>' +
                          '<a:blip r:embed="' + spec.relationshipId + '" ' +
                            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>' +
                          '<a:stretch><a:fillRect/></a:stretch>' +
                        '</pic:blipFill>' +
                        '<pic:spPr>' +
                          '<a:xfrm>' +
                            '<a:off x="0" y="0"/>' +
                            '<a:ext cx="' + widthEmu + '" cy="' + heightEmu + '"/>' +
                          '</a:xfrm>' +
                          '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                        '</pic:spPr>' +
                      '</pic:pic>' +
                    '</a:graphicData>' +
                  '</a:graphic>' +
                '</wp:inline>' +
                '</w:drawing></w:r><w:r><w:t xml:space="preserve">';

        } catch (Exception e) {
            // Image injection failed (invalid CV ID, corrupt base64, etc.) — skip this image
            return null;
        }
    }

    /**
     * Resolves a {%Image:N} or {%Image:N:SIZE} tag.
     * Queries ContentDocumentLink for images attached to the current record,
     * picks the Nth oldest, and returns an ImageRenderSpec ready for buildImageXml.
     * Returns null silently if the record has fewer than N images (empty render).
     *
     * Size grammar (SIZE segment, optional):
     *   "200"     → max dimension, preserves aspect
     *   "200x200" → explicit width × height
     *   "200x"    → width only, auto height
     *   "x200"    → auto width, height only
     */
    @TestVisible
    private static ImageRenderSpec resolveImageByIndexTag(String imageTagSpec, Map<String, Object> data) {
        if (String.isBlank(imageTagSpec)) return null;
        List<String> parts = imageTagSpec.split(':');
        if (parts.size() < 2) return null;
        String indexToken = parts[1].trim();
        if (!indexToken.isNumeric()) return null;
        Integer n = Integer.valueOf(indexToken);
        if (n < 1) return null;

        Object recordIdVal = data != null ? data.get('Id') : null;
        if (recordIdVal == null) return null;
        Id recordId;
        try { recordId = Id.valueOf(String.valueOf(recordIdVal)); } catch (Exception e) { return null; }

        String cvId = resolveImageCvIdByIndex(n, recordId);
        if (String.isBlank(cvId)) return null;

        ImageRenderSpec spec = new ImageRenderSpec();
        spec.imageField = 'Image:' + n;
        spec.fieldValue = cvId;

        if (parts.size() >= 3) {
            applyImageSizeToken(spec, parts[2].trim());
        }
        return spec;
    }

    /**
     * Resolves the Nth ContentVersion ID from the per-transaction cache,
     * or falls back to a single-record SOQL query if the record isn't cached.
     * Returns null if the record has fewer than N image attachments.
     */
    @TestVisible
    private static String resolveImageCvIdByIndex(Integer n, Id recordId) {
        if (n == null || n < 1 || recordId == null) return null;

        if (imageCvCache != null && imageCvCache.containsKey(recordId)) {
            List<String> cached = imageCvCache.get(recordId);
            if (cached == null || cached.size() < n) return null;
            return cached[n - 1];
        }

        Set<String> imageExts = new Set<String>{'png','jpg','jpeg','gif','bmp','tif','tiff','svg'};
        List<ContentDocumentLink> cdls = [
            SELECT ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
              AND ContentDocument.FileExtension IN :imageExts
            WITH USER_MODE
            ORDER BY ContentDocument.CreatedDate ASC, ContentDocument.Id ASC
            LIMIT 50
        ];
        if (cdls.size() < n) return null;
        return String.valueOf(cdls[n - 1].ContentDocument.LatestPublishedVersionId);
    }

    /**
     * Bulk-fetches attached image CVs for a set of record Ids in ONE SOQL query
     * and caches the results keyed by LinkedEntityId. Called before a loop body
     * that contains {%Image:N} tags, so per-iteration resolution is O(1).
     *
     * ContentDocumentLink polymorphic-IN restriction: all IDs must be the same
     * sObject type. Callers enforce this by passing iteration IDs from a single
     * {#Relationship} loop, which always yields one type per loop.
     */
    @TestVisible
    private static void prefetchImagesForIds(Set<Id> recordIds) {
        if (recordIds == null || recordIds.isEmpty()) return;
        if (imageCvCache == null) imageCvCache = new Map<Id, List<String>>();

        Set<Id> toFetch = new Set<Id>();
        for (Id rid : recordIds) {
            if (rid != null && !imageCvCache.containsKey(rid)) toFetch.add(rid);
        }
        if (toFetch.isEmpty()) return;

        // Seed cache with empty lists so records with zero images don't re-query on cache miss
        for (Id rid : toFetch) {
            imageCvCache.put(rid, new List<String>());
        }

        Set<String> imageExts = new Set<String>{'png','jpg','jpeg','gif','bmp','tif','tiff','svg'};
        List<ContentDocumentLink> cdls = [
            SELECT LinkedEntityId, ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :toFetch
              AND ContentDocument.FileExtension IN :imageExts
            WITH USER_MODE
            ORDER BY ContentDocument.CreatedDate ASC, ContentDocument.Id ASC
        ];
        for (ContentDocumentLink cdl : cdls) {
            List<String> bucket = imageCvCache.get(cdl.LinkedEntityId);
            if (bucket != null) {
                bucket.add(String.valueOf(cdl.ContentDocument.LatestPublishedVersionId));
            }
        }
    }

    /**
     * Returns true if the given XML contains a {%Image:...} tag — used to decide
     * whether to pre-fetch attachments for an upcoming loop body.
     */
    @TestVisible
    private static Boolean loopBodyHasImageTag(String innerXml) {
        if (String.isBlank(innerXml)) return false;
        String lower = innerXml.toLowerCase();
        return lower.contains('{%image:');
    }

    /**
     * Applies {%Image:N:SIZE} size token to an ImageRenderSpec.
     *   single number   → max dimension (preserves aspect)
     *   WxH             → explicit width × height
     *   Wx              → width only, auto height
     *   xH              → auto width, height only
     */
    @TestVisible
    private static void applyImageSizeToken(ImageRenderSpec spec, String sizeToken) {
        if (spec == null || String.isBlank(sizeToken)) return;
        String t = sizeToken.trim().toLowerCase();
        if (!t.contains('x')) {
            if (t.isNumeric()) {
                Integer nVal = Integer.valueOf(t);
                spec.maxWidthPx = nVal;
                spec.maxHeightPx = nVal;
            }
            return;
        }
        Integer xIdx = t.indexOf('x');
        String w = t.substring(0, xIdx).trim();
        String h = t.substring(xIdx + 1).trim();
        if (!String.isBlank(w) && w.isNumeric()) {
            spec.widthPx = Integer.valueOf(w);
        }
        if (!String.isBlank(h) && h.isNumeric()) {
            spec.heightPx = Integer.valueOf(h);
        }
    }

    private static ImageRenderSpec parseImageTagSpec(String imageTagSpec) {
        ImageRenderSpec spec = new ImageRenderSpec();
        spec.imageField = imageTagSpec;
        if (String.isBlank(imageTagSpec) || !imageTagSpec.contains(':')) {
            return spec;
        }

        List<String> tagParts = imageTagSpec.split(':', 2);
        spec.imageField = tagParts[0].trim();
        String sizeToken = tagParts[1].trim().toLowerCase();
        if (!sizeToken.contains('x')) {
            return spec;
        }

        Integer separatorIndex = sizeToken.indexOf('x');
        if (separatorIndex < 0) {
            return spec;
        }
        String widthToken = sizeToken.substring(0, separatorIndex).trim();
        String heightToken = sizeToken.substring(separatorIndex + 1).trim();

        ImageDimensionSpec widthSpec = parseImageDimensionSpec(widthToken);
        ImageDimensionSpec heightSpec = parseImageDimensionSpec(heightToken);
        if (widthSpec != null) {
            if (widthSpec.isMaxConstraint) {
                spec.maxWidthPx = widthSpec.pixelValue;
                spec.maxWidthPercent = widthSpec.percentValue;
            } else {
                spec.widthPx = widthSpec.pixelValue;
                spec.widthPercent = widthSpec.percentValue;
            }
        }
        if (heightSpec != null) {
            if (heightSpec.isMaxConstraint) {
                spec.maxHeightPx = heightSpec.pixelValue;
                spec.maxHeightPercent = heightSpec.percentValue;
            } else {
                spec.heightPx = heightSpec.pixelValue;
                spec.heightPercent = heightSpec.percentValue;
            }
        }
        return spec;
    }

    private static ImageDimensionSpec parseImageDimensionSpec(String rawToken) {
        if (String.isBlank(rawToken)) {
            return null;
        }
        String token = rawToken.trim().toLowerCase();
        Boolean isMax = token.startsWith('m');
        if (isMax) {
            token = token.substring(1).trim();
        }
        if (String.isBlank(token)) {
            return null;
        }

        Integer percentValue = null;
        Integer pixelValue = null;
        if (token.endsWith('%')) {
            String num = token.substring(0, token.length() - 1).trim();
            if (num.isNumeric()) {
                percentValue = Integer.valueOf(num);
            }
        } else if (token.endsWith('px')) {
            String num = token.substring(0, token.length() - 2).trim();
            if (num.isNumeric()) {
                pixelValue = Integer.valueOf(num);
            }
        } else if (token.isNumeric()) {
            pixelValue = Integer.valueOf(token);
        }

        if (percentValue == null && pixelValue == null) {
            return null;
        }
        ImageDimensionSpec dimSpec = new ImageDimensionSpec();
        dimSpec.isMaxConstraint = isMax;
        dimSpec.percentValue = percentValue;
        dimSpec.pixelValue = pixelValue;
        return dimSpec;
    }

    private static Integer parseHexToInt(String hexStr) {
        if (String.isBlank(hexStr)) {
            return 0;
        }
        String hexChars = '0123456789ABCDEF';
        Integer result = 0;
        for (Integer i = 0; i < hexStr.length(); i++) {
            Integer digit = hexChars.indexOf(hexStr.substring(i, i + 1).toUpperCase());
            if (digit < 0) {
                return 0;
            }
            result = (result * 16) + digit;
        }
        return result;
    }

    private static List<Integer> getImageDimensionsInEmu(Blob imageBlob, String fileExtension) {
        if (imageBlob == null || imageBlob.size() < 24) {
            return null;
        }
        String hex = EncodingUtil.convertToHex(imageBlob);
        if (String.isBlank(hex) || hex.length() < 64) {
            return null;
        }
        String hexUpper = hex.toUpperCase();
        String extLower = fileExtension != null ? fileExtension.toLowerCase() : '';
        Integer widthPx = null;
        Integer heightPx = null;
        try {
            Boolean looksPng = extLower == 'png' || (hexUpper.length() >= 16 && hexUpper.substring(0, 16) == '89504E470D0A1A0A');
            if (looksPng) {
                Integer ihdrIdx = hexUpper.indexOf('49484452');
                if (ihdrIdx >= 0 && ihdrIdx + 24 <= hexUpper.length()) {
                    Integer w = parseHexToInt(hexUpper.substring(ihdrIdx + 8, ihdrIdx + 16));
                    Integer h = parseHexToInt(hexUpper.substring(ihdrIdx + 16, ihdrIdx + 24));
                    if (w > 0 && h > 0) {
                        widthPx = w;
                        heightPx = h;
                    }
                }
            }
            Boolean looksJpeg = extLower == 'jpg' || extLower == 'jpeg' || (hexUpper.length() >= 4 && hexUpper.substring(0, 4) == 'FFD8');
            if ((widthPx == null || heightPx == null) && looksJpeg) {
                Integer sofIdx = hexUpper.indexOf('FFC0');
                if (sofIdx >= 0 && sofIdx + 18 <= hexUpper.length()) {
                    heightPx = parseHexToInt(hexUpper.substring(sofIdx + 10, sofIdx + 14));
                    widthPx = parseHexToInt(hexUpper.substring(sofIdx + 14, sofIdx + 18));
                }
            }
            if (widthPx == null || heightPx == null || widthPx <= 0 || heightPx <= 0) {
                return null;
            }
            Integer emuPerPx = 9525;
            return new List<Integer>{widthPx * emuPerPx, heightPx * emuPerPx};
        } catch (Exception e) {
            return null;
        }
    }

    private static Integer[] scaleImageDimensionsEmu(Integer baseWidthEmu, Integer baseHeightEmu, ImageRenderSpec spec) {
        Integer pageContentWidthEmu = 5943600; // 6.5in
        Integer pageContentHeightEmu = 8229600; // 9in

        Integer resolvedW = baseWidthEmu;
        Integer resolvedH = baseHeightEmu;

        Integer fixedW = spec.widthPx != null ? (spec.widthPx * 9525) : null;
        if (fixedW == null && spec.widthPercent != null) {
            fixedW = (pageContentWidthEmu * spec.widthPercent) / 100;
        }
        Integer fixedH = spec.heightPx != null ? (spec.heightPx * 9525) : null;
        if (fixedH == null && spec.heightPercent != null) {
            fixedH = (pageContentHeightEmu * spec.heightPercent) / 100;
        }

        if (fixedW != null && fixedW > 0 && fixedH != null && fixedH > 0) {
            resolvedW = fixedW;
            resolvedH = fixedH;
        } else if (fixedW != null && fixedW > 0 && baseWidthEmu > 0) {
            Decimal scale = ((Decimal)fixedW) / ((Decimal)baseWidthEmu);
            resolvedW = fixedW;
            resolvedH = (((Decimal)baseHeightEmu) * scale).intValue();
        } else if (fixedH != null && fixedH > 0 && baseHeightEmu > 0) {
            Decimal scale = ((Decimal)fixedH) / ((Decimal)baseHeightEmu);
            resolvedH = fixedH;
            resolvedW = (((Decimal)baseWidthEmu) * scale).intValue();
        }

        Integer maxW = spec.maxWidthPx != null ? (spec.maxWidthPx * 9525) : null;
        if (maxW == null && spec.maxWidthPercent != null) {
            maxW = (pageContentWidthEmu * spec.maxWidthPercent) / 100;
        }
        Integer maxH = spec.maxHeightPx != null ? (spec.maxHeightPx * 9525) : null;
        if (maxH == null && spec.maxHeightPercent != null) {
            maxH = (pageContentHeightEmu * spec.maxHeightPercent) / 100;
        }

        Decimal maxScale = 1;
        if (maxW != null && maxW > 0 && resolvedW > maxW && resolvedW > 0) {
            Decimal ws = ((Decimal)maxW) / ((Decimal)resolvedW);
            if (ws < maxScale) { maxScale = ws; }
        }
        if (maxH != null && maxH > 0 && resolvedH > maxH && resolvedH > 0) {
            Decimal hs = ((Decimal)maxH) / ((Decimal)resolvedH);
            if (hs < maxScale) { maxScale = hs; }
        }
        if (maxScale < 1) {
            resolvedW = (((Decimal)resolvedW) * maxScale).intValue();
            resolvedH = (((Decimal)resolvedH) * maxScale).intValue();
        }

        if (resolvedW == null || resolvedW <= 0) { resolvedW = 288 * 12700; }
        if (resolvedH == null || resolvedH <= 0) { resolvedH = 216 * 12700; }
        return new Integer[]{resolvedW, resolvedH};
    }

    /**
     * Extracts the first image from rich text HTML.
     * Handles data URIs, Salesforce servlet URLs (via session-based auth), and refid references.
     */
    private static Blob extractImageFromHtml(String html) {
        // Use string parsing instead of regex to avoid "Regex too complicated" on large base64 data
        Integer imgIdx = html.indexOfIgnoreCase('<img');
        if (imgIdx == -1) {
            return null;
        }

        Integer srcIdx = html.indexOfIgnoreCase('src=', imgIdx);
        if (srcIdx == -1) {
            return null;
        }

        srcIdx += 4; // skip 'src='
        // Skip optional whitespace
        while (srcIdx < html.length() && html.substring(srcIdx, srcIdx + 1) == ' ') {
            srcIdx++;
        }

        // Determine quote character
        String quoteChar = html.substring(srcIdx, srcIdx + 1);
        if (quoteChar != '"' && quoteChar != '\'') {
            return null;
        }
        srcIdx++; // skip opening quote

        Integer srcEnd = html.indexOf(quoteChar, srcIdx);
        if (srcEnd == -1) {
            return null;
        }

        String src = html.substring(srcIdx, srcEnd).replace('&amp;', '&');

        // Data URI — decode to blob
        if (src.startsWith('data:image/')) {
            String base64Part = src.substringAfter(',');
            return EncodingUtil.base64Decode(base64Part);
        }

        // Salesforce URLs — can't fetch without session ID (AppExchange limitation).
        // For PDF, Blob.toPdf() resolves these URLs natively via the VF engine.
        // Return null here; the caller will use the URL path for PDF rendering.
        return null;
    }

    // No session-based HTTP fetch methods — AppExchange safe.
    // Blob.toPdf() resolves Salesforce URLs natively via the VF rendering engine.

    /**
     * Fetches image blob from a Salesforce file reference (ContentDocument ID or ContentVersion ID).
     */
    private static Blob fetchSalesforceImage(String fileRef) {
        if (String.isBlank(fileRef)) {
            return null;
        }
        try {
            // Try as ContentVersion ID first
            if (fileRef.startsWith('068')) {
                List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :fileRef WITH USER_MODE LIMIT 1];
                if (!cvs.isEmpty()) {
                    return cvs[0].VersionData;
                }
            }
            // Try as ContentDocument ID
            if (fileRef.startsWith('069')) {
                List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :fileRef WITH USER_MODE LIMIT 1];
                if (!docs.isEmpty() && docs[0].LatestPublishedVersionId != null) {
                    Id latestCvId = docs[0].LatestPublishedVersionId;
                    List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :latestCvId WITH USER_MODE LIMIT 1];
                    if (!cvs.isEmpty()) {
                        return cvs[0].VersionData;
                    }
                }
            }
            // Try as a generic ID that could be linked
            if (fileRef.length() >= 15) {
                List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :fileRef WITH USER_MODE LIMIT 1];
                if (!cvs.isEmpty()) {
                    return cvs[0].VersionData;
                }
            }
        } catch (Exception e) {
            // Intentionally swallowed — image fetch failed (invalid ID, access denied)
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
        }
        return null;
    }


    private static Id saveFile(Blob fileBlob, String title, Id recordId, String format, String type) {
        String baseName = title != null ? title : 'Generated_Document';
        String ext = (type == 'PowerPoint') ? '.pptx' : '.docx';
        return saveContentVersion(fileBlob, baseName, baseName + ext, recordId);
    }

    /**
     * Saves a PDF Blob as a ContentVersion attached to the record.
     */
    private static Id savePdfFile(Blob pdfBlob, String title, Id recordId) {
        String baseName = title != null ? title : 'Generated_Document';
        return saveContentVersion(pdfBlob, baseName, baseName + '.pdf', recordId);
    }

    /**
     * Saves a Blob as a ContentVersion linked to the given record.
     * Some standard objects (e.g., Pricebook2) don't support FirstPublishLocationId.
     * In that case, insert without linking and create a ContentDocumentLink separately.
     */
    private static Id saveContentVersion(Blob fileBlob, String title, String fileName, Id recordId) {
        ContentVersion cv = new ContentVersion();
        cv.Title = title;
        cv.PathOnClient = fileName;
        cv.VersionData = fileBlob;
        cv.FirstPublishLocationId = recordId;

        Id savedCvId;
        try {
            SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
            insert cvDecision.getRecords();
            savedCvId = cvDecision.getRecords()[0].Id;
        } catch (DmlException dml) {
            // FirstPublishLocationId rejected (e.g., Pricebook2) — insert without link, then create CDL
            if (dml.getMessage().contains('FIELD_INTEGRITY_EXCEPTION') && dml.getMessage().containsIgnoreCase('FirstPublishLocationId')) {
                cv.FirstPublishLocationId = null;
                SObjectAccessDecision cvDecision2 = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
                insert cvDecision2.getRecords();
                savedCvId = cvDecision2.getRecords()[0].Id;

                Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH USER_MODE].ContentDocumentId;
                // Try to link the file to the source record — some objects (e.g. Pricebook2) don't support CDLs
                try {
                    ContentDocumentLink cdl = new ContentDocumentLink(
                        ContentDocumentId = docId,
                        LinkedEntityId = recordId,
                        ShareType = 'V',
                        Visibility = 'AllUsers'
                    );
                    SObjectAccessDecision cdlDec = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{ cdl });
                    insert cdlDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
                } catch (DmlException linkErr) {
                    // Intentionally swallowed — object may not support ContentDocumentLink
                    String noop = linkErr.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                }
                return docId;
            }
            throw dml;
        }

        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH USER_MODE].ContentDocumentId;
    }
    /**
     * Extracts an attribute value from an XML tag string.
     * E.g., extractXmlAttrValue('<Relationship Id="rId1" Target="media/image1.png"/>', 'Id') returns 'rId1'
     */
    private static String extractXmlAttrValue(String tag, String attrName) {
        String search = attrName + '="';
        Integer start = tag.indexOf(search);
        if (start == -1) {
            return null;
        }
        start += search.length();
        Integer end2 = tag.indexOf('"', start);
        if (end2 == -1) {
            return null;
        }
        return tag.substring(start, end2);
    }

    private static String generateDocTitle(String format, Map<String, Object> data) {
        if (String.isBlank(format)) {
            return null;
        }
        String result = format;
        Pattern p = Pattern.compile('\\{([^}]+)\\}');
        Matcher m = p.matcher(format);
        while(m.find()) {
            String key = m.group(1);
            Object val = resolveValue(data, key);
            if (val != null) {
                 result = result.replace('{' + key + '}', String.valueOf(val));
            } else {
                result = result.replace('{' + key + '}', '');
            }
        }
        return result;
    }

    // =========================================================================
    // Backward-compatibility stubs for removed signature classes.
    // Old orgs may still have DocGenSignatureSenderController and
    // DocGenSignatureService which reference these methods. The stubs
    // exist solely so those old classes compile during package upgrade.
    // They do nothing — signatures have been removed from DocGen.
    // =========================================================================

    /**
     * Merges a template with record data and returns intermediate XML parts + image map.
     * Used by the signature flow to pre-compute merge data and render signed PDFs.
     */
    public static Map<String, Object> mergeTemplateForSignature(Id templateId, String recordIdStr) {
        MergeResult mr = mergeTemplate(templateId, recordIdStr, null, 'PDF');

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Signature PDF generation is only supported for Word templates.');
        }

        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);

        // Prime the HTML renderer's static context so tables using Word "table styles"
        // (which reference styles.xml for borders) render with their borders, and numbered
        // lists render correctly. Side-effect priming covers sync callers that call
        // convertToHtml immediately after. Also return the XMLs in the map so async callers
        // (queueables) can re-prime right before their convertToHtml call — statics can
        // silently fail to survive intermediate calls in some async execution contexts.
        String stylesXml = null;
        String numberingXml = null;
        if (mr.processedXmlEntries != null && mr.processedXmlEntries.containsKey('word/styles.xml')) {
            stylesXml = mr.processedXmlEntries.get('word/styles.xml');
        }
        if (mr.passthroughEntries != null && mr.passthroughEntries.containsKey('word/numbering.xml')) {
            numberingXml = mr.passthroughEntries.get('word/numbering.xml').toString();
        }
        DocGenHtmlRenderer.stylesXml = stylesXml;
        DocGenHtmlRenderer.numberingXml = numberingXml;

        return new Map<String, Object>{
            'documentXml' => mr.documentXml,
            'relsXml' => mr.relsXml,
            'contentTypesXml' => mr.contentTypesXml,
            'pdfImageMap' => pdfImages,
            'docTitle' => mr.docTitle,
            'stylesXml' => stylesXml,
            'numberingXml' => numberingXml
        };
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Giant Query helpers — extract, render, and inject pre-rendered loop content
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * Extracts the loop body XML from a template for a specific relationship.
     * Returns the XML between {#relationshipName} and {/relationshipName} tags,
     * plus the surrounding context (before/after the loop) for final assembly.
     * Uses the same loop detection logic as processXml but only extracts — does not render.
     * @param templateXml The raw template XML (e.g., word/document.xml)
     * @param relationshipName The loop tag key (e.g., "Contacts", "OpportunityLineItems")
     * @return Map with keys: 'innerXml', 'beforeLoop', 'afterLoop'
     */
    public static Map<String, String> extractLoopBody(String templateXml, String relationshipName) {
        Map<String, String> result = new Map<String, String>();

        // Merge runs first so we find complete tags
        String xml = mergeRunsInTags(templateXml);

        // Find the opening tag {#relationshipName}
        String openTag = '{#' + relationshipName + '}';
        Integer openIdx = xml.indexOf(openTag);
        if (openIdx == -1) {
            // Try with whitespace variations
            Pattern openPattern = Pattern.compile('\\{\\s*#\\s*' + Pattern.quote(relationshipName) + '\\s*\\}');
            Matcher openMatcher = openPattern.matcher(xml);
            if (openMatcher.find()) {
                openIdx = openMatcher.start();
                openTag = openMatcher.group();
            } else {
                return null;
            }
        }

        Integer contentStart = openIdx + openTag.length();
        Integer sectionEnd = findBalancedEnd(xml, contentStart, relationshipName);
        if (sectionEnd == -1) {
            return null;
        }

        Integer closeTagEnd = xml.indexOf('}', sectionEnd) + 1;

        // Determine container boundaries (same logic as processXml — expand to
        // the nearest valid row/list-item container if applicable). Checks both
        // DOCX <w:tr> and HTML <tr>/<li> containers; whichever is closer and
        // encloses the full {#Rel}...{/Rel} section wins. Safe for both
        // template types because DOCX XML doesn't contain literal <tr>/<li>
        // and HTML doesn't contain <w:tr>.
        Integer containerStart = openIdx;
        Integer containerEnd = closeTagEnd;

        // DOCX <w:tr>
        Integer wTrStart = lastIndexOfTagStart(xml, 'w:tr', openIdx);
        if (wTrStart != -1) {
            Integer wTrEnd = xml.indexOf('</w:tr>', wTrStart);
            Boolean closedBeforeOpen = xml.substring(wTrStart, openIdx).contains('</w:tr>');
            if (!closedBeforeOpen && wTrEnd != -1 && wTrEnd >= closeTagEnd) {
                containerStart = wTrStart;
                containerEnd = wTrEnd + 7; // </w:tr>
            }
        }

        // HTML <tr>
        Integer htmlTrStart = lastIndexOfTagStart(xml, 'tr', openIdx);
        if (htmlTrStart != -1) {
            Integer htmlTrEnd = xml.indexOf('</tr>', htmlTrStart);
            Boolean closedBeforeOpen = xml.substring(htmlTrStart, openIdx).contains('</tr>');
            if (!closedBeforeOpen && htmlTrEnd != -1 && htmlTrEnd >= closeTagEnd) {
                if (containerStart == openIdx || htmlTrStart > containerStart) {
                    containerStart = htmlTrStart;
                    containerEnd = htmlTrEnd + 5; // </tr>
                }
            }
        }

        // HTML <li>
        Integer htmlLiStart = lastIndexOfTagStart(xml, 'li', openIdx);
        if (htmlLiStart != -1) {
            Integer htmlLiEnd = xml.indexOf('</li>', htmlLiStart);
            Boolean closedBeforeOpen = xml.substring(htmlLiStart, openIdx).contains('</li>');
            if (!closedBeforeOpen && htmlLiEnd != -1 && htmlLiEnd >= closeTagEnd) {
                if (containerStart == openIdx || htmlLiStart > containerStart) {
                    containerStart = htmlLiStart;
                    containerEnd = htmlLiEnd + 5; // </li>
                }
            }
        }

        // Build inner XML (container content minus the open/close tags)
        String innerXml = xml.substring(containerStart, containerEnd);
        innerXml = innerXml.replace(openTag, '');
        String closeTag = xml.substring(sectionEnd, closeTagEnd);
        innerXml = innerXml.replace(closeTag, '');

        result.put('innerXml', innerXml);
        result.put('beforeLoop', xml.substring(0, containerStart));
        result.put('afterLoop', xml.substring(containerEnd));

        return result;
    }

    /**
     * Renders the loop body XML for a list of child records.
     * Each record gets its merge tags replaced via processXml, producing repeated content.
     * @param innerXml The loop body template XML (one iteration)
     * @param relationshipName The relationship name (used for context)
     * @param records List of SObject child records to render
     * @param fieldNames List of field API names to include in the data map
     * @return Concatenated rendered XML for all records
     */
    public static String renderLoopBodyForRecords(String innerXml, String relationshipName, List<SObject> records, List<String> fieldNames) {
        String rendered = '';
        for (SObject rec : records) {
            Map<String, Object> dataMap = new Map<String, Object>();
            for (String field : fieldNames) {
                try {
                    // Handle parent fields (e.g., Product2.Name) — store as nested map
                    // so resolveValue() can traverse: dataMap['Product2']['Name']
                    if (field.contains('.')) {
                        List<String> parts = field.split('\\.');
                        SObject current = rec;
                        for (Integer i = 0; i < parts.size() - 1; i++) {
                            current = current.getSObject(parts[i]);
                            if (current == null) { break; }
                        }
                        Object val = (current != null) ? current.get(parts[parts.size() - 1]) : null;
                        // Build nested map structure for resolveValue traversal
                        Map<String, Object> nested = dataMap;
                        for (Integer i = 0; i < parts.size() - 1; i++) {
                            if (!nested.containsKey(parts[i])) {
                                nested.put(parts[i], new Map<String, Object>());
                            }
                            nested = (Map<String, Object>) nested.get(parts[i]);
                        }
                        nested.put(parts[parts.size() - 1], val);
                    } else {
                        dataMap.put(field, rec.get(field));
                    }
                } catch (Exception e) {
                    dataMap.put(field, null);
                }
            }
            rendered += processXml(innerXml, dataMap);
        }
        return rendered;
    }

    /**
     * Merges a template but injects pre-rendered content for specified relationships
     * instead of processing the loop normally. The pre-rendered content replaces the
     * entire loop section (including container) for each specified relationship.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID for parent-level merge tags
     * @param preRenderedLoops Map of relationship name to pre-rendered XML content
     * @param outputFormat The desired output format ('PDF' or 'Native')
     * @return ContentDocumentId of the saved document
     */
    public static Id mergeTemplateWithPreRenderedLoops(Id templateId, Id recordId, Map<String, String> preRenderedLoops, String outputFormat) {
        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        Map<String, Object> dataMap;
        try {
            dataMap = DocGenController.generateDocumentData(templateId, recordId);
        } catch (Exception e) {
            throw new DocGenException('Error retrieving template data: ' + e.getMessage());
        }

        String base64File = (String) dataMap.get('templateFile');
        Object dataObj = dataMap.get('data');
        String templateType = (String) dataMap.get('templateType');
        String titleFormat = (String) dataMap.get('titleFormat');

        if (base64File == null) {
            throw new DocGenException('Template file content is missing.');
        }

        Map<String, Object> recordDataMap;
        if (dataObj instanceof Map<String, Object>) {
            recordDataMap = (Map<String, Object>) dataObj;
        } else if (dataObj instanceof SObject) {
            recordDataMap = ((SObject) dataObj).getPopulatedFieldsAsMap();
        } else {
            throw new DocGenException('Invalid data format.');
        }

        // For PDF output, use pre-decomposed path if available
        currentOutputFormat = (outputFormat == 'PDF') ? 'PDF' : 'Native';
        currentTemplateType = templateType;

        MergeResult mr = new MergeResult();
        mr.templateType = templateType;
        mr.outputFormat = outputFormat;
        mr.relsPath = 'word/_rels/document.xml.rels';
        mr.mediaPath = 'word/media/';

        // Decode template ZIP to get the raw document XML
        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);
        String rawDocumentXml = null;

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            if (name == 'word/document.xml') {
                rawDocumentXml = reader.extract(name).toString();
            } else if (name == '[Content_Types].xml') {
                mr.contentTypesXml = reader.extract(name).toString();
            } else if (name == mr.relsPath) {
                mr.relsXml = reader.extract(name).toString();
            } else {
                Boolean isProcessedXml = (name.startsWith('word/header') && name.endsWith('.xml')) ||
                                         (name.startsWith('word/footer') && name.endsWith('.xml'));
                if (isProcessedXml) {
                    String xml = mergeRunsInTags(reader.extract(name).toString());
                    xml = processXml(xml, recordDataMap);
                    mr.processedXmlEntries.put(name, xml);
                } else {
                    mr.passthroughEntries.put(name, reader.extract(name));
                }
            }
        }

        if (rawDocumentXml == null) {
            throw new DocGenException('Template does not contain word/document.xml.');
        }

        // Merge runs first, then inject pre-rendered loops before processXml
        rawDocumentXml = mergeRunsInTags(rawDocumentXml);

        // For each pre-rendered relationship, replace the loop section with pre-rendered content
        for (String relName : preRenderedLoops.keySet()) {
            Map<String, String> loopParts = extractLoopBody(rawDocumentXml, relName);
            if (loopParts != null) {
                rawDocumentXml = loopParts.get('beforeLoop') +
                    preRenderedLoops.get(relName) +
                    loopParts.get('afterLoop');
            }
        }

        // Now process remaining merge tags (parent-level fields, other loops)
        String processedXml = processXml(rawDocumentXml, recordDataMap);
        mr.documentXml = processedXml;
        mr.processedXmlEntries.put('word/document.xml', processedXml);

        // Generate document title
        mr.docTitle = generateDocTitle(titleFormat, recordDataMap);
        if (mr.docTitle == null) {
            mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
        }

        // Handle pending images
        if (!pendingImages.isEmpty()) {
            if (mr.contentTypesXml != null) {
                if (!mr.contentTypesXml.contains('Extension="png"')) {
                    mr.contentTypesXml = mr.contentTypesXml.replace('</Types>', '<Default Extension="png" ContentType="image/png"/></Types>');
                }
                if (!mr.contentTypesXml.contains('Extension="jpeg"') && !mr.contentTypesXml.contains('Extension="jpg"')) {
                    mr.contentTypesXml = mr.contentTypesXml.replace('</Types>', '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>');
                }
            }
            if (mr.relsXml != null) {
                for (Map<String, Object> img : pendingImages) {
                    String relId = (String) img.get('relId');
                    String fName = (String) img.get('fileName');
                    String newRel = '<Relationship Id="' + relId + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + fName + '"/>';
                    mr.relsXml = mr.relsXml.replace('</Relationships>', newRel + '</Relationships>');
                }
            }
            for (Map<String, Object> img : pendingImages) {
                String relId = (String) img.get('relId');
                if (img.containsKey('blob')) {
                    mr.imageBase64ByRelId.put(relId, EncodingUtil.base64Encode((Blob) img.get('blob')));
                }
                if (img.containsKey('url')) {
                    mr.imageUrlByRelId.put(relId, (String) img.get('url'));
                }
            }
        }

        // Render to final format
        if (outputFormat == 'PDF' && templateType == 'Word') {
            Blob pdfBlob = renderPdf(mr, templateId, recordId);
            return savePdfFile(pdfBlob, mr.docTitle, recordId);
        }

        Blob resultBlob = assembleZip(mr);
        return saveFile(resultBlob, mr.docTitle, recordId, outputFormat, templateType);
    }

    /**
     * HTML template asset extraction (v1.61+).
     * Runs after an HTML-type template version is created. If the uploaded file
     * is a zip (Google Docs "Download → Web Page" format), unpacks it:
     *   - Saves each image entry as a ContentVersion linked to the version
     *     (titled docgen_html_img_<versionId>_<basename>)
     *   - Rewrites <img src="..."> references in the HTML to point at the
     *     saved ContentVersions' /sfc/servlet.shepherd/... relative URLs
     *   - Saves the rewritten HTML as a new ContentVersion and repoints the
     *     version's Content_Version_Id__c at it
     * For single .html uploads there is nothing to extract — the method returns.
     */
    public static void extractAndSaveHtmlTemplateAssets(Id templateId, Id versionId) {
        List<DocGen_Template__c> templates = [
            SELECT Type__c FROM DocGen_Template__c WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1
        ];
        if (templates.isEmpty() || templates[0].Type__c != 'HTML') { return; }

        List<DocGen_Template_Version__c> vers = [
            SELECT Id, Content_Version_Id__c FROM DocGen_Template_Version__c
            WHERE Id = :versionId WITH SYSTEM_MODE LIMIT 1
        ];
        if (vers.isEmpty() || String.isBlank(vers[0].Content_Version_Id__c)) { return; }
        Id sourceCvId = (Id) vers[0].Content_Version_Id__c;

        List<ContentVersion> cvs = [
            SELECT VersionData, FileExtension, Title FROM ContentVersion
            WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1
        ];
        if (cvs.isEmpty()) { return; }
        String ext = cvs[0].FileExtension == null ? '' : cvs[0].FileExtension.toLowerCase();
        if (ext != 'zip') { return; }  // .html/.htm uploads have no assets to extract

        Compression.ZipReader reader = new Compression.ZipReader(cvs[0].VersionData);

        String htmlEntryName = null;
        String htmlContent = null;
        Map<String, Blob> imageEntries = new Map<String, Blob>();
        Set<String> imageExts = new Set<String>{'png','jpg','jpeg','gif','bmp','tif','tiff','svg'};

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            String lower = name.toLowerCase();
            if ((lower.endsWith('.html') || lower.endsWith('.htm')) && htmlEntryName == null) {
                htmlEntryName = name;
                htmlContent = reader.extract(name).toString();
            } else {
                Integer dot = lower.lastIndexOf('.');
                if (dot > 0) {
                    String e = lower.substring(dot + 1);
                    if (imageExts.contains(e)) {
                        imageEntries.put(name, reader.extract(name));
                    }
                }
            }
        }

        if (String.isBlank(htmlContent)) {
            throw new DocGenException('HTML template zip has no .html file.');
        }

        // 1. Insert each image as a ContentVersion, collect originalPath → CV map
        List<ContentVersion> imageCvs = new List<ContentVersion>();
        Map<String, Integer> nameToIndex = new Map<String, Integer>();
        String imgPrefix = 'docgen_html_img_' + versionId + '_';
        Integer idx = 0;
        for (String name : imageEntries.keySet()) {
            String base = name.substringAfterLast('/');
            if (String.isBlank(base)) { base = name; }
            ContentVersion icv = new ContentVersion();
            icv.Title = imgPrefix + base;
            icv.PathOnClient = base;
            icv.VersionData = imageEntries.get(name);
            icv.FirstPublishLocationId = versionId;
            imageCvs.add(icv);
            nameToIndex.put(name, idx);
            idx++;
        }
        if (!imageCvs.isEmpty()) {
            insert imageCvs; // NOPMD ApexCRUDViolation — package-internal; CRUD via DocGen perm sets
        }

        // 2. Rewrite every referenced image path in the HTML to its CV URL
        String rewritten = htmlContent;
        if (!imageCvs.isEmpty()) {
            List<Id> reloadIds = new List<Id>();
            for (ContentVersion icv : imageCvs) { reloadIds.add(icv.Id); }
            Map<Id, ContentVersion> byId = new Map<Id, ContentVersion>([
                SELECT Id FROM ContentVersion WHERE Id IN :reloadIds WITH SYSTEM_MODE
            ]);
            for (String originalPath : imageEntries.keySet()) {
                Integer i = nameToIndex.get(originalPath);
                if (i == null) { continue; }
                Id cvId = imageCvs[i].Id;
                if (cvId == null) { continue; }
                String url = '/sfc/servlet.shepherd/version/download/' + cvId;
                String basePath = originalPath.substringAfterLast('/');
                // Google Docs most often writes src="images/foo.png". Replace
                // the full path first, then the bare basename as a fallback.
                rewritten = rewritten.replace('"' + originalPath + '"', '"' + url + '"');
                rewritten = rewritten.replace('\'' + originalPath + '\'', '\'' + url + '\'');
                if (String.isNotBlank(basePath) && basePath != originalPath) {
                    rewritten = rewritten.replace('"' + basePath + '"', '"' + url + '"');
                    rewritten = rewritten.replace('\'' + basePath + '\'', '\'' + url + '\'');
                }
            }
        }

        // 3. Save rewritten HTML as a new ContentVersion; repoint the version at it
        ContentVersion htmlCv = new ContentVersion();
        htmlCv.Title = 'docgen_html_body_' + versionId;
        htmlCv.PathOnClient = 'docgen_html_body_' + versionId + '.html';
        htmlCv.VersionData = Blob.valueOf(rewritten);
        htmlCv.FirstPublishLocationId = versionId;
        insert htmlCv; // NOPMD ApexCRUDViolation — package-internal; CRUD via DocGen perm sets

        DocGen_Template_Version__c upd = new DocGen_Template_Version__c(
            Id = versionId,
            Content_Version_Id__c = htmlCv.Id
        );
        update upd; // NOPMD ApexCRUDViolation — package-internal; CRUD via DocGen perm sets
    }

    // =====================================================================
    // HTML Template Pipeline (v1.61+)
    //
    // HTML-type templates are raw .html files (exported from Google Docs,
    // Notion, etc.) with merge tags. Pipeline:
    //   1. Decode base64 ContentVersion → HTML string
    //   2. Extract <body> content + preserve <style> block
    //   3. Run processXml on body + Header_Html__c + Footer_Html__c fields
    //   4. Substitute {PageNumber}/{TotalPages} → CSS counter spans
    //   5. Wrap with @page margin boxes for Flying Saucer (Blob.toPdf engine)
    //   6. Return MergeResult with full HTML in documentXml; renderPdf() sees
    //      templateType='HTML' and passes documentXml straight to Blob.toPdf.
    // =====================================================================
    private static MergeResult mergeHtmlTemplate(
        MergeResult mr,
        String base64File,
        Map<String, Object> recordDataMap,
        String headerHtml,
        String footerHtml,
        String titleFormat
    ) {
        Blob htmlBlob = EncodingUtil.base64Decode(base64File);
        String rawHtml = htmlBlob.toString();

        String sourceStyles = extractHtmlStyleBlocks(rawHtml);
        String bodyContent = extractHtmlBodyContent(rawHtml);

        String mergedBody = processXml(bodyContent, recordDataMap);
        String mergedHeader = String.isBlank(headerHtml)
            ? null
            : processXml(decodeBraceEntities(headerHtml), recordDataMap);
        String mergedFooter = String.isBlank(footerHtml)
            ? null
            : processXml(decodeBraceEntities(footerHtml), recordDataMap);

        mr.documentXml = wrapHtmlForPdf(mergedBody, sourceStyles, mergedHeader, mergedFooter);

        String title = generateDocTitle(titleFormat, recordDataMap);
        if (String.isBlank(title)) {
            Object nameVal = resolveValue(recordDataMap, 'Name');
            title = (nameVal != null) ? String.valueOf(nameVal) : 'Document';
        }
        mr.docTitle = title;
        return mr;
    }

    /**
     * Extracts and concatenates the contents of all <style> blocks from HTML source.
     * Preserves Google Docs / Notion / Word HTML class-based styling in the PDF.
     */
    public static String extractHtmlStyleBlocks(String html) {
        if (String.isBlank(html)) { return ''; }
        String result = '';
        Integer cursor = 0;
        String lower = html.toLowerCase();
        while (cursor < html.length()) {
            Integer start = lower.indexOf('<style', cursor);
            if (start == -1) { break; }
            Integer openEnd = html.indexOf('>', start);
            if (openEnd == -1) { break; }
            Integer closeStart = lower.indexOf('</style>', openEnd);
            if (closeStart == -1) { break; }
            result += html.substring(openEnd + 1, closeStart) + '\n';
            cursor = closeStart + 8;
        }
        return result;
    }

    /**
     * Returns content inside <body>...</body>, or the whole string if no body tag.
     * Handles common HTML export wrappers (<html>, <head>) from Google Docs, Notion, Word, etc.
     */
    public static String extractHtmlBodyContent(String html) {
        if (String.isBlank(html)) { return ''; }
        String lower = html.toLowerCase();
        Integer bodyOpen = lower.indexOf('<body');
        if (bodyOpen == -1) {
            Integer htmlClose = lower.indexOf('</html>');
            Integer headClose = lower.indexOf('</head>');
            Integer start = (headClose != -1) ? (html.indexOf('>', headClose) + 1) : 0;
            Integer endPos = (htmlClose != -1) ? htmlClose : html.length();
            if (start >= endPos) { return html; }
            return html.substring(start, endPos);
        }
        Integer openEnd = html.indexOf('>', bodyOpen);
        if (openEnd == -1) { return html; }
        Integer bodyClose = lower.lastIndexOf('</body>');
        if (bodyClose == -1 || bodyClose <= openEnd) {
            return html.substring(openEnd + 1);
        }
        return html.substring(openEnd + 1, bodyClose);
    }

    /**
     * No-op — retained for backward compatibility. Page-counter tokens are now
     * preserved through processXml and resolved by wrapHtmlForPdf's @page CSS.
     */
    public static String substituteHtmlPageCounters(String html) {
        return html;
    }

    /**
     * Decodes HTML-entity-encoded curly braces back to literal `{` / `}`.
     * lightning-input-rich-text (and other WYSIWYG editors) sometimes emit
     * `&#123;` / `&#125;` / `&lbrace;` / `&rbrace;` around authored merge
     * tags; processXml only matches literal braces, so un-encode before merge.
     */
    public static String decodeBraceEntities(String html) {
        if (String.isBlank(html)) { return html; }
        return html
            .replace('&#123;', '{').replace('&#x7B;', '{').replace('&#x7b;', '{').replace('&lbrace;', '{')
            .replace('&#125;', '}').replace('&#x7D;', '}').replace('&#x7d;', '}').replace('&rbrace;', '}');
    }

    /**
     * Wraps merged body + header + footer into a full HTML document for
     * Flying Saucer PDF rendering.
     *
     * Page counters ({PageNumber} / {TotalPages}) are only resolvable inside
     * @page rules, so headers/footers containing those tokens get their text
     * rendered via @page margin box `content` property with counter(page) /
     * counter(pages) calls. Side effect: inline markup (images, tables,
     * formatting) in such a header/footer is flattened to plain text, which
     * is a Flying Saucer limitation.
     *
     * Headers/footers without page counters use the CSS running element
     * pattern (position: running(name) + @page { @top-center: element(name) })
     * which preserves arbitrary HTML.
     */
    public static String wrapHtmlForPdf(String body, String sourceStyles, String header, String footer) {
        Boolean headerHasCounters = hasPageCounterTokens(header);
        Boolean footerHasCounters = hasPageCounterTokens(footer);

        String css = '@page { size: letter; margin: 1in;';
        if (String.isNotBlank(header)) {
            if (headerHasCounters) {
                css += ' @top-center { ' + buildPageMarginContentCss(header) + ' vertical-align: bottom; font-size: 9pt; color: #444; }';
            } else {
                css += ' @top-center { content: element(dgheader); vertical-align: bottom; }';
            }
        }
        if (String.isNotBlank(footer)) {
            if (footerHasCounters) {
                css += ' @bottom-center { ' + buildPageMarginContentCss(footer) + ' vertical-align: top; font-size: 9pt; color: #444; }';
            } else {
                css += ' @bottom-center { content: element(dgfooter); vertical-align: top; }';
            }
        }
        css += ' }';
        if (String.isNotBlank(header) && !headerHasCounters) {
            css += ' .docgen-running-header { position: running(dgheader); }';
        }
        if (String.isNotBlank(footer) && !footerHasCounters) {
            css += ' .docgen-running-footer { position: running(dgfooter); }';
        }
        css += ' body { font-family: Arial, Helvetica, sans-serif; font-size: 11pt; line-height: 1.4; color: #000; margin: 0; }';
        css += ' img { max-width: 100%; }';
        css += ' table { border-collapse: collapse; }';

        String html = '<html><head><meta charset="utf-8"/>';
        html += '<style>' + css + '</style>';
        if (String.isNotBlank(sourceStyles)) {
            html += '<style>' + sourceStyles + '</style>';
        }
        html += '</head><body>';
        if (String.isNotBlank(header) && !headerHasCounters) {
            html += '<div class="docgen-running-header">' + header + '</div>';
        }
        if (String.isNotBlank(footer) && !footerHasCounters) {
            html += '<div class="docgen-running-footer">' + footer + '</div>';
        }
        html += (body == null ? '' : body);
        html += '</body></html>';
        return html;
    }

    private static Boolean hasPageCounterTokens(String html) {
        if (String.isBlank(html)) { return false; }
        return html.contains('{PageNumber}') || html.contains('{TotalPages}');
    }

    /**
     * Converts a user-authored header/footer HTML fragment containing
     * {PageNumber} / {TotalPages} tokens into a Flying Saucer @page margin
     * box `content` property value.
     *
     * HTML tags are stripped (flattened to plain text) because @page content
     * only accepts strings + counter() functions. Tokens become counter(page)
     * / counter(pages) calls; surrounding text becomes CSS string literals.
     *
     * Example:
     *   "<div>Page {PageNumber} of {TotalPages}</div>"
     *     → content: "Page " counter(page) " of " counter(pages);
     */
    private static String buildPageMarginContentCss(String html) {
        String text = html == null ? '' : decodeBraceEntities(html).replaceAll('<[^>]+>', '');
        text = text.replace('&nbsp;', ' ')
                   .replace('&amp;', '&')
                   .replace('&lt;', '<')
                   .replace('&gt;', '>')
                   .replace('&quot;', '"')
                   .replace('&#39;', '\'');

        List<String> parts = new List<String>();
        Integer cursor = 0;
        while (cursor < text.length()) {
            Integer pnIdx = text.indexOf('{PageNumber}', cursor);
            Integer tpIdx = text.indexOf('{TotalPages}', cursor);

            Integer next = -1;
            String counterFn = null;
            if (pnIdx != -1 && (tpIdx == -1 || pnIdx < tpIdx)) {
                next = pnIdx;
                counterFn = 'counter(page)';
            } else if (tpIdx != -1) {
                next = tpIdx;
                counterFn = 'counter(pages)';
            }

            if (next == -1) {
                if (cursor < text.length()) {
                    parts.add('"' + escapeForCssString(text.substring(cursor)) + '"');
                }
                break;
            }
            if (next > cursor) {
                parts.add('"' + escapeForCssString(text.substring(cursor, next)) + '"');
            }
            parts.add(counterFn);
            cursor = next + 12; // both tokens are 12 chars ({PageNumber}, {TotalPages})
        }
        if (parts.isEmpty()) { parts.add('""'); }
        return 'content: ' + String.join(parts, ' ') + ';';
    }

    private static String escapeForCssString(String s) {
        return s.replace('\\', '\\\\').replace('"', '\\"');
    }
}