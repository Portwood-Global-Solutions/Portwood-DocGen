global with sharing class DocGenFlowAction {
    
    global class Request {
        @InvocableVariable(label='Template ID' required=true)
        global Id templateId;
        
        @InvocableVariable(label='Base Record ID' required=true)
        global Id recordId;
    }
    
    global class Response {
        @InvocableVariable(label='Content Document ID')
        global Id contentDocumentId;
        
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Generate Document (Native)' description='Generates a DOCX/PPTX document using the DocGen package. Note: Does not support complex loops or conditional logic in this version.')
    global static List<Response> generateDocument(List<Request> requests) {
        List<Response> responses = new List<Response>();
        
        for (Request req : requests) {
            Response res = new Response();
            try {
                // Call Service
                Id docId = DocGenService.generateDocument(req.templateId, req.recordId);
                res.contentDocumentId = docId;
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                System.debug('DocGen Flow Error: ' + e.getStackTraceString());
            }
            responses.add(res);
        }
        
        // Flush collected PDF rendition jobs
        // Direct enqueuing preserves the user's auth context for loopback callouts
        DocGenRenditionService.enqueueRenditions(true);

        return responses;
    }
}