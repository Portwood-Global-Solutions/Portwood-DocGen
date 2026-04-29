// Build the v1.72 feature-showcase template + render a live PDF.
// Pairs with `ProjectStatusDemoProvider.cls` and `template-project-status.html`.
//
// Run: sf apex run --target-org docgen-dev -f scripts/demo-project-status-template.apex
//
// This script:
//   1. Cleans up any prior copy of the demo template
//   2. Reads template-project-status.html (Note: paste the content here since
//      anonymous Apex can't read local files — see the HTML constant below)
//   3. Creates the DocGen_Template__c + active version pointing at the provider
//   4. Renders one PDF and attaches it to a record so you can preview it

Integer pass = 0;
Integer fail = 0;
Id tmplId;

// ── Tear down any prior copy ──
try {
    List<portwoodglobal__DocGen_Template__c> existing = [
        SELECT Id
        FROM portwoodglobal__DocGen_Template__c
        WHERE Name = 'v1.72 Feature Showcase — Project Status'
        LIMIT 5
    ];
    if (!existing.isEmpty()) {
        delete existing;
    }
    System.debug('CLEANUP: ' + existing.size() + ' existing template(s) removed');
} catch (Exception e) {
    System.debug('CLEANUP FAIL (non-fatal): ' + e.getMessage());
}

// ── HTML body — keep in sync with scripts/template-project-status.html ──
String html =
    '<!DOCTYPE html><html><head><meta charset="utf-8"/><style>' +
    'body{font-family:Arial,sans-serif;font-size:11pt;line-height:1.4;color:#1a1a1a;}' +
    'h1{font-size:22pt;margin:0 0 4pt 0;}' +
    'h2{font-size:14pt;margin:18pt 0 6pt 0;padding-bottom:3pt;border-bottom:1pt solid #d0d0d0;}' +
    'h3{font-size:11pt;margin:8pt 0 4pt 0;color:#444;}' +
    '.meta{color:#555;font-size:10pt;}' +
    '.status-badge{display:inline-block;padding:2pt 8pt;border-radius:4pt;font-weight:bold;font-size:10pt;color:#fff;}' +
    '.green{background:#2e7d32;}.amber{background:#e6a700;color:#1a1a1a;}.red{background:#c62828;}' +
    '.callout{padding:8pt 12pt;margin:6pt 0;border-radius:4pt;}' +
    '.callout.alert{background:#fdecea;border-left:3pt solid #c62828;}' +
    '.kv{width:100%;border-collapse:collapse;margin:4pt 0 0 0;}' +
    '.kv td{padding:3pt 6pt;vertical-align:top;}' +
    '.kv td:first-child{color:#666;width:32%;}' +
    'table.data{width:100%;border-collapse:collapse;margin:4pt 0;}' +
    'table.data th,table.data td{padding:4pt 8pt;border:1pt solid #d0d0d0;text-align:left;}' +
    'table.data th{background:#f4f4f4;font-weight:bold;}' +
    '.empty-note{color:#888;font-style:italic;padding:4pt 8pt;}' +
    '.phase-block{margin:8pt 0 14pt 0;}' +
    '.footer{margin-top:24pt;font-size:9pt;color:#888;border-top:1pt solid #e0e0e0;padding-top:6pt;}' +
    '</style></head><body>' +
    '<h1>{Name}</h1>' +
    '<p class="meta">{ProjectCode__c} &middot; Customer: {Customer} &middot; Manager: {Manager}</p>' +
    '<p>Status: ' +
    '{#IF (CompletionPercent__c >= 100) OR (IsOnTrack__c AND DaysRemaining__c > 5)}' +
    '<span class="status-badge green">ON TRACK</span>' +
    '{/IF}' +
    '{#IF IsOnTrack__c AND DaysRemaining__c <= 5 AND CompletionPercent__c < 100}' +
    '<span class="status-badge amber">TIGHT TIMELINE</span>' +
    '{/IF}' +
    '{#IF IsAtRisk__c OR (Spent__c > Budget__c) OR RequiresEscalation__c}' +
    '<span class="status-badge red">AT RISK</span>' +
    '{/IF}' +
    '</p>' +
    '{#IF IsAtRisk__c}<div class="callout alert"><strong>Risk flagged.</strong> Review the risks section below and the escalation path.</div>{/IF}' +
    '{#IF Spent__c > Budget__c}<div class="callout alert"><strong>Over budget.</strong> Spent {Spent__c:currency} against {Budget__c:currency}.{#IF NOT RequiresEscalation__c} No escalation flag yet — please review.{/IF}</div>{/IF}' +
    '<h2>Summary</h2>' +
    '<table class="kv">' +
    '<tr><td>Start date</td><td>{StartDate:date}</td></tr>' +
    '<tr><td>Target date</td><td>{TargetDate:date}</td></tr>' +
    '<tr><td>Days remaining</td><td>{DaysRemaining__c}</td></tr>' +
    '<tr><td>Budget</td><td>{Budget__c:currency}</td></tr>' +
    '<tr><td>Spent</td><td>{Spent__c:currency}</td></tr>' +
    '<tr><td>Completion</td><td>{CompletionPercent__c}%</td></tr>' +
    '</table>' +
    '<h2>Phases</h2>' +
    '{#Phases}<div class="phase-block"><h3>{Name} <span class="meta">&mdash; {Status__c}</span></h3>' +
    '{#IF Tasks.totalSize != 0}' +
    '<table class="data"><thead><tr><th>Task</th><th style="text-align:right">Hours</th></tr></thead><tbody>' +
    '{#Tasks}<tr><td>{Name}</td><td style="text-align:right">{Hours__c}</td></tr>{/Tasks}' +
    '</tbody></table>' +
    '{/IF}' +
    '{#IF Tasks.totalSize = 0}<p class="empty-note">No tasks defined for this phase yet.</p>{/IF}' +
    '</div>{/Phases}' +
    '<h2>Issues</h2>' +
    '{#IF Issues.totalSize != 0}' +
    '<table class="data"><thead><tr><th>Title</th><th style="width:90pt">Severity</th></tr></thead><tbody>' +
    '{#Issues}<tr><td>{Title}</td><td>{Severity}</td></tr>{/Issues}' +
    '</tbody></table>' +
    '{/IF}' +
    '{#IF Issues.totalSize = 0}<p class="empty-note">No issues currently logged.</p>{/IF}' +
    '<h2>Risks</h2>' +
    '{#IF Risks.totalSize != 0}' +
    '<table class="data"><thead><tr><th>Risk</th></tr></thead><tbody>' +
    '{#Risks}<tr><td>{Title}</td></tr>{/Risks}' +
    '</tbody></table>' +
    '{/IF}' +
    '{#IF Risks.totalSize = 0}<p class="empty-note">No risks currently identified. ({Risks.totalSize} open)</p>{/IF}' +
    '<h2>Approvals</h2>' +
    '<p>Pending approvals: <strong>{Approvals.totalSize}</strong></p>' +
    '{#IF Approvals.totalSize > 0}<p>Awaiting sign-off &mdash; see workflow.</p>{/IF}' +
    '{#IF NOT (Approvals.totalSize > 0)}<p class="empty-note">No approvals required at this stage.</p>{/IF}' +
    '<div class="footer">Generated by Portwood DocGen &mdash; v1.72 Feature Showcase.</div>' +
    '</body></html>';

// ── Create the template + active version ──
try {
    portwoodglobal__DocGen_Template__c tmpl = new portwoodglobal__DocGen_Template__c(
        Name = 'v1.72 Feature Showcase — Project Status',
        portwoodglobal__Description__c = 'Demonstrates nested IF, AND/OR/NOT, empty-rel totalSize, bare-boolean IF, and parens grouping. Backed by ProjectStatusDemoProvider (synthetic data — no SOQL).',
        portwoodglobal__Type__c = 'HTML',
        portwoodglobal__Output_Format__c = 'PDF',
        portwoodglobal__Base_Object_API__c = 'Account',
        portwoodglobal__Query_Config__c = '{"v":4,"provider":"ProjectStatusDemoProvider"}',
        portwoodglobal__Category__c = 'Demo'
    );
    insert tmpl;
    tmplId = tmpl.Id;

    ContentVersion cv = new ContentVersion(
        Title = 'Project Status Showcase Body',
        PathOnClient = 'project-status.html',
        VersionData = Blob.valueOf(html),
        FirstPublishLocationId = tmplId
    );
    insert cv;
    cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

    insert new portwoodglobal__DocGen_Template_Version__c(
        portwoodglobal__Template__c = tmplId,
        portwoodglobal__Content_Version_Id__c = cv.Id,
        portwoodglobal__Is_Active__c = true,
        portwoodglobal__Type__c = 'HTML',
        portwoodglobal__Base_Object_API__c = 'Account',
        portwoodglobal__Query_Config__c = '{"v":4,"provider":"ProjectStatusDemoProvider"}'
    );
    pass++;
    System.debug('TEMPLATE: PASS — ' + tmplId);
} catch (Exception e) {
    fail++;
    System.debug('TEMPLATE FAIL: ' + e.getMessage());
    return;
}

// ── Render a sample PDF ──
try {
    Account anchor = [SELECT Id, Name FROM Account ORDER BY CreatedDate DESC LIMIT 1];
    Map<String, Object> result = portwoodglobal.DocGenService.generatePdfBlob(tmplId, anchor.Id);
    Blob pdf = (Blob) result.get('blob');
    if (pdf != null && pdf.size() > 1000) {
        pass++;
        System.debug('RENDER: PASS — ' + pdf.size() + ' bytes');
        insert new ContentVersion(
            Title = 'v1.72 Feature Showcase — Project Status',
            PathOnClient = 'project-status-showcase.pdf',
            VersionData = pdf,
            FirstPublishLocationId = anchor.Id
        );
        System.debug('>>> PDF attached to Account ' + anchor.Id + ' (' + anchor.Name + ')');
        System.debug('>>> Open: /lightning/r/Account/' + anchor.Id + '/related/AttachedContentDocuments/view');
    } else {
        fail++;
        System.debug('RENDER FAIL: PDF empty or too small');
    }
} catch (Exception e) {
    fail++;
    System.debug('RENDER FAIL: ' + e.getMessage() + ' (line ' + e.getLineNumber() + ')');
}

System.debug('========================================');
System.debug('v1.72 SHOWCASE — PASS: ' + pass + '  FAIL: ' + fail);
System.debug('========================================');
System.debug('>>> Template: /lightning/r/portwoodglobal__DocGen_Template__c/' + tmplId + '/view');
