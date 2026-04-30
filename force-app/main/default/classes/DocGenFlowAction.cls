/**
 * Invocable action for generating a single document from a Flow.
 * Supports PDF, DOCX, PPTX, and XLSX output. Full merge tag support
 * including loops, conditionals, images, barcodes, and aggregates.
 */
global with sharing class DocGenFlowAction { // NOPMD AvoidGlobalModifier — global required for @InvocableMethod visibility in subscriber orgs
    global class Request {
        @InvocableVariable(label='Template ID' required=true description='The DocGen Template record ID')
        global Id templateId;

        @InvocableVariable(
            label='Record ID'
            required=false
            description='The source record ID to merge data from. Required unless JSON Data is supplied.'
        )
        global Id recordId;

        @InvocableVariable(
            label='Save to Record'
            description='If true, attach the generated file to the source record via ContentDocumentLink. Default: false'
        )
        global Boolean saveToRecord;

        @InvocableVariable(
            label='Document Title'
            description='Override the generated file name. Leave blank to use the template default.'
        )
        global String documentTitle;

        @InvocableVariable(
            label='Output Format Override'
            description='Optional. Override the template Output Format at runtime. Allowed: PDF, Word, PowerPoint. Word templates can render to PDF or DOCX. PowerPoint templates render only to PPTX. Leave blank to use the template default. Throws if the template has Lock Output Format = true.'
        )
        global String outputFormatOverride;

        @InvocableVariable(
            label='JSON Data'
            required=false
            description='Optional. Pre-built merge data as a JSON string — bypasses the SOQL data retrieval entirely. Use this when a Flow has assembled custom data from external APIs, computed values, or cross-object aggregations and wants to render directly without persisting to records first. Shape mirrors the merge engine: {"Name":"Acme","Amount":50000,"Items":{"records":[{"Product":"Widget","Qty":2}]}}. When supplied, this takes precedence over Record ID for data — but Record ID is still used as the file attachment target if Save to Record is true.'
        )
        global String jsonData;
    }

    global class Response {
        @InvocableVariable(label='Content Document ID')
        global Id contentDocumentId;

        @InvocableVariable(label='Content Version ID')
        global Id contentVersionId;

        @InvocableVariable(label='Error Message')
        global String errorMessage;

        @InvocableVariable(label='Success')
        global Boolean success;
    }

    @InvocableMethod(
        label='Generate Document'
        description='Generates a document (PDF, DOCX, PPTX, XLSX) from a DocGen template and record. Supports all merge tags including loops, images, barcodes, QR codes, and aggregates.'
    )
    global static List<Response> generateDocument(List<Request> requests) {
        List<Response> responses = new List<Response>();

        // Phase 1: Generate all documents and collect results
        Map<Integer, Id> docIdsByIndex = new Map<Integer, Id>();
        for (Integer i = 0; i < requests.size(); i++) {
            Request req = requests[i];
            Response res = new Response();
            try {
                Boolean useDataMap = String.isNotBlank(req.jsonData);
                if (!useDataMap && req.recordId == null) {
                    throw new DocGenException('Either Record ID or JSON Data must be supplied.');
                }

                Id docId;
                if (useDataMap) {
                    // Parse the supplied JSON into the merge engine's expected Map shape.
                    // JSON.deserializeUntyped returns Map<String,Object> for objects, List<Object>
                    // for arrays — matches what DocGenDataRetriever's other paths produce.
                    Object parsed = JSON.deserializeUntyped(req.jsonData);
                    if (!(parsed instanceof Map<String, Object>)) {
                        throw new DocGenException(
                            'JSON Data must deserialize to an object (Map), not an array or scalar.'
                        );
                    }
                    Map<String, Object> dataMap = (Map<String, Object>) parsed;

                    if (req.recordId != null) {
                        // Caller wants the file attached to the supplied record (FirstPublishLocationId).
                        // saveToRecord=true adds an extra ContentDocumentLink in Phase 3.
                        docId = DocGenService.generateAndSaveFromData(
                            req.templateId,
                            req.recordId,
                            dataMap,
                            req.outputFormatOverride,
                            req.documentTitle
                        );
                    } else {
                        // No record context — render PDF and insert as a standalone ContentVersion.
                        // Caller can pick it up via the returned ContentDocumentId / ContentVersionId.
                        Map<String, Object> result = DocGenService.generatePdfBlobFromData(req.templateId, dataMap);
                        Blob pdfBlob = (Blob) result.get('blob');
                        String title = String.isNotBlank(req.documentTitle)
                            ? req.documentTitle
                            : (String) result.get('title');
                        if (String.isBlank(title)) {
                            title = 'Generated_Document';
                        }
                        ContentVersion cv = new ContentVersion();
                        cv.Title = title;
                        cv.PathOnClient = title + '.pdf';
                        cv.VersionData = pdfBlob;
                        SObjectAccessDecision dec = Security.stripInaccessible(
                            AccessType.CREATABLE,
                            new List<ContentVersion>{ cv }
                        );
                        insert dec.getRecords(); // NOPMD ApexCRUDViolation - FLS enforced via stripInaccessible
                        Id newCvId = ((ContentVersion) dec.getRecords()[0]).Id;
                        ContentVersion saved = [
                            SELECT Id, ContentDocumentId
                            FROM ContentVersion
                            WHERE Id = :newCvId
                            WITH USER_MODE
                            LIMIT 1
                        ];
                        docId = saved.ContentDocumentId;
                        res.contentVersionId = saved.Id;
                    }
                } else {
                    docId = DocGenService.generateDocument(
                        req.templateId,
                        req.recordId,
                        req.outputFormatOverride,
                        req.documentTitle
                    );
                }
                res.contentDocumentId = docId;
                res.success = true;
                docIdsByIndex.put(i, docId);
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                res.success = false;
            }
            responses.add(res);
        }

        // Phase 2: Bulk query ContentVersion IDs for all generated documents
        Set<Id> allDocIds = new Set<Id>(docIdsByIndex.values());
        allDocIds.remove(null);
        if (!allDocIds.isEmpty()) {
            Map<Id, Id> cvIdByDocId = new Map<Id, Id>();
            for (ContentVersion cv : [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE ContentDocumentId IN :allDocIds
                WITH USER_MODE
            ]) {
                // Keep only the first CV per document (matching original LIMIT 1 behavior)
                if (!cvIdByDocId.containsKey(cv.ContentDocumentId)) {
                    cvIdByDocId.put(cv.ContentDocumentId, cv.Id);
                }
            }
            for (Integer i : docIdsByIndex.keySet()) {
                Id docId = docIdsByIndex.get(i);
                if (docId != null && cvIdByDocId.containsKey(docId)) {
                    responses[i].contentVersionId = cvIdByDocId.get(docId);
                }
            }
        }

        // Phase 3: Bulk link documents to source records where requested
        // First, collect which doc+record pairs need linking
        Set<Id> linkDocIds = new Set<Id>();
        Map<Integer, Id> saveToRecordByIndex = new Map<Integer, Id>();
        for (Integer i = 0; i < requests.size(); i++) {
            Request req = requests[i];
            Id docId = docIdsByIndex.get(i);
            if (req.saveToRecord == true && docId != null && responses[i].success == true) {
                linkDocIds.add(docId);
                saveToRecordByIndex.put(i, req.recordId);
            }
        }

        if (!linkDocIds.isEmpty()) {
            // Bulk query existing links to avoid duplicates
            Set<String> existingLinkKeys = new Set<String>();
            for (ContentDocumentLink cdl : [
                SELECT ContentDocumentId, LinkedEntityId
                FROM ContentDocumentLink
                WHERE ContentDocumentId IN :linkDocIds
                WITH USER_MODE
            ]) {
                existingLinkKeys.add(String.valueOf(cdl.ContentDocumentId) + ':' + String.valueOf(cdl.LinkedEntityId));
            }

            // Build list of new links needed
            List<ContentDocumentLink> linksToInsert = new List<ContentDocumentLink>();
            for (Integer i : saveToRecordByIndex.keySet()) {
                Id docId = docIdsByIndex.get(i);
                Id recordId = saveToRecordByIndex.get(i);
                String linkKey = String.valueOf(docId) + ':' + String.valueOf(recordId);
                if (!existingLinkKeys.contains(linkKey)) {
                    linksToInsert.add(
                        new ContentDocumentLink(
                            ContentDocumentId = docId,
                            LinkedEntityId = recordId,
                            ShareType = 'V',
                            Visibility = 'AllUsers'
                        )
                    );
                }
            }

            if (!linksToInsert.isEmpty()) {
                SObjectAccessDecision decision = Security.stripInaccessible(AccessType.CREATABLE, linksToInsert);
                insert decision.getRecords(); // NOPMD ApexCRUDViolation - FLS enforced via stripInaccessible
            }
        }

        return responses;
    }
}
