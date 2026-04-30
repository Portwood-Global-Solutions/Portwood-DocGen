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
    private String childObjectName;
    private String lookupFieldName;
    private String whereClauseOverride;
    private String colGroupHtml = '';

    public DocGenGiantQueryAssembler(Id jobId, Id templateId, Id recordId, String giantRelationshipName) {
        this(jobId, templateId, recordId, giantRelationshipName, null, null, null);
    }

    /**
     * 7-arg constructor used by DocGenGiantQueryBatch — passes child object, lookup,
     * and WHERE clause through so resolveGiantAggregateTags works regardless of whether
     * the template uses V1 flat, V2, or V3 query config format. Without these, the
     * resolver has to reparse Query_Config__c and only V3 parses cleanly as JSON.
     */
    public DocGenGiantQueryAssembler(
        Id jobId,
        Id templateId,
        Id recordId,
        String giantRelationshipName,
        String childObjectName,
        String lookupFieldName,
        String whereClauseOverride
    ) {
        this.jobId = jobId;
        this.templateId = templateId;
        this.recordId = recordId;
        this.giantRelationshipName = giantRelationshipName;
        this.childObjectName = childObjectName;
        this.lookupFieldName = lookupFieldName;
        this.whereClauseOverride = whereClauseOverride;
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
                SELECT Title, VersionData, ContentDocumentId
                FROM ContentVersion
                WHERE Title LIKE :(prefix + '%') AND Title != :finalExclude AND (NOT Title LIKE :partExclude)
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
            update new DocGen_Job__c(Id = jobId, Status__c = 'Failed', Label__c = e.getMessage().left(255)); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
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
            update new DocGen_Job__c(Id = jobId, Status__c = 'Failed', Label__c = 'No data to render'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
            return;
        }

        // Build the HTML wrapper (template + CSS + parent merge tags)
        String htmlTemplate = buildHtmlTemplate();

        // Insert </table><table> breaks every ROWS_PER_PDF_CHUNK rows to prevent
        // Flying Saucer's "Maximum stack depth" error on very large tables.
        // This keeps everything in ONE Blob.toPdf() call — no gap between chunks.
        // Prepend colgroup to rows so the first table also gets fixed column widths
        if (String.isNotBlank(this.colGroupHtml)) {
            allRows = this.colGroupHtml + allRows;
        }
        allRows = insertTableBreaks(allRows, ROWS_PER_PDF_CHUNK, this.colGroupHtml);

        String html = injectRowsIntoTemplate(htmlTemplate, allRows);
        allRows = null;
        htmlTemplate = null;

        // DEBUG: save HTML for inspection before Blob.toPdf()
        ContentVersion debugCv = new ContentVersion(
            Title = 'docgen_giant_' + jobId + '_debug_html',
            PathOnClient = 'debug.html',
            VersionData = Blob.valueOf(html.substring(0, Math.min(100000, html.length()))),
            IsMajorVersion = false
        );
        SObjectAccessDecision dbgDec = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<ContentVersion>{ debugCv }
        );
        insert dbgDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible

        Blob pdfBlob;
        try {
            pdfBlob = Blob.toPdf(html);
        } catch (Exception pdfErr) {
            // Flying Saucer stack overflow — fall back to multi-part PDF approach
            pdfBlob = null;
            renderMultiPartPdf(html, htmlTemplate);
            html = null;
            return;
        }
        html = null;

        ContentVersion pdfCv = new ContentVersion(
            Title = 'docgen_giant_' + jobId + '_final',
            PathOnClient = 'docgen_giant_' + jobId + '_final.pdf',
            VersionData = pdfBlob,
            IsMajorVersion = false
        );
        SObjectAccessDecision pdfDec = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<ContentVersion>{ pdfCv }
        );
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
            SObjectAccessDecision cdlDec = Security.stripInaccessible(
                AccessType.CREATABLE,
                new List<ContentDocumentLink>{ cdl }
            );
            insert cdlDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
        } catch (Exception linkErr) {
            String noop = linkErr.getMessage(); // NOPMD EmptyCatchBlock — non-fatal
        }

        update new DocGen_Job__c(Id = jobId, Status__c = 'Completed'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
    }

    /**
     * Builds the HTML template wrapper with CSS and resolved parent merge tags.
     * Returns the template with a {ROWS} placeholder for row injection.
     *
     * Two paths:
     *   - DOCX templates: read the pre-baked `docgen_tmpl_html_<versionId>` CV
     *     (built at version-save time by DocGenHtmlRenderer.convertToHtml), inject
     *     column CSS derived from <w:tblGrid>, resolve parent/aggregate tags,
     *     replace the loop <tr> with {ROWS}.
     *   - HTML templates (v1.61+): read the active version's body CV directly,
     *     resolve parent/aggregate tags, replace the loop <tr>/<li> with {ROWS},
     *     then wrap with @page margin boxes + header/footer/page counters via
     *     DocGenService.wrapHtmlForPdf.
     */
    private String buildHtmlTemplate() {
        // Route HTML-type templates to their own path — simpler, no DOCX-specific
        // column-CSS extraction or <w:tblGrid> parsing.
        List<DocGen_Template__c> tpls = [
            SELECT Type__c, Header_Html__c, Footer_Html__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!tpls.isEmpty() && tpls[0].Type__c == 'HTML') {
            return buildHtmlTemplateForHtmlType(tpls[0].Header_Html__c, tpls[0].Footer_Html__c);
        }

        List<DocGen_Template_Version__c> vers = [
            SELECT Id
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        String html = null;
        if (!vers.isEmpty()) {
            String htmlTitle = 'docgen_tmpl_html_' + vers[0].Id;
            List<ContentVersion> htmlCvs = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Title = :htmlTitle
                WITH USER_MODE
                LIMIT 1
            ];
            if (!htmlCvs.isEmpty()) {
                html = htmlCvs[0].VersionData.toString();
            }
        }

        String columnCss = '';
        try {
            Map<String, Object> cfg = DocGenService.extractGiantQueryFragmentConfig(templateId, giantRelationshipName);
            columnCss = cfg.get('columnCss') != null ? (String) cfg.get('columnCss') : '';
            // Parse column widths from the template's <w:tblGrid>
            String tblPropsXml = cfg.get('tablePropertiesXml') != null ? (String) cfg.get('tablePropertiesXml') : '';
            if (tblPropsXml.contains('<w:tblGrid')) {
                this.colGroupHtml = buildColGroupFromTblGrid(tblPropsXml);
            }
        } catch (Exception e) {
            String noop = e.getMessage();
        } // NOPMD EmptyCatchBlock

        if (html != null) {
            if (html.contains('</style>')) {
                html = html.replace(
                    '</style>',
                    'table { table-layout: fixed; } td, th { border: 0.5pt solid #ccc; padding: 3px 5px; } th { background-color: #f0f0f0; font-weight: bold; } tr { page-break-inside: avoid; } ' +
                        columnCss +
                        '</style>'
                );
            }

            // Resolve parent merge tags on the template (~2KB, before row injection)
            html = resolveParentMergeTags(html);

            // Resolve grand-total aggregate tags ({SUM:Rel.Field}, {COUNT:Rel}, etc.)
            // via a single SOQL aggregate query — works for datasets of any size.
            html = resolveGiantAggregateTags(html);

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
                html =
                    html.substring(0, bodyEnd) +
                    '<table style="width:100%;border-collapse:collapse;">{ROWS}</table>' +
                    html.substring(bodyEnd);
            }
        } else {
            // Build a header row from the query config field names
            String headerRow = buildHeaderRowFromConfig();
            html =
                '<html><head><style>' +
                '@page { size: letter; margin: 0.75in; }' +
                'body { font-family: Helvetica, sans-serif; font-size: 9pt; margin: 0; }' +
                'table { width: 100%; border-collapse: collapse; table-layout: fixed; }' +
                'td, th { border: 0.5pt solid #ccc; padding: 3px 5px; }' +
                'th { background-color: #f0f0f0; font-weight: bold; }' +
                'tr { page-break-inside: avoid; }' +
                columnCss +
                '</style></head><body><table>' +
                headerRow +
                '{ROWS}</table></body></html>';
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
     * HTML-type template shell builder. Reads the active version's body CV
     * (already rewritten with /sfc/ image URLs at upload time), resolves
     * parent + aggregate merge tags, inserts a {ROWS} placeholder at the
     * giant-loop boundary, and wraps with the PDF shell (page margin boxes,
     * running header/footer with page counters). Output has the same shape
     * the DOCX path emits: a full HTML doc with {ROWS} ready for row injection.
     */
    private String buildHtmlTemplateForHtmlType(String headerHtml, String footerHtml) {
        List<DocGen_Template_Version__c> vers = [
            SELECT Id, Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (vers.isEmpty() || String.isBlank(vers[0].Content_Version_Id__c)) {
            throw new DocGenException('HTML template has no active version body.');
        }
        Id bodyCvId = (Id) vers[0].Content_Version_Id__c;
        List<ContentVersion> cvs = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :bodyCvId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (cvs.isEmpty()) {
            throw new DocGenException('HTML template body ContentVersion not found.');
        }
        String rawHtml = cvs[0].VersionData.toString();

        String sourceStyles = DocGenService.extractHtmlStyleBlocks(rawHtml);
        String bodyContent = DocGenService.extractHtmlBodyContent(rawHtml);

        // Resolve parent-level merge tags (outside the loop) and grand-total
        // aggregate tags. Both operate as regex/string replace on HTML —
        // same implementation works for HTML-type templates.
        bodyContent = resolveParentMergeTags(bodyContent);
        bodyContent = resolveGiantAggregateTags(bodyContent);

        // Replace the giant-loop <tr>…</tr> (or <li>…</li>) section with a
        // {ROWS} placeholder. Same boundary logic the DOCX path uses — find
        // the nearest opening tag before {#Rel} and the next closing container.
        String openTag = '{#' + giantRelationshipName + '}';
        if (bodyContent.contains(openTag)) {
            Integer openIdx = bodyContent.indexOf(openTag);
            Integer trStart = bodyContent.lastIndexOf('<tr', openIdx);
            Integer tableEnd = bodyContent.indexOf('</table>', openIdx);
            Integer liStart = bodyContent.lastIndexOf('<li', openIdx);
            Integer listEnd = -1;
            Integer ulEnd = bodyContent.indexOf('</ul>', openIdx);
            Integer olEnd = bodyContent.indexOf('</ol>', openIdx);
            if (ulEnd != -1 && olEnd != -1) {
                listEnd = Math.min(ulEnd, olEnd);
            } else if (ulEnd != -1) {
                listEnd = ulEnd;
            } else if (olEnd != -1) {
                listEnd = olEnd;
            }

            // Prefer the innermost (closest to openTag) container
            Boolean useTable = (trStart != -1 && tableEnd != -1 && (liStart == -1 || trStart > liStart));
            Boolean useList = (liStart != -1 && listEnd != -1 && (trStart == -1 || liStart > trStart));

            if (useTable) {
                bodyContent = bodyContent.substring(0, trStart) + '{ROWS}' + bodyContent.substring(tableEnd);
            } else if (useList) {
                bodyContent = bodyContent.substring(0, liStart) + '{ROWS}' + bodyContent.substring(listEnd);
            } else {
                // No recognisable container — fall back to replacing the
                // `{#Rel}…{/Rel}` section with {ROWS} directly. The loop body
                // already got rendered per-record into fragments; the shell
                // just needs a drop-in point.
                Integer closeIdx = bodyContent.indexOf('{/' + giantRelationshipName + '}');
                if (closeIdx != -1) {
                    Integer closeEnd = bodyContent.indexOf('}', closeIdx) + 1;
                    bodyContent = bodyContent.substring(0, openIdx) + '{ROWS}' + bodyContent.substring(closeEnd);
                }
            }
        } else {
            // Loop tag not present in parent-resolved body (shouldn't happen,
            // but handle gracefully by appending a table at the end).
            bodyContent += '<table style="width:100%;border-collapse:collapse;">{ROWS}</table>';
        }

        // Resolve field merge tags in the header/footer using the same parent-
        // tag resolver that runs on the body. Without this, `{Name}`, `{Owner.Name}`,
        // `{Field:format}` tags in Header_Html__c / Footer_Html__c would render
        // as literal text in the final PDF.
        String mergedHeader = String.isBlank(headerHtml)
            ? null
            : resolveParentMergeTags(DocGenService.decodeBraceEntities(headerHtml));
        String mergedFooter = String.isBlank(footerHtml)
            ? null
            : resolveParentMergeTags(DocGenService.decodeBraceEntities(footerHtml));

        return DocGenService.wrapHtmlForPdf(bodyContent, sourceStyles, mergedHeader, mergedFooter);
    }

    /**
     * Builds a table header row from the query config's field names.
     * Reads the child node matching giantRelationshipName and generates
     * <tr><th>...</th></tr> from its fields + parentFields.
     */
    private String buildHeaderRowFromConfig() {
        try {
            // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
            List<DocGen_Template__c> tpls = [
                SELECT Query_Config__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (tpls.isEmpty() || String.isBlank(tpls[0].Query_Config__c)) {
                return '';
            }

            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(tpls[0].Query_Config__c.trim());
            List<Object> nodes = (List<Object>) config.get('nodes');
            if (nodes == null) {
                return '';
            }

            for (Object nodeObj : nodes) {
                Map<String, Object> node = (Map<String, Object>) nodeObj;
                String nodeAlias = (String) node.get('alias');
                String effectiveKey = String.isNotBlank(nodeAlias) ? nodeAlias : (String) node.get('relationshipName');
                if (giantRelationshipName.equals(effectiveKey)) {
                    String row = '<tr>';
                    // Parent fields first (e.g., Product2.Name → "Product Name")
                    List<Object> pFields = (List<Object>) node.get('parentFields');
                    if (pFields != null) {
                        for (Object f : pFields) {
                            row += '<th>' + formatFieldLabel(String.valueOf(f)) + '</th>';
                        }
                    }
                    // Then child fields (e.g., UnitPrice → "Unit Price")
                    List<Object> fields = (List<Object>) node.get('fields');
                    if (fields != null) {
                        for (Object f : fields) {
                            row += '<th>' + formatFieldLabel(String.valueOf(f)) + '</th>';
                        }
                    }
                    row += '</tr>';
                    return row;
                }
            }
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD — non-fatal, table works without header
        }
        return '';
    }

    /**
     * Converts an API field name to a human-readable label.
     * Product2.Name → "Product Name", UnitPrice → "Unit Price",
     * My_Custom_Field__c → "My Custom Field".
     */
    private static String formatFieldLabel(String apiName) {
        if (String.isBlank(apiName)) {
            return '';
        }
        // Take the last part after dot (Product2.Name → Name, Product2.ProductCode → ProductCode)
        if (apiName.contains('.')) {
            String parent = apiName.substringBefore('.');
            String field = apiName.substringAfter('.');
            // Clean parent name (Product2 → Product)
            parent = parent.removeEnd('2').replaceAll('__c$', '').replaceAll('__r$', '').replace('_', ' ');
            return parent + ' ' + formatFieldLabel(field);
        }
        // Remove __c suffix, split camelCase, replace underscores
        String label = apiName.removeEnd('__c').removeEnd('__r');
        // Insert space before each uppercase letter (camelCase → camel Case)
        String result = '';
        for (Integer i = 0; i < label.length(); i++) {
            String ch = label.substring(i, i + 1);
            if (i > 0 && ch == ch.toUpperCase() && ch != ch.toLowerCase() && ch != '_') {
                result += ' ';
            }
            result += ch;
        }
        return result.replace('_', ' ').trim();
    }

    /**
     * Resolves parent merge tags in the HTML template:
     *   {Name}, {Owner.Name}              — raw value
     *   {AnnualRevenue:currency}          — via DocGenService formatter
     *   {CloseDate:date:de_DE}            — via DocGenService formatter
     *
     * Aggregate tags ({SUM:...}, {COUNT:...}, etc.) are handled separately by
     * resolveGiantAggregateTags and are skipped here.
     */
    private String resolveParentMergeTags(String html) {
        try {
            List<DocGen_Template__c> tpls = [
                SELECT Base_Object_API__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (tpls.isEmpty()) {
                return html;
            }
            String baseObj = tpls[0].Base_Object_API__c;

            // Collect unique field paths and the full match → format map
            Set<String> fieldPaths = new Set<String>{ 'Name' };
            // fullMatch → [fieldPath, format-or-null]
            List<String> fullMatches = new List<String>();
            List<String> matchedPaths = new List<String>();
            List<String> matchedFormats = new List<String>();

            Pattern p = Pattern.compile('\\{([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)(?::([^}]+))?\\}');
            Matcher m = p.matcher(html);
            Set<String> aggFns = new Set<String>{ 'SUM', 'COUNT', 'AVG', 'MIN', 'MAX' };
            Set<String> builtins = new Set<String>{ 'TODAY', 'NOW' };
            while (m.find()) {
                String path = m.group(1);
                // Skip aggregate tags — handled by resolveGiantAggregateTags
                if (aggFns.contains(path.toUpperCase())) {
                    continue;
                }
                fullMatches.add(m.group(0));
                matchedPaths.add(path);
                matchedFormats.add(m.group(2));
                // Built-ins bypass schema field validation; the data-map fallback resolves them.
                if (!builtins.contains(path.toUpperCase())) {
                    fieldPaths.add(path);
                }
            }

            // Validate field paths against schema
            List<String> validFields = new List<String>();
            Map<String, Schema.SObjectField> fieldMap = Schema.getGlobalDescribe()
                .get(baseObj)
                ?.getDescribe()
                ?.fields
                ?.getMap();
            if (fieldMap != null) {
                for (String fn : fieldPaths) {
                    if (fn.contains('.')) {
                        String relName = fn.substringBefore('.');
                        Boolean relFound = false;
                        for (Schema.SObjectField sof : fieldMap.values()) {
                            if (
                                sof.getDescribe().getRelationshipName() != null &&
                                sof.getDescribe().getRelationshipName().equalsIgnoreCase(relName)
                            ) {
                                relFound = true;
                                break;
                            }
                        }
                        if (relFound) {
                            validFields.add(fn);
                        }
                    } else if (fieldMap.containsKey(fn.toLowerCase())) {
                        validFields.add(fn);
                    }
                }
            }
            if (validFields.isEmpty()) {
                return html;
            }

            String soql =
                'SELECT ' +
                String.join(validFields, ', ') +
                ' FROM ' +
                String.escapeSingleQuotes(baseObj) +
                ' WHERE Id = :recordId LIMIT 1';
            List<SObject> recs = Database.query(soql, AccessLevel.USER_MODE);
            if (recs.isEmpty()) {
                return html;
            }
            SObject rec = recs[0];

            // Resolve + format each matched tag. For format-suffix tags we build a
            // 1-field data map and hand the tag to DocGenService.processXmlForTest
            // so currency/number/date formatters stay centralized.
            Set<String> validFieldSet = new Set<String>(validFields);
            for (Integer i = 0; i < fullMatches.size(); i++) {
                String path = matchedPaths.get(i);
                String upperPath = path.toUpperCase();
                String fmt = matchedFormats.get(i);

                Object val = null;
                if (upperPath == 'TODAY') {
                    Date td = Date.today();
                    val = DateTime.newInstance(td.year(), td.month(), td.day());
                } else if (upperPath == 'NOW') {
                    val = DateTime.now();
                } else {
                    if (!validFieldSet.contains(path)) {
                        continue;
                    }
                    try {
                        if (path.contains('.')) {
                            List<String> parts = path.split('\\.');
                            SObject cur = rec;
                            for (Integer j = 0; j < parts.size() - 1 && cur != null; j++) {
                                cur = cur.getSObject(parts[j]);
                            }
                            if (cur != null) {
                                val = cur.get(parts[parts.size() - 1]);
                            }
                        } else {
                            val = rec.get(path);
                        }
                    } catch (Exception fieldErr) {
                        String noop = fieldErr.getMessage();
                    } // NOPMD
                }

                String replacement;
                if (val == null) {
                    replacement = '';
                } else if (String.isBlank(fmt)) {
                    replacement = String.valueOf(val);
                } else {
                    // Build a nested 1-field data map shaped like the path
                    Map<String, Object> miniMap = new Map<String, Object>();
                    if (path.contains('.')) {
                        List<String> parts = path.split('\\.');
                        Map<String, Object> cur = miniMap;
                        for (Integer j = 0; j < parts.size() - 1; j++) {
                            Map<String, Object> next = new Map<String, Object>();
                            cur.put(parts[j], next);
                            cur = next;
                        }
                        cur.put(parts[parts.size() - 1], val);
                    } else {
                        miniMap.put(path, val);
                    }
                    try {
                        replacement = DocGenService.processXmlForTest('{' + path + ':' + fmt + '}', miniMap);
                    } catch (Exception procErr) {
                        replacement = String.valueOf(val);
                    }
                }
                html = html.replace(fullMatches.get(i), replacement);
            }
        } catch (Exception mergeErr) {
            String noop = mergeErr.getMessage(); // NOPMD
        }
        // Resolve {%Image:N} / {%Image:N:SIZE} tags in the parent HTML (headers/footers/summaries)
        html = resolveParentImageTags(html);
        return html;
    }

    /**
     * Resolves {%Image:N} and {%Image:N:SIZE} tags at the parent level of a giant-query
     * template — headers, footers, grand-summary rows. Each tag expands to an HTML
     * <img src="/sfc/servlet.shepherd/version/download/<cvId>"> element referencing
     * the Nth oldest image attached to this.recordId. Unlike row-level images, this
     * emits HTML directly (the giant-query path builds HTML, not DOCX XML).
     *
     * Size grammar matches {%Image:N} elsewhere:
     *   "200"     → max dimension, preserves aspect  (style="max-width:200px;max-height:200px")
     *   "200x200" → explicit width × height
     *   "200x"    → width only (auto height)
     *   "x200"    → height only (auto width)
     */
    @TestVisible
    private String resolveParentImageTags(String html) {
        if (String.isBlank(html) || !html.containsIgnoreCase('{%image:'))
            return html;

        Pattern p = Pattern.compile('\\{%[Ii]mage:(\\d+)(?::([^}]+))?\\}');
        Matcher m = p.matcher(html);

        List<String> cachedCvIds = null; // lazy — only query CDL if at least one tag is found
        String result = '';
        Integer last = 0;
        while (m.find()) {
            Integer n = Integer.valueOf(m.group(1));
            String sizeToken = m.group(2);

            if (cachedCvIds == null) {
                cachedCvIds = new List<String>();
                Set<String> imageExts = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'tif', 'tiff', 'svg' };
                /* code-analyzer-suppress ApexFlsViolation */
                for (ContentDocumentLink cdl : [
                    SELECT ContentDocument.LatestPublishedVersionId
                    FROM ContentDocumentLink
                    WHERE LinkedEntityId = :recordId AND ContentDocument.FileExtension IN :imageExts
                    WITH USER_MODE
                    ORDER BY ContentDocument.CreatedDate ASC, ContentDocument.Id ASC
                    LIMIT 50
                ]) {
                    cachedCvIds.add(String.valueOf(cdl.ContentDocument.LatestPublishedVersionId));
                }
            }

            String replacement = '';
            if (n >= 1 && cachedCvIds.size() >= n) {
                replacement = buildParentImageHtml(cachedCvIds[n - 1], sizeToken);
            }
            result += html.substring(last, m.start()) + replacement;
            last = m.end();
        }
        result += html.substring(last);
        return result;
    }

    /**
     * Builds an HTML <img> element for a ContentVersion ID with optional size token.
     * Salesforce's Blob.toPdf() (Flying Saucer) resolves the relative /sfc/ URL natively.
     */
    private String buildParentImageHtml(String cvId, String sizeToken) {
        String url = '/sfc/servlet.shepherd/version/download/' + cvId;
        String style = '';
        if (String.isNotBlank(sizeToken)) {
            String t = sizeToken.trim().toLowerCase();
            if (!t.contains('x')) {
                if (t.isNumeric()) {
                    Integer nv = Integer.valueOf(t);
                    style = 'max-width:' + nv + 'px;max-height:' + nv + 'px;';
                }
            } else {
                Integer xIdx = t.indexOf('x');
                String w = t.substring(0, xIdx).trim();
                String h = t.substring(xIdx + 1).trim();
                if (String.isNotBlank(w) && w.isNumeric()) {
                    style += 'width:' + w + 'px;';
                }
                if (String.isNotBlank(h) && h.isNumeric()) {
                    style += 'height:' + h + 'px;';
                }
            }
        }
        return '<img src="' + url + '"' + (String.isBlank(style) ? '' : ' style="' + style + '"') + '/>';
    }

    /**
     * Resolves grand-total aggregate tags that reference the giant relationship:
     *   {SUM:Rel.Field}, {COUNT:Rel}, {AVG:Rel.Field}, {MIN:Rel.Field}, {MAX:Rel.Field}
     * with optional numeric format: {SUM:Rel.Field:currency}.
     *
     * One SOQL aggregate query covers all referenced fn/field pairs. Honors the
     * same lookup + WHERE clause used for the row pages, so totals match the rows.
     * Unlike in-memory aggregates this is accurate for arbitrarily large datasets
     * (60K+ rows) because the DB does the math.
     */
    @TestVisible
    private String resolveGiantAggregateTags(String html) {
        if (String.isBlank(html) || String.isBlank(giantRelationshipName)) {
            return html;
        }

        Pattern p = Pattern.compile(
            '\\{(SUM|COUNT|AVG|MIN|MAX):([A-Za-z0-9_]+)(?:\\.([A-Za-z0-9_]+))?(?::([^}]+))?\\}'
        );
        Matcher m = p.matcher(html);

        List<String> fullMatches = new List<String>();
        List<String> fns = new List<String>();
        List<String> fields = new List<String>();
        List<String> fmts = new List<String>();
        Set<String> neededPairs = new Set<String>();

        while (m.find()) {
            String rel = m.group(2);
            if (!giantRelationshipName.equalsIgnoreCase(rel)) {
                continue;
            }
            String fn = m.group(1).toUpperCase();
            String field = m.group(3);
            fullMatches.add(m.group(0));
            fns.add(fn);
            fields.add(field == null ? '' : field);
            fmts.add(m.group(4));
            neededPairs.add(fn + '|' + (field == null ? '' : field));
        }
        if (fullMatches.isEmpty()) {
            return html;
        }

        // Prefer the child/lookup/where passed in via constructor (the batch has them
        // regardless of config format). Only fall back to parsing Query_Config__c if
        // the constructor values are absent — and that path only works for V3 JSON.
        String childObj = this.childObjectName;
        String lookupFld = this.lookupFieldName;
        String whereCls = this.whereClauseOverride;

        if (String.isBlank(childObj) || String.isBlank(lookupFld)) {
            try {
                List<DocGen_Template__c> tpls = [
                    SELECT Query_Config__c
                    FROM DocGen_Template__c
                    WHERE Id = :templateId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (tpls.isEmpty() || String.isBlank(tpls[0].Query_Config__c)) {
                    return html;
                }
                String cfgStr = tpls[0].Query_Config__c.trim();
                if (!cfgStr.startsWith('{')) {
                    return html;
                } // V1 flat — caller must pass child/lookup explicitly
                Map<String, Object> cfg = (Map<String, Object>) JSON.deserializeUntyped(cfgStr);
                List<Object> nodes = (List<Object>) cfg.get('nodes');
                if (nodes == null) {
                    return html;
                }
                for (Object nodeObj : nodes) {
                    Map<String, Object> node = (Map<String, Object>) nodeObj;
                    String nodeAlias = (String) node.get('alias');
                    String effectiveKey = String.isNotBlank(nodeAlias)
                        ? nodeAlias
                        : (String) node.get('relationshipName');
                    if (giantRelationshipName.equalsIgnoreCase(effectiveKey)) {
                        childObj = (String) node.get('object');
                        lookupFld = (String) node.get('lookupField');
                        whereCls = (String) node.get('where');
                        if (whereCls == null) {
                            whereCls = (String) node.get('whereClause');
                        }
                        // Sanitize the whereCls pulled directly from V3 config — the
                        // batch path passes an already-sanitized value via constructor,
                        // but this fallback (4-arg constructor) reads it raw. Reuse the
                        // canonical sanitizer to block injection (DML keywords, ;, --, /*).
                        if (String.isNotBlank(whereCls)) {
                            whereCls = DocGenDataRetriever.sanitizeWhereClause(whereCls);
                        }
                        break;
                    }
                }
            } catch (DocGenException dge) {
                // Sanitizer rejected the where clause — abort aggregate resolution
                // and leave tags unresolved rather than running the unsafe SOQL.
                return html;
            } catch (Exception e) {
                String noop = e.getMessage(); // NOPMD — aggregate resolution is non-fatal
                return html;
            }
        }

        if (String.isBlank(childObj) || String.isBlank(lookupFld)) {
            return html;
        }
        Schema.SObjectType childType = Schema.getGlobalDescribe().get(childObj);
        if (childType == null) {
            return html;
        }
        // Validate aggregate fields against the child object's schema — this allows
        // aggregating any queryable field, not just columns declared for rendering.
        // Regex already restricts field names to [A-Za-z0-9_]+ so SOQL injection is
        // blocked; Schema existence check is the second line of defense.
        Map<String, Schema.SObjectField> childFieldMap = childType.getDescribe().fields.getMap();
        // Allowlist-validate lookupFld against the child schema. The batch sanitizes
        // its own incoming clauses, but lookupFld is only escapeSingleQuotes'd — that
        // doesn't protect against identifier-level injection (no quotes needed). Reject
        // anything that isn't a real field on the child object.
        if (!childFieldMap.containsKey(lookupFld.toLowerCase())) {
            return html;
        }

        // Build aggregate SELECT clauses — each unique (fn, field) pair gets one alias
        List<String> selectClauses = new List<String>();
        Map<String, String> pairToAlias = new Map<String, String>();
        Integer aliasIdx = 0;
        for (String pair : neededPairs) {
            List<String> parts = pair.split('\\|', 2);
            String fn = parts[0];
            String field = parts.size() > 1 ? parts[1] : '';
            String alias = 'agg' + aliasIdx++;
            if (fn == 'COUNT' && String.isBlank(field)) {
                selectClauses.add('COUNT(Id) ' + alias);
                pairToAlias.put(pair, alias);
            } else if (String.isNotBlank(field) && childFieldMap.containsKey(field.toLowerCase())) {
                selectClauses.add(fn + '(' + field + ') ' + alias);
                pairToAlias.put(pair, alias);
            }
        }
        if (selectClauses.isEmpty()) {
            return html;
        }

        String soql =
            'SELECT ' +
            String.join(selectClauses, ', ') +
            ' FROM ' +
            String.escapeSingleQuotes(childObj) +
            ' WHERE ' +
            String.escapeSingleQuotes(lookupFld) +
            ' = :recordId';
        if (String.isNotBlank(whereCls)) {
            soql += ' AND ' + whereCls;
        }

        AggregateResult agg;
        try {
            List<AggregateResult> results = Database.query(soql, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — child object + fields validated against Schema + declared template fields; lookup and where re-use the same sanitized clauses as row queries
            if (results.isEmpty()) {
                return html;
            }
            agg = results[0];
        } catch (Exception qErr) {
            String noop = qErr.getMessage(); // NOPMD — fall through, tags stay unresolved
            return html;
        }

        // Replace each tag occurrence
        for (Integer i = 0; i < fullMatches.size(); i++) {
            String pair = fns[i] + '|' + fields[i];
            String alias = pairToAlias.get(pair);
            if (alias == null) {
                continue;
            }
            Object raw = agg.get(alias);
            String replacement;
            if (raw == null) {
                replacement = '0';
            } else if (fmts[i] != null) {
                try {
                    replacement = DocGenService.formatAggregateValue(Decimal.valueOf(String.valueOf(raw)), fmts[i]);
                } catch (Exception fmtErr) {
                    replacement = String.valueOf(raw);
                }
            } else {
                replacement = String.valueOf(raw);
            }
            html = html.replace(fullMatches[i], replacement);
        }
        return html;
    }

    /**
     * Fallback: renders multiple separate PDFs if the single-call approach fails.
     * This produces the old behavior (gap between chunks) but at least doesn't crash.
     */
    private void renderMultiPartPdf(String fullHtml, String htmlTemplate) {
        // Re-parse: we need the original allRows without table breaks, but we've
        // already modified them. Since this is a fallback for an unexpected failure,
        // just mark the job as failed with a descriptive message.
        update new DocGen_Job__c(
            Id = jobId,
            Status__c = 'Failed',
            Label__c = 'PDF render failed — dataset too large for single-pass rendering. Try reducing child record count.'
        ); // NOPMD ApexCRUDViolation — package-internal
    }

    /**
     * Builds a <colgroup> with percentage column widths from the template's
     * <w:tblGrid><w:gridCol w:w="2400"/>...</w:tblGrid> XML.
     * Widths are in twips (1440 = 1 inch). Converts to percentages of total width.
     */
    private static String buildColGroupFromTblGrid(String tblPropsXml) {
        List<Integer> colWidths = new List<Integer>();
        Integer totalWidth = 0;

        Integer gridStart = tblPropsXml.indexOf('<w:tblGrid');
        Integer gridEnd = tblPropsXml.indexOf('</w:tblGrid>');
        if (gridStart == -1 || gridEnd == -1) {
            return '';
        }

        String gridXml = tblPropsXml.substring(gridStart, gridEnd);
        Integer scanPos = 0;
        while (scanPos < gridXml.length()) {
            Integer colStart = gridXml.indexOf('<w:gridCol', scanPos);
            if (colStart == -1) {
                break;
            }
            Integer wStart = gridXml.indexOf('w:w="', colStart);
            if (wStart == -1) {
                break;
            }
            wStart += 5;
            Integer wEnd = gridXml.indexOf('"', wStart);
            if (wEnd == -1) {
                break;
            }
            try {
                Integer w = Integer.valueOf(gridXml.substring(wStart, wEnd));
                colWidths.add(w);
                totalWidth += w;
            } catch (Exception e) {
                String noop = e.getMessage(); // NOPMD
            }
            scanPos = wEnd + 1;
        }

        if (colWidths.isEmpty() || totalWidth == 0) {
            return '';
        }

        String colGroup = '<colgroup>';
        for (Integer w : colWidths) {
            Decimal pct = (Decimal.valueOf(w) / Decimal.valueOf(totalWidth) * 100).setScale(1);
            colGroup += '<col style="width:' + pct + '%">';
        }
        colGroup += '</colgroup>';
        return colGroup;
    }

    /**
     * Inserts </table><table> breaks every N rows into the row HTML.
     * This resets Flying Saucer's DOM tree depth without splitting into
     * separate PDF files, keeping the output as one continuous document.
     */
    private static String insertTableBreaks(String allRows, Integer rowsPerBreak, String colGroupHtml) {
        if (String.isBlank(allRows)) {
            return allRows;
        }

        final String TR_CLOSE = '</tr>';
        final Integer trCloseLen = TR_CLOSE.length();

        // Use template column widths if available, otherwise calculate equal widths from first row
        String colGroup = String.isNotBlank(colGroupHtml) ? colGroupHtml : '';
        if (String.isBlank(colGroup)) {
            Integer colCount = 0;
            Integer firstTrEnd = allRows.indexOf(TR_CLOSE);
            if (firstTrEnd != -1) {
                String firstRow = allRows.substring(0, firstTrEnd);
                Integer tdIdx = 0;
                while (tdIdx < firstRow.length()) {
                    Integer tdStart = firstRow.indexOf('<td', tdIdx);
                    if (tdStart == -1) {
                        break;
                    }
                    colCount++;
                    tdIdx = tdStart + 3;
                }
            }
            if (colCount > 0) {
                String colWidth = String.valueOf((100.0 / colCount).setScale(2)) + '%';
                colGroup = '<colgroup>';
                for (Integer i = 0; i < colCount; i++) {
                    colGroup += '<col style="width:' + colWidth + '">';
                }
                colGroup += '</colgroup>';
            }
        }

        final String TABLE_BREAK =
            '</table><table style="width:100%;border-collapse:collapse;table-layout:fixed;">' + colGroup;

        // Build result with table breaks inserted at row boundaries.
        // Use List<String> + join instead of string concatenation for heap efficiency.
        List<String> parts = new List<String>();
        Integer rowCount = 0;
        Integer scanPos = 0;
        Integer lastBreakPos = 0;

        while (scanPos < allRows.length()) {
            Integer idx = allRows.indexOf(TR_CLOSE, scanPos);
            if (idx == -1) {
                break;
            }
            rowCount++;
            scanPos = idx + trCloseLen;

            if (rowCount >= rowsPerBreak && scanPos < allRows.length()) {
                parts.add(allRows.substring(lastBreakPos, scanPos));
                lastBreakPos = scanPos;
                rowCount = 0;
            }
        }
        // Append remaining rows
        if (lastBreakPos < allRows.length()) {
            parts.add(allRows.substring(lastBreakPos));
        }
        return String.join(parts, TABLE_BREAK);
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
            if (idx == -1) {
                break;
            }
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
