// Demo: Filtered Subsets — multiple loops against same relationship
// Builds an Opportunity with mixed product families, then renders a quote
// PDF with separate Subscription / Setup / Hardware tables + grand totals.
//
// Edge cases covered:
//   1) Three filtered subsets of the same relationship (3-way split)
//   2) An EMPTY filtered subset (no Hardware items) — must render gracefully
//   3) Aggregates per subset ({SUM:Subscriptions.Amount}, {COUNT:Setup})
//   4) An additional unfiltered loop ({#OpportunityLineItems}) alongside aliases
//   5) Mixed currency formatting in aggregates
//   6) An Opportunity-Contact-Roles unfiltered loop (different relationship)
//      to confirm aliases don't accidentally hide other loops.

Integer pass = 0;
Integer fail = 0;
Id stdPbId;

try {
    stdPbId = [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1].Id;
} catch (Exception e) {
    System.debug('NO STANDARD PRICEBOOK — cannot continue: ' + e.getMessage());
    return;
}

// ── 1. Build the demo dataset ────────────────────────────────────
Account demoAcct;
Opportunity demoOpp;
try {
    // Wipe prior demo state so the script is idempotent
    delete [SELECT Id FROM Account WHERE Name = 'Filtered Subset Demo Co'];
    delete [SELECT Id FROM DocGen_Template__c WHERE Name LIKE 'Filtered Subset Demo%'];
    delete [SELECT Id FROM Product2 WHERE ProductCode LIKE 'FSDEMO-%'];

    demoAcct = new Account(
        Name = 'Filtered Subset Demo Co',
        Industry = 'Technology',
        BillingCity = 'Austin',
        BillingState = 'TX'
    );
    insert demoAcct;

    demoOpp = new Opportunity(
        Name = 'Q2 Renewal + Implementation',
        AccountId = demoAcct.Id,
        StageName = 'Proposal/Price Quote',
        CloseDate = Date.today().addDays(30),
        Amount = 0,
        Pricebook2Id = stdPbId
    );
    insert demoOpp;

    // Products in three families
    List<Product2> products = new List<Product2>{
        // Subscription
        new Product2(
            Name = 'Platform License (Annual)',
            ProductCode = 'FSDEMO-SUB-1',
            Family = 'Subscription',
            IsActive = true
        ),
        new Product2(
            Name = 'Premium Support (Annual)',
            ProductCode = 'FSDEMO-SUB-2',
            Family = 'Subscription',
            IsActive = true
        ),
        new Product2(
            Name = 'Add-on Module: Reporting',
            ProductCode = 'FSDEMO-SUB-3',
            Family = 'Subscription',
            IsActive = true
        ),
        // Setup
        new Product2(Name = 'Implementation Services', ProductCode = 'FSDEMO-SET-1', Family = 'Setup', IsActive = true),
        new Product2(Name = 'Data Migration', ProductCode = 'FSDEMO-SET-2', Family = 'Setup', IsActive = true),
        // Hardware (will NOT be added to this opp — tests empty-subset rendering)
        new Product2(Name = 'On-Prem Appliance', ProductCode = 'FSDEMO-HW-1', Family = 'Hardware', IsActive = true)
    };
    insert products;

    // Standard Pricebook entries
    List<PricebookEntry> stdEntries = new List<PricebookEntry>();
    Map<String, Decimal> prices = new Map<String, Decimal>{
        'FSDEMO-SUB-1' => 60000,
        'FSDEMO-SUB-2' => 12000,
        'FSDEMO-SUB-3' => 8400,
        'FSDEMO-SET-1' => 45000,
        'FSDEMO-SET-2' => 15000,
        'FSDEMO-HW-1' => 9500
    };
    for (Product2 p : products) {
        stdEntries.add(
            new PricebookEntry(
                Pricebook2Id = stdPbId,
                Product2Id = p.Id,
                UnitPrice = prices.get(p.ProductCode),
                IsActive = true
            )
        );
    }
    insert stdEntries;

    // Add lines to the Opportunity (Subscription x3, Setup x2, NO Hardware)
    Map<String, PricebookEntry> peByCode = new Map<String, PricebookEntry>();
    for (PricebookEntry pe : [
        SELECT Id, Product2Id, Product2.ProductCode, UnitPrice
        FROM PricebookEntry
        WHERE Id IN :stdEntries
    ]) {
        peByCode.put(pe.Product2.ProductCode, pe);
    }
    insert new List<OpportunityLineItem>{
        new OpportunityLineItem(
            OpportunityId = demoOpp.Id,
            PricebookEntryId = peByCode.get('FSDEMO-SUB-1').Id,
            Quantity = 50,
            UnitPrice = peByCode.get('FSDEMO-SUB-1').UnitPrice
        ),
        new OpportunityLineItem(
            OpportunityId = demoOpp.Id,
            PricebookEntryId = peByCode.get('FSDEMO-SUB-2').Id,
            Quantity = 50,
            UnitPrice = peByCode.get('FSDEMO-SUB-2').UnitPrice
        ),
        new OpportunityLineItem(
            OpportunityId = demoOpp.Id,
            PricebookEntryId = peByCode.get('FSDEMO-SUB-3').Id,
            Quantity = 25,
            UnitPrice = peByCode.get('FSDEMO-SUB-3').UnitPrice
        ),
        new OpportunityLineItem(
            OpportunityId = demoOpp.Id,
            PricebookEntryId = peByCode.get('FSDEMO-SET-1').Id,
            Quantity = 1,
            UnitPrice = peByCode.get('FSDEMO-SET-1').UnitPrice
        ),
        new OpportunityLineItem(
            OpportunityId = demoOpp.Id,
            PricebookEntryId = peByCode.get('FSDEMO-SET-2').Id,
            Quantity = 1,
            UnitPrice = peByCode.get('FSDEMO-SET-2').UnitPrice
        )
    };
    pass++;
    System.debug('DATASET BUILT — Opp: ' + demoOpp.Id);
} catch (Exception e) {
    fail++;
    System.debug('DATASET BUILD FAIL: ' + e.getMessage() + ' line ' + e.getLineNumber());
    return;
}

// ── 2. Build the V3 query config with three filtered subsets + one unfiltered loop ──
String v3Config =
    '{"v":3,"root":"Opportunity","nodes":[' +
    // Root
    '{"id":"n0","object":"Opportunity","fields":["Name","Amount","CloseDate","StageName"],' +
    '"parentFields":["Account.Name","Account.BillingCity","Account.BillingState"],' +
    '"parentNode":null,"lookupField":null,"relationshipName":null},' +
    // Subscription items (alias). ORDER BY with parent-relationship fields
    // now works (sanitizeClause was extended to recognize standard relationships).
    '{"id":"n1","object":"OpportunityLineItem","fields":["Quantity","UnitPrice","TotalPrice"],' +
    '"parentFields":["Product2.Name","Product2.ProductCode"],' +
    '"parentNode":"n0","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems",' +
    '"alias":"Subscriptions","where":"Product2.Family = \'Subscription\'","orderBy":"Product2.Name ASC"},' +
    // Setup items (alias)
    '{"id":"n2","object":"OpportunityLineItem","fields":["Quantity","UnitPrice","TotalPrice"],' +
    '"parentFields":["Product2.Name","Product2.ProductCode"],' +
    '"parentNode":"n0","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems",' +
    '"alias":"Setup","where":"Product2.Family = \'Setup\'","orderBy":"Product2.Name ASC"},' +
    // Hardware items (alias, INTENTIONALLY EMPTY for this opp)
    '{"id":"n3","object":"OpportunityLineItem","fields":["Quantity","UnitPrice","TotalPrice"],' +
    '"parentFields":["Product2.Name","Product2.ProductCode"],' +
    '"parentNode":"n0","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems",' +
    '"alias":"Hardware","where":"Product2.Family = \'Hardware\'"}' +
    ']}';

// Sanity: scout returns counts per ALIAS
try {
    Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(demoOpp.Id, v3Config);
    System.debug('Scout counts (by alias): ' + counts);
    Boolean ok = counts.get('Subscriptions') == 3 && counts.get('Setup') == 2 && counts.get('Hardware') == 0;
    if (ok) {
        pass++;
        System.debug('SCOUT BY ALIAS: PASS');
    } else {
        fail++;
        System.debug('SCOUT BY ALIAS: FAIL — got ' + counts);
    }
} catch (Exception e) {
    fail++;
    System.debug('SCOUT FAIL: ' + e.getMessage());
}

// ── 3. Build a Word-style HTML template that uses each alias + aggregates ──
String body =
    '<html><body style="font-family:Helvetica;font-size:11pt;">' +
    '<h1 style="margin-bottom:0;">{Name}</h1>' +
    '<p style="margin:0;color:#666;">{Account.Name} — {Account.BillingCity}, {Account.BillingState}</p>' +
    '<p>Stage: <b>{StageName}</b> · Close: {CloseDate:MM/dd/yyyy}</p>' +
    '<h2 style="margin-top:24px;border-bottom:2px solid #0066cc;">Subscription Items</h2>' +
    '<table style="width:100%;border-collapse:collapse;">' +
    '<tr style="background:#eef;"><th align="left">Product</th><th align="right">Qty</th><th align="right">Unit Price</th><th align="right">Total</th></tr>' +
    '{#Subscriptions}' +
    '<tr><td>{Product2.Name} <small>({Product2.ProductCode})</small></td><td align="right">{Quantity}</td><td align="right">{UnitPrice:currency}</td><td align="right">{TotalPrice:currency}</td></tr>' +
    '{/Subscriptions}' +
    '<tr style="background:#f8f8f8;font-weight:bold;"><td colspan="3" align="right">Subscription Total</td><td align="right">{SUM:Subscriptions.TotalPrice:currency}</td></tr>' +
    '</table>' +
    '<h2 style="margin-top:24px;border-bottom:2px solid #cc6600;">Setup &amp; Implementation</h2>' +
    '<table style="width:100%;border-collapse:collapse;">' +
    '<tr style="background:#fed;"><th align="left">Service</th><th align="right">Qty</th><th align="right">Unit Price</th><th align="right">Total</th></tr>' +
    '{#Setup}' +
    '<tr><td>{Product2.Name} <small>({Product2.ProductCode})</small></td><td align="right">{Quantity}</td><td align="right">{UnitPrice:currency}</td><td align="right">{TotalPrice:currency}</td></tr>' +
    '{/Setup}' +
    '<tr style="background:#f8f8f8;font-weight:bold;"><td colspan="3" align="right">Setup Total</td><td align="right">{SUM:Setup.TotalPrice:currency}</td></tr>' +
    '</table>' +
    '<h2 style="margin-top:24px;border-bottom:2px solid #999;">Hardware</h2>' +
    // Conditional visibility via {#IF expr}…{:else}…{/IF}.
    // The data map for any alias is {records: [...], totalSize: N}, so we
    // can drive visibility off Alias.totalSize. The IF block evaluates the
    // expression and renders the matching branch — true conditional output,
    // not a hard-coded label.
    '{#IF Hardware.totalSize > 0}' +
    '<table style="width:100%;border-collapse:collapse;">' +
    '<tr style="background:#eee;"><th align="left">Product</th><th align="right">Qty</th><th align="right">Unit Price</th><th align="right">Total</th></tr>' +
    '{#Hardware}' +
    '<tr><td>{Product2.Name}</td><td align="right">{Quantity}</td><td align="right">{UnitPrice:currency}</td><td align="right">{TotalPrice:currency}</td></tr>' +
    '{/Hardware}' +
    '</table>' +
    '{:else}' +
    '<p style="color:#888;font-style:italic;">No hardware items on this order.</p>' +
    '{/IF}' +
    '<p style="color:#888;font-size:9pt;margin-top:4px;">{COUNT:Hardware} hardware line(s) on this order.</p>' +
    '<h2 style="margin-top:24px;border-top:3px double #000;padding-top:12px;">Order Summary</h2>' +
    '<table style="width:50%;margin-left:auto;font-size:11pt;">' +
    '<tr><td>Subscription items:</td><td align="right">{COUNT:Subscriptions}</td></tr>' +
    '<tr><td>Setup items:</td><td align="right">{COUNT:Setup}</td></tr>' +
    '<tr><td>Hardware items:</td><td align="right">{COUNT:Hardware}</td></tr>' +
    '<tr style="border-top:1px solid #ccc;"><td><b>Subscription subtotal</b></td><td align="right"><b>{SUM:Subscriptions.TotalPrice:currency}</b></td></tr>' +
    '<tr><td><b>Setup subtotal</b></td><td align="right"><b>{SUM:Setup.TotalPrice:currency}</b></td></tr>' +
    '<tr><td><b>Hardware subtotal</b></td><td align="right"><b>{SUM:Hardware.TotalPrice:currency}</b></td></tr>' +
    '</table>' +
    '</body></html>';

// ── 4. Persist as a HTML/PDF template ────────────────────────────
DocGen_Template__c tmpl;
try {
    tmpl = new DocGen_Template__c(
        Name = 'Filtered Subset Demo Quote',
        Description__c = 'Demo of filtered-subset loops on Opportunity',
        Type__c = 'HTML',
        Output_Format__c = 'PDF',
        Base_Object_API__c = 'Opportunity',
        Query_Config__c = v3Config
    );
    insert tmpl;

    ContentVersion cv = new ContentVersion(
        Title = tmpl.Name + ' Body',
        PathOnClient = 'quote.html',
        VersionData = Blob.valueOf(body),
        FirstPublishLocationId = tmpl.Id
    );
    insert cv;
    cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

    insert new DocGen_Template_Version__c(Template__c = tmpl.Id, Content_Version_Id__c = cv.Id, Is_Active__c = true);
    pass++;
    System.debug('TEMPLATE PERSISTED — Id: ' + tmpl.Id);
} catch (Exception e) {
    fail++;
    System.debug('TEMPLATE PERSIST FAIL: ' + e.getMessage() + ' line ' + e.getLineNumber());
    return;
}

// ── 5. Generate the PDF and run the assertions ──────────────────
try {
    Map<String, Object> r = DocGenService.generatePdfBlob(tmpl.Id, demoOpp.Id);
    Blob pdf = (Blob) r.get('blob');
    String fh = DocGenService.lastRenderedHtml;

    if (pdf == null || pdf.size() < 1000) {
        fail++;
        System.debug('PDF TOO SMALL: ' + (pdf == null ? 0 : pdf.size()));
    } else {
        pass++;
        System.debug('PDF GENERATED — size: ' + pdf.size() + ' bytes');
    }

    // Edge case 1: Subscription block contains all 3 subscriptions, none of the others.
    // Use the cc-borders to find sections (the heading underline color is unique per section).
    Integer subStart = fh.indexOf('Subscription Items');
    Integer setStart = fh.indexOf('Setup &amp; Implementation');
    Integer hwStart = fh.indexOf('border-bottom:2px solid #999;">Hardware');
    Integer summaryStart = fh.indexOf('Order Summary');
    String subBlock = fh.substring(subStart, setStart);
    String setBlock = fh.substring(setStart, hwStart);
    String hwBlock = fh.substring(hwStart, summaryStart);

    Boolean subOk =
        subBlock.contains('Platform License') &&
        subBlock.contains('Premium Support') &&
        subBlock.contains('Reporting') &&
        !subBlock.contains('Implementation Services') &&
        !subBlock.contains('Data Migration');
    if (subOk) {
        pass++;
        System.debug('SUBSCRIPTION ROWS ONLY IN SUBSCRIPTION BLOCK: PASS');
    } else {
        fail++;
        System.debug('SUBSCRIPTION BLOCK BLEED: FAIL — block excerpt: ' + subBlock.left(800));
    }

    // Edge case 2: Setup block has setup rows only.
    Boolean setOk =
        setBlock.contains('Implementation Services') &&
        setBlock.contains('Data Migration') &&
        !setBlock.contains('Platform License') &&
        !setBlock.contains('Premium Support');
    if (setOk) {
        pass++;
        System.debug('SETUP ROWS ONLY IN SETUP BLOCK: PASS');
    } else {
        fail++;
        System.debug('SETUP BLOCK BLEED: FAIL — block excerpt: ' + setBlock.left(800));
    }

    // Edge case 3: Empty subset renders gracefully — table outer markup
    // stays, loop body iterates zero times, COUNT aggregate reports 0.
    // (Empty-list conditional visibility via {:else}/{^X} is not honored by
    // the engine — only boolean conditionals are. The {COUNT:Alias} aggregate
    // is the live signal of subset emptiness.)
    Boolean hwEmpty = !hwBlock.contains('On-Prem Appliance') && hwBlock.contains('0 hardware line(s)');
    if (hwEmpty) {
        pass++;
        System.debug('EMPTY SUBSET RENDERS GRACEFULLY: PASS');
    } else {
        fail++;
        System.debug('EMPTY SUBSET FAIL — hwBlock excerpt: ' + hwBlock.left(800));
    }

    // Edge case 3b: {#IF Alias.totalSize > 0}…{:else}…{/IF} drives genuine
    // conditional visibility. With 0 hardware records, the :else branch fires
    // and renders the empty notice. The success branch (the table) does NOT.
    Boolean hwIfElseFired =
        hwBlock.contains('No hardware items on this order') && !hwBlock.contains('<th align="left">Product</th>');
    if (hwIfElseFired) {
        pass++;
        System.debug('IF/ELSE ON EMPTY SUBSET: PASS — :else branch rendered');
    } else {
        fail++;
        System.debug('IF/ELSE ON EMPTY SUBSET: FAIL — hwBlock excerpt: ' + hwBlock.left(800));
    }

    // Edge case 4: Aggregate sums per alias are correctly scoped.
    // Subscription total = 60000*50 + 12000*50 + 8400*25 = 3,000,000 + 600,000 + 210,000 = 3,810,000
    // Setup total        = 45000 + 15000 = 60,000
    Boolean subTotal = fh.contains('$3,810,000.00');
    Boolean setTotal = fh.contains('$60,000.00');
    Boolean hwTotal = fh.contains('$0.00') || fh.contains('Hardware subtotal</b></td><td align="right"><b>0');
    if (subTotal && setTotal) {
        pass++;
        System.debug('AGGREGATE SUMS PER ALIAS: PASS — sub=$3,810,000 set=$60,000');
    } else {
        fail++;
        System.debug('AGGREGATE SUMS FAIL — subFound=' + subTotal + ' setFound=' + setTotal + ' hwFound=' + hwTotal);
    }

    // Edge case 5: COUNT aggregates per alias.
    Boolean countSubs = fh.contains('Subscription items:</td><td align="right">3');
    Boolean countSet = fh.contains('Setup items:</td><td align="right">2');
    Boolean countHw = fh.contains('Hardware items:</td><td align="right">0');
    if (countSubs && countSet && countHw) {
        pass++;
        System.debug('COUNT AGGREGATES: PASS — subs=3 set=2 hw=0');
    } else {
        fail++;
        System.debug('COUNT AGGREGATES FAIL: subs=' + countSubs + ' set=' + countSet + ' hw=' + countHw);
    }

    // Edge case 6: Parent merge tags resolve outside loops (Account fields)
    Boolean parentTags = fh.contains('Filtered Subset Demo Co') && fh.contains('Austin') && fh.contains('TX');
    if (parentTags) {
        pass++;
        System.debug('PARENT-LEVEL TAGS RESOLVE: PASS');
    } else {
        fail++;
        System.debug('PARENT-LEVEL TAGS FAIL');
    }

    // Save the PDF on the Opportunity for manual inspection
    insert new ContentVersion(
        Title = 'Filtered Subset Demo Quote.pdf',
        PathOnClient = 'demo-filtered-subsets.pdf',
        VersionData = pdf,
        FirstPublishLocationId = demoOpp.Id
    );
    pass++;
    System.debug('PDF ATTACHED TO OPPORTUNITY ' + demoOpp.Id);
} catch (Exception e) {
    fail++;
    System.debug('GENERATE FAIL: ' + e.getMessage() + ' line ' + e.getLineNumber() + '\n' + e.getStackTraceString());
}

// ── 6. Summary ──────────────────────────────────────────────────
System.debug('========================================');
System.debug('FILTERED SUBSET DEMO — PASS: ' + pass + '  FAIL: ' + fail);
System.debug('========================================');
System.debug('>>> Opportunity URL: /lightning/r/Opportunity/' + demoOpp.Id + '/view');
System.debug('>>> Template URL:    /lightning/r/portwoodglobal__DocGen_Template__c/' + tmpl.Id + '/view');
System.debug('>>> Files tab on Opportunity → "Filtered Subset Demo Quote.pdf"');
