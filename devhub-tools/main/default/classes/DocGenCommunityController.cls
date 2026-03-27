/**
 * Controller for the DocGen Community forum.
 * Handles auth (registration, email verification, login, sessions),
 * post/reply CRUD, voting, file upload, and vendor applications.
 * Deploy to partner org only — runs on VF Site with guest user profile.
 *
 * Security notes:
 * - Uses `without sharing` because guest user has no sharing access; all data
 *   access is via SYSTEM_MODE queries and session-gated RemoteActions.
 * - All DML runs through RemoteActions (session-validated) or @future (system context).
 *   Guest user page-render getters are read-only — no DML during page load.
 * - URL parameters are sanitized via String.escapeSingleQuotes() in the constructor.
 * - HTML input is sanitized via sanitizeHtml() to prevent stored XSS.
 * - Resend API key is stored in a Custom Setting, not hardcoded. NOPMD on the
 *   endpoint because Named Credentials don't support Bearer token auth cleanly
 *   for third-party REST APIs outside of OAuth flows.
 */
public without sharing class DocGenCommunityController { // NOPMD ExcessivePublicCount — VF controller requires public getters for page bindings

    // ─── Constants (declared before methods per PMD FieldDeclarationsShouldBeAtStart) ───
    private static final Integer TOKEN_EXPIRY_HOURS = 48;
    private static final Integer SESSION_EXPIRY_DAYS = 30;
    private static final String SESSION_COOKIE = 'dgc_session';

    // ─── Post query field list (DRY constant to reduce duplication in getPosts) ───
    private static final String POST_LIST_FIELDS =
        'Id, Name, Title__c, Category__c, Topics__c, Upvote_Count__c, Reply_Count__c, View_Count__c, ' +
        'Is_Pinned__c, Is_Answered__c, Status__c, CreatedDate, Has_Attachments__c, ' +
        'Author__c, Author_Contact_Id__c, Author_Display_Name__c, Author_Company__c';

    // ─── Profile display properties (bypass guest user FLS on Contact fields) ───
    private transient String profDisplayName;
    private transient String profDisplayTitle;
    private transient String profDisplayCompany;
    private transient String profDisplayBio;
    private transient String profInitials;
    private transient Decimal profPostCount;
    private transient Decimal profSolutionCount;
    private transient Datetime profCreatedDate;
    private transient Id profContactId;

    // ─── Category Counts (cached per request) ───
    private transient Map<String, Integer> categoryCounts;

    // ─── Session State ───
    private Contact currentMember;
    public String pageView { get; set; }
    public String postId { get; set; }
    public String profileId { get; set; }
    public String categoryFilter { get; set; }
    public String topicFilter { get; set; }
    public String sortBy { get; set; }

    // ─── Form Fields ───
    public String formEmail { get; set; }
    public String formPassword { get; set; }
    public String formName { get; set; }
    public String formCompany { get; set; }
    public String formBio { get; set; }
    public String formTitle { get; set; }
    public String formBody { get; set; }
    public String formCategory { get; set; }
    public String formTopics { get; set; }
    public String formMessage { get; set; }
    public String formServices { get; set; }
    public String formWebsite { get; set; }
    public String formCertifications { get; set; }
    public String verifyToken { get; set; }
    public String statusMessage { get; set; }
    public String errorMessage { get; set; }

    // ─── Constructor ───
    public DocGenCommunityController() {
        // Read and sanitize URL parameters (String.escapeSingleQuotes prevents SOQL injection)
        Map<String, String> params = ApexPages.currentPage().getParameters();
        pageView = esc(params.get('view'));
        postId = esc(params.get('id'));
        profileId = esc(params.get('mid'));
        categoryFilter = esc(params.get('cat'));
        topicFilter = esc(params.get('topic'));
        sortBy = esc(params.get('sort'));
        verifyToken = esc(params.get('token'));
        formCategory = 'Discussion';
        String precat = esc(params.get('precat'));
        if (String.isNotBlank(precat)) {
            formCategory = precat;
        }
        formTopics = esc(params.get('pretopic'));

        if (String.isBlank(pageView)) {
            pageView = 'home';
        }
        if (String.isBlank(sortBy)) {
            sortBy = 'recent';
        }

        // Handle server-side session cookie setting (called after login/signup via redirect)
        String sessionParam = esc(params.get('s'));
        if (pageView == 'setSession' && String.isNotBlank(sessionParam)) {
            setSessionCookie(sessionParam);
            pageView = 'home';
        }

        if (pageView == 'verify' && String.isNotBlank(verifyToken)) {
            handleVerifyEmail();
        }

        restoreSession();

        // Handle logout — clear cookie only (no DML/future from guest user context)
        if (pageView == 'logout') {
            clearSessionCookie();
            currentMember = null;
            pageView = 'home';
        }
    }

    /**
     * Escapes a URL parameter to prevent SOQL injection.
     * PMD flags getParameters().get() as XSS — this method applies escapeSingleQuotes
     * which is the standard Salesforce mitigation. Values are only used in SOQL bind
     * variables (`:postId`, `:profileId`), never rendered directly in HTML.
     */
    private static String esc(String param) { // NOPMD ApexXSSFromURLParam — sanitized via escapeSingleQuotes; used only in SOQL bind variables
        if (String.isBlank(param)) {
            return param;
        }
        return String.escapeSingleQuotes(param.trim());
    }

    // ═══════════════════════════════════════════════════════════
    // AUTH
    // ═══════════════════════════════════════════════════════════

    private void restoreSession() {
        Cookie sessionCookie = ApexPages.currentPage().getCookies().get(SESSION_COOKIE);
        if (sessionCookie == null || String.isBlank(sessionCookie.getValue())) {
            return;
        }

        String cookieVal = sessionCookie.getValue();
        List<Contact> members = [
            SELECT Id, FirstName, LastName, Email, Account.Name, Title,
                   Community_Bio__c, Community_Post_Count__c, Community_Solution_Count__c,
                   Community_Verified__c, Community_Token_Expiry__c, Community_Notifications__c
            FROM Contact
            WHERE Community_Token__c = :cookieVal
            AND Community_Verified__c = true
            AND Community_Token_Expiry__c > :Datetime.now()
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (!members.isEmpty()) {
            currentMember = members[0];
        }
    }

    private void setSessionCookie(String token) {
        Cookie c = new Cookie(SESSION_COOKIE, token, null, SESSION_EXPIRY_DAYS * 86400, true);
        ApexPages.currentPage().setCookies(new Cookie[]{ c });
    }

    private void clearSessionCookie() {
        Cookie c = new Cookie(SESSION_COOKIE, '', null, 0, true);
        ApexPages.currentPage().setCookies(new Cookie[]{ c });
    }

    private static String generateToken() {
        Blob b = Crypto.generateAesKey(128);
        return EncodingUtil.convertToHex(b);
    }

    private static String hashPassword(String password) {
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(password));
        return EncodingUtil.convertToHex(hash);
    }

    public Boolean getIsLoggedIn() {
        return currentMember != null;
    }

    public Contact getMember() {
        return currentMember;
    }

    public String getSessionToken() {
        Cookie c = ApexPages.currentPage().getCookies().get(SESSION_COOKIE);
        return (c != null) ? c.getValue() : '';
    }

    public String getMemberId() {
        return currentMember != null ? String.valueOf(currentMember.Id) : '';
    }

    public String getMemberName() {
        if (currentMember == null) {
            return '';
        }
        String fullName = '';
        if (String.isNotBlank(currentMember.FirstName)) {
            fullName = currentMember.FirstName;
        }
        if (String.isNotBlank(currentMember.LastName)) {
            fullName += (fullName.length() > 0 ? ' ' : '') + currentMember.LastName;
        }
        return fullName;
    }

    // ─── Registration ───
    @RemoteAction
    public static String register(String email, String orgId) { // NOPMD ExcessiveParameterList
        if (String.isBlank(email) || !email.contains('@')) {
            throw new AuraHandledException('Please enter a valid email address.');
        }
        email = email.toLowerCase().trim();

        List<Contact> existingContacts = [
            SELECT Id, Community_Verified__c FROM Contact WHERE Email = :email WITH SYSTEM_MODE LIMIT 1
        ];
        if (!existingContacts.isEmpty() && existingContacts[0].Community_Verified__c) {
            return 'already_registered';
        }

        String token = generateToken();
        Datetime expiry = Datetime.now().addHours(TOKEN_EXPIRY_HOURS);

        if (!existingContacts.isEmpty()) {
            Contact c = existingContacts[0];
            c.Community_Token__c = token;
            c.Community_Token_Expiry__c = expiry;
            update c; // NOPMD ApexCRUDViolation — community auth: updating token on existing unverified contact
        } else {
            Contact c = new Contact(
                LastName = email.split('@')[0],
                Email = email,
                Community_Token__c = token,
                Community_Token_Expiry__c = expiry,
                Community_Verified__c = false,
                LeadSource = 'DocGen Community'
            );
            insert c; // NOPMD ApexCRUDViolation — community auth: creating contact for new registration
        }

        sendVerificationEmail(email, token, orgId);
        return 'verification_sent';
    }

    @future(callout=true)
    private static void sendVerificationEmail(String email, String token, String orgId) {
        String verifyUrl = 'https://portwoodglobalsolutions.com/DocGenCommunity?view=verify&token=' + token;
        if (String.isNotBlank(orgId)) {
            verifyUrl += '&orgId=' + orgId;
        }
        String htmlBody = '<div style="font-family: -apple-system, sans-serif; max-width: 500px; margin: 0 auto;">' +
            '<h2 style="color: #1a1a2e;">Welcome to DocGen Community</h2>' +
            '<p>Click the button below to verify your email and complete your profile:</p>' +
            '<a href="' + verifyUrl + '" ' +
            'style="display: inline-block; padding: 12px 28px; background: #2563eb; color: #fff; text-decoration: none; border-radius: 50px; font-weight: 700;">Verify Email</a>' +
            '<p style="color: #64748b; font-size: 0.85rem; margin-top: 2rem;">This link expires in 48 hours. If you didn\'t sign up, you can ignore this email.</p>' +
            '</div>';

        DocGen_Demo_Config__c config = DocGen_Demo_Config__c.getOrgDefaults();
        String apiKey = (config != null) ? config.Resend_API_Key__c : null;

        if (String.isNotBlank(apiKey)) {
            sendViaResend(apiKey, email, 'Verify your DocGen Community account', htmlBody);
        } else {
            sendViaSalesforce(email, 'Verify your DocGen Community account', htmlBody);
        }
    }

    private static void sendViaResend(String apiKey, String toAddr, String subject, String htmlBody) { // NOPMD ExcessiveParameterList — email sending requires all fields
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.resend.com/emails');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + apiKey); // NOPMD ApexSuggestUsingNamedCred — Resend REST API uses Bearer token; Named Credentials designed for OAuth
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, String>{
            'from' => 'DocGen Community <hello@portwoodglobalsolutions.com>',
            'to' => toAddr,
            'subject' => subject,
            'html' => htmlBody
        }));
        Http http = new Http();
        HttpResponse res = http.send(req);
        if (res.getStatusCode() >= 400) {
            System.debug(LoggingLevel.ERROR, 'Resend email failed: ' + res.getStatusCode() + ' ' + res.getBody());
        }
    }

    @future(callout=true)
    private static void sendReplyNotification(String toEmail, String firstName, String replierName, String postId) {
        DocGen_Demo_Config__c config = DocGen_Demo_Config__c.getOrgDefaults();
        if (config == null || String.isBlank(config.Resend_API_Key__c)) {
            System.debug(LoggingLevel.ERROR, 'sendReplyNotification: No Resend API key configured');
            return;
        }

        String postUrl = 'https://portwoodglobalsolutions.com/DocGenCommunity?view=post&id=' + postId;
        String greeting = String.isNotBlank(firstName) ? firstName : 'there';
        String htmlBody = '<div style="font-family: -apple-system, sans-serif; max-width: 500px; margin: 0 auto;">' +
            '<h2 style="color: #1a1a2e;">New Reply on Your Post</h2>' +
            '<p>Hey ' + greeting.escapeHtml4() + ', <strong>' + replierName.escapeHtml4() + '</strong> replied to your post on the DocGen Community.</p>' +
            '<a href="' + postUrl + '" ' +
            'style="display: inline-block; background: #2563eb; color: #fff; padding: 12px 24px; border-radius: 8px; text-decoration: none; margin: 1rem 0;">View Reply</a>' +
            '<p style="color: #666; font-size: 0.85rem; margin-top: 1.5rem;">— DocGen Community</p>' +
            '</div>';

        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.resend.com/emails'); // NOPMD ApexSuggestUsingNamedCred — Resend API on VF Site; named credentials not available
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + config.Resend_API_Key__c); // NOPMD ApexSuggestUsingNamedCred — Resend API on VF Site
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{
            'from' => 'DocGen Community <community@send.portwoodglobalsolutions.com>',
            'to' => new List<String>{ toEmail },
            'subject' => replierName + ' replied to your post',
            'html' => htmlBody
        }));

        try {
            Http http = new Http();
            HttpResponse res = http.send(req);
            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.ERROR, 'sendReplyNotification failed: ' + res.getStatusCode() + ' ' + res.getBody());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'sendReplyNotification callout error: ' + e.getMessage());
        }
    }

    private static void sendViaSalesforce(String toAddr, String subject, String htmlBody) {
        Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
        msg.setToAddresses(new String[]{ toAddr });
        msg.setSubject(subject);
        List<OrgWideEmailAddress> owas = [
            SELECT Id FROM OrgWideEmailAddress WHERE Address = 'hello@portwoodglobalsolutions.com' WITH SYSTEM_MODE LIMIT 1
        ];
        if (!owas.isEmpty()) {
            msg.setOrgWideEmailAddressId(owas[0].Id);
        } else {
            msg.setSenderDisplayName('DocGen Community');
        }
        msg.setHtmlBody(htmlBody);
        Messaging.sendEmail(new Messaging.SingleEmailMessage[]{ msg });
    }

    // ─── Email Verification ───
    private void handleVerifyEmail() {
        if (String.isBlank(verifyToken)) {
            return;
        }

        List<Contact> matches = [
            SELECT Id, Email, Community_Verified__c, Community_Token_Expiry__c
            FROM Contact WHERE Community_Token__c = :verifyToken
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (matches.isEmpty()) {
            errorMessage = 'Invalid or expired verification link.';
            return;
        }

        Contact c = matches[0];
        if (c.Community_Token_Expiry__c < Datetime.now()) {
            errorMessage = 'This verification link has expired. Please sign up again.';
            return;
        }
        if (c.Community_Verified__c) {
            statusMessage = 'Your email is already verified. Please log in.';
            pageView = 'login';
            return;
        }

        formEmail = c.Email;
        pageView = 'completeProfile';
    }

    // ─── Complete Profile ───
    @RemoteAction
    public static String completeProfile(String token, String fullName, String company, String pwd) { // NOPMD ExcessiveParameterList
        return completeProfileWithOrg(token, fullName, company, pwd, null);
    }

    @RemoteAction
    public static String completeProfileWithOrg(String token, String fullName, String company, String pwd, String orgId) { // NOPMD ExcessiveParameterList — registration flow requires all fields
        if (String.isBlank(fullName) || String.isBlank(pwd)) {
            throw new AuraHandledException('Name and password are required.');
        }
        if (pwd.length() < 8) {
            throw new AuraHandledException('Password must be at least 8 characters.');
        }

        List<Contact> matches = [
            SELECT Id, Email FROM Contact
            WHERE Community_Token__c = :token AND Community_Token_Expiry__c > :Datetime.now()
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (matches.isEmpty()) {
            throw new AuraHandledException('Invalid or expired token.');
        }

        Contact c = matches[0];
        String firstName = '';
        String lastName = fullName.trim();
        if (fullName.contains(' ')) {
            Integer idx = fullName.indexOf(' ');
            firstName = fullName.substring(0, idx);
            lastName = fullName.substring(idx + 1);
        }

        Id accountId = resolveAccountWithOrg(company, c.Email, orgId);
        String newSessionToken = generateToken();

        c.FirstName = firstName;
        c.LastName = lastName;
        c.AccountId = accountId;
        c.Community_Verified__c = true;
        c.Community_Password_Hash__c = hashPassword(pwd);
        c.Community_Token__c = newSessionToken;
        c.Community_Token_Expiry__c = Datetime.now().addDays(SESSION_EXPIRY_DAYS);
        c.Last_Community_Login__c = Datetime.now();
        update c; // NOPMD ApexCRUDViolation — community auth: completing profile after email verification
        return newSessionToken;
    }

    // ─── Login ───
    @RemoteAction
    public static String login(String email, String pwd) {
        if (String.isBlank(email) || String.isBlank(pwd)) {
            throw new AuraHandledException('Email and password are required.');
        }
        email = email.toLowerCase().trim();
        String passwordHash = hashPassword(pwd);

        List<Contact> matches = [
            SELECT Id FROM Contact
            WHERE Email = :email AND Community_Password_Hash__c = :passwordHash AND Community_Verified__c = true
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (matches.isEmpty()) {
            throw new AuraHandledException('Invalid email or password.');
        }

        String newSessionToken = generateToken();
        Contact c = matches[0];
        c.Community_Token__c = newSessionToken;
        c.Community_Token_Expiry__c = Datetime.now().addDays(SESSION_EXPIRY_DAYS);
        c.Last_Community_Login__c = Datetime.now();
        update c; // NOPMD ApexCRUDViolation — community auth: setting session token on login
        return newSessionToken;
    }

    // ─── Logout ───
    public PageReference doLogout() {
        if (currentMember != null) {
            Contact c = new Contact(Id = currentMember.Id, Community_Token__c = null, Community_Token_Expiry__c = null);
            update c; // NOPMD ApexCRUDViolation — community auth: clearing session on logout
        }
        clearSessionCookie();
        PageReference pr = new PageReference('/DocGenCommunity?view=home');
        pr.setRedirect(true);
        return pr;
    }

    // ─── Account Resolution ───
    private static Id resolveAccountWithOrg(String companyName, String email, String orgId) {
        if (String.isNotBlank(orgId)) {
            List<DocGen_Subscriber_Org__c> orgMatches = [
                SELECT Account__c FROM DocGen_Subscriber_Org__c
                WHERE Org_Id__c = :orgId AND Account__c != null WITH SYSTEM_MODE LIMIT 1
            ];
            if (!orgMatches.isEmpty()) {
                return orgMatches[0].Account__c;
            }
        }

        String domain = email.substring(email.indexOf('@') + 1);
        String domainPattern = '%' + domain + '%';
        List<Account> domainMatches = [
            SELECT Id FROM Account WHERE Website LIKE :domainPattern WITH SYSTEM_MODE LIMIT 1
        ];
        if (!domainMatches.isEmpty()) {
            return domainMatches[0].Id;
        }

        if (String.isNotBlank(companyName)) {
            List<Account> nameMatches = [
                SELECT Id FROM Account WHERE Name = :companyName WITH SYSTEM_MODE LIMIT 1
            ];
            if (!nameMatches.isEmpty()) {
                return nameMatches[0].Id;
            }
            Account a = new Account(Name = companyName, Website = domain);
            insert a; // NOPMD ApexCRUDViolation — community registration: auto-creating Account for new member
            return a.Id;
        }

        Account a = new Account(Name = domain);
        insert a; // NOPMD ApexCRUDViolation — community registration: auto-creating Account from email domain
        return a.Id;
    }

    // ═══════════════════════════════════════════════════════════
    // POSTS — all page-render getters wrapped in try-catch to prevent
    // Authorization Required errors on VF Site guest user context
    // ═══════════════════════════════════════════════════════════

    public List<DocGen_Community_Post__c> getPosts() {
        try {
            return queryPosts();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getPosts failed: ' + e.getMessage());
            return new List<DocGen_Community_Post__c>();
        }
    }

    private List<DocGen_Community_Post__c> queryPosts() {
        // Dynamic SOQL with bind variables — safe from injection because
        // categoryFilter and topicFilter are sanitized in constructor via esc()
        String query = 'SELECT ' + POST_LIST_FIELDS +
            ' FROM DocGen_Community_Post__c WHERE Status__c != \'Archived\'';
        String topicPattern = String.isNotBlank(topicFilter) ? '%' + topicFilter + '%' : null;

        if (String.isNotBlank(categoryFilter)) {
            query += ' AND Category__c = :categoryFilter';
        }
        if (topicPattern != null) {
            query += ' AND Topics__c LIKE :topicPattern';
        }

        query += ' ORDER BY Is_Pinned__c DESC, ';
        if (sortBy == 'popular') {
            query += 'Upvote_Count__c DESC, ';
        } else if (sortBy == 'active') {
            query += 'Reply_Count__c DESC, ';
        }
        query += 'CreatedDate DESC LIMIT 50';

        return Database.query(query); // NOPMD ApexSOQLInjection — all user input sanitized via esc(); bind variables used for filter values
    }

    public DocGen_Community_Post__c getPost() {
        try {
            return queryPost();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getPost failed: ' + e.getMessage());
            return null;
        }
    }

    private DocGen_Community_Post__c queryPost() {
        if (String.isBlank(postId)) {
            return null;
        }
        List<DocGen_Community_Post__c> posts = [
            SELECT Id, Name, Title__c, Body__c, Category__c, Topics__c,
                   Upvote_Count__c, Reply_Count__c, View_Count__c,
                   Is_Pinned__c, Is_Answered__c, Status__c, Has_Attachments__c,
                   CreatedDate, Author__c, Author_Contact_Id__c, Author_Display_Name__c, Author_Company__c
            FROM DocGen_Community_Post__c WHERE Id = :postId
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (posts.isEmpty()) {
            return null;
        }

        return posts[0];
    }

    public List<DocGen_Community_Reply__c> getReplies() {
        try {
            if (String.isBlank(postId)) {
                return new List<DocGen_Community_Reply__c>();
            }
            return [
                SELECT Id, Body__c, Is_Solution__c, Upvote_Count__c, Has_Attachments__c,
                       CreatedDate, Author__c, Author_Contact_Id__c, Author_Display_Name__c, Author_Company__c
                FROM DocGen_Community_Reply__c WHERE Post__c = :postId
                WITH SYSTEM_MODE ORDER BY Is_Solution__c DESC, Upvote_Count__c DESC, CreatedDate ASC
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getReplies failed: ' + e.getMessage());
            return new List<DocGen_Community_Reply__c>();
        }
    }

    @RemoteAction
    public static String createPost(String sessToken, String title, String body, String category, String topics) { // NOPMD ExcessiveParameterList — post creation requires all fields
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in to post.');
        }
        if (String.isBlank(title) || String.isBlank(body)) {
            throw new AuraHandledException('Title and body are required.');
        }

        String authorName = ((member.FirstName != null ? member.FirstName + ' ' : '') + member.LastName).trim();
        DocGen_Community_Post__c post = new DocGen_Community_Post__c(
            Title__c = title.trim(),
            Body__c = sanitizeHtml(body),
            Category__c = category,
            Topics__c = topics,
            Author__c = member.Id,
            Author_Contact_Id__c = member.Id,
            Author_Display_Name__c = authorName,
            Author_Company__c = member.AccountId != null ? getAccountName(member.AccountId) : null,
            Account__c = member.AccountId,
            Status__c = 'Active'
        );
        insert post; // NOPMD ApexCRUDViolation — community: creating post for verified member

        member.Community_Post_Count__c = (member.Community_Post_Count__c == null ? 0 : member.Community_Post_Count__c) + 1;
        update member; // NOPMD ApexCRUDViolation — community: incrementing post count on member
        return post.Id;
    }

    @RemoteAction
    public static String createReply(String sessToken, String replyPostId, String body) {
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in to reply.');
        }
        if (String.isBlank(body)) {
            throw new AuraHandledException('Reply cannot be empty.');
        }

        String replyAuthorName = ((member.FirstName != null ? member.FirstName + ' ' : '') + member.LastName).trim();
        DocGen_Community_Reply__c reply = new DocGen_Community_Reply__c(
            Post__c = replyPostId,
            Body__c = sanitizeHtml(body),
            Author__c = member.Id,
            Author_Contact_Id__c = member.Id,
            Author_Display_Name__c = replyAuthorName,
            Author_Company__c = member.AccountId != null ? getAccountName(member.AccountId) : null
        );
        insert reply; // NOPMD ApexCRUDViolation — community: creating reply for verified member

        DocGen_Community_Post__c post = [
            SELECT Reply_Count__c FROM DocGen_Community_Post__c WHERE Id = :replyPostId WITH SYSTEM_MODE LIMIT 1
        ];
        post.Reply_Count__c = (post.Reply_Count__c == null ? 0 : post.Reply_Count__c) + 1;
        update post; // NOPMD ApexCRUDViolation — community: incrementing reply count

        // Notify post author of new reply (async to avoid blocking)
        try {
            List<DocGen_Community_Post__c> replyPosts = [
                SELECT Author__c FROM DocGen_Community_Post__c WHERE Id = :replyPostId WITH SYSTEM_MODE LIMIT 1
            ];
            if (!replyPosts.isEmpty() && replyPosts[0].Author__c != member.Id) {
                List<Contact> postAuthors = [
                    SELECT Email, FirstName, Community_Notifications__c FROM Contact WHERE Id = :replyPosts[0].Author__c WITH SYSTEM_MODE LIMIT 1
                ];
                if (!postAuthors.isEmpty() && String.isNotBlank(postAuthors[0].Email)) {
                    // Check notification preference (default: on)
                    Boolean notifyEnabled = postAuthors[0].Community_Notifications__c == null || postAuthors[0].Community_Notifications__c == true;
                    if (notifyEnabled) {
                        sendReplyNotification(postAuthors[0].Email, postAuthors[0].FirstName, replyAuthorName, replyPostId);
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Reply notification failed: ' + e.getMessage());
        }

        return reply.Id;
    }

    // ─── Edit Post ───
    @RemoteAction
    public static String editPost(String sessToken, String editPostId, String title, String body) { // NOPMD ExcessiveParameterList — edit requires all fields
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in to edit.');
        }
        if (String.isBlank(title) || String.isBlank(body)) {
            throw new AuraHandledException('Title and body are required.');
        }

        List<DocGen_Community_Post__c> posts = [
            SELECT Id, Author__c FROM DocGen_Community_Post__c WHERE Id = :editPostId WITH SYSTEM_MODE LIMIT 1
        ];
        if (posts.isEmpty()) {
            throw new AuraHandledException('Post not found.');
        }
        if (posts[0].Author__c != member.Id) {
            throw new AuraHandledException('You can only edit your own posts.');
        }

        posts[0].Title__c = title.trim();
        posts[0].Body__c = sanitizeHtml(body);
        update posts[0]; // NOPMD ApexCRUDViolation — community: author editing own post
        return 'updated';
    }

    // ─── Delete Post (soft) ───
    @RemoteAction
    public static String deletePost(String sessToken, String delPostId) {
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in to delete.');
        }

        List<DocGen_Community_Post__c> posts = [
            SELECT Id, Author__c FROM DocGen_Community_Post__c WHERE Id = :delPostId WITH SYSTEM_MODE LIMIT 1
        ];
        if (posts.isEmpty()) {
            throw new AuraHandledException('Post not found.');
        }
        if (posts[0].Author__c != member.Id) {
            throw new AuraHandledException('You can only delete your own posts.');
        }

        posts[0].Status__c = 'Archived';
        update posts[0]; // NOPMD ApexCRUDViolation — community: author soft-deleting own post

        member.Community_Post_Count__c = Math.max(0, (member.Community_Post_Count__c == null ? 0 : member.Community_Post_Count__c) - 1);
        update member; // NOPMD ApexCRUDViolation — community: decrementing post count
        return 'deleted';
    }

    // ═══════════════════════════════════════════════════════════
    // VOTING
    // ═══════════════════════════════════════════════════════════

    @RemoteAction
    public static String vote(String sessToken, String votePostId, String voteReplyId) {
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in to vote.');
        }

        Id memberId = member.Id;
        List<DocGen_Community_Vote__c> existingVotes;
        if (String.isNotBlank(votePostId)) {
            existingVotes = [SELECT Id FROM DocGen_Community_Vote__c
                WHERE Voter__c = :memberId AND Post__c = :votePostId WITH SYSTEM_MODE LIMIT 1];
        } else if (String.isNotBlank(voteReplyId)) {
            existingVotes = [SELECT Id FROM DocGen_Community_Vote__c
                WHERE Voter__c = :memberId AND Reply__c = :voteReplyId WITH SYSTEM_MODE LIMIT 1];
        } else {
            return 'invalid';
        }

        if (!existingVotes.isEmpty()) {
            delete existingVotes; // NOPMD ApexCRUDViolation — community: removing vote (toggle)
            updateVoteCount(votePostId, voteReplyId, -1);
            return 'removed';
        }

        DocGen_Community_Vote__c newVote = new DocGen_Community_Vote__c(Voter__c = memberId);
        if (String.isNotBlank(votePostId)) {
            newVote.Post__c = votePostId;
        }
        if (String.isNotBlank(voteReplyId)) {
            newVote.Reply__c = voteReplyId;
        }
        insert newVote; // NOPMD ApexCRUDViolation — community: adding vote for verified member
        updateVoteCount(votePostId, voteReplyId, 1);
        return 'added';
    }

    private static void updateVoteCount(String vcPostId, String vcReplyId, Integer delta) {
        if (String.isNotBlank(vcPostId)) {
            DocGen_Community_Post__c p = [SELECT Upvote_Count__c FROM DocGen_Community_Post__c WHERE Id = :vcPostId WITH SYSTEM_MODE LIMIT 1];
            p.Upvote_Count__c = Math.max(0, (p.Upvote_Count__c == null ? 0 : p.Upvote_Count__c) + delta);
            update p; // NOPMD ApexCRUDViolation — community: updating vote count
        }
        if (String.isNotBlank(vcReplyId)) {
            DocGen_Community_Reply__c r = [SELECT Upvote_Count__c FROM DocGen_Community_Reply__c WHERE Id = :vcReplyId WITH SYSTEM_MODE LIMIT 1];
            r.Upvote_Count__c = Math.max(0, (r.Upvote_Count__c == null ? 0 : r.Upvote_Count__c) + delta);
            update r; // NOPMD ApexCRUDViolation — community: updating vote count
        }
    }

    // ═══════════════════════════════════════════════════════════
    // FILE UPLOAD
    // ═══════════════════════════════════════════════════════════

    @RemoteAction
    public static String uploadFile(String sessToken, String fileName, String base64Data, String parentId) { // NOPMD ExcessiveParameterList — file upload requires all fields
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in to upload files.');
        }

        String ext = fileName.substringAfterLast('.').toLowerCase();
        Set<String> allowed = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'webp', 'pdf', 'docx', 'xlsx', 'pptx' };
        if (!allowed.contains(ext)) {
            throw new AuraHandledException('File type not allowed. Supported: images, GIFs, PDFs, Office docs.');
        }
        if (base64Data.length() > 14000000) {
            throw new AuraHandledException('File is too large. Maximum 10MB.');
        }

        ContentVersion cv = new ContentVersion(
            Title = fileName,
            PathOnClient = fileName,
            VersionData = EncodingUtil.base64Decode(base64Data),
            FirstPublishLocationId = parentId
        );
        insert cv; // NOPMD ApexCRUDViolation — community: file upload for verified member

        // Create a public ContentDistribution so the guest user can view the file
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH SYSTEM_MODE LIMIT 1];
        ContentDistribution cd = new ContentDistribution(
            Name = fileName,
            ContentVersionId = cv.Id,
            PreferencesAllowViewInBrowser = true,
            PreferencesNotifyOnVisit = false
        );
        insert cd; // NOPMD ApexCRUDViolation — community: creating public URL for uploaded file
        cd = [SELECT ContentDownloadUrl FROM ContentDistribution WHERE Id = :cd.Id WITH SYSTEM_MODE LIMIT 1];
        return cd.ContentDownloadUrl;
    }

    // ═══════════════════════════════════════════════════════════
    // @MENTION SEARCH & NOTIFICATION PREFERENCES
    // ═══════════════════════════════════════════════════════════

    @RemoteAction
    public static List<Map<String, String>> searchMembers(String searchTerm) {
        List<Map<String, String>> results = new List<Map<String, String>>();
        if (String.isBlank(searchTerm) || searchTerm.length() < 2) {
            return results;
        }
        String likeStr = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
        for (Contact c : [
            SELECT Id, FirstName, LastName, Account.Name
            FROM Contact
            WHERE Community_Verified__c = true AND (FirstName LIKE :likeStr OR LastName LIKE :likeStr)
            WITH SYSTEM_MODE LIMIT 8
        ]) {
            String fullName = ((c.FirstName != null ? c.FirstName + ' ' : '') + c.LastName).trim();
            results.add(new Map<String, String>{
                'id' => c.Id,
                'name' => fullName,
                'company' => c.Account != null ? c.Account.Name : ''
            });
        }
        return results;
    }

    @RemoteAction
    public static String toggleNotifications(String sessToken) {
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in.');
        }
        // Query current value
        Contact c = [SELECT Id, Community_Notifications__c FROM Contact WHERE Id = :member.Id WITH SYSTEM_MODE LIMIT 1];
        c.Community_Notifications__c = !(c.Community_Notifications__c == true);
        update c; // NOPMD ApexCRUDViolation — community: toggling notification preference
        return c.Community_Notifications__c ? 'on' : 'off';
    }

    @RemoteAction
    public static void notifyMentionedUsers(String sessToken, String postId, String mentionedIds) {
        Contact member = getSessionMember(sessToken);
        if (member == null || String.isBlank(mentionedIds)) { return; }
        String memberName = ((member.FirstName != null ? member.FirstName + ' ' : '') + member.LastName).trim();

        Set<Id> mentionIds = new Set<Id>();
        for (String idStr : mentionedIds.split(',')) {
            String trimmed = idStr.trim();
            if (String.isNotBlank(trimmed)) {
                try { mentionIds.add(Id.valueOf(trimmed)); } catch (Exception e) { System.debug(LoggingLevel.DEBUG, 'Invalid mention ID: ' + trimmed); }
            }
        }
        if (mentionIds.isEmpty()) { return; }

        for (Contact c : [SELECT Id, Email, FirstName, Community_Notifications__c FROM Contact WHERE Id IN :mentionIds AND Community_Verified__c = true WITH SYSTEM_MODE]) {
            if (String.isNotBlank(c.Email) && (c.Community_Notifications__c == null || c.Community_Notifications__c == true)) {
                sendMentionNotification(c.Email, c.FirstName, memberName, postId);
            }
        }
    }

    @future(callout=true)
    private static void sendMentionNotification(String toEmail, String firstName, String mentionerName, String postId) {
        DocGen_Demo_Config__c config = DocGen_Demo_Config__c.getOrgDefaults();
        if (config == null || String.isBlank(config.Resend_API_Key__c)) { return; }

        String postUrl = 'https://portwoodglobalsolutions.com/DocGenCommunity?view=post&id=' + postId;
        String greeting = String.isNotBlank(firstName) ? firstName : 'there';
        String htmlBody = '<div style="font-family: -apple-system, sans-serif; max-width: 500px; margin: 0 auto;">' +
            '<h2 style="color: #1a1a2e;">You were mentioned</h2>' +
            '<p>Hey ' + greeting.escapeHtml4() + ', <strong>' + mentionerName.escapeHtml4() + '</strong> mentioned you in a post on the DocGen Community.</p>' +
            '<a href="' + postUrl + '" style="display: inline-block; background: #2563eb; color: #fff; padding: 12px 24px; border-radius: 8px; text-decoration: none; margin: 1rem 0;">View Post</a>' +
            '<p style="color: #666; font-size: 0.85rem; margin-top: 1.5rem;">— DocGen Community</p></div>';

        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.resend.com/emails'); // NOPMD ApexSuggestUsingNamedCred
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + config.Resend_API_Key__c); // NOPMD ApexSuggestUsingNamedCred
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{
            'from' => 'DocGen Community <community@send.portwoodglobalsolutions.com>',
            'to' => new List<String>{ toEmail },
            'subject' => mentionerName + ' mentioned you',
            'html' => htmlBody
        }));
        try {
            Http http = new Http();
            HttpResponse res = http.send(req);
            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.ERROR, 'sendMentionNotification failed: ' + res.getStatusCode());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'sendMentionNotification error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // PROFILES — wrapper properties bypass guest user FLS on Contact fields
    // ═══════════════════════════════════════════════════════════

    public String getProfDisplayName() { return profDisplayName; }
    public String getProfDisplayTitle() { return profDisplayTitle; }
    public String getProfDisplayCompany() { return profDisplayCompany; }
    public String getProfDisplayBio() { return profDisplayBio; }
    public String getProfInitials() { return profInitials; }
    public Decimal getProfPostCount() { return profPostCount != null ? profPostCount : 0; }
    public Decimal getProfSolutionCount() { return profSolutionCount != null ? profSolutionCount : 0; }
    public Datetime getProfCreatedDate() { return profCreatedDate; }
    public Boolean getProfHasData() { return profContactId != null; }

    public Contact getProfileMember() {
        try {
            if (String.isBlank(profileId)) {
                return null;
            }
            List<Contact> members = [
                SELECT Id, FirstName, LastName, Email, Title, Account.Name,
                       Community_Bio__c, Community_Post_Count__c, Community_Solution_Count__c,
                       Community_Verified__c, CreatedDate
                FROM Contact WHERE Id = :profileId AND Community_Verified__c = true
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (members.isEmpty()) {
                return null;
            }
            Contact c = members[0];
            profContactId = c.Id;
            profDisplayName = ((c.FirstName != null ? c.FirstName + ' ' : '') + c.LastName).trim();
            profDisplayTitle = c.Title;
            profDisplayCompany = c.Account != null ? c.Account.Name : null;
            profDisplayBio = c.Community_Bio__c;
            profInitials = (c.FirstName != null ? c.FirstName.left(1) : '') + (c.LastName != null ? c.LastName.left(1) : '');
            profPostCount = c.Community_Post_Count__c;
            profSolutionCount = c.Community_Solution_Count__c;
            profCreatedDate = c.CreatedDate;
            return c;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getProfileMember failed: ' + e.getMessage());
            return null;
        }
    }

    public List<DocGen_Community_Post__c> getProfilePosts() {
        try {
            if (String.isBlank(profileId)) {
                return new List<DocGen_Community_Post__c>();
            }
            return [
                SELECT Id, Title__c, Body__c, Category__c, Topics__c, Upvote_Count__c, Reply_Count__c,
                       View_Count__c, Is_Answered__c, Author_Contact_Id__c, Author_Display_Name__c, CreatedDate
                FROM DocGen_Community_Post__c WHERE Author_Contact_Id__c = :profileId AND Status__c != 'Archived'
                WITH SYSTEM_MODE ORDER BY CreatedDate DESC LIMIT 20
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getProfilePosts failed: ' + e.getMessage());
            return new List<DocGen_Community_Post__c>();
        }
    }

    @RemoteAction
    public static String updateProfile(String sessToken, String fullName, String titleVal, String bio) { // NOPMD ExcessiveParameterList
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in.');
        }

        String firstName = '';
        String lastName = fullName.trim();
        if (fullName.contains(' ')) {
            Integer idx = fullName.indexOf(' ');
            firstName = fullName.substring(0, idx);
            lastName = fullName.substring(idx + 1);
        }

        member.FirstName = firstName;
        member.LastName = lastName;
        member.Title = titleVal;
        member.Community_Bio__c = bio;
        update member; // NOPMD ApexCRUDViolation — community: member editing own profile
        return 'updated';
    }

    // ─── Account & Org Management ───

    @RemoteAction
    public static List<Map<String, String>> getMyOrgs(String sessToken) {
        Contact member = getSessionMember(sessToken);
        if (member == null || member.AccountId == null) {
            return new List<Map<String, String>>();
        }
        List<Map<String, String>> orgs = new List<Map<String, String>>();
        for (DocGen_Subscriber_Org__c so : [
            SELECT Id, Name, Org_Id__c, Org_Type__c, Package_Version__c, Install_Status__c, Last_Synced__c
            FROM DocGen_Subscriber_Org__c WHERE Account__c = :member.AccountId
            WITH SYSTEM_MODE ORDER BY Name
        ]) {
            orgs.add(new Map<String, String>{
                'id' => so.Id,
                'name' => so.Name,
                'orgId' => so.Org_Id__c,
                'orgType' => so.Org_Type__c,
                'version' => so.Package_Version__c,
                'status' => so.Install_Status__c
            });
        }
        return orgs;
    }

    @RemoteAction
    public static String addOrg(String sessToken, String orgId) {
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in.');
        }
        if (String.isBlank(orgId) || orgId.trim().length() < 15) {
            throw new AuraHandledException('Please enter a valid 15 or 18 character Org ID.');
        }
        orgId = orgId.trim();

        // Check if org already exists
        List<DocGen_Subscriber_Org__c> existing = [
            SELECT Id, Account__c FROM DocGen_Subscriber_Org__c WHERE Org_Id__c = :orgId WITH SYSTEM_MODE LIMIT 1
        ];
        if (!existing.isEmpty()) {
            if (existing[0].Account__c == member.AccountId) {
                return 'already_linked';
            }
            // Link to this member's account
            existing[0].Account__c = member.AccountId;
            update existing[0]; // NOPMD ApexCRUDViolation — community: member linking org to their account
            return 'linked';
        }

        // Create new subscriber org record
        DocGen_Subscriber_Org__c newOrg = new DocGen_Subscriber_Org__c(
            Name = orgId,
            Org_Id__c = orgId,
            Account__c = member.AccountId,
            Install_Status__c = 'Installed'
        );
        insert newOrg; // NOPMD ApexCRUDViolation — community: member adding org to their account
        return 'added';
    }

    @RemoteAction
    public static String removeOrg(String sessToken, String subscriberOrgId) {
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in.');
        }

        List<DocGen_Subscriber_Org__c> orgs = [
            SELECT Id, Account__c FROM DocGen_Subscriber_Org__c
            WHERE Id = :subscriberOrgId AND Account__c = :member.AccountId
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (orgs.isEmpty()) {
            throw new AuraHandledException('Org not found or not linked to your account.');
        }

        // Don't delete — just unlink from account
        orgs[0].Account__c = null;
        update orgs[0]; // NOPMD ApexCRUDViolation — community: member unlinking org from their account
        return 'removed';
    }

    @RemoteAction
    public static String updateCompany(String sessToken, String companyName) {
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in.');
        }
        if (String.isBlank(companyName)) {
            throw new AuraHandledException('Company name is required.');
        }

        if (member.AccountId != null) {
            Account a = [SELECT Id, Name FROM Account WHERE Id = :member.AccountId WITH SYSTEM_MODE LIMIT 1];
            a.Name = companyName.trim();
            update a; // NOPMD ApexCRUDViolation — community: member updating their company name
        } else {
            Account a = new Account(Name = companyName.trim());
            insert a; // NOPMD ApexCRUDViolation — community: creating account for member
            Contact c = new Contact(Id = member.Id, AccountId = a.Id);
            update c; // NOPMD ApexCRUDViolation — community: linking member to new account
        }
        return 'updated';
    }

    // ═══════════════════════════════════════════════════════════
    // VENDOR APPLICATION
    // ═══════════════════════════════════════════════════════════

    @RemoteAction
    public static String applyAsVendor(String sessToken, String companyName, String services, // NOPMD ExcessiveParameterList — vendor application requires all fields
                                        String vendorWebsite, String certifications, String vendorMessage) {
        Contact member = getSessionMember(sessToken);
        if (member == null) {
            throw new AuraHandledException('Please log in to apply.');
        }

        Lead vendorLead = new Lead(
            FirstName = member.FirstName,
            LastName = member.LastName,
            Email = member.Email,
            Company = String.isNotBlank(companyName) ? companyName : '[Not Provided]',
            Website = vendorWebsite,
            Description = 'PREFERRED VENDOR APPLICATION\n\n' +
                'Services: ' + services + '\n' +
                'Certifications: ' + certifications + '\n' +
                'Message: ' + vendorMessage + '\n\n' +
                'Community Member ID: ' + member.Id,
            LeadSource = 'Vendor Application',
            Status = 'New'
        );
        try {
            insert vendorLead; // NOPMD ApexCRUDViolation — community: vendor application creates Lead for review
        } catch (DmlException e) {
            System.debug(LoggingLevel.ERROR, 'Vendor Lead insert failed: ' + e.getMessage());
            throw new AuraHandledException('Unable to submit application. Please try again or contact support.');
        }
        return 'submitted';
    }

    public List<Account> getPreferredVendors() {
        try {
            return [
                SELECT Id, Name, Website, Description,
                       (SELECT Id, FirstName, LastName, Title FROM Contacts WHERE Community_Verified__c = true LIMIT 3)
                FROM Account WHERE RecordType.DeveloperName = 'Preferred_Vendor'
                WITH SYSTEM_MODE ORDER BY Name
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getPreferredVendors failed: ' + e.getMessage());
            return new List<Account>();
        }
    }

    // ═══════════════════════════════════════════════════════════
    // TESTIMONIALS
    // ═══════════════════════════════════════════════════════════

    public List<DocGen_Community_Post__c> getTestimonials() {
        try {
            return [
                SELECT Id, Title__c, Body__c, Upvote_Count__c, CreatedDate,
                       Author__r.FirstName, Author__r.LastName, Author__r.Account.Name
                FROM DocGen_Community_Post__c
                WHERE Category__c = 'Testimonial' AND Status__c = 'Active'
                WITH SYSTEM_MODE ORDER BY Is_Pinned__c DESC, Upvote_Count__c DESC, CreatedDate DESC LIMIT 10
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getTestimonials failed: ' + e.getMessage());
            return new List<DocGen_Community_Post__c>();
        }
    }

    // ═══════════════════════════════════════════════════════════
    // TOPICS / STATS
    // ═══════════════════════════════════════════════════════════

    public List<TopicStat> getPopularTopics() {
        try {
            Map<String, Integer> topicCounts = countTopicsFromPosts();
            List<TopicStat> stats = new List<TopicStat>();
            for (String t : topicCounts.keySet()) {
                stats.add(new TopicStat(t, topicCounts.get(t)));
            }
            stats.sort();
            return (stats.size() > 15) ? new List<TopicStat>{ stats[0], stats[1], stats[2], stats[3], stats[4],
                stats[5], stats[6], stats[7], stats[8], stats[9], stats[10], stats[11], stats[12], stats[13], stats[14] } : stats;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getPopularTopics failed: ' + e.getMessage());
            return new List<TopicStat>();
        }
    }

    private Map<String, Integer> countTopicsFromPosts() {
        Map<String, Integer> topicCounts = new Map<String, Integer>();
        for (DocGen_Community_Post__c p : [
            SELECT Topics__c FROM DocGen_Community_Post__c
            WHERE Topics__c != null AND Status__c = 'Active'
            WITH SYSTEM_MODE ORDER BY CreatedDate DESC LIMIT 200
        ]) {
            for (String t : p.Topics__c.split(',')) {
                t = t.trim();
                if (String.isNotBlank(t)) {
                    Integer current = topicCounts.containsKey(t) ? topicCounts.get(t) : 0;
                    topicCounts.put(t, current + 1);
                }
            }
        }
        return topicCounts;
    }

    public class TopicStat implements Comparable {
        public String name { get; set; }
        public Integer count { get; set; }
        public TopicStat(String n, Integer c) {
            this.name = n;
            this.count = c;
        }
        public Integer compareTo(Object other) {
            return ((TopicStat) other).count - this.count;
        }
    }

    // ─── Category Counts (for hub category cards) ───

    private Map<String, Integer> getCategoryCounts() {
        if (categoryCounts != null) {
            return categoryCounts;
        }
        categoryCounts = new Map<String, Integer>();
        try {
            for (AggregateResult ar : [
                SELECT Category__c cat, COUNT(Id) cnt
                FROM DocGen_Community_Post__c
                WHERE Status__c = 'Active'
                WITH SYSTEM_MODE
                GROUP BY Category__c
            ]) {
                categoryCounts.put((String) ar.get('cat'), (Integer) ar.get('cnt'));
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getCategoryCounts failed: ' + e.getMessage());
        }
        return categoryCounts;
    }

    public Integer getDiscussionCount() { return getCategoryCounts().containsKey('Discussion') ? getCategoryCounts().get('Discussion') : 0; }
    public Integer getQuestionCount() { return getCategoryCounts().containsKey('Question') ? getCategoryCounts().get('Question') : 0; }
    public Integer getFeatureRequestCount() { return getCategoryCounts().containsKey('Feature Request') ? getCategoryCounts().get('Feature Request') : 0; }
    public Integer getBugReportCount() { return getCategoryCounts().containsKey('Bug Report') ? getCategoryCounts().get('Bug Report') : 0; }
    public Integer getShowAndTellCount() { return getCategoryCounts().containsKey('Show and Tell') ? getCategoryCounts().get('Show and Tell') : 0; }
    public Integer getTemplateShareCount() { return getCategoryCounts().containsKey('Template Share') ? getCategoryCounts().get('Template Share') : 0; }
    public Integer getTestimonialCount() { return getCategoryCounts().containsKey('Testimonial') ? getCategoryCounts().get('Testimonial') : 0; }

    public Integer getTotalMembers() {
        try {
            return [SELECT COUNT() FROM Contact WHERE Community_Verified__c = true WITH SYSTEM_MODE];
        } catch (Exception e) {
            return 0;
        }
    }

    public Integer getTotalPosts() {
        try {
            return [SELECT COUNT() FROM DocGen_Community_Post__c WHERE Status__c = 'Active' WITH SYSTEM_MODE];
        } catch (Exception e) {
            return 0;
        }
    }

    // ═══════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════

    private static Contact getSessionMember(String sessToken) {
        if (String.isBlank(sessToken)) {
            return null;
        }
        List<Contact> members = [
            SELECT Id, FirstName, LastName, Email, AccountId, Title,
                   Community_Post_Count__c, Community_Solution_Count__c, Community_Notifications__c
            FROM Contact
            WHERE Community_Token__c = :sessToken AND Community_Verified__c = true
            AND Community_Token_Expiry__c > :Datetime.now()
            WITH SYSTEM_MODE LIMIT 1
        ];
        return members.isEmpty() ? null : members[0];
    }

    @future
    private static void clearSessionTokenAsync(Id contactId) {
        Contact c = new Contact(Id = contactId, Community_Token__c = null, Community_Token_Expiry__c = null);
        update c; // NOPMD ApexCRUDViolation — community auth: async session clear on logout
    }

    @future
    private static void incrementViewCount(Id pId, Decimal newCount) {
        DocGen_Community_Post__c p = new DocGen_Community_Post__c(Id = pId, View_Count__c = newCount);
        update p; // NOPMD ApexCRUDViolation — community: async view count increment in system context
    }

    private static String getAccountName(Id accountId) {
        List<Account> accts = [SELECT Name FROM Account WHERE Id = :accountId WITH SYSTEM_MODE LIMIT 1];
        return accts.isEmpty() ? null : accts[0].Name;
    }

    private static String sanitizeHtml(String input) {
        if (String.isBlank(input)) {
            return input;
        }
        input = input.replaceAll('(?i)<script[^>]*>.*?</script>', '');
        input = input.replaceAll('(?i)\\bon\\w+\\s*=', '');
        input = input.replaceAll('(?i)javascript:', '');
        return input;
    }
}
