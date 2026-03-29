/**
 * Batch Apex that harvests child records in cursor-based pages and renders
 * each page as a standalone fragment. Each execute() queries one page of
 * children, renders the loop body XML, and saves as a ContentVersion.
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
    }

    public Iterable<String> start(Database.BatchableContext bc) {
        String countQuery = 'SELECT COUNT() FROM ' + String.escapeSingleQuotes(childObjectName) +
            ' WHERE ' + String.escapeSingleQuotes(lookupField) + ' = :recordId WITH USER_MODE';
        Integer totalChildren = Database.countQuery(countQuery);

        Integer totalPages = (Integer) Math.ceil((Decimal) totalChildren / batchSize);
        update new DocGen_Job__c( // NOPMD ApexCRUDViolation — package-internal
            Id = jobId,
            Status__c = 'Harvesting',
            Total_Records__c = totalChildren
        );

        List<String> pages = new List<String>();
        for (Integer i = 0; i < totalPages; i++) {
            pages.add('page:' + i);
        }
        if (pages.isEmpty()) {
            pages.add('page:0');
        }

        this.lastCursorId = null;
        return pages;
    }

    /**
     * Processes one page: queries children, renders loop body XML, saves as text CV.
     * Both PDF and DOCX save raw XML — PDF assembly happens in finish().
     */
    public void execute(Database.BatchableContext bc, List<String> scope) {
        for (String pageDescriptor : scope) {
            List<String> selectFields = new List<String>{ 'Id' };
            for (String f : childFields) {
                if (f != 'Id') { selectFields.add(f); }
            }
            for (String f : parentFields) { selectFields.add(f); }

            String query = 'SELECT ' + String.join(selectFields, ', ') +
                ' FROM ' + String.escapeSingleQuotes(childObjectName) +
                ' WHERE ' + String.escapeSingleQuotes(lookupField) + ' = :recordId';
            if (lastCursorId != null) {
                query += ' AND Id > :lastCursorId';
            }
            query += ' ORDER BY Id LIMIT :batchSize';

            List<SObject> records = Database.query(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — validated by Schema.getGlobalDescribe; USER_MODE enforced
            if (records.isEmpty()) { continue; }

            lastCursorId = records[records.size() - 1].Id;

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

            ContentVersion cv = new ContentVersion(
                Title = 'docgen_giant_' + jobId + '_' + seq,
                PathOnClient = 'docgen_giant_' + jobId + '_' + seq + '.html',
                VersionData = fragmentData,
                IsMajorVersion = false
            );
            insert cv; // NOPMD ApexCRUDViolation — internal fragment for Giant Query

            update new DocGen_Job__c(Id = jobId, Success_Count__c = fragmentSequence); // NOPMD ApexCRUDViolation — package-internal
        }
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

                // Strip barcode markers to plain text value
                if (txt.contains('##BARCODE:')) {
                    txt = txt.replaceAll('##BARCODE:[^:]*:[^:]*:([^#]*)##', '$1');
                }

                row += '<td class="c' + colNum + '">' + txt + '</td>';
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
                    } catch (Exception e) { /* skip */ }
                }
            }

            if (!styles.isEmpty()) {
                css += '.c' + colNum + '{' + String.join(styles, ';') + '} ';
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
                // Chain to assembler Queueable — finish() heap is too constrained
                System.enqueueJob(new DocGenGiantQueryAssembler(jobId, templateId, recordId, giantRelationshipName));
            } else {
                update new DocGen_Job__c(Id = jobId, Status__c = 'Completed'); // NOPMD ApexCRUDViolation — package-internal
            }
        } catch (Exception e) {
            update new DocGen_Job__c(Id = jobId, Status__c = 'Failed', Label__c = e.getMessage().left(255)); // NOPMD ApexCRUDViolation — package-internal
        }
    }
}
