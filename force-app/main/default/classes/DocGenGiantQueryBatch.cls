/**
 * Batch Apex that harvests child records in cursor-based pages and renders
 * template loop body fragments. Each execute() queries one page of children,
 * renders the loop body for those records, and saves the result as a
 * ContentVersion fragment. After all pages are processed, chains the
 * DocGenGiantQueryStitchJob to assemble fragments and produce the final document.
 *
 * Implements Database.Batchable<String> (not SObject) so we can use page
 * descriptors as the iterable — each string triggers one cursor page query.
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
        this.batchSize = 200;

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
     * Updates job status to 'Harvesting'.
     * @param bc The batch context provided by the platform
     * @return Iterable of page descriptor strings
     */
    public Iterable<String> start(Database.BatchableContext bc) {
        // Validate object name against Schema to prevent injection
        if (Schema.getGlobalDescribe().get(childObjectName) == null) {
            throw new DocGenException('Invalid child object: ' + childObjectName);
        }

        // Count total children
        String countQuery = 'SELECT COUNT() FROM ' + String.escapeSingleQuotes(childObjectName) +
            ' WHERE ' + String.escapeSingleQuotes(lookupField) + ' = :recordId WITH USER_MODE';
        Integer totalChildren = Database.countQuery(countQuery);

        // Update job status
        Integer totalPages = (Integer) Math.ceil((Decimal) totalChildren / batchSize);
        DocGen_Job__c jobUpdate = new DocGen_Job__c(
            Id = jobId,
            Status__c = 'Harvesting',
            Total_Records__c = totalChildren
        );
        update jobUpdate; // NOPMD ApexCRUDViolation — package-internal object; CRUD controlled by permission set

        // Generate page descriptors
        List<String> pages = new List<String>();
        for (Integer i = 0; i < totalPages; i++) {
            pages.add('page:' + i);
        }

        // Edge case: if no children, still need at least an empty list
        if (pages.isEmpty()) {
            pages.add('page:0');
        }

        this.lastCursorId = null;
        return pages;
    }

    /**
     * Processes one page of child records: queries, renders loop body, saves fragment.
     * Uses cursor-based pagination (Id > lastCursorId) to avoid OFFSET limits.
     * @param bc The batch context
     * @param scope List of page descriptors (typically one per execute)
     */
    public void execute(Database.BatchableContext bc, List<String> scope) {
        // Validate object against Schema
        if (Schema.getGlobalDescribe().get(childObjectName) == null) {
            return;
        }

        for (String pageDescriptor : scope) {
            // Build SELECT fields
            List<String> selectFields = new List<String>{ 'Id' };
            for (String f : childFields) {
                if (f != 'Id') {
                    selectFields.add(f);
                }
            }
            for (String f : parentFields) {
                selectFields.add(f);
            }

            // Cursor-based query
            String query = 'SELECT ' + String.join(selectFields, ', ') +
                ' FROM ' + String.escapeSingleQuotes(childObjectName) +
                ' WHERE ' + String.escapeSingleQuotes(lookupField) + ' = :recordId';

            if (lastCursorId != null) {
                query += ' AND Id > :lastCursorId';
            }

            query += ' ORDER BY Id LIMIT :batchSize';

            List<SObject> records = Database.query(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — childObjectName validated by Schema.getGlobalDescribe(); lookupField from template config; USER_MODE enforced

            if (records.isEmpty()) {
                continue;
            }

            // Update cursor
            lastCursorId = records[records.size() - 1].Id;

            // Build combined field list for rendering
            List<String> allFields = new List<String>();
            allFields.addAll(childFields);
            allFields.addAll(parentFields);

            // Render fragment
            String fragment = DocGenService.renderLoopBodyForRecords(innerXml, relationshipName, records, allFields);

            // Save as ContentVersion fragment
            String seq = String.valueOf(fragmentSequence++).leftPad(5, '0');
            ContentVersion cv = new ContentVersion(
                Title = 'docgen_giant_' + jobId + '_' + seq,
                PathOnClient = 'docgen_giant_' + jobId + '_' + seq + '.xml',
                VersionData = Blob.valueOf(fragment),
                IsMajorVersion = false,
                FirstPublishLocationId = jobId
            );
            insert cv; // NOPMD ApexCRUDViolation — internal fragment file for Giant Query processing

            // Update job progress
            DocGen_Job__c jobProgress = new DocGen_Job__c(
                Id = jobId,
                Success_Count__c = fragmentSequence
            );
            update jobProgress; // NOPMD ApexCRUDViolation — package-internal object; CRUD controlled by permission set
        }
    }

    /**
     * Chains the stitch Queueable to assemble all fragments into the final document.
     * @param bc The batch context
     */
    public void finish(Database.BatchableContext bc) {
        try {
            System.enqueueJob(new DocGenGiantQueryStitchJob(
                jobId, templateId, recordId, relationshipName, outputFormat
            ));
        } catch (Exception e) {
            update new DocGen_Job__c(Id = jobId, Status__c = 'Failed'); // NOPMD ApexCRUDViolation — package-internal object; CRUD controlled by permission set
        }
    }
}
