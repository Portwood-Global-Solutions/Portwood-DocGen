// DocGen — Test Signing Flow (creates signature request with v3 placements, bypasses PIN for testing)
// Run: sf apex run --target-org <org> -f scripts/test-signing-flow.apex
// Depends on: e2e-02 (Account 'E2E Test Corp', Template 'E2E Test Template')
// After running: open the URL printed in debug logs

// Look up test data
List<Account> accts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp' LIMIT 1];
if (accts.isEmpty()) {
    System.debug('ERROR: Run e2e-02 first to create test data.');
    return;
}
Id acctId = accts[0].Id;

List<DocGen_Template__c> tmpls = [SELECT Id, Name FROM DocGen_Template__c WHERE Name = 'E2E Test Template' LIMIT 1];
if (tmpls.isEmpty()) {
    System.debug('ERROR: Run e2e-02 first to create test template.');
    return;
}
Id tmplId = tmpls[0].Id;

// Create signature request
String signerToken = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
    Status__c = 'Sent',
    Related_Record_Id__c = acctId,
    Template__c = tmplId
);
insert req;

// Create signer with PIN already verified (bypasses email verification for testing)
DocGen_Signer__c signer = new DocGen_Signer__c(
    Signature_Request__c = req.Id,
    Signer_Name__c = 'Dave Moudy',
    Signer_Email__c = 'dave@portwoodglobalsolutions.com',
    Role_Name__c = 'Buyer',
    Secure_Token__c = signerToken,
    Status__c = 'Pending',
    Sort_Order__c = 1,
    PIN_Verified_At__c = System.now() // <-- bypass PIN
);
insert signer;

// Create v3 placements
List<DocGen_Signature_Placement__c> placements = new List<DocGen_Signature_Placement__c>();
placements.add(
    new DocGen_Signature_Placement__c(
        Signer__c = signer.Id,
        Signature_Request__c = req.Id,
        Document_Index__c = 0,
        Sequence_Order__c = 1,
        Placement_Type__c = 'Initials',
        Status__c = 'Pending',
        Section_Context__c = 'Section 1: Terms and Conditions',
        Tag_Text__c = '{@Signature_Buyer:1:Initials}'
    )
);
placements.add(
    new DocGen_Signature_Placement__c(
        Signer__c = signer.Id,
        Signature_Request__c = req.Id,
        Document_Index__c = 0,
        Sequence_Order__c = 2,
        Placement_Type__c = 'Full',
        Status__c = 'Pending',
        Section_Context__c = 'Section 3: Agreement',
        Tag_Text__c = '{@Signature_Buyer:2:Full}'
    )
);
placements.add(
    new DocGen_Signature_Placement__c(
        Signer__c = signer.Id,
        Signature_Request__c = req.Id,
        Document_Index__c = 0,
        Sequence_Order__c = 3,
        Placement_Type__c = 'Date',
        Status__c = 'Pending',
        Section_Context__c = 'Section 3: Agreement',
        Tag_Text__c = '{@Signature_Buyer:3:Date}'
    )
);
insert placements;

// Get the site URL from settings (or use a fallback)
DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
String siteUrl = settings.Experience_Site_Url__c;

System.debug('========================================');
System.debug('TEST SIGNING FLOW CREATED');
System.debug('Request ID: ' + req.Id);
System.debug('Signer ID: ' + signer.Id);
System.debug('Token: ' + signerToken);
System.debug('Placements: ' + placements.size());
if (String.isNotBlank(siteUrl)) {
    System.debug('SIGNING URL: ' + siteUrl + '/apex/DocGenSignature?token=' + signerToken);
} else {
    System.debug('NOTE: No site URL configured. Set it in DocGen > Signatures settings.');
    System.debug('Then open: <your-site-url>/apex/DocGenSignature?token=' + signerToken);
}
System.debug('PIN: Pre-verified (bypassed for testing)');
System.debug('========================================');
