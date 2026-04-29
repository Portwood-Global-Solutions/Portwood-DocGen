/**
 * Invocable action for starting bulk document generation from a Flow.
 * Exposes the full bulk generation pipeline: filtering, batch size,
 * combined PDF, and individual file options.
 */
global with sharing class DocGenBulkFlowAction { // NOPMD AvoidGlobalModifier — global required for @InvocableMethod visibility in subscriber orgs
    global class Request {
        @InvocableVariable(label='Template ID' required=true description='The DocGen Template record ID')
        global Id templateId;

        @InvocableVariable(
            label='WHERE Condition'
            description='Optional SOQL WHERE clause to filter records (e.g. Industry = \'Technology\')'
        )
        global String queryCondition;

        @InvocableVariable(
            label='Record IDs'
            required=false
            description='Optional collection of record IDs to generate documents for. When supplied, the bulk job runs against just these records (Id IN clause). Combine with WHERE Condition to filter the set further. Skips the need to save a Query Filter when the calling Flow has already determined which records to target.'
        )
        global List<String> recordIds;

        @InvocableVariable(label='Job Label' description='A friendly label for this job (shown in Job History)')
        global String jobLabel;

        @InvocableVariable(
            label='Combined PDF Only'
            description='Recommended. Produce one merged PDF with all records. Uses minimal heap. Default: true'
        )
        global Boolean combinedPdfOnly;

        @InvocableVariable(
            label='Also Keep Individual Files'
            description='Generate a separate PDF per record in addition to the combined PDF. Uses more heap.'
        )
        global Boolean keepIndividualFiles;

        @InvocableVariable(
            label='Batch Size'
            description='Records per batch transaction. Use 1 for complex templates, 10-50 for simple ones. Default: 1'
        )
        global Integer batchSize;
    }

    global class Response {
        @InvocableVariable(label='Job ID')
        global Id jobId;

        @InvocableVariable(label='Error Message')
        global String errorMessage;

        @InvocableVariable(label='Success')
        global Boolean success;
    }

    @InvocableMethod(
        label='Generate Bulk Documents'
        description='Starts a batch job to generate documents for multiple records. Supports combined PDF, individual files, batch sizing, and WHERE filters.'
    )
    global static List<Response> generateBulkDocuments(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request req : requests) {
            Response res = new Response();
            try {
                // Default: combined PDF only (most efficient)
                Boolean mergeOnly = (req.combinedPdfOnly != false && req.keepIndividualFiles != true);
                Boolean mergePdf = mergeOnly || (req.keepIndividualFiles == true);
                Integer batchSize = (req.batchSize != null && req.batchSize > 0) ? req.batchSize : 1;

                // Build the effective WHERE clause. When the Flow supplies a
                // collection of IDs, fold them into an `Id IN (...)` clause so
                // the bulk pipeline runs only against those records. Combines
                // (AND) with any user-supplied queryCondition.
                String effectiveCondition = buildEffectiveCondition(req.queryCondition, req.recordIds);

                Id jobId = DocGenBulkController.submitJob(
                    req.templateId,
                    effectiveCondition,
                    req.jobLabel,
                    mergePdf,
                    batchSize,
                    mergeOnly
                );
                res.jobId = jobId;
                res.success = true;
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                res.success = false;
            }
            responses.add(res);
        }

        return responses;
    }

    /**
     * Combines a user-supplied WHERE condition with an Id collection into a single
     * sanitized clause. Each ID is validated against Salesforce's 15/18-char
     * alphanumeric format before inclusion to defend against injection.
     */
    @TestVisible
    private static String buildEffectiveCondition(String userCondition, List<String> recordIds) {
        String idClause = null;
        if (recordIds != null && !recordIds.isEmpty()) {
            List<String> quoted = new List<String>();
            for (String raw : recordIds) {
                if (String.isBlank(raw)) {
                    continue;
                }
                String trimmed = raw.trim();
                // 15 or 18 char alphanumeric — Salesforce ID format. Reject anything else.
                if (!Pattern.matches('[a-zA-Z0-9]{15}|[a-zA-Z0-9]{18}', trimmed)) {
                    throw new DocGenException('Invalid record ID supplied: ' + trimmed);
                }
                quoted.add('\'' + trimmed + '\'');
            }
            if (!quoted.isEmpty()) {
                idClause = 'Id IN (' + String.join(quoted, ',') + ')';
            }
        }

        Boolean hasUser = String.isNotBlank(userCondition);
        if (hasUser && idClause != null) {
            return '(' + userCondition + ') AND ' + idClause;
        }
        if (idClause != null) {
            return idClause;
        }
        return userCondition;
    }
}
