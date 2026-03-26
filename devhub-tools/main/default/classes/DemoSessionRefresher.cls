/**
 * Scheduled Apex that refreshes the demo org session token.
 * Uses OAuth client_credentials flow to get a fresh token,
 * builds a frontdoor.jsp URL, and stores it in DocGen_Demo_Config__c.
 *
 * Schedule: System.schedule('Demo Session Refresh', '0 0 0/2 * * ?', new DemoSessionRefresher());
 * Deploy to partner org only.
 */
public with sharing class DemoSessionRefresher implements Schedulable {

    private static final String RET_URL = '/lightning/n/portwoodglobal__DocGen_Command_Hub';

    public void execute(SchedulableContext ctx) {
        refreshSession();
    }

    @future(callout=true)
    public static void refreshSessionAsync() {
        refreshSession();
    }

    public static void refreshSession() {
        DocGen_Demo_Config__c config = DocGen_Demo_Config__c.getOrgDefaults();
        if (config == null || String.isBlank(config.Client_Id__c) || String.isBlank(config.Instance_Url__c)) {
            System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: Missing config. Set Client_Id__c, Client_Secret__c, Instance_Url__c on DocGen_Demo_Config__c org defaults.');
            return;
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint(config.Instance_Url__c + '/services/oauth2/token');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setBody('grant_type=password&client_id=' + EncodingUtil.urlEncode(config.Client_Id__c.trim(), 'UTF-8') + '&client_secret=' + EncodingUtil.urlEncode(config.Client_Secret__c.trim(), 'UTF-8') + '&username=docgen-demo-user%40portwoodglobal.demo&password=DocGenDemo2026!');

        try {
            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() == 200) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                String token = (String) body.get('access_token');
                String instanceUrl = (String) body.get('instance_url');

                config.Access_Token__c = token;
                config.Instance_Url__c = instanceUrl;
                config.Last_Refreshed__c = Datetime.now();
                upsert config;

                System.debug('DemoSessionRefresher: Token refreshed for ' + instanceUrl);
            } else {
                System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: OAuth failed - ' + res.getStatusCode() + ': ' + res.getBody());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DemoSessionRefresher: Callout error - ' + e.getMessage());
        }
    }
}
