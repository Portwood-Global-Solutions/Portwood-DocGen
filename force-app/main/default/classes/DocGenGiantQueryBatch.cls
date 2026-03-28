/**
 * Batch Apex that harvests child records in cursor-based pages and renders
 * each page as a standalone fragment. Each execute() queries one page of
 * children, renders the loop body XML, and saves as a ContentVersion.
 *
 * For PDF output: fragments are saved as HTML, then the stitch job groups
 * them into PDFs via Blob.toPdf().
 *
 * For DOCX output: fragments are saved as raw XML, stitch is skipped, and
 * the client fetches each fragment one at a time to assemble the DOCX ZIP
 * in JavaScript (no Apex heap limit).
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

    /**
     * Constructs a Giant Query batch for a single child relationship.
     * @param jobId The DocGen_Job__c record tracking this generation
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The parent record ID
     * @param childNodeConfig Map containing: object, lookupField, relationshipName, fields, parentFields
     * @param innerXml The extracted loop body XML template for this relationship
     * @param outputFormat The desired output format (PDF or Native)
     */
    public DocGenGiantQueryBatch(Id jobId, Id templateId, Id recordId, Map<String, Object> childNodeConfig, String innerXml, String outputFormat) {
        this.jobId = jobId;
        this.templateId = templateId;
        this.recordId = recordId;
        this.innerXml = innerXml;
        this.outputFormat = outputFormat;
        this.fragmentSequence = 0;
        this.batchSize = 50; // Keep small for Blob.toPdf() HTML size limit (~150KB per fragment)

        this.relationshipName = (String) childNodeConfig.get('relationshipName');
        this.childObjectName = (String) childNodeConfig.get('object');
        this.lookupField = (String) childNodeConfig.get('lookupField');

        this.childFields = new List<String>();
        List<Object> flds = (List<Object>) childNodeConfig.get('fields');
        if (flds != null) {
            for (Object f : flds) {
                this.childFields.add(String.valueOf(f));
            }
        }

        this.parentFields = new List<String>();
        List<Object> pFlds = (List<Object>) childNodeConfig.get('parentFields');
        if (pFlds != null) {
            for (Object f : pFlds) {
                this.parentFields.add(String.valueOf(f));
            }
        }
    }

    /**
     * Counts total children and generates page descriptors for cursor-based iteration.
     * @param bc The batch context provided by the platform
     * @return Iterable of page descriptor strings
     */
    public Iterable<String> start(Database.BatchableContext bc) {
        if (Schema.getGlobalDescribe().get(childObjectName) == null) {
            throw new DocGenException('Invalid child object: ' + childObjectName);
        }

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
     * Processes one page: queries children, renders loop body, converts to PDF,
     * saves as ContentVersion. The PDF is a standalone page fragment that the
     * stitch job will reference by URL without loading into heap.
     * @param bc The batch context
     * @param scope List of page descriptors
     */
    public void execute(Database.BatchableContext bc, List<String> scope) {
        if (Schema.getGlobalDescribe().get(childObjectName) == null) {
            return;
        }

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

            // Render the loop body HTML for this batch of records
            String fragmentHtml = DocGenService.renderLoopBodyForRecords(innerXml, relationshipName, records, allFields);

            // Save rendered XML fragment — stitch handles PDF conversion in groups,
            // or client fetches directly for DOCX assembly
            String seq = String.valueOf(fragmentSequence++).leftPad(5, '0');
            String fragExtension = ('PDF'.equalsIgnoreCase(outputFormat)) ? '.html' : '.xml';
            ContentVersion cv = new ContentVersion(
                Title = 'docgen_giant_' + jobId + '_' + seq,
                PathOnClient = 'docgen_giant_' + jobId + '_' + seq + fragExtension,
                VersionData = Blob.valueOf(fragmentHtml),
                IsMajorVersion = false,
                FirstPublishLocationId = jobId
            );
            insert cv; // NOPMD ApexCRUDViolation — internal fragment for Giant Query

            update new DocGen_Job__c(Id = jobId, Success_Count__c = fragmentSequence); // NOPMD ApexCRUDViolation — package-internal
        }
    }

    /**
     * For PDF output, launches the stitch Batch to assemble HTML fragments into final PDFs.
     * For DOCX/Native output, skips stitch entirely — client-side assembly fetches fragments
     * one at a time via getContentVersionBase64() and builds the DOCX ZIP in JavaScript.
     * @param bc The batch context
     */
    public void finish(Database.BatchableContext bc) {
        try {
            if ('PDF'.equalsIgnoreCase(outputFormat)) {
                Database.executeBatch(new DocGenGiantQueryStitchJob(
                    jobId, templateId, recordId, relationshipName, outputFormat
                ), 1); // batch size 1 = one PDF per execute()
            } else {
                // DOCX: no server-side stitch needed — client will assemble
                update new DocGen_Job__c(Id = jobId, Status__c = 'Completed'); // NOPMD ApexCRUDViolation — package-internal
            }
        } catch (Exception e) {
            update new DocGen_Job__c(Id = jobId, Status__c = 'Failed'); // NOPMD ApexCRUDViolation — package-internal
        }
    }
}
