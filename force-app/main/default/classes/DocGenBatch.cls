public with sharing class DocGenBatch implements Database.Batchable<SObject>, Database.Stateful, Database.AllowsCallouts {

    public Id jobId;
    public Id templateId;
    public String baseObject;
    public String condition;
    public String queryConfig;
    public Boolean mergeMode;
    public Boolean mergeOnly;

    public Integer successCount = 0;
    public Integer failCount = 0;

    // Bulk data cache — populated in start(), read in execute()
    public Id dataCacheCvId;
    public String cachedDataJson;

    // Merge mode: sequence counter for HTML snippet ordering
    public Integer htmlSequence = 0;

    /**
     * Constructs a batch job in default (non-merge) mode.
     * @param jobId The DocGen_Job__c record ID
     */
    public DocGenBatch(Id jobId) {
        this(jobId, false, false);
    }

    /**
     * Constructs a batch job with optional merge mode.
     * @param jobId The DocGen_Job__c record ID
     * @param mergeMode Whether to merge all outputs into a single PDF
     */
    public DocGenBatch(Id jobId, Boolean mergeMode) {
        this(jobId, mergeMode, false);
    }

    /**
     * Constructs a batch job with merge mode and merge-only options.
     * @param jobId The DocGen_Job__c record ID
     * @param mergeMode Whether to merge all outputs into a single PDF
     * @param mergeOnly Whether to only generate merged PDF without individual files
     */
    public DocGenBatch(Id jobId, Boolean mergeMode, Boolean mergeOnly) {
        this.jobId = jobId;
        this.mergeMode = mergeMode || (mergeOnly == true);
        this.mergeOnly = (mergeOnly == true);
        DocGen_Job__c job = [SELECT Template__c, Template__r.Base_Object_API__c, Template__r.Query_Config__c, Query_Condition__c FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE];
        this.templateId = job.Template__c;
        this.baseObject = job.Template__r.Base_Object_API__c;
        this.condition = job.Query_Condition__c;
        this.queryConfig = job.Template__r.Query_Config__c;
    }

    /**
     * Initializes the batch job: sets status, counts records, builds data cache, and returns query locator.
     * @param bc The batch context provided by the platform
     * @return QueryLocator for the records to process
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Update Status to Processing
        update new DocGen_Job__c(Id = jobId, Status__c = 'Processing'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets

        // Validate object name against Schema to prevent injection
        if (Schema.getGlobalDescribe().get(baseObject) == null) {
            throw new DocGenException('Invalid object: ' + baseObject);
        }

        String sanitizedCondition = sanitizeCondition(condition);
        String query = 'SELECT Id FROM ' + baseObject;
        if (String.isNotBlank(sanitizedCondition)) {
            query += ' WHERE ' + sanitizedCondition;
        }
        query += ' WITH USER_MODE';

        // Count total records for progress tracking
        String countQuery = 'SELECT Count() FROM ' + baseObject;
        if (String.isNotBlank(sanitizedCondition)) {
            countQuery += ' WHERE ' + sanitizedCondition;
        }
        Integer total = Database.countQuery(countQuery, AccessLevel.USER_MODE);
        update new DocGen_Job__c(Id = jobId, Status__c = 'Processing', Total_Records__c = total); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets

        // Bulk data pre-cache for V3 configs
        buildDataCache(query, sanitizedCondition);

        return Database.getQueryLocator(query);
    }

    /**
     * Bulk-queries all record data and saves as a JSON ContentVersion on the Job.
     * Only runs for V3 query configs. Gracefully falls back on any failure.
     */
    private void buildDataCache(String query, String sanitizedCondition) {
        try {
            Integer configVersion = DocGenDataRetriever.getConfigVersion(queryConfig);
                        if (configVersion < 3) { return; }

            // Collect all record IDs
            String idQuery = 'SELECT Id FROM ' + String.escapeSingleQuotes(baseObject);
            if (String.isNotBlank(sanitizedCondition)) {
                idQuery += ' WHERE ' + sanitizedCondition;
            }
            idQuery += ' LIMIT 50000';

            Set<Id> recordIds = new Set<Id>();
            for (SObject rec : Database.query(idQuery, AccessLevel.USER_MODE)) { // NOPMD ApexSOQLInjection - baseObject validated by Schema.getGlobalDescribe() above; condition sanitized
                recordIds.add(rec.Id);
            }
                        if (recordIds.isEmpty()) { return; }

            // Bulk query all record data in one pass
            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(queryConfig.trim());
            Map<Id, Map<String, Object>> bulkData = DocGenDataRetriever.getRecordDataV3Bulk(recordIds, config);

            // Resolve rich text images on each record's data
            for (Map<String, Object> recordData : bulkData.values()) {
                DocGenController.resolveRichTextImages(recordData);
            }

            // Convert to String-keyed map for JSON serialization
            Map<String, Object> serializableMap = new Map<String, Object>();
            for (Id recId : bulkData.keySet()) {
                serializableMap.put(String.valueOf(recId), bulkData.get(recId));
            }

            String jsonStr = JSON.serialize(serializableMap);

            // Heap guard: skip caching if JSON is too large
            if (jsonStr.length() > 4000000) {
                return;
            }

            // Save as ContentVersion linked to Job
            ContentVersion cv = new ContentVersion(
                Title = 'docgen_cache_' + jobId,
                PathOnClient = 'docgen_cache_' + jobId + '.json',
                VersionData = Blob.valueOf(jsonStr),
                IsMajorVersion = true,
                FirstPublishLocationId = jobId
            );
            SObjectAccessDecision cvDec = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
            insert cvDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
            cv.Id = cvDec.getRecords()[0].Id;

            // Store CV Id on Job and in Stateful memory
            dataCacheCvId = cv.Id;
            cachedDataJson = jsonStr;

            update new DocGen_Job__c(Id = jobId, Data_Cache_CV__c = cv.Id); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets

        } catch (Exception e) {
            // Graceful fallback: continue without cache
            dataCacheCvId = null;
            cachedDataJson = null;
        }
    }

    /**
     * Basic sanitization of dynamic WHERE conditions to prevent SOQL injection.
     */
    private static String sanitizeCondition(String condition) {
                if (String.isBlank(condition)) { return condition; }
        // Reject dangerous characters (statement termination, comments)
        if (condition.contains(';') || condition.contains('--') || condition.contains('/*')) {
            throw new DocGenException('Invalid filter condition.');
        }
        String upper = condition.toUpperCase().trim();
        List<String> disallowed = new List<String>{
            'SELECT ', 'INSERT ', 'UPDATE ', 'DELETE ', 'MERGE ', 'UNDELETE ',
            'WITH ', 'GROUP BY ', 'ORDER BY ', 'LIMIT ', 'OFFSET ', 'FOR UPDATE',
            'HAVING ', 'TYPEOF '
        };
        for (String keyword : disallowed) {
            if (upper.contains(keyword)) {
                throw new DocGenException('Invalid filter condition.');
            }
        }
        return condition;
    }

    /**
     * Generates an individual document for a record, using cached data if available.
     * Also captures HTML snippet for merge mode.
     */
    private void generateIndividualDocument(Id recordId, Map<String, Object> recordData) {
        if (recordData != null) {
            DocGenService.generateDocumentFromData(templateId, recordId, recordData);
        } else {
            DocGenService.generateDocument(templateId, recordId);
        }

        // Merge mode (not merge-only): also capture HTML snippet for merged PDF
        if (mergeMode && DocGenService.lastRenderedHtml != null) {
            saveHtmlSnippet(DocGenService.lastRenderedHtml);
            DocGenService.lastRenderedHtml = null;
        }
    }

    /**
     * Writes one HTML snippet as a tiny ContentVersion linked to the Job.
     * No reads — just write. The Queueable assembles them all at the end.
     */
    private void saveHtmlSnippet(String html) {
        String seq = String.valueOf(htmlSequence++).leftPad(5, '0');
        ContentVersion cv = new ContentVersion(
            Title = 'docgen_merge_' + jobId + '_' + seq,
            PathOnClient = 'docgen_merge_' + jobId + '_' + seq + '.html',
            VersionData = Blob.valueOf(html),
            IsMajorVersion = false,
            FirstPublishLocationId = jobId
        );
        SObjectAccessDecision cvDec = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
        insert cvDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
    }

    /**
     * Processes a batch of records: generates documents and optionally captures HTML snippets for merge.
     * @param bc The batch context provided by the platform
     * @param scope The list of records to process in this batch execution
     */
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        // Lazy-load cache from ContentVersion if Stateful string was lost
        if (dataCacheCvId != null && cachedDataJson == null) {
            try {
                ContentVersion cv = [SELECT VersionData FROM ContentVersion WHERE Id = :dataCacheCvId WITH USER_MODE LIMIT 1];
                cachedDataJson = cv.VersionData.toString();
            } catch (Exception e) {
                // Intentionally swallowed: cached data CV not found or inaccessible — fall through to fresh query
                dataCacheCvId = null;
            }
        }

        // Deserialize cache once per execute
        Map<String, Object> dataCache = null;
        if (cachedDataJson != null) {
            try {
                dataCache = (Map<String, Object>) JSON.deserializeUntyped(cachedDataJson);
            } catch (Exception e) {
                // Intentionally swallowed: cached JSON deserialization failed (corrupted or schema mismatch) — fall through to fresh query
                dataCache = null;
            }
        }

        for (SObject rec : scope) {
            try {
                Map<String, Object> recordData = null;
                if (dataCache != null) {
                    recordData = (Map<String, Object>) dataCache.get(String.valueOf(rec.Id));
                }

                if (mergeOnly) {
                    // Merge-only: generate HTML, save snippet — no Blob.toPdf(), no individual file
                    String html = DocGenService.generateHtmlForRecord(templateId, rec.Id, recordData);
                    saveHtmlSnippet(html);
                } else {
                    // Normal: generate + save individual PDF per record
                    generateIndividualDocument(rec.Id, recordData);
                }

                successCount++;
            } catch (Exception e) {
                failCount++;
            }
        }

        // Update Job record incrementally for real-time progress tracking
        update new DocGen_Job__c( // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
            Id = jobId,
            Success_Count__c = successCount,
            Error_Count__c = failCount
        );
    }

    /**
     * Finalizes the batch job: updates status, chains merge Queueable if needed, sends notification.
     * @param bc The batch context provided by the platform
     */
    public void finish(Database.BatchableContext bc) {
        String status;
        if (successCount == 0 && failCount > 0) {
            status = 'Failed';
        } else if (failCount > 0) {
            status = 'Completed with Errors';
        } else {
            status = 'Completed';
        }

        // Merge mode: chain Queueable to assemble snippets + render one PDF
        if (mergeMode && htmlSequence > 0) {
            try {
                status = 'Merging';

                update new DocGen_Job__c( // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
                    Id = jobId,
                    Status__c = status,
                    Success_Count__c = successCount,
                    Error_Count__c = failCount
                );

                // Chain the merge Queueable — it reads all snippets by title prefix
                System.enqueueJob(new DocGenMergeJob(jobId));
            } catch (Exception e) {
                status = 'Completed with Errors';
                update new DocGen_Job__c(Id = jobId, Status__c = status, Success_Count__c = successCount, Error_Count__c = failCount); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
            }
        } else {
            update new DocGen_Job__c( // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
                Id = jobId,
                Status__c = status,
                Success_Count__c = successCount,
                Error_Count__c = failCount
            );
        }

        // Send notification for non-merge jobs (merge jobs notify from DocGenMergeJob)
        if (!mergeMode || htmlSequence == 0) {
            sendJobNotification(status);
        }

        // Clean up data cache ContentVersion
        if (dataCacheCvId != null) {
            try {
                Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :dataCacheCvId WITH USER_MODE].ContentDocumentId;
                if (Schema.sObjectType.ContentDocument.isDeletable()) {
                    delete new ContentDocument(Id = docId); // NOPMD ApexCRUDViolation — CRUD checked above
                }
            } catch (Exception e) {
                // Intentionally swallowed — cleanup failure is non-fatal
                String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
            }
        }
    }

    private void sendJobNotification(String status) {
        try {
            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'DocGen_Job_Complete'
                WITH SYSTEM_MODE LIMIT 1
            ];
                        if (types.isEmpty()) { return; }

            DocGen_Job__c job = [SELECT CreatedById, Label__c, Name FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE LIMIT 1];
            String jobName = String.isNotBlank(job.Label__c) ? job.Label__c : job.Name;

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(types[0].Id);
            notification.setTargetId(jobId);
            notification.setTitle('DocGen: ' + jobName + ' — ' + status);
            notification.setBody(successCount + ' documents generated' + (failCount > 0 ? ', ' + failCount + ' failed' : '') + '. Tap to view.');
            notification.send(new Set<String>{ job.CreatedById });
        } catch (Exception e) {
            // Intentionally swallowed — notification failure is non-fatal
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
        }
    }
}
