// Demo: create an HTML/PDF template wired to DocGenSampleAccountProvider.
//
// Pre-req: deploy dev-only-deploy/ to this org first
//   sf project deploy start --target-org <alias> --source-dir dev-only-deploy
//
// What this script does:
//   1. Creates (or refreshes) "Apex Provider Account Brief" — a one-page Account
//      report that pulls EVERYTHING from DocGenSampleAccountProvider, not SOQL.
//   2. Stamps Query_Config__c = {"v":4,"provider":"DocGenSampleAccountProvider"}
//      so the engine routes through getRecordDataV4() at render time.
//   3. Optionally generates a sample PDF against the first Account in the org
//      so you can see it work end-to-end.

Integer pass = 0;
Integer fail = 0;
Id tmplId;

// ── 1. Wipe prior demo state ──
try {
    delete [SELECT Id FROM DocGen_Template__c WHERE Name = 'Apex Provider Account Brief'];
    pass++;
    System.debug('PRIOR DEMO WIPED: PASS');
} catch (Exception e) {
    System.debug('Wipe non-fatal: ' + e.getMessage());
}

// ── 2. Verify the provider class is callable ──
try {
    Type t = Type.forName('DocGenSampleAccountProvider');
    if (t == null) {
        fail++;
        System.debug('PROVIDER LOOKUP: FAIL — DocGenSampleAccountProvider not found. Deploy dev-only-deploy/ first.');
        return;
    }
    Object inst = t.newInstance();
    if (!(inst instanceof DocGenDataProvider)) {
        fail++;
        System.debug('PROVIDER INTERFACE: FAIL — class does not implement DocGenDataProvider');
        return;
    }
    pass++;
    System.debug('PROVIDER CLASS RESOLVES: PASS');
} catch (Exception e) {
    fail++;
    System.debug('PROVIDER LOOKUP FAIL: ' + e.getMessage());
    return;
}

// ── 3. Build the HTML template body — every tag the provider supplies ──
String html =
    '<html><body style="font-family:Helvetica;font-size:11pt;color:#1f2937;line-height:1.5;">' +
    // Cover band
    '<div style="background:#1F4E79;color:#fff;padding:18px 24px;border-radius:6px;">' +
    '<div style="font-size:9pt;letter-spacing:1px;text-transform:uppercase;opacity:.85;">Account Brief</div>' +
    '<h1 style="margin:4px 0 0 0;font-size:24pt;">{Name}</h1>' +
    '<div style="font-size:10pt;opacity:.85;">{Industry} · {BillingAddress}</div>' +
    '</div>' +
    // Computed fields band — proves the provider is doing more than SOQL
    '<table style="width:100%;border-collapse:collapse;margin-top:18px;">' +
    '<tr>' +
    '<td style="background:#eef2f7;padding:10px;border-radius:4px;width:33%;">' +
    '<div style="font-size:9pt;color:#475569;text-transform:uppercase;">Customer Score</div>' +
    '<div style="font-size:22pt;font-weight:700;color:#1F4E79;">{CustomerScore}</div>' +
    '</td>' +
    '<td style="width:6px;"></td>' +
    '<td style="background:#eef2f7;padding:10px;border-radius:4px;width:33%;">' +
    '<div style="font-size:9pt;color:#475569;text-transform:uppercase;">Risk Tier</div>' +
    '<div style="font-size:18pt;font-weight:700;color:#1F4E79;">{RiskTier}</div>' +
    '</td>' +
    '<td style="width:6px;"></td>' +
    '<td style="background:#eef2f7;padding:10px;border-radius:4px;width:33%;">' +
    '<div style="font-size:9pt;color:#475569;text-transform:uppercase;">Open Pipeline</div>' +
    '<div style="font-size:18pt;font-weight:700;color:#1F4E79;">{TotalPipeline:currency}</div>' +
    '</td>' +
    '</tr>' +
    '</table>' +
    // Account / Owner two-up — parent lookup tags
    '<div style="display:flex;gap:18px;margin-top:18px;">' +
    '<div style="flex:1;">' +
    '<h3 style="border-bottom:2px solid #1F4E79;padding-bottom:4px;color:#1F4E79;">Account</h3>' +
    '<p style="margin:4px 0;"><b>Phone:</b> {Phone}</p>' +
    '<p style="margin:4px 0;"><b>Website:</b> {Website}</p>' +
    '<p style="margin:4px 0;"><b>Annual Revenue:</b> {AnnualRevenue:currency}</p>' +
    '<p style="margin:4px 0;"><b>Employees:</b> {NumberOfEmployees}</p>' +
    '</div>' +
    '<div style="flex:1;">' +
    '<h3 style="border-bottom:2px solid #1F4E79;padding-bottom:4px;color:#1F4E79;">Owner</h3>' +
    '<p style="margin:4px 0;"><b>Name:</b> {Owner.Name}</p>' +
    '<p style="margin:4px 0;"><b>Email:</b> {Owner.Email}</p>' +
    '<p style="margin:4px 0;"><b>Phone:</b> {Owner.Phone}</p>' +
    '</div>' +
    '</div>' +
    // Contacts loop — child records supplied by the provider
    '<h3 style="margin-top:22px;border-bottom:2px solid #1F4E79;padding-bottom:4px;color:#1F4E79;">Key Contacts ({Contacts.totalSize})</h3>' +
    '{#IF Contacts.totalSize > 0}' +
    '<table style="width:100%;border-collapse:collapse;margin-top:6px;">' +
    '<tr style="background:#f8fafc;"><th align="left" style="padding:6px;">Name</th><th align="left" style="padding:6px;">Title</th><th align="left" style="padding:6px;">Email</th><th align="left" style="padding:6px;">Phone</th></tr>' +
    '{#Contacts}' +
    '<tr style="border-top:1px solid #e5e7eb;">' +
    '<td style="padding:6px;">{FullName}</td>' +
    '<td style="padding:6px;color:#475569;">{Title}</td>' +
    '<td style="padding:6px;color:#1d4ed8;">{Email}</td>' +
    '<td style="padding:6px;">{Phone}</td>' +
    '</tr>' +
    '{/Contacts}' +
    '</table>' +
    '{:else}' +
    '<p style="color:#94a3b8;font-style:italic;">No contacts on file for this account.</p>' +
    '{/IF}' +
    // Opportunities loop + engine SUM aggregate
    '<h3 style="margin-top:22px;border-bottom:2px solid #1F4E79;padding-bottom:4px;color:#1F4E79;">Opportunities ({Opportunities.totalSize}) · Won so far: {WonOpportunityCount}</h3>' +
    '{#IF Opportunities.totalSize > 0}' +
    '<table style="width:100%;border-collapse:collapse;margin-top:6px;">' +
    '<tr style="background:#f8fafc;"><th align="left" style="padding:6px;">Opportunity</th><th align="left" style="padding:6px;">Stage</th><th align="right" style="padding:6px;">Amount</th><th align="left" style="padding:6px;">Close</th></tr>' +
    '{#Opportunities}' +
    '<tr style="border-top:1px solid #e5e7eb;">' +
    '<td style="padding:6px;">{Name}</td>' +
    '<td style="padding:6px;color:#475569;">{StageName}</td>' +
    '<td style="padding:6px;text-align:right;">{Amount:currency}</td>' +
    '<td style="padding:6px;">{CloseDate:MM/dd/yyyy}</td>' +
    '</tr>' +
    '{/Opportunities}' +
    '<tr style="background:#1F4E79;color:#fff;font-weight:bold;">' +
    '<td colspan="2" align="right" style="padding:6px;">All-time total:</td>' +
    '<td colspan="2" style="padding:6px;text-align:right;">{SUM:Opportunities.Amount:currency}</td>' +
    '</tr>' +
    '</table>' +
    '{:else}' +
    '<p style="color:#94a3b8;font-style:italic;">No opportunities on file.</p>' +
    '{/IF}' +
    // Provenance footer — fields you can ONLY get from a provider
    '<p style="margin-top:24px;font-size:9pt;color:#64748b;text-align:right;font-style:italic;">' +
    'Generated by {GeneratedBy} on {GeneratedAt:MM/dd/yyyy hh:mm a}' +
    '</p>' +
    '</body></html>';

// ── 4. Persist the template + version + body CV ──
try {
    DocGen_Template__c tmpl = new DocGen_Template__c(
        Name = 'Apex Provider Account Brief',
        Description__c = 'Demo template wired to DocGenSampleAccountProvider (v4 Apex Data Provider). Pass any Account ID at render time.',
        Type__c = 'HTML',
        Output_Format__c = 'PDF',
        // Base_Object_API__c is conventionally set to the SObject the provider
        // anchors on (Account here). It's a hint — the engine ignores it for v4.
        Base_Object_API__c = 'Account',
        Query_Config__c = '{"v":4,"provider":"DocGenSampleAccountProvider"}',
        Category__c = 'Demo'
    );
    insert tmpl;
    tmplId = tmpl.Id;

    ContentVersion cv = new ContentVersion(
        Title = 'Apex Provider Account Brief Body',
        PathOnClient = 'account-brief.html',
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
        Base_Object_API__c = 'Account',
        Query_Config__c = '{"v":4,"provider":"DocGenSampleAccountProvider"}'
    );
    pass++;
    System.debug('TEMPLATE PERSISTED: PASS — ' + tmplId);
} catch (Exception e) {
    fail++;
    System.debug('TEMPLATE PERSIST FAIL: ' + e.getMessage());
    return;
}

// ── 5. Generate a sample PDF against the first Account with contacts ──
try {
    List<Account> seed = [SELECT Id, Name FROM Account ORDER BY CreatedDate DESC LIMIT 25];
    Id chosenId;
    for (Account a : seed) {
        Integer cnt = [SELECT COUNT() FROM Contact WHERE AccountId = :a.Id LIMIT 1];
        if (cnt > 0) {
            chosenId = a.Id;
            break;
        }
    }
    if (chosenId == null && !seed.isEmpty()) {
        chosenId = seed[0].Id;
    }
    if (chosenId == null) {
        System.debug('NO ACCOUNT TO RENDER AGAINST — skipping render check (template still created).');
    } else {
        Map<String, Object> result = DocGenService.generatePdfBlob(tmplId, chosenId);
        Blob pdf = (Blob) result.get('blob');
        if (pdf != null && pdf.size() > 1000) {
            pass++;
            System.debug('SAMPLE RENDER: PASS — ' + pdf.size() + ' bytes against Account ' + chosenId);
            // Attach so you can preview in the Files tab
            insert new ContentVersion(
                Title = 'Apex Provider Account Brief',
                PathOnClient = 'account-brief.pdf',
                VersionData = pdf,
                FirstPublishLocationId = chosenId
            );
            System.debug('PDF attached to Account ' + chosenId + ' — open the Files tab to view.');
        } else {
            fail++;
            System.debug('SAMPLE RENDER: FAIL — PDF empty or too small');
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('RENDER FAIL: ' + e.getMessage() + ' line ' + e.getLineNumber());
}

System.debug('========================================');
System.debug('APEX PROVIDER DEMO TEMPLATE — PASS: ' + pass + '  FAIL: ' + fail);
System.debug('========================================');
System.debug('>>> Template: /lightning/r/portwoodglobal__DocGen_Template__c/' + tmplId + '/view');
System.debug('>>> Open the DocGen app → Templates → "Apex Provider Account Brief"');
System.debug('>>> Edit it to see the wizard auto-detect the v4 binding and land on the Apex Provider view.');
