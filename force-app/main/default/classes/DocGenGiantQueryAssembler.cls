/**
 * Queueable that progressively assembles Giant Query PDF fragments.
 * Chains to itself, each pass loading the previous accumulated HTML + next
 * batch of fragments. Final pass wraps in HTML and calls Blob.toPdf().
 * Peak heap stays under 12MB even for 10K+ rows.
 */
public with sharing class DocGenGiantQueryAssembler implements Queueable {

    private static final Integer FRAGS_PER_PASS = 50; // ~1.15MB per pass
    private static final Integer ROWS_PER_PDF_CHUNK = 2000; // Max rows per Blob.toPdf() call

    private Id jobId;
    private Id templateId;
    private Id recordId;
    private String giantRelationshipName;

    public DocGenGiantQueryAssembler(Id jobId, Id templateId, Id recordId, String giantRelationshipName) {
        this.jobId = jobId;
        this.templateId = templateId;
        this.recordId = recordId;
        this.giantRelationshipName = giantRelationshipName;
    }

    public void execute(QueueableContext ctx) {
        try {
            // Load ALL fragments in one pass — no Queueable chaining needed.
            // 28K rows × ~5KB/frag = ~2.8MB, well within 12MB Queueable heap.
            // Chaining was limited to 5 depth on some orgs, causing stack overflow.
            String prefix = 'docgen_giant_' + jobId + '_';
            String finalExclude = prefix + 'final';
            String partExclude = prefix + 'part_%';

            String allRows = '';
            Set<Id> fragDocIds = new Set<Id>();

            List<ContentVersion> frags = [
                SELECT Title, VersionData, ContentDocumentId FROM ContentVersion
                WHERE Title LIKE :(prefix + '%')
                AND Title != :finalExclude
                AND (NOT Title LIKE :partExclude)
                ORDER BY Title
                LIMIT 10000 // NOPMD — need all fragments for assembly
            ];

            for (ContentVersion cv : frags) {
                allRows += cv.VersionData.toString();
                fragDocIds.add(cv.ContentDocumentId);
            }
            frags = null;

            // Render final PDF
            renderFinalPdf(allRows, null);
            allRows = null;

            // Clean up fragments
            if (!fragDocIds.isEmpty() && Schema.sObjectType.ContentDocument.isDeletable()) {
                delete [SELECT Id FROM ContentDocument WHERE Id IN :fragDocIds]; // NOPMD ApexCRUDViolation — CRUD checked above
            }

        } catch (Exception e) {
            SObjectAccessDecision failDec = Security.stripInaccessible(AccessType.UPDATABLE, new List<DocGen_Job__c>{ new DocGen_Job__c(Id = jobId, Status__c = 'Failed', Label__c = e.getMessage().left(255)) });
            update failDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
        }
    }

    /**
     * Final pass: wraps accumulated rows in a complete document and renders PDF.
     * For large datasets (>2000 rows), splits into multiple Blob.toPdf() calls
     * to avoid Flying Saucer's "Maximum stack depth" error. Each chunk renders
     * as a separate PDF part; the client merges them via docGenPdfMerger.js.
     */
    private void renderFinalPdf(String allRows, Id accumDocId) {
        // Clean up the accumulation CV
        if (accumDocId != null && Schema.sObjectType.ContentDocument.isDeletable()) {
            delete new ContentDocument(Id = accumDocId); // NOPMD ApexCRUDViolation — CRUD checked above
        }

        if (String.isBlank(allRows)) {
            SObjectAccessDecision noDataDec = Security.stripInaccessible(AccessType.UPDATABLE, new List<DocGen_Job__c>{ new DocGen_Job__c(Id = jobId, Status__c = 'Failed', Label__c = 'No data to render') });
            update noDataDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
            return;
        }

        // Build the HTML wrapper (template + CSS + parent merge tags)
        String htmlTemplate = buildHtmlTemplate();

        // Split rows into chunks — each chunk gets its own Blob.toPdf() call
        List<String> rowChunks = splitRowsIntoChunks(allRows, ROWS_PER_PDF_CHUNK);
        allRows = null;

        if (rowChunks.size() == 1) {
            // Small enough for single PDF
            String html = injectRowsIntoTemplate(htmlTemplate, rowChunks[0]);
            rowChunks = null;
            // DEBUG: save HTML for inspection before Blob.toPdf()
            ContentVersion debugCv = new ContentVersion(Title = 'docgen_giant_' + jobId + '_debug_html', PathOnClient = 'debug.html', VersionData = Blob.valueOf(html.substring(0, Math.min(100000, html.length()))), IsMajorVersion = false);
            SObjectAccessDecision dbgDec = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ debugCv });
            insert dbgDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
            Blob pdfBlob = Blob.toPdf(html);
            html = null;

            ContentVersion pdfCv = new ContentVersion(
                Title = 'docgen_giant_' + jobId + '_final',
                PathOnClient = 'docgen_giant_' + jobId + '_final.pdf',
                VersionData = pdfBlob,
                IsMajorVersion = false
            );
            SObjectAccessDecision pdfDec = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ pdfCv });
            insert pdfDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
            pdfCv.Id = pdfDec.getRecords()[0].Id;

            // Link PDF to the source record
            try {
                Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :pdfCv.Id].ContentDocumentId;
                ContentDocumentLink cdl = new ContentDocumentLink(
                    ContentDocumentId = docId,
                    LinkedEntityId = recordId,
                    ShareType = 'V'
                );
                SObjectAccessDecision cdlDec = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{ cdl });
                insert cdlDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
            } catch (Exception linkErr) {
                String noop = linkErr.getMessage(); // NOPMD EmptyCatchBlock — non-fatal
            }
        } else {
            // Multiple chunks — render each as a separate PDF part for client-side merge
            // Collect all CVs, bulk insert after loop. PDF blobs are small (~50-200KB each).
            List<ContentVersion> partCvs = new List<ContentVersion>();
            for (Integer i = 0; i < rowChunks.size(); i++) {
                String html = injectRowsIntoTemplate(htmlTemplate, rowChunks[i]);
                rowChunks[i] = null; // free memory
                // DEBUG: save first chunk's HTML for inspection
                if (i == 0) {
                    partCvs.add(new ContentVersion(Title = 'docgen_giant_' + jobId + '_debug_html', PathOnClient = 'debug.html', VersionData = Blob.valueOf(html.substring(0, Math.min(100000, html.length()))), IsMajorVersion = false));
                }
                Blob pdfBlob = Blob.toPdf(html);
                html = null;

                String seq = String.valueOf(i).leftPad(3, '0');
                partCvs.add(new ContentVersion(
                    Title = 'docgen_giant_' + jobId + '_part_' + seq,
                    PathOnClient = 'docgen_giant_' + jobId + '_part_' + seq + '.pdf',
                    VersionData = pdfBlob,
                    IsMajorVersion = false
                ));
                pdfBlob = null;

                // Heap safety valve — flush if approaching limit
                if (Limits.getHeapSize() > Limits.getLimitHeapSize() * 0.8 && !partCvs.isEmpty()) {
                    SObjectAccessDecision flushDec = Security.stripInaccessible(AccessType.CREATABLE, partCvs);
                    insert flushDec.getRecords();
                    partCvs.clear();
                }
            }
            // Bulk insert remaining
            if (!partCvs.isEmpty()) {
                SObjectAccessDecision partDec = Security.stripInaccessible(AccessType.CREATABLE, partCvs);
                insert partDec.getRecords();
            }
        }

        SObjectAccessDecision completeDec = Security.stripInaccessible(AccessType.UPDATABLE, new List<DocGen_Job__c>{ new DocGen_Job__c(Id = jobId, Status__c = 'Completed') });
        update completeDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
    }

    /**
     * Builds the HTML template wrapper with CSS and resolved parent merge tags.
     * Returns the template with a {ROWS} placeholder for row injection.
     */
    private String buildHtmlTemplate() {
        List<DocGen_Template_Version__c> vers = [
            SELECT Id FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = true
            WITH SYSTEM_MODE LIMIT 1
        ];
        String html = null;
        if (!vers.isEmpty()) {
            String htmlTitle = 'docgen_tmpl_html_' + vers[0].Id;
            List<ContentVersion> htmlCvs = [
                SELECT VersionData FROM ContentVersion
                WHERE Title = :htmlTitle WITH USER_MODE LIMIT 1
            ];
            if (!htmlCvs.isEmpty()) {
                html = htmlCvs[0].VersionData.toString();
            }
        }

        String columnCss = '';
        try {
            Map<String, Object> cfg = DocGenService.extractGiantQueryFragmentConfig(templateId, giantRelationshipName);
            columnCss = cfg.get('columnCss') != null ? (String) cfg.get('columnCss') : '';
        } catch (Exception e) { String noop = e.getMessage(); } // NOPMD EmptyCatchBlock

        if (html != null) {
            if (html.contains('</style>')) {
                html = html.replace('</style>',
                    'td { border: 0.5pt solid #ccc; padding: 3px 5px; } tr { page-break-inside: avoid; } ' +
                    columnCss + '</style>');
            }

            // Resolve parent merge tags on the template (~2KB, before row injection)
            html = resolveParentMergeTags(html);

            // Replace the loop row with a placeholder
            String openTag = '{#' + giantRelationshipName + '}';
            if (html.contains(openTag)) {
                Integer openIdx = html.indexOf(openTag);
                Integer loopTrStart = html.lastIndexOf('<tr', openIdx);
                Integer tableEnd = html.indexOf('</table>', openIdx);
                if (loopTrStart != -1 && tableEnd != -1) {
                    html = html.substring(0, loopTrStart) + '{ROWS}' + html.substring(tableEnd);
                }
            } else {
                Integer bodyEnd = html.lastIndexOf('</body>');
                html = html.substring(0, bodyEnd) +
                    '<table style="width:100%;border-collapse:collapse;">{ROWS}</table>' +
                    html.substring(bodyEnd);
            }
        } else {
            html = '<html><head><style>' +
                '@page { size: letter; margin: 0.75in; }' +
                'body { font-family: Helvetica, sans-serif; font-size: 9pt; margin: 0; }' +
                'table { width: 100%; border-collapse: collapse; }' +
                'td { border: 0.5pt solid #ccc; padding: 3px 5px; }' +
                'tr { page-break-inside: avoid; }' +
                columnCss +
                '</style></head><body><table>{ROWS}</table></body></html>';
        }
        return html;
    }

    /**
     * Injects row HTML into the template by replacing the {ROWS} placeholder.
     */
    private static String injectRowsIntoTemplate(String template, String rows) {
        return template.replace('{ROWS}', rows);
    }

    /**
     * Resolves parent merge tags in the HTML template (e.g., {Name}, {Owner.Name}).
     */
    private String resolveParentMergeTags(String html) {
        try {
            List<DocGen_Template__c> tpls = [
                SELECT Base_Object_API__c FROM DocGen_Template__c
                WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1
            ];
            if (tpls.isEmpty()) { return html; }
            String baseObj = tpls[0].Base_Object_API__c;
            Set<String> fieldNames = new Set<String>{'Name'};
            Pattern p = Pattern.compile('\\{(\\w[\\w.]*)\\}');
            Matcher m = p.matcher(html);
            while (m.find()) { fieldNames.add(m.group(1)); }
            List<String> validFields = new List<String>();
            Map<String, Schema.SObjectField> fieldMap = Schema.getGlobalDescribe().get(baseObj)?.getDescribe()?.fields?.getMap();
            if (fieldMap != null) {
                for (String fn : fieldNames) {
                    if (fn.contains('.')) {
                        // Validate parent lookup: Owner.Name → check 'ownerid' exists in field map
                        String relName = fn.substringBefore('.');
                        Boolean relFound = false;
                        for (Schema.SObjectField sof : fieldMap.values()) {
                            if (sof.getDescribe().getRelationshipName() != null &&
                                sof.getDescribe().getRelationshipName().equalsIgnoreCase(relName)) {
                                relFound = true;
                                break;
                            }
                        }
                        if (relFound) { validFields.add(fn); }
                    } else if (fieldMap.containsKey(fn.toLowerCase())) {
                        validFields.add(fn);
                    }
                }
            }
            if (!validFields.isEmpty()) {
                String soql = 'SELECT ' + String.join(validFields, ', ') + ' FROM ' + String.escapeSingleQuotes(baseObj) + ' WHERE Id = :recordId LIMIT 1';
                List<SObject> recs = Database.query(soql, AccessLevel.USER_MODE);
                if (!recs.isEmpty()) {
                    for (String fn : validFields) {
                        Object val = null;
                        try {
                            if (fn.contains('.')) {
                                List<String> parts = fn.split('\\.');
                                SObject cur = recs[0];
                                for (Integer i = 0; i < parts.size() - 1 && cur != null; i++) { cur = cur.getSObject(parts[i]); }
                                if (cur != null) { val = cur.get(parts[parts.size() - 1]); }
                            } else {
                                val = recs[0].get(fn);
                            }
                        } catch (Exception fieldErr) { String noop = fieldErr.getMessage(); } // NOPMD
                        html = html.replace('{' + fn + '}', val != null ? String.valueOf(val) : '');
                    }
                }
            }
        } catch (Exception mergeErr) {
            String noop = mergeErr.getMessage(); // NOPMD
        }
        return html;
    }

    /**
     * Splits a large block of <tr> rows into chunks for separate Blob.toPdf() calls.
     * Each chunk contains up to maxRowsPerChunk rows, split at </tr> boundaries.
     */
    private static List<String> splitRowsIntoChunks(String allRows, Integer maxRowsPerChunk) {
        List<String> chunks = new List<String>();
        if (String.isBlank(allRows)) {
            chunks.add('');
            return chunks;
        }

        final String TR_CLOSE = '</tr>';
        final Integer trCloseLen = TR_CLOSE.length();
        Integer chunkStart = 0;
        Integer rowsInChunk = 0;
        Integer scanPos = 0;

        while (scanPos < allRows.length()) {
            Integer idx = allRows.indexOf(TR_CLOSE, scanPos);
            if (idx == -1) { break; }
            rowsInChunk++;
            scanPos = idx + trCloseLen;

            if (rowsInChunk >= maxRowsPerChunk) {
                chunks.add(allRows.substring(chunkStart, scanPos));
                chunkStart = scanPos;
                rowsInChunk = 0;
            }
        }
        // Remaining rows
        if (chunkStart < allRows.length()) {
            chunks.add(allRows.substring(chunkStart));
        }
        if (chunks.isEmpty()) {
            chunks.add(allRows);
        }
        return chunks;
    }
}
