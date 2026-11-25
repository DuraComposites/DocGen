/**
 * Copyright Dura Composites Ltd. Licensed under the Apache License, Version 2.0.
 *
 * Tests for the optional Microsoft 365 (Graph) route for signature emails: DocGenGraphMail,
 * its use in DocGenSignatureEmailService, and the settings methods in DocGenSetupController.
 */
@IsTest
private class DocGenGraphMailTest {
    private static final String NC = 'Microsoft_Graph';

    private class GraphMock implements HttpCalloutMock {
        Integer status;
        String body;
        Map<String, String> headers;
        List<HttpRequest> requests = new List<HttpRequest>();

        GraphMock(Integer status, String body) {
            this(status, body, new Map<String, String>());
        }
        GraphMock(Integer status, String body, Map<String, String> headers) {
            this.status = status;
            this.body = body;
            this.headers = headers;
        }
        public HttpResponse respond(HttpRequest req) {
            requests.add(req);
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            if (body != null) {
                res.setBody(body);
            }
            for (String k : headers.keySet()) {
                res.setHeader(k, headers.get(k));
            }
            return res;
        }
    }

    private static void enableGraph(String nc) {
        DocGen_Settings__c s = DocGen_Settings__c.getOrgDefaults();
        s.Signature_Graph_Named_Credential__c = nc;
        upsert s;
    }

    private static DocGen_Signature_Request__c newRequest() {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Signer_Name__c = 'Graph Signer',
            Signer_Email__c = 'graph.signer@example.com',
            Status__c = 'Sent'
        );
        Database.insert(req, AccessLevel.SYSTEM_MODE);
        return req;
    }

    private static String emailStatus(Id requestId) {
        return [SELECT Email_Status__c FROM DocGen_Signature_Request__c WHERE Id = :requestId].Email_Status__c;
    }

    private static List<DocGenSignatureEmailService.SignerEmail> oneSigner() {
        return new List<DocGenSignatureEmailService.SignerEmail>{
            new DocGenSignatureEmailService.SignerEmail(
                'Graph Signer',
                'graph.signer@example.com',
                'Customer',
                'https://sign.example.com/?token=abc',
                null
            )
        };
    }

    @IsTest
    static void offByDefault() {
        System.assertEquals(false, DocGenGraphMail.isEnabled(), 'blank setting means Salesforce email');
        System.assertEquals(null, DocGenGraphMail.namedCredential(), 'no named credential');
    }

    @IsTest
    static void requestEmail_sentFromCreatorMailboxViaGraph() {
        enableGraph(NC);
        DocGen_Signature_Request__c req = newRequest();
        GraphMock mock = new GraphMock(202, null);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        // No OWA is configured: the Graph route must not need one.
        DocGenSignatureEmailService.sendSignatureRequestEmails(oneSigner(), 'Quote Q-1', req.Id);
        Test.stopTest();

        System.assertEquals(1, mock.requests.size(), 'one Graph call');
        HttpRequest sent = mock.requests[0];
        String creatorEmail = UserInfo.getUserEmail();
        System.assertEquals(
            'callout:' + NC + '/v1.0/users/' + EncodingUtil.urlEncode(creatorEmail, 'UTF-8') + '/sendMail',
            sent.getEndpoint(),
            'sends as the request creator'
        );
        System.assertEquals('POST', sent.getMethod(), 'POST');
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(sent.getBody());
        System.assertEquals(true, body.get('saveToSentItems'), 'saved to Sent Items');
        Map<String, Object> message = (Map<String, Object>) body.get('message');
        String recipients = JSON.serialize(message.get('toRecipients'));
        System.assert(recipients.contains('graph.signer@example.com'), 'to the signer: ' + recipients);
        System.assert(JSON.serialize(message.get('body')).contains('sign.example.com'), 'signing link in the body');
        String status = emailStatus(req.Id);
        System.assert(status.contains('graph.signer@example.com: Sent from ' + creatorEmail), status);
    }

    @IsTest
    static void accessDenied_recordedNoFallback() {
        enableGraph(NC);
        DocGen_Signature_Request__c req = newRequest();
        Test.setMock(
            HttpCalloutMock.class,
            new GraphMock(403, '{"error":{"code":"ErrorAccessDenied","message":"Access is denied."}}')
        );

        Test.startTest();
        DocGenSignatureEmailService.sendSignatureReminderEmails(oneSigner(), 'Quote Q-1', req.Id);
        Integer emailsBefore = Limits.getEmailInvocations();
        Test.stopTest();

        String status = emailStatus(req.Id);
        System.assert(status.startsWith('EMAIL DELIVERY ERRORS (Microsoft 365)'), status);
        System.assert(status.contains('ErrorAccessDenied: Access is denied.'), status);
        System.assertEquals(0, emailsBefore, 'no Salesforce email fallback');
        System.assert(
            [SELECT COUNT() FROM DocGen_Error_Log__c WHERE Record_Id__c = :String.valueOf(req.Id)] > 0,
            'failure logged'
        );
        System.assertEquals(null, DocGenGraphMail.lastRetryJob, 'a 403 is not retried');
    }

    @IsTest
    static void throttled_retriedWithDelay() {
        enableGraph(NC);
        DocGen_Signature_Request__c req = newRequest();
        Test.setMock(
            HttpCalloutMock.class,
            new GraphMock(
                429,
                '{"error":{"code":"TooManyRequests","message":"Slow down"}}',
                new Map<String, String>{ 'Retry-After' => '150' }
            )
        );

        Test.startTest();
        DocGenSignatureEmailService.sendSignatureRequestEmails(oneSigner(), 'Quote Q-1', req.Id);
        Test.stopTest();

        DocGenGraphMail.SendJob retry = DocGenGraphMail.lastRetryJob;
        System.assertNotEquals(null, retry, 'retry queued');
        System.assertEquals(2, retry.attempt, 'second attempt');
        System.assertEquals(3, retry.delayMinutes, '150 seconds rounds up to 3 minutes');
        System.assertEquals(1, retry.messages.size(), 'only the throttled message');
        System.assert(emailStatus(req.Id).contains('retrying (attempt 2 of 3)'), emailStatus(req.Id));
    }

    @IsTest
    static void throttledOnLastAttempt_fails() {
        DocGen_Signature_Request__c req = newRequest();
        Test.setMock(HttpCalloutMock.class, new GraphMock(503, null));
        DocGenGraphMail.SendJob job = new DocGenGraphMail.SendJob(
            req.Id,
            NC,
            'creator@example.com',
            new List<DocGenGraphMail.Message>{
                new DocGenGraphMail.Message('a@example.com', 'A', 'Subject', '<p>x</p>')
            },
            'Reminder',
            DocGenGraphMail.MAX_ATTEMPTS
        );

        Test.startTest();
        System.enqueueJob(job);
        Test.stopTest();

        System.assertEquals(null, DocGenGraphMail.lastRetryJob, 'no retry after the last attempt');
        System.assert(
            emailStatus(req.Id).contains('a@example.com: FAILED via Microsoft 365, HTTP 503'),
            emailStatus(req.Id)
        );
    }

    @IsTest
    static void calloutException_recorded() {
        DocGen_Signature_Request__c req = newRequest();
        // No mock set: the callout throws, as it would for a missing Named Credential.
        DocGenGraphMail.SendJob job = new DocGenGraphMail.SendJob(
            req.Id,
            NC,
            'creator@example.com',
            new List<DocGenGraphMail.Message>{
                new DocGenGraphMail.Message('a@example.com', null, 'Subject', '<p>x</p>')
            },
            'Request',
            1
        );
        Test.startTest();
        System.enqueueJob(job);
        Test.stopTest();
        System.assert(emailStatus(req.Id).contains('a@example.com: FAILED via Microsoft 365'), emailStatus(req.Id));
    }

    @IsTest
    static void invalidNamedCredentialSetting_notSent() {
        enableGraph('callout:bad/name');
        DocGen_Signature_Request__c req = newRequest();
        Test.startTest();
        DocGenSignatureEmailService.sendSignatureRequestEmails(oneSigner(), 'Quote Q-1', req.Id);
        Test.stopTest();
        String status = emailStatus(req.Id);
        System.assert(status.contains('Not sent: the Microsoft 365 Named Credential setting'), status);
    }

    @IsTest
    static void revokedEmails_viaGraph() {
        enableGraph(NC);
        DocGen_Signature_Request__c req = newRequest();
        insert new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Pending Signer',
            Signer_Email__c = 'pending@example.com',
            Role_Name__c = 'Customer',
            Status__c = 'Pending',
            Sort_Order__c = 1
        );
        GraphMock mock = new GraphMock(202, null);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DocGenSignatureEmailService.sendSignerRevokedEmails(req.Id);
        Test.stopTest();

        System.assertEquals(1, mock.requests.size(), 'one revocation through Graph');
        System.assert(mock.requests[0].getBody().contains('pending@example.com'), 'to the pending signer');
    }

    @IsTest
    static void sendTestToSelf_results() {
        System.assert(DocGenGraphMail.sendTestToSelf().contains('off'), 'off without a setting');

        enableGraph(NC);
        Test.setMock(HttpCalloutMock.class, new GraphMock(202, null));
        Test.startTest();
        String ok = DocGenSetupController.sendGraphTestEmail();
        Test.stopTest();
        System.assert(ok.startsWith('Sent.'), ok);
    }

    @IsTest
    static void sendTestToSelf_failure() {
        enableGraph(NC);
        Test.setMock(HttpCalloutMock.class, new GraphMock(401, 'not json'));
        Test.startTest();
        String result = DocGenGraphMail.sendTestToSelf();
        Test.stopTest();
        System.assert(result.startsWith('Failed: HTTP 401 not json'), result);
    }

    @IsTest
    static void saveGraphMailSettings_validatesAndClears() {
        DocGenSetupController.saveGraphMailSettings('  ' + NC + '  ');
        System.assertEquals(NC, DocGen_Settings__c.getOrgDefaults().Signature_Graph_Named_Credential__c, 'trimmed');
        System.assertEquals(
            NC,
            DocGenSetupController.getSettingsFresh().get('Signature_Graph_Named_Credential__c'),
            'returned to the settings screen'
        );

        Boolean threw = false;
        try {
            DocGenSetupController.saveGraphMailSettings('https://graph.microsoft.com');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'a URL is rejected');

        DocGenSetupController.saveGraphMailSettings('');
        System.assertEquals(null, DocGen_Settings__c.getOrgDefaults().Signature_Graph_Named_Credential__c, 'cleared');
    }

    @IsTest
    static void setupCheck_reportsMissingNamedCredential() {
        enableGraph('DocGen_Test_No_Such_NC');
        Boolean found = false;
        for (Map<String, Object> check : DocGenSetupController.validateSignatureSetup()) {
            if (check.get('name') == 'Microsoft 365 sending') {
                found = true;
                System.assertEquals(false, check.get('passed'), 'missing NC fails the check');
            }
        }
        System.assert(found, 'check shown when the route is on');
    }

    @IsTest
    static void helpers() {
        System.assert(DocGenGraphMail.isValidNamedCredentialName('ns__Microsoft_Graph'), 'namespaced name');
        System.assert(!DocGenGraphMail.isValidNamedCredentialName('Graph/../x'), 'path rejected');
        System.assertEquals(2, DocGenGraphMail.clampDelay(null), 'default delay');
        System.assertEquals(10, DocGenGraphMail.clampDelay(60), 'capped at 10');
        System.assertEquals('', DocGenGraphMail.describeError(null), 'blank body');
        System.assertEquals(null, DocGenGraphMail.creatorMailbox(null), 'no request');
        String payload = DocGenGraphMail.buildPayload(
            new DocGenGraphMail.Message('x@example.com', null, 'S', '<b>hi</b>')
        );
        System.assert(payload.contains('"name":"x@example.com"'), 'name defaults to the address: ' + payload);
    }
}
