/**
 * Scheduled Apex that refreshes the demo org session token.
 * Uses OAuth username-password flow to get a session ID that works with
 * frontdoor.jsp for browser SSO. Client_credentials tokens are API-only
 * and do not support frontdoor.jsp.
 *
 * Schedule: System.schedule('Demo Session Refresh', '0 0 0/2 * * ?', new DemoSessionRefresher());
 * Deploy to partner org only.
 */
public with sharing class DemoSessionRefresher implements Schedulable {

    private static final String RET_URL = '/lightning/n/portwoodglobal__DocGen_Command_Hub';

    public void execute(SchedulableContext ctx) {
        refreshSession();
    }

    @future(callout=true) // NOPMD AnnotationsNamingConventions
    public static void refreshSessionAsync() {
        refreshSession();
    }

    public static void refreshSession() {
        DocGen_Demo_Config__c config = DocGen_Demo_Config__c.getOrgDefaults();
        if (config == null || String.isBlank(config.Instance_Url__c)) {
            System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: Missing config.');
            return;
        }

        // OAuth password flow gives a session ID that works with frontdoor.jsp.
        // Requires "Allow OAuth Username-Password Flows" enabled in the target org.
        // client_credentials tokens are API-only and do NOT work for browser SSO.
        if (String.isNotBlank(config.Demo_Username__c) && String.isNotBlank(config.Demo_Password__c)
                && String.isNotBlank(config.Client_Id__c)) {
            refreshViaPasswordFlow(config);
        } else if (String.isNotBlank(config.Client_Id__c) && String.isNotBlank(config.Client_Secret__c)) {
            refreshViaClientCredentials(config);
        } else {
            System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: No credentials configured.');
        }
    }

    private static void refreshViaPasswordFlow(DocGen_Demo_Config__c config) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(config.Instance_Url__c + '/services/oauth2/token'); // NOPMD ApexSuggestUsingNamedCred — cross-org OAuth to scratch demo org
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setBody('grant_type=password'
            + '&client_id=' + EncodingUtil.urlEncode(config.Client_Id__c.trim(), 'UTF-8')
            + '&client_secret=' + EncodingUtil.urlEncode(config.Client_Secret__c.trim(), 'UTF-8')
            + '&username=' + EncodingUtil.urlEncode(config.Demo_Username__c.trim(), 'UTF-8')
            + '&password=' + EncodingUtil.urlEncode(config.Demo_Password__c.trim(), 'UTF-8'));

        try {
            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: OAuth password failed - ' + res.getStatusCode() + ': ' + res.getBody());
                return;
            }

            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            config.Access_Token__c = (String) body.get('access_token');
            config.Instance_Url__c = (String) body.get('instance_url');
            config.Last_Refreshed__c = Datetime.now();
            upsert config; // NOPMD ApexCRUDViolation — scheduled job updating config in system context
            System.debug('DemoSessionRefresher: OAuth password flow success for ' + config.Instance_Url__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: OAuth password error - ' + e.getMessage());
        }
    }

    private static void refreshViaSoapLogin(DocGen_Demo_Config__c config) {
        String soapBody = '<?xml version="1.0" encoding="utf-8"?>'
            + '<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:partner.soap.sforce.com">'
            + '<env:Body><urn:login>'
            + '<urn:username>' + config.Demo_Username__c.trim().escapeXml() + '</urn:username>'
            + '<urn:password>' + config.Demo_Password__c.trim().escapeXml() + '</urn:password>'
            + '</urn:login></env:Body></env:Envelope>';

        // Use test.salesforce.com for scratch/sandbox orgs — avoids IP-based security token requirement
        String loginHost = 'https://test.salesforce.com';
        HttpRequest req = new HttpRequest();
        req.setEndpoint(loginHost + '/services/Soap/u/59.0'); // NOPMD ApexSuggestUsingNamedCred — cross-org SOAP login; v59 because login() removed in v66
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml');
        req.setHeader('SOAPAction', 'login');
        req.setBody(soapBody);

        try {
            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: SOAP login failed - ' + res.getStatusCode() + ': ' + res.getBody());
                return;
            }

            String body = res.getBody();
            String sessionId = extractXmlValue(body, 'sessionId');
            String serverUrl = extractXmlValue(body, 'serverUrl');

            if (String.isBlank(sessionId)) {
                System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: SOAP login — no sessionId in response');
                return;
            }

            String instanceUrl = config.Instance_Url__c;
            if (String.isNotBlank(serverUrl) && serverUrl.contains('/services/')) {
                instanceUrl = serverUrl.substringBefore('/services/');
            }

            config.Access_Token__c = sessionId;
            config.Instance_Url__c = instanceUrl;
            config.Last_Refreshed__c = Datetime.now();
            upsert config; // NOPMD ApexCRUDViolation — scheduled job updating config in system context
            System.debug('DemoSessionRefresher: SOAP login success for ' + instanceUrl);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: SOAP callout error - ' + e.getMessage());
        }
    }

    private static void refreshViaClientCredentials(DocGen_Demo_Config__c config) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(config.Instance_Url__c + '/services/oauth2/token'); // NOPMD ApexSuggestUsingNamedCred — cross-org OAuth to scratch demo org
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setBody('grant_type=client_credentials'
            + '&client_id=' + EncodingUtil.urlEncode(config.Client_Id__c.trim(), 'UTF-8')
            + '&client_secret=' + EncodingUtil.urlEncode(config.Client_Secret__c.trim(), 'UTF-8'));

        try {
            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() == 200) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                config.Access_Token__c = (String) body.get('access_token');
                config.Instance_Url__c = (String) body.get('instance_url');
                config.Last_Refreshed__c = Datetime.now();
                upsert config; // NOPMD ApexCRUDViolation — scheduled job updating config in system context
                System.debug('DemoSessionRefresher: client_credentials refresh for ' + config.Instance_Url__c);
            } else {
                System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: OAuth failed - ' + res.getStatusCode() + ': ' + res.getBody());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: OAuth callout error - ' + e.getMessage());
        }
    }

    private static String extractXmlValue(String xml, String tagName) {
        String openTag = '<' + tagName + '>';
        String closeTag = '</' + tagName + '>';
        Integer startIdx = xml.indexOf(openTag);
        Integer endIdx = xml.indexOf(closeTag);
        if (startIdx >= 0 && endIdx > startIdx) {
            return xml.substring(startIdx + openTag.length(), endIdx);
        }
        return null;
    }
}
