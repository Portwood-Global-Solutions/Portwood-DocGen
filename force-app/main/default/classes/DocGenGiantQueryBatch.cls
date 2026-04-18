/**
 * Batch Apex that harvests child records in cursor-based pages and renders
 * each page as a standalone fragment. Each execute() queries one page of
 * children, renders the loop body XML, and saves as a ContentVersion.
 *
 * When an ORDER BY clause is configured, a pre-query in start() fetches all
 * child Ids in the desired sort order. execute() then pages through pre-sorted
 * Id chunks so fragments are globally ordered — not just sorted within each batch.
 *
 * For PDF output: fragments are saved as raw XML text. In finish(), all
 * fragments are loaded, wrapped in one HTML document, and rendered to a
 * single PDF via Blob.toPdf(). One PDF, no client-side merge needed.
 *
 * For DOCX output: fragments are saved as raw XML, and the client fetches
 * each fragment one at a time to assemble the DOCX ZIP in JavaScript.
 */
public with sharing class DocGenGiantQueryBatch implements Database.Batchable<String>, Database.Stateful {

    private Id jobId;
    private Id templateId;
    private Id recordId;
    private String relationshipName;
    private String childObjectName;
    private String lookupField;
    private List<String> childFields;
    private List<String> parentFields;
    private String innerXml;
    private String lastCursorId;
    private Integer batchSize;
    private Integer fragmentSequence;
    private String outputFormat;
    private String giantRelationshipName;
    private String orderByClause;
    private String whereClause;
    private String limitClause;
    private List<List<Id>> sortedIdChunks;

    public DocGenGiantQueryBatch(Id jobId, Id templateId, Id recordId, Map<String, Object> childNodeConfig, String innerXml, String outputFormat) {
        this.jobId = jobId;
        this.templateId = templateId;
        this.recordId = recordId;
        this.innerXml = innerXml;
        this.outputFormat = outputFormat;
        this.fragmentSequence = 0;
        this.batchSize = 50;

        this.relationshipName = (String) childNodeConfig.get('relationshipName');
        this.giantRelationshipName = this.relationshipName;
        this.childObjectName = (String) childNodeConfig.get('object');
        this.lookupField = (String) childNodeConfig.get('lookupField');

        // Schema validation: verify object exists and is accessible
        if (String.isBlank(this.childObjectName) || Schema.getGlobalDescribe().get(this.childObjectName) == null) {
            throw new DocGenException('Invalid or inaccessible object: ' + this.childObjectName);
        }

        this.childFields = new List<String>();
        List<Object> flds = (List<Object>) childNodeConfig.get('fields');
        if (flds != null) {
            for (Object f : flds) { this.childFields.add(String.valueOf(f)); }
        }
        this.parentFields = new List<String>();
        List<Object> pFlds = (List<Object>) childNodeConfig.get('parentFields');
        if (pFlds != null) {
            for (Object f : pFlds) { this.parentFields.add(String.valueOf(f)); }
        }

        // Read and sanitize ORDER BY clause from config
        String rawOrderBy = (String) childNodeConfig.get('orderBy');
        if (String.isNotBlank(rawOrderBy)) {
            this.orderByClause = sanitizeOrderByClause(rawOrderBy);
        }

        // Read and sanitize WHERE clause from config
        String rawWhere = (String) childNodeConfig.get('where');
        if (rawWhere == null) { rawWhere = (String) childNodeConfig.get('whereClause'); }
        if (String.isNotBlank(rawWhere)) {
            this.whereClause = sanitizeWhereClause(rawWhere);
        }

        // Read and sanitize LIMIT clause from config
        String rawLimit = childNodeConfig.get('limit') != null ? String.valueOf(childNodeConfig.get('limit')) : null;
        if (rawLimit == null) { rawLimit = childNodeConfig.get('limitClause') != null ? String.valueOf(childNodeConfig.get('limitClause')) : null; }
        if (String.isNotBlank(rawLimit) && rawLimit.trim().isNumeric()) {
            this.limitClause = rawLimit.trim();
        }
    }

    public Iterable<String> start(Database.BatchableContext bc) {
        List<String> pages = new List<String>();

        if (String.isNotBlank(orderByClause)) {
            // Pre-query: fetch all child Ids in the desired sort order.
            // This lets execute() page through globally-sorted chunks instead of
            // cursor-based Id order. Costs one lightweight Id-only query (<50K rows).
            String sortQuery = 'SELECT Id FROM ' + String.escapeSingleQuotes(childObjectName) +
                ' WHERE ' + String.escapeSingleQuotes(lookupField) + ' = :recordId';
            if (String.isNotBlank(whereClause)) { sortQuery += ' AND ' + whereClause; }
            sortQuery += ' ORDER BY ' + orderByClause;
            if (String.isNotBlank(limitClause)) { sortQuery += ' LIMIT ' + limitClause; }

            List<SObject> sortedRecords = Database.query(sortQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — object/field validated by Schema.getGlobalDescribe; orderBy sanitized by sanitizeOrderByClause(); runs with USER_MODE

            Integer totalChildren = sortedRecords.size();
            update new DocGen_Job__c(Id = jobId, Status__c = 'Harvesting', Total_Records__c = totalChildren); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets

            // Chunk the sorted Ids for execute() to page through
            this.sortedIdChunks = new List<List<Id>>();
            List<Id> currentChunk = new List<Id>();
            for (SObject rec : sortedRecords) {
                currentChunk.add(rec.Id);
                if (currentChunk.size() >= batchSize) {
                    this.sortedIdChunks.add(currentChunk);
                    currentChunk = new List<Id>();
                }
            }
            if (!currentChunk.isEmpty()) {
                this.sortedIdChunks.add(currentChunk);
            }
            sortedRecords = null; // free heap

            for (Integer i = 0; i < this.sortedIdChunks.size(); i++) {
                pages.add('sorted:' + i);
            }
        } else {
            // Original cursor-based path (no sort requested)
            String countQuery = 'SELECT COUNT() FROM ' + String.escapeSingleQuotes(childObjectName) +
                ' WHERE ' + String.escapeSingleQuotes(lookupField) + ' = :recordId';
            if (String.isNotBlank(whereClause)) { countQuery += ' AND ' + whereClause; }
            Integer totalChildren = Database.countQuery(countQuery, AccessLevel.USER_MODE);

            Integer totalPages = (Integer) Math.ceil((Decimal) totalChildren / batchSize);
            update new DocGen_Job__c(Id = jobId, Status__c = 'Harvesting', Total_Records__c = totalChildren); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets

            for (Integer i = 0; i < totalPages; i++) {
                pages.add('page:' + i);
            }
            this.lastCursorId = null;
        }

        if (pages.isEmpty()) {
            pages.add('page:0');
        }
        return pages;
    }

    /**
     * Processes one page: queries children, renders loop body XML, saves as text CV.
     * Both PDF and DOCX save raw XML — PDF assembly happens in finish().
     *
     * Two query strategies:
     *   sorted:N — fetches pre-sorted Id chunk by index, preserving global sort order
     *   page:N   — cursor-based Id pagination (original behavior, no orderBy)
     */
    public void execute(Database.BatchableContext bc, List<String> scope) {
        // Collect fragment CVs, bulk insert after loop. Fragments are small HTML text (~5-50KB each).
        List<ContentVersion> fragmentCvs = new List<ContentVersion>();
        for (String pageDescriptor : scope) {
            List<String> selectFields = new List<String>{ 'Id' };
            for (String f : childFields) {
                if (f != 'Id') { selectFields.add(f); }
            }
            for (String f : parentFields) { selectFields.add(f); }

            List<SObject> records;

            if (pageDescriptor.startsWith('sorted:')) {
                // Sorted path: fetch by pre-sorted Id chunk
                Integer chunkIndex = Integer.valueOf(pageDescriptor.substringAfter('sorted:'));
                List<Id> idChunk = sortedIdChunks.get(chunkIndex);

                String query = 'SELECT ' + String.join(selectFields, ', ') +
                    ' FROM ' + String.escapeSingleQuotes(childObjectName) +
                    ' WHERE Id IN :idChunk';

                List<SObject> unordered = Database.query(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — object/fields validated by Schema; Id chunk from pre-query; runs with USER_MODE

                // Re-order to match the pre-sorted Id sequence
                Map<Id, SObject> byId = new Map<Id, SObject>();
                for (SObject rec : unordered) { byId.put(rec.Id, rec); }
                records = new List<SObject>();
                for (Id sortedId : idChunk) {
                    SObject rec = byId.get(sortedId);
                    if (rec != null) { records.add(rec); }
                }
            } else {
                // Original cursor-based path
                String query = 'SELECT ' + String.join(selectFields, ', ') +
                    ' FROM ' + String.escapeSingleQuotes(childObjectName) +
                    ' WHERE ' + String.escapeSingleQuotes(lookupField) + ' = :recordId';
                if (String.isNotBlank(whereClause)) { query += ' AND ' + whereClause; }
                if (lastCursorId != null) {
                    query += ' AND Id > :lastCursorId';
                }
                query += ' ORDER BY Id LIMIT :batchSize';

                records = Database.query(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — validated by Schema.getGlobalDescribe; USER_MODE enforced
                if (!records.isEmpty()) {
                    lastCursorId = records[records.size() - 1].Id;
                }
            }

            if (records == null || records.isEmpty()) { continue; }

            List<String> allFields = new List<String>();
            allFields.addAll(childFields);
            allFields.addAll(parentFields);

            // Render loop body
            String renderedRows = DocGenService.renderLoopBodyForRecords(innerXml, relationshipName, records, allFields);

            String seq = String.valueOf(fragmentSequence++).leftPad(5, '0');
            Blob fragmentData;

            if ('PDF'.equalsIgnoreCase(outputFormat)) {
                // Convert DOCX XML rows to simple HTML <tr><td> — lightweight text extraction
                // No DocGenHtmlRenderer (too heavy for batch execute heap)
                fragmentData = Blob.valueOf(xmlRowsToHtmlRows(renderedRows));
            } else {
                fragmentData = Blob.valueOf(renderedRows);
            }
            renderedRows = null;

            fragmentCvs.add(new ContentVersion(
                Title = 'docgen_giant_' + jobId + '_' + seq,
                PathOnClient = 'docgen_giant_' + jobId + '_' + seq + '.html',
                VersionData = fragmentData,
                IsMajorVersion = false
            ));
        }
        // Bulk insert all fragments
        if (!fragmentCvs.isEmpty()) {
            SObjectAccessDecision cvDec = Security.stripInaccessible(AccessType.CREATABLE, fragmentCvs);
            insert cvDec.getRecords();
        }
        // Update progress
        update new DocGen_Job__c(Id = jobId, Success_Count__c = fragmentSequence); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
    }

    /**
     * Lightweight DOCX XML → HTML row converter. Extracts text from <w:t> tags.
     * No inline formatting — column styles applied via nth-child CSS in the assembler.
     * Barcode markers stripped to plain text values.
     */
    private static String xmlRowsToHtmlRows(String xml) {
        String result = '';
        Integer cursor = 0;
        while (cursor < xml.length()) {
            Integer trStart = xml.indexOf('<w:tr', cursor);
            if (trStart == -1) { break; }
            Integer trEnd = xml.indexOf('</w:tr>', trStart);
            if (trEnd == -1) { break; }
            String trXml = xml.substring(trStart, trEnd + 7);
            cursor = trEnd + 7;
            String row = '<tr>';
            Integer cellIdx = 0;
            Integer colNum = 0;
            while (cellIdx < trXml.length()) {
                Integer cellStart = findTag(trXml, '<w:tc', cellIdx);
                if (cellStart == -1) { break; }
                Integer cellEnd = trXml.indexOf('</w:tc>', cellStart);
                if (cellEnd == -1) { break; }
                String cellXml = trXml.substring(cellStart, cellEnd);
                cellIdx = cellEnd + 7;
                colNum++;

                // Extract all <w:t> text content
                String txt = '';
                Integer txtIdx = 0;
                while (txtIdx < cellXml.length()) {
                    Integer wtStart = findTag(cellXml, '<w:t', txtIdx);
                    if (wtStart == -1) { break; }
                    Integer wtContentStart = cellXml.indexOf('>', wtStart) + 1;
                    Integer wtEnd = cellXml.indexOf('</w:t>', wtContentStart);
                    if (wtEnd == -1) { break; }
                    txt += cellXml.substring(wtContentStart, wtEnd);
                    txtIdx = wtEnd + 6;
                }

                // Strip barcode markers to plain text value (no regex — Apex regex too complex for 10K rows)
                if (txt.contains('##BARCODE:')) {
                    Integer bcStart = txt.indexOf('##BARCODE:');
                    Integer bcEnd = txt.indexOf('##', bcStart + 10);
                    if (bcEnd != -1) {
                        String marker = txt.substring(bcStart + 10, bcEnd); // type:size:VALUE
                        String val = marker.substringAfterLast(':');
                        txt = txt.substring(0, bcStart) + val + txt.substring(bcEnd + 2);
                    }
                }

                row += '<td>' + txt + '</td>';
            }
            result += row + '</tr>';
        }
        return result;
    }

    /** Finds a tag like <w:tc> or <w:tc  but NOT <w:tcPr>, <w:tcW> etc. */
    private static Integer findTag(String xml, String tag, Integer fromIdx) {
        Integer tagLen = tag.length();
        Integer searchFrom = fromIdx;
        while (searchFrom < xml.length()) {
            Integer candidate = xml.indexOf(tag, searchFrom);
            if (candidate == -1) { return -1; }
            String nc = xml.substring(candidate + tagLen, Math.min(candidate + tagLen + 1, xml.length()));
            if (nc == '>' || nc == ' ') { return candidate; }
            searchFrom = candidate + 1;
        }
        return -1;
    }

    /**
     * Extracts per-column CSS from the template's loop row XML. Reads bold, italic,
     * font-size from <w:rPr> and alignment from <w:pPr> for each cell, returns
     * nth-child CSS rules. Called once during config extraction, injected into
     * the assembler's HTML <style> block.
     */
    public static String extractColumnCss(String loopRowXml) {
        String css = '';
        Integer colNum = 0;
        Integer cellIdx = 0;
        while (cellIdx < loopRowXml.length()) {
            Integer cellStart = findTag(loopRowXml, '<w:tc', cellIdx);
            if (cellStart == -1) { break; }
            Integer cellEnd = loopRowXml.indexOf('</w:tc>', cellStart);
            if (cellEnd == -1) { break; }
            String cellXml = loopRowXml.substring(cellStart, cellEnd);
            cellIdx = cellEnd + 7;
            colNum++;

            List<String> styles = new List<String>();

            // Alignment
            if (cellXml.contains('<w:jc ')) {
                Integer jcIdx = cellXml.indexOf('<w:jc ');
                Integer valIdx = cellXml.indexOf('w:val="', jcIdx);
                if (valIdx != -1) {
                    Integer valStart = valIdx + 7;
                    Integer valEnd = cellXml.indexOf('"', valStart);
                    String jcVal = cellXml.substring(valStart, valEnd);
                    if (jcVal == 'center') { styles.add('text-align:center'); }
                    else if (jcVal == 'right' || jcVal == 'end') { styles.add('text-align:right'); }
                }
            }

            // Bold / Italic
            if (cellXml.contains('<w:b/>') || cellXml.contains('<w:b ')) { styles.add('font-weight:bold'); }
            if (cellXml.contains('<w:i/>') || cellXml.contains('<w:i ')) { styles.add('font-style:italic'); }

            // Font size from <w:sz>
            if (cellXml.contains('<w:sz ')) {
                Integer szIdx = cellXml.indexOf('<w:sz ');
                Integer szValIdx = cellXml.indexOf('w:val="', szIdx);
                if (szValIdx != -1) {
                    Integer szStart = szValIdx + 7;
                    Integer szEnd = cellXml.indexOf('"', szStart);
                    try {
                        Integer halfPts = Integer.valueOf(cellXml.substring(szStart, szEnd));
                        styles.add('font-size:' + (halfPts / 2) + 'pt');
                    } catch (Exception e) { String noop = e.getMessage(); } // NOPMD EmptyCatchBlock — skip invalid font size
                }
            }

            if (!styles.isEmpty()) {
                css += 'td:nth-child(' + colNum + '){' + String.join(styles, ';') + '} ';
            }
        }
        return css;
    }

    /**
     * For PDF: chains to DocGenGiantQueryAssembler Queueable which gets its own
     * fresh 6MB heap for the HTML conversion + Blob.toPdf() assembly.
     * For DOCX: marks job as Completed for client-side assembly.
     */
    public void finish(Database.BatchableContext bc) {
        try {
            if ('PDF'.equalsIgnoreCase(outputFormat)) {
                // Chain to assembler Queueable — pass child/lookup/where so aggregate
                // resolution works for V1/V2/V3 query configs (not just V3 JSON).
                System.enqueueJob(new DocGenGiantQueryAssembler(
                    jobId, templateId, recordId, giantRelationshipName,
                    childObjectName, lookupField, whereClause
                ));
            } else {
                update new DocGen_Job__c(Id = jobId, Status__c = 'Completed'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
            }
        } catch (Exception e) {
            update new DocGen_Job__c(Id = jobId, Status__c = 'Failed', Label__c = e.getMessage().left(255)); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
        }
    }

    /**
     * Sanitizes an ORDER BY clause for use in dynamic SOQL.
     * Rejects injection vectors (statement terminators, comments, DML keywords,
     * subqueries). Mirrors DocGenDataRetriever.sanitizeClause() logic.
     */
    /**
     * Sanitizes a WHERE clause for use in dynamic SOQL.
     * Mirrors DocGenDataRetriever.sanitizeClause() logic.
     */
    private static String sanitizeWhereClause(String clause) {
        if (String.isBlank(clause)) { return null; }
        if (clause.contains(';') || clause.contains('--') || clause.contains('/*')) {
            throw new DocGenException('Invalid WHERE clause in query config.');
        }
        String normalized = clause.replaceAll('\\s+', ' ').toUpperCase().trim();
        List<String> disallowed = new List<String>{
            'INSERT ', 'UPDATE ', 'DELETE ', 'MERGE ', 'UNDELETE ',
            'DROP ', 'ALTER ', 'CREATE ', 'GRANT ', 'REVOKE ', 'SELECT '
        };
        for (String keyword : disallowed) {
            if (normalized.contains(keyword)) {
                throw new DocGenException('Invalid WHERE clause: disallowed keyword detected.');
            }
        }
        return clause;
    }

    private static String sanitizeOrderByClause(String clause) {
        if (String.isBlank(clause)) { return null; }
        // Reject statement terminators and comments
        if (clause.contains(';') || clause.contains('--') || clause.contains('/*')) {
            throw new DocGenException('Invalid ORDER BY clause in query config.');
        }
        String normalized = clause.replaceAll('\\s+', ' ').toUpperCase().trim();
        // Reject DML and structural keywords that don't belong in ORDER BY
        List<String> disallowed = new List<String>{
            'INSERT ', 'UPDATE ', 'DELETE ', 'MERGE ', 'UNDELETE ',
            'DROP ', 'ALTER ', 'CREATE ', 'GRANT ', 'REVOKE ', 'SELECT '
        };
        for (String keyword : disallowed) {
            if (normalized.contains(keyword)) {
                throw new DocGenException('Invalid ORDER BY clause: disallowed keyword detected.');
            }
        }
        return clause;
    }
}
