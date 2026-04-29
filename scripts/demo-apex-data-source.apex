// Demo: Render a document straight from an Apex-built data wrapper — no SObject behind it.
//
// Use case: Flow / Apex caller has aggregated, computed, or external data that doesn't
// exist as records in Salesforce. They want DocGen to render a document off that wrapper
// without persisting to records first or implementing the DocGenDataProvider interface.
//
// What this exercises:
//   - DocGenService.generatePdfBlobFromData(templateId, dataMap) — pure render, returns blob
//   - DocGenService.generateAndSaveFromData(templateId, recordId, dataMap, format) — render + attach
//   - HTML template (no DOCX needed) with parent/child loop merge tags
//   - {SUM:Items.Total:currency} aggregate over child records supplied entirely in-memory
//   - {#IF expr}…{:else}…{/IF} expression conditional driven by computed totals
//
// All three render against the SAME wrapper — proves the data shape is engine-portable.

Integer pass = 0;
Integer fail = 0;
Id parkAcct;
Id tmplId;

// ── 1. Wipe + setup a parent record we can attach the demo PDF to ──
try {
    delete [SELECT Id FROM DocGen_Template__c WHERE Name = 'Apex Data Source Demo'];
    delete [SELECT Id FROM Account WHERE Name = 'Apex DataSrc Demo Parent'];

    Account a = new Account(Name = 'Apex DataSrc Demo Parent', Industry = 'Software');
    insert a;
    parkAcct = a.Id;
    pass++;
    System.debug('PARENT ACCT INSERTED: ' + parkAcct);
} catch (Exception e) {
    fail++;
    System.debug('SETUP FAIL: ' + e.getMessage());
    return;
}

// ── 2. Build a simple HTML template — no SObject querying involved ──
//   Tags reference data that exists ONLY in the in-memory wrapper.
String html =
    '<html><body style="font-family:Helvetica;font-size:11pt;color:#222;">' +
    '<h1 style="color:#1F4E79;border-bottom:2px solid #1F4E79;padding-bottom:6px;">VENDOR INVOICE</h1>' +
    '<p style="margin:0;color:#555;">Issued: {IssueDate:MMMM dd, yyyy} · Due: {DueDate:MMMM dd, yyyy}</p>' +
    '<p style="margin:6px 0;"><b>Bill To:</b> {BillTo.Name}<br/>{BillTo.Address}</p>' +
    '<h2 style="color:#1F4E79;margin-top:18px;">Line Items</h2>' +
    '<table style="width:100%;border-collapse:collapse;">' +
    '<tr style="background:#eef2f7;">' +
    '<th align="left">Description</th><th align="right">Qty</th>' +
    '<th align="right">Unit</th><th align="right">Total</th>' +
    '</tr>' +
    '{#Items}' +
    '<tr><td>{Description}</td>' +
    '<td align="right">{Qty}</td>' +
    '<td align="right">{UnitPrice:currency}</td>' +
    '<td align="right">{Total:currency}</td></tr>' +
    '{/Items}' +
    '<tr style="background:#fafafa;font-weight:bold;border-top:2px solid #1F4E79;">' +
    '<td colspan="3" align="right">Subtotal</td>' +
    '<td align="right">{SUM:Items.Total:currency}</td></tr>' +
    '<tr><td colspan="3" align="right">Tax ({TaxRatePct}%)</td>' +
    '<td align="right">{TaxAmount:currency}</td></tr>' +
    '<tr style="background:#1F4E79;color:#fff;font-weight:bold;">' +
    '<td colspan="3" align="right">Total Due</td>' +
    '<td align="right">{GrandTotal:currency}</td></tr>' +
    '</table>' +
    '<p style="margin-top:18px;">' +
    '{#IF GrandTotal > 10000}' +
    '<b style="color:#a02525;">Wire transfer required for invoices over $10,000.</b>' +
    '{:else}' +
    '<i>Payment accepted via ACH or check.</i>' +
    '{/IF}' +
    '</p>' +
    '<p style="margin-top:18px;color:#777;font-size:9pt;">' +
    '{Items.totalSize} line item(s) · Reference #{InvoiceNumber}' +
    '</p>' +
    '</body></html>';

try {
    DocGen_Template__c tmpl = new DocGen_Template__c(
        Name = 'Apex Data Source Demo',
        Description__c = 'Renders a vendor invoice from an in-memory Apex wrapper (no SObject, no SOQL).',
        Type__c = 'HTML',
        Output_Format__c = 'PDF',
        Base_Object_API__c = 'Account', // arbitrary — engine ignores this when data is supplied
        // Query_Config__c can be anything (or even blank) — it gets bypassed when dataMap is supplied
        Query_Config__c = 'Name',
        Category__c = 'Demo'
    );
    insert tmpl;
    tmplId = tmpl.Id;

    ContentVersion cv = new ContentVersion(
        Title = 'Apex Data Source Demo Body',
        PathOnClient = 'invoice.html',
        VersionData = Blob.valueOf(html),
        FirstPublishLocationId = tmplId
    );
    insert cv;
    cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

    insert new DocGen_Template_Version__c(
        Template__c = tmplId,
        Content_Version_Id__c = cv.Id,
        Is_Active__c = true,
        Type__c = 'HTML',
        Base_Object_API__c = 'Account'
    );
    pass++;
    System.debug('TEMPLATE PERSISTED: ' + tmplId);
} catch (Exception e) {
    fail++;
    System.debug('TEMPLATE FAIL: ' + e.getMessage());
    return;
}

// ── 3. Build the in-memory wrapper. This is the "Apex DTO as input source." ──
//   Could come from a Flow's Apex action, a callout response, computed totals, etc.
//   Map shape mirrors what the merge engine consumes from any source (V1/V2/V3/V4).
Decimal subtotal = 0;
List<Object> lineRecords = new List<Object>();
List<Map<String, Object>> rawLines = new List<Map<String, Object>>{
    new Map<String, Object>{ 'Description' => 'Premium Cloud Subscription (Annual)', 'Qty' => 12, 'UnitPrice' => 850 },
    new Map<String, Object>{ 'Description' => 'Implementation Services', 'Qty' => 1, 'UnitPrice' => 4500 },
    new Map<String, Object>{ 'Description' => 'Custom Integration (Salesforce)', 'Qty' => 1, 'UnitPrice' => 3200 },
    new Map<String, Object>{ 'Description' => 'Managed Support — 24/7 (Quarterly)', 'Qty' => 4, 'UnitPrice' => 1750 }
};
for (Map<String, Object> line : rawLines) {
    Decimal total = ((Integer) line.get('Qty')) * ((Integer) line.get('UnitPrice'));
    line.put('Total', total);
    subtotal += total;
    lineRecords.add(line);
}

Decimal taxRatePct = 8.25;
Decimal taxAmount = (subtotal * taxRatePct / 100).setScale(2);
Decimal grandTotal = subtotal + taxAmount;

Map<String, Object> wrapper = new Map<String, Object>{
    'InvoiceNumber' => 'INV-2026-0427',
    'IssueDate' => Date.today(),
    'DueDate' => Date.today().addDays(30),
    'BillTo' => new Map<String, Object>{
        'Name' => 'Pacific Realty Group — Demo',
        'Address' => '4521 Sunset Boulevard, Santa Monica, CA 90405'
    },
    'Items' => new Map<String, Object>{ 'records' => lineRecords, 'totalSize' => lineRecords.size() },
    'TaxRatePct' => taxRatePct,
    'TaxAmount' => taxAmount,
    'GrandTotal' => grandTotal
};

System.debug('WRAPPER SUBTOTAL: ' + subtotal + ' | TAX: ' + taxAmount + ' | GRAND: ' + grandTotal);

// ── 4. Path A — pure blob render (no record context at all) ──
try {
    Map<String, Object> result = DocGenService.generatePdfBlobFromData(tmplId, wrapper);
    Blob pdf = (Blob) result.get('blob');
    String fh = DocGenService.lastRenderedHtml;

    if (pdf == null || pdf.size() < 1000) {
        fail++;
        System.debug('BLOB-ONLY RENDER: FAIL — size: ' + (pdf == null ? 0 : pdf.size()));
    } else {
        pass++;
        System.debug('BLOB-ONLY RENDER: PASS — ' + pdf.size() + ' bytes');
    }

    // Spot-check that the in-memory data actually rendered
    Boolean ok =
        fh != null &&
        fh.contains('Pacific Realty Group') && // BillTo.Name parent merge
        fh.contains('Premium Cloud Subscription') && // child loop row
        fh.contains('Custom Integration') && // another loop row
        fh.contains('$10,200.00') && // Premium Cloud Sub * 12 = 10200
        fh.contains('INV-2026-0427'); // simple field
    if (ok) {
        pass++;
        System.debug('CHILD LOOP + PARENT MERGE TAGS RESOLVED: PASS');
    } else {
        fail++;
        System.debug('MERGE TAG RESOLUTION: FAIL — html excerpt: ' + (fh != null ? fh.left(800) : 'null'));
    }

    // {SUM:Items.Total:currency} aggregate over the in-memory list
    Decimal expectedSubtotal = subtotal;
    String formattedSubtotal = '$' + expectedSubtotal.format();
    Boolean aggOk = fh != null && fh.contains(formattedSubtotal);
    if (aggOk) {
        pass++;
        System.debug('AGGREGATE OVER IN-MEMORY LIST: PASS — ' + formattedSubtotal);
    } else {
        fail++;
        System.debug('AGGREGATE FAIL — expected ' + formattedSubtotal + ' in HTML');
    }

    // {#IF GrandTotal > 10000} branch — should fire :else since 18750 > 10000
    Boolean ifOk = fh != null && fh.contains('Wire transfer required');
    if (ifOk) {
        pass++;
        System.debug('IF-EXPR ON COMPUTED TOTAL: PASS — true branch fired');
    } else {
        fail++;
        System.debug('IF-EXPR FAIL — html excerpt: ' + (fh != null ? fh.left(800) : 'null'));
    }
} catch (Exception e) {
    fail++;
    System.debug('BLOB-ONLY PATH FAIL: ' + e.getMessage() + ' line ' + e.getLineNumber());
}

// ── 5. Path B — render + attach to a record ──
try {
    Id docId = DocGenService.generateAndSaveFromData(tmplId, parkAcct, wrapper, 'PDF');
    System.assertNotEquals(null, docId);
    Integer linked = [
        SELECT COUNT()
        FROM ContentDocumentLink
        WHERE ContentDocumentId = :docId AND LinkedEntityId = :parkAcct
    ];
    if (linked > 0) {
        pass++;
        System.debug('RENDER+ATTACH: PASS — ContentDoc ' + docId + ' linked to Account ' + parkAcct);
    } else {
        fail++;
        System.debug('RENDER+ATTACH: FAIL — no ContentDocumentLink found');
    }
} catch (Exception e) {
    fail++;
    System.debug('SAVE PATH FAIL: ' + e.getMessage() + ' line ' + e.getLineNumber());
}

// ── 6. Path C — Flow action with JSON Data + no record ──
try {
    DocGenFlowAction.Request req = new DocGenFlowAction.Request();
    req.templateId = tmplId;
    req.recordId = null;
    req.jsonData = JSON.serialize(wrapper);

    List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
        new List<DocGenFlowAction.Request>{ req }
    );
    if (responses[0].success && responses[0].contentVersionId != null) {
        pass++;
        System.debug('FLOW ACTION (jsonData, no record): PASS — CV: ' + responses[0].contentVersionId);
    } else {
        fail++;
        System.debug('FLOW ACTION FAIL: ' + responses[0].errorMessage);
    }
} catch (Exception e) {
    fail++;
    System.debug('FLOW ACTION PATH FAIL: ' + e.getMessage());
}

// ── Summary ──
System.debug('========================================');
System.debug('APEX-DATA-SOURCE DEMO — PASS: ' + pass + '  FAIL: ' + fail);
System.debug('========================================');
System.debug('>>> Template: /lightning/r/portwoodglobal__DocGen_Template__c/' + tmplId + '/view');
System.debug('>>> Parent record (with attached PDF): /lightning/r/Account/' + parkAcct + '/view');
System.debug('>>> Files tab on the Account → "Apex Data Source Demo.pdf"');
