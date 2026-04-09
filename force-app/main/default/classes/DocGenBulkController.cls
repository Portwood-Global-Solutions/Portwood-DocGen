public with sharing class DocGenBulkController {

    /**
     * Returns all DocGen templates for the bulk generation UI.
     * @return List of DocGen_Template__c records ordered by name
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getBulkTemplates() {
        /* code-analyzer-suppress ApexFlsViolation */
        return [SELECT Id, Name, Base_Object_API__c, Description__c, Output_Format__c, Query_Config__c, Test_Record_Id__c FROM DocGen_Template__c WITH SYSTEM_MODE ORDER BY Name LIMIT 2000];
    }

    /**
     * Validates a SOQL WHERE clause filter and returns the count of matching records.
     * @param objectName The SObject API name to query against
     * @param condition The WHERE clause condition to validate
     * @return The number of records matching the filter
     */
    @AuraEnabled
    public static Integer validateFilter(String objectName, String condition) {
        if (String.isBlank(objectName)) { return 0; }
        // Allowlist validation: object verified against Schema.getGlobalDescribe()
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            throw DocGenService.ahe('Invalid or inaccessible object.');
        }
        String sanitizedCondition = sanitizeCondition(condition);
        // Allowlist validation: WHERE clause field names verified against Schema.describeSObjects() field map
        if (String.isNotBlank(sanitizedCondition)) {
            Map<String, Schema.SObjectField> fieldMap = objType.getDescribe().fields.getMap();
            validateWhereClauseFields(sanitizedCondition, fieldMap);
        }
        String query = 'SELECT Count() FROM ' + String.escapeSingleQuotes(objectName);
        if (String.isNotBlank(sanitizedCondition)) {
            query += ' WHERE ' + sanitizedCondition;
        }
        // CxSAST: SOQL injection mitigated by Schema allowlist validation on object + WHERE field names verified against Schema.describeSObjects() field map + keyword blocklist + USER_MODE
        return Database.countQuery(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — object allowlist-validated against Schema.getGlobalDescribe(); condition fields allowlist-validated against Schema field map; USER_MODE enforced
    }

    /**
     * Allowlist validation: extracts field-name tokens from a WHERE clause and validates
     * each against the provided Schema field map. Tokens that look like values (quoted strings,
     * numbers, dates, booleans, null, bind variables) are skipped.
     */
    @TestVisible
    private static void validateWhereClauseFields(String whereClause, Map<String, Schema.SObjectField> fieldMap) {
        // Strip quoted string literals so they don't confuse the tokenizer
        String stripped = whereClause.replaceAll('\'[^\']*\'', '\'\'');
        // Tokenize on whitespace and parentheses
        List<String> tokens = stripped.split('[\\s(),]+');
        // SOQL operators and keywords to skip
        Set<String> skipTokens = new Set<String>{
            '=', '!=', '<', '>', '<=', '>=', 'LIKE', 'IN', 'NOT', 'AND', 'OR',
            'NULL', 'TRUE', 'FALSE', 'INCLUDES', 'EXCLUDES', 'LAST_N_DAYS',
            'NEXT_N_DAYS', 'TODAY', 'YESTERDAY', 'TOMORROW', 'LAST_WEEK',
            'THIS_WEEK', 'NEXT_WEEK', 'LAST_MONTH', 'THIS_MONTH', 'NEXT_MONTH',
            'LAST_QUARTER', 'THIS_QUARTER', 'NEXT_QUARTER', 'LAST_YEAR',
            'THIS_YEAR', 'NEXT_YEAR', 'LAST_90_DAYS', 'NEXT_90_DAYS',
            'LAST_N_MONTHS', 'NEXT_N_MONTHS', 'LAST_N_QUARTERS', 'NEXT_N_QUARTERS',
            'LAST_N_YEARS', 'NEXT_N_YEARS', ''
        };
        for (String token : tokens) {
            String t = token.trim();
            if (String.isBlank(t)) { continue; }
            String upper = t.toUpperCase();
            // Skip SOQL keywords, operators, quoted literals, numbers, date literals, bind vars
            if (skipTokens.contains(upper)) { continue; }
            if (t.startsWith('\'') || t.startsWith(':')) { continue; }
            if (t.isNumeric() || Pattern.matches('[0-9]{4}-[0-9]{2}-[0-9]{2}.*', upper)) { continue; }
            if (Pattern.matches('LAST_N_.*:\\d+', upper) || Pattern.matches('NEXT_N_.*:\\d+', upper)) { continue; }
            // This looks like a field name — allowlist validate against Schema
            String baseField = t.contains('.') ? t.split('\\.')[0].toLowerCase() : t.toLowerCase();
            if (!fieldMap.containsKey(baseField)) {
                // Try __r -> __c for custom relationship traversals
                String asLookup = baseField.endsWith('__r') ? baseField.substring(0, baseField.length() - 3) + '__c' : baseField;
                if (!fieldMap.containsKey(asLookup)) {
                    throw DocGenService.ahe('Invalid field in filter condition: ' + t);
                }
            }
        }
    }

    /**
     * Sanitization of dynamic WHERE conditions to prevent SOQL injection.
     * Two layers: (1) keyword blocklist rejects structural SOQL/DML keywords,
     * (2) caller performs allowlist validation of field names against Schema describe.
     */
    public static String sanitizeCondition(String condition) {
        if (String.isBlank(condition)) { return condition; }
        // Reject dangerous characters (statement termination, comments)
        if (condition.contains(';') || condition.contains('--') || condition.contains('/*')) {
            throw DocGenService.ahe('Invalid filter condition.');
        }
        // Normalize whitespace for keyword matching (tabs, newlines, multiple spaces -> single space)
        String normalized = condition.replaceAll('\\s+', ' ').toUpperCase().trim();
        // Reject conditions containing SOQL/DML keywords that don't belong in a WHERE clause
        List<String> disallowed = new List<String>{
            'SELECT ', 'INSERT ', 'UPDATE ', 'DELETE ', 'MERGE ', 'UNDELETE ',
            'WITH ', 'GROUP BY ', 'ORDER BY ', 'LIMIT ', 'OFFSET ', 'FOR UPDATE',
            'HAVING ', 'TYPEOF '
        };
        for (String keyword : disallowed) {
            if (normalized.contains(keyword)) {
                throw DocGenService.ahe('Invalid filter condition.');
            }
        }
        return condition;
    }

    /**
     * Analyzes a bulk job for governor limit risks before execution.
     * Checks SOQL queries, DML statements, heap (merge mode), and record count.
     * @param templateId The DocGen template record ID
     * @param recordCount Total number of records to be processed
     * @param batchSize Records per batch execution
     * @param mergePdf Whether merge mode is enabled
     * @return JobAnalysis with per-check results and overall verdict
     */
    @AuraEnabled
    public static JobAnalysis analyzeJob(Id templateId, Integer recordCount, Integer batchSize, Boolean mergePdf) {
        JobAnalysis analysis = new JobAnalysis();
        analysis.recordCount = recordCount;
        analysis.items = new List<AnalysisItem>();
        analysis.canProceed = true;

        if (templateId == null || recordCount == null || recordCount <= 0) {
            analysis.summary = 'No records to process.';
            return analysis;
        }

        Integer safeBatchSize = (batchSize != null && batchSize >= 1 && batchSize <= 200) ? batchSize : 1;
        Boolean isMerge = (mergePdf == true);

        try {
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> tempList = [SELECT Query_Config__c, Test_Record_Id__c, Output_Format__c
                FROM DocGen_Template__c WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1];
            DocGen_Template__c temp = tempList[0];

            // --- 1. SOQL Queries per batch execution ---
            Integer queriesPerRecord = countQueriesPerRecord(temp.Query_Config__c);
            // Overhead: template load (~3 queries first batch, cached after), job update (1)
            Integer overhead = 4;
            Integer soqlPerBatch = (queriesPerRecord * safeBatchSize) + overhead;
            Integer soqlLimit = 100; // async limit

            AnalysisItem soqlItem = new AnalysisItem();
            soqlItem.label = 'SOQL Queries';
            soqlItem.estimated = soqlPerBatch;
            soqlItem.limitVal = soqlLimit;
            if (soqlPerBatch >= soqlLimit) {
                soqlItem.status = 'error';
                soqlItem.message = soqlPerBatch + ' / ' + soqlLimit + ' per batch — will exceed limit. Reduce batch size to ' + Math.max(1, Math.floor((soqlLimit - overhead) / queriesPerRecord)) + ' or lower.';
                analysis.canProceed = false;
            } else if (soqlPerBatch >= 80) {
                soqlItem.status = 'warning';
                soqlItem.message = soqlPerBatch + ' / ' + soqlLimit + ' per batch — approaching limit. Consider reducing batch size.';
            } else {
                soqlItem.status = 'ok';
                soqlItem.message = soqlPerBatch + ' / ' + soqlLimit + ' per batch.';
            }
            analysis.items.add(soqlItem);

            // --- 2. DML Statements per batch execution ---
            // Each record: 1 CV insert. Merge mode: +1 HTML snippet CV per record. Job update: 1.
            Integer dmlPerRecord = isMerge ? 2 : 1;
            Integer dmlPerBatch = (dmlPerRecord * safeBatchSize) + 1;
            Integer dmlLimit = 150;

            AnalysisItem dmlItem = new AnalysisItem();
            dmlItem.label = 'DML Statements';
            dmlItem.estimated = dmlPerBatch;
            dmlItem.limitVal = dmlLimit;
            if (dmlPerBatch >= dmlLimit) {
                dmlItem.status = 'error';
                dmlItem.message = dmlPerBatch + ' / ' + dmlLimit + ' per batch — will exceed limit. Reduce batch size.';
                analysis.canProceed = false;
            } else if (dmlPerBatch >= 120) {
                dmlItem.status = 'warning';
                dmlItem.message = dmlPerBatch + ' / ' + dmlLimit + ' per batch — approaching limit.';
            } else {
                dmlItem.status = 'ok';
                dmlItem.message = dmlPerBatch + ' / ' + dmlLimit + ' per batch.';
            }
            analysis.items.add(dmlItem);

            // --- 3. Record Count ---
            AnalysisItem countItem = new AnalysisItem();
            countItem.label = 'Record Count';
            countItem.estimated = recordCount;
            countItem.limitVal = 50000;
            if (recordCount > 50000) {
                countItem.status = 'error';
                countItem.message = recordCount + ' records — exceeds 50,000 batch query locator limit.';
                analysis.canProceed = false;
            } else if (recordCount > 10000) {
                countItem.status = 'warning';
                countItem.message = recordCount + ' records — large job, may take a while.';
            } else {
                countItem.status = 'ok';
                countItem.message = recordCount + ' records.';
            }
            analysis.items.add(countItem);

            // --- 4. Heap estimation ---
            if (String.isNotBlank(temp.Test_Record_Id__c)) {
                try {
                    // Measure actual heap consumed by generation (queries + template + rendering)
                    Integer heapBefore = Limits.getHeapSize();
                    String html = DocGenService.generateHtmlForRecord(templateId, temp.Test_Record_Id__c, null);
                    Integer heapAfter = Limits.getHeapSize();
                    // Generation heap = full cost (queries + parsing + rendering) — used for batch estimate
                    Long generationBytes = Math.max(heapAfter - heapBefore, html.length() * 2);
                    // Snippet size = just the HTML output — used for merge estimate
                    // Merge Queueable only reads back saved HTML snippets, not full generation heap
                    Long snippetBytes = html.length() * 2; // UTF-16

                    if (isMerge) {
                        // Merge heap: Queueable reads all HTML snippets + concatenates + Blob.toPdf()
                        AnalysisItem heapItem = new AnalysisItem();
                        heapItem.label = 'Merge Heap';
                        heapItem.limitVal = 12;
                        // snippetBytes × records × 1.5 (overhead for string concat + PDF render)
                        Decimal totalMb = ((snippetBytes * recordCount) * 1.5) / (1024.0 * 1024.0);
                        heapItem.estimated = totalMb.setScale(2);

                        if (totalMb >= 10.0) {
                            heapItem.status = 'error';
                            heapItem.message = totalMb.setScale(1) + 'MB / 12MB — high risk of heap failure. Reduce record count or switch to Individual Files.';
                            analysis.canProceed = false;
                        } else if (totalMb >= 7.0) {
                            heapItem.status = 'warning';
                            heapItem.message = totalMb.setScale(1) + 'MB / 12MB — moderate usage, monitor job.';
                        } else {
                            heapItem.status = 'ok';
                            heapItem.message = totalMb.setScale(1) + 'MB / 12MB — safe.';
                        }
                        analysis.items.add(heapItem);
                    }

                    // Per-batch heap: measured heap × batch size (each execute() gets fresh 12MB)
                    AnalysisItem batchHeapItem = new AnalysisItem();
                    batchHeapItem.label = 'Batch Heap';
                    batchHeapItem.limitVal = 12;
                    Decimal batchMb = ((generationBytes * safeBatchSize) * 1.3) / (1024.0 * 1024.0);
                    batchHeapItem.estimated = batchMb.setScale(2);

                    if (batchMb >= 10.0) {
                        batchHeapItem.status = 'error';
                        batchHeapItem.message = batchMb.setScale(1) + 'MB / 12MB per batch — reduce batch size to ' + Math.max(1, Math.floor(9.0 / (batchMb / safeBatchSize))) + ' or lower.';
                        analysis.canProceed = false;
                    } else if (batchMb >= 7.0) {
                        batchHeapItem.status = 'warning';
                        batchHeapItem.message = batchMb.setScale(1) + 'MB / 12MB per batch — consider reducing batch size.';
                    } else {
                        batchHeapItem.status = 'ok';
                        batchHeapItem.message = batchMb.setScale(1) + 'MB / 12MB per batch.';
                    }
                    analysis.items.add(batchHeapItem);
                } catch (Exception e) {
                    AnalysisItem heapItem = new AnalysisItem();
                    heapItem.label = 'Heap Estimate';
                    heapItem.status = 'warning';
                    heapItem.message = 'Could not estimate — test record may be inaccessible.';
                    analysis.items.add(heapItem);
                }
            } else {
                AnalysisItem heapItem = new AnalysisItem();
                heapItem.label = 'Heap Estimate';
                heapItem.status = 'warning';
                heapItem.message = 'No test record on template — heap estimate unavailable.';
                analysis.items.add(heapItem);
            }

            // --- Build summary ---
            Integer errors = 0;
            Integer warnings = 0;
            for (AnalysisItem item : analysis.items) {
                if (item.status == 'error') { errors++; }
                else if (item.status == 'warning') { warnings++; }
            }
            if (errors > 0) {
                analysis.summary = 'Cannot proceed — ' + errors + ' limit(s) will be exceeded.';
            } else if (warnings > 0) {
                analysis.summary = 'Should work, but ' + warnings + ' item(s) need attention.';
            } else {
                analysis.summary = 'All checks passed. Safe to proceed.';
            }

        } catch (Exception e) {
            analysis.summary = 'Analysis error: ' + e.getMessage();
        }
        return analysis;
    }

    /**
     * Counts the number of SOQL queries needed per record based on the query config format.
     */
    private static Integer countQueriesPerRecord(String queryConfig) {
        if (String.isBlank(queryConfig)) { return 1; }
        if (!queryConfig.trim().startsWith('{')) { return 1; } // V1 flat string

        try {
            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(queryConfig);
            Object versionObj = config.get('v');
            Integer version = (versionObj instanceof Integer) ? (Integer) versionObj : ((Decimal) versionObj).intValue();

            if (version == 2) {
                // V2: 1 base + children + junctions
                Integer count = 1;
                List<Object> children = (List<Object>) config.get('children');
                if (children != null) { count += children.size(); }
                List<Object> junctions = (List<Object>) config.get('junctions');
                if (junctions != null) { count += junctions.size() * 2; } // junction query + target query
                return count;
            } else if (version == 3) {
                // V3: one query per node
                List<Object> nodes = (List<Object>) config.get('nodes');
                return (nodes != null) ? nodes.size() : 1;
            }
        } catch (Exception e) { // NOPMD EmptyCatchBlock — intentional fallback to 1 query for unparseable configs
        }
        return 1;
    }

    public class JobAnalysis {
        @AuraEnabled public Integer recordCount;
        @AuraEnabled public Boolean canProceed = true;
        @AuraEnabled public List<AnalysisItem> items;
        @AuraEnabled public String summary;
    }

    public class AnalysisItem {
        @AuraEnabled public String label;
        @AuraEnabled public String status;   // 'ok', 'warning', 'error'
        @AuraEnabled public String message;
        @AuraEnabled public Decimal estimated;
        @AuraEnabled public Decimal limitVal;
    }

    // Keep for backward compatibility — delegates to analyzeJob
    @AuraEnabled
    public static HeapEstimate estimateHeapUsage(Id templateId, Integer recordCount) {
        JobAnalysis analysis = analyzeJob(templateId, recordCount, 1, true);
        HeapEstimate estimate = new HeapEstimate();
        for (AnalysisItem item : analysis.items) {
            if (item.label == 'Merge Heap') {
                estimate.estimatedHeapMb = item.estimated;
                estimate.isRisk = (item.status == 'error');
                estimate.message = item.message;
                return estimate;
            }
        }
        estimate.message = analysis.summary;
        return estimate;
    }

    public class HeapEstimate {
        @AuraEnabled public Decimal estimatedHeapMb;
        @AuraEnabled public Boolean isRisk = false;
        @AuraEnabled public String message;
    }

    /**
     * Submits a bulk document generation job for async processing.
     * @param templateId The DocGen template record ID
     * @param condition Optional SOQL WHERE clause to filter records
     * @param jobLabel Optional human-readable label for the job
     * @param mergePdf Whether to merge all outputs into a single PDF
     * @param batchSize Number of records per batch execution (1-200)
     * @param mergeOnly Whether to only generate merged PDF without individual files
     * @return The DocGen_Job__c record ID
     */
    @AuraEnabled
    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    public static Id submitJob(Id templateId, String condition, String jobLabel, Boolean mergePdf, Integer batchSize, Boolean mergeOnly) {
        try {
            Boolean isMergeOnly = (mergeOnly == true);
            Boolean isMergeMode = (mergePdf == true) || isMergeOnly;

            // 1. Create Job Record
            DocGen_Job__c job = new DocGen_Job__c(
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                Template__c = templateId,
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                Query_Condition__c = condition,
                Status__c = 'Queued',
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                Merge_Only__c = isMergeOnly
            );
            if (String.isNotBlank(jobLabel)) {
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                job.Label__c = jobLabel;
            }
            /* code-analyzer-suppress ApexFlsViolation */
            insert job; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

            // 2. Run Batch — user-configurable batch size (default 1, max 200)
            Integer size = (batchSize != null && batchSize >= 1 && batchSize <= 200) ? batchSize : 1;
            DocGenBatch batch = new DocGenBatch(job.Id, isMergeMode, isMergeOnly);
            Database.executeBatch(batch, size);

            return job.Id;
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error starting bulk generation job.');
        }
    }

    /**
     * Returns the current status and progress of a bulk generation job.
     * @param jobId The DocGen_Job__c record ID
     * @return The job record with status and count fields
     */
    @AuraEnabled
    public static DocGen_Job__c getJobStatus(Id jobId) {
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Job__c> jsRecords = [SELECT Id, Name, Status__c, Success_Count__c, Error_Count__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE];
        return jsRecords[0];
    }

    /**
     * Returns the 20 most recent bulk generation jobs ordered by creation date.
     * @return List of DocGen_Job__c records with status and template info
     */
    @AuraEnabled
    public static List<DocGen_Job__c> getRecentJobs() {
        /* code-analyzer-suppress ApexFlsViolation */
        return [SELECT Id, Name, Label__c, Status__c, Success_Count__c, Error_Count__c, Total_Records__c,
                   CreatedDate, Template__r.Name, Template__r.Output_Format__c
            FROM DocGen_Job__c
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 20];
    }

    /**
     * Returns ContentVersion IDs for PDFs generated by a completed bulk job.
     * Queries the same records the job processed, finds PDFs created after the job started.
     * @param jobId The DocGen_Job__c record ID
     * @return List of maps with 'label' (file title) and 'value' (ContentVersion ID)
     */
    @AuraEnabled
    public static List<Map<String, String>> getJobGeneratedPdfs(Id jobId) {
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Job__c> gpRecords = [SELECT Template__c, Template__r.Base_Object_API__c, Template__r.Name,
                   Query_Condition__c, CreatedDate
            FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE];
        DocGen_Job__c job = gpRecords[0];

        String baseObject = job.Template__r.Base_Object_API__c;
        if (Schema.getGlobalDescribe().get(baseObject) == null) {
            throw DocGenService.ahe('Invalid base object on job template.');
        }

        // Query the same records the batch processed
        String recQuery = 'SELECT Id FROM ' + String.escapeSingleQuotes(baseObject);
        String condition = sanitizeCondition(job.Query_Condition__c);
        if (String.isNotBlank(condition)) {
            recQuery += ' WHERE ' + condition;
        }
        recQuery += ' LIMIT 2000';

        Set<Id> recordIds = new Set<Id>();
        for (SObject rec : Database.query(recQuery, AccessLevel.USER_MODE)) {
            recordIds.add(rec.Id);
        }

        if (recordIds.isEmpty()) { return new List<Map<String, String>>(); }

        // Find PDFs attached to those records created after the job was created
        Datetime jobStart = job.CreatedDate.addMinutes(-1);
        List<ContentDocumentLink> links = [
            SELECT ContentDocument.LatestPublishedVersionId,
                   ContentDocument.Title, LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :recordIds
            AND ContentDocument.FileExtension = 'pdf'
            AND ContentDocument.CreatedDate >= :jobStart
            WITH USER_MODE
            ORDER BY ContentDocument.Title
        ];

        List<Map<String, String>> result = new List<Map<String, String>>();
        for (ContentDocumentLink link : links) {
            result.add(new Map<String, String>{
                'label' => link.ContentDocument.Title + '.pdf',
                'value' => link.ContentDocument.LatestPublishedVersionId
            });
        }
        return result;
    }

    // --- Saved Queries ---
    /**
     * Returns saved filter queries for a template, ordered by creation date descending.
     * @param templateId The DocGen template record ID
     * @return List of DocGen_Saved_Query__c records
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Saved_Query__c> getSavedQueries(Id templateId) {
        /* code-analyzer-suppress ApexFlsViolation */
        return [SELECT Id, Name, Description__c, Query_Condition__c
            FROM DocGen_Saved_Query__c
            WHERE DocGen_Template__c = :templateId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC];
    }

    /**
     * Saves a named filter query for reuse with a template.
     * @param templateId The DocGen template record ID
     * @param label The display name for the saved query
     * @param description Optional description of the query
     * @param condition The SOQL WHERE clause condition
     */
    @AuraEnabled
    public static void saveQuery(Id templateId, String label, String description, String condition) {
        try {
            DocGen_Saved_Query__c sq = new DocGen_Saved_Query__c(
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                DocGen_Template__c = templateId,
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                Name = label,
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                Description__c = description,
                // CxSAST: FLS enforced by DocGen permission sets; package-internal custom objects
                Query_Condition__c = condition
            );
            /* code-analyzer-suppress ApexFlsViolation */
            insert sq; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error saving query.');
        }
    }

    /**
     * Deletes a saved filter query.
     * @param queryId The DocGen_Saved_Query__c record ID to delete
     */
    @AuraEnabled
    public static void deleteQuery(Id queryId) {
        try {
            if (!Schema.sObjectType.DocGen_Saved_Query__c.isDeletable()) {
                throw DocGenService.ahe('Insufficient access.');
            }
            /* code-analyzer-suppress ApexFlsViolation */
            delete new DocGen_Saved_Query__c(Id = queryId);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error deleting query.');
        }
    }
}