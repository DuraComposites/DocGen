/**
 * Copyright Dura Composites Ltd. Licensed under the Apache License, Version 2.0.
 *
 * Optional Microsoft 365 route for signature emails. When
 * DocGen_Settings__c.Signature_Graph_Named_Credential__c names a Named Credential for
 * https://graph.microsoft.com, signer request, reminder and revocation emails are sent
 * through Microsoft Graph (POST /users/{mailbox}/sendMail, saveToSentItems) from the
 * mailbox of the user who CREATED the signature request, so they land in that user's
 * Sent Items. Blank setting = Salesforce email, unchanged.
 *
 * Rules (agreed for this route):
 * - The sender is always the request creator's User.Email, resolved server-side. Nobody
 *   picks it. Exchange (RBAC for Applications / Application Access Policy) limits which
 *   mailboxes the app may send as.
 * - No fallback to the Org-Wide Email Address. A failure is written to the request's
 *   Email_Status__c and the DocGen error log.
 * - Sends run in a Queueable: every caller has already done DML in its transaction, and
 *   a callout after DML is not allowed.
 * - Throttling (429) and "service unavailable" (503) are retried, up to MAX_ATTEMPTS, a few
 *   minutes apart. Nothing else is retried, because Graph may already have sent the
 *   message and a retry would duplicate it. A manual retry is the request's Resend.
 *
 * The job runs as the user who triggered the send: the salesperson, the reminder scheduler,
 * or Automated Process (DocGenSignaturePdfTrigger, later signers in sequential signing).
 * Each needs principal access to the Named Credential's External Credential; see the "Send
 * signature emails from Microsoft 365" article. The guest signing page sends none of the
 * Graph-routed emails.
 */
public without sharing class DocGenGraphMail {
    public static final Integer MAX_ATTEMPTS = 3;
    @TestVisible
    private static final Integer MAX_CALLOUTS_PER_JOB = 90;
    private static final Integer DEFAULT_RETRY_MINUTES = 2;
    private static final Integer MAX_RETRY_MINUTES = 10;
    private static final Pattern NAMED_CREDENTIAL_NAME = Pattern.compile('^[A-Za-z][A-Za-z0-9_]{0,79}$');
    private static final String STATUS_FIX_HINT = '\n\nCheck: (1) the sender has a Microsoft 365 mailbox at their Salesforce email address (2) that mailbox is in the group the Exchange policy allows (3) the user who sent it has access to the Named Credential\'s External Credential (permission set) (4) the app\'s secret or certificate has not expired';

    // Test hook: the job a retry would enqueue (queueables cannot chain inside a test).
    @TestVisible
    private static SendJob lastRetryJob;

    /** One email to one recipient. */
    public class Message {
        public String toAddress;
        public String toName;
        public String subject;
        public String htmlBody;

        public Message(String toAddress, String toName, String subject, String htmlBody) {
            this.toAddress = toAddress;
            this.toName = toName;
            this.subject = subject;
            this.htmlBody = htmlBody;
        }
    }

    /** The configured Named Credential name, or null when the Graph route is off. */
    public static String namedCredential() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Signature_Graph_Named_Credential__c)) {
            return null;
        }
        return settings.Signature_Graph_Named_Credential__c.trim();
    }

    /** True when signer emails go through Microsoft 365. */
    public static Boolean isEnabled() {
        return namedCredential() != null;
    }

    /** A Named Credential API name: letters, digits and underscores (a namespace__ prefix is allowed). */
    public static Boolean isValidNamedCredentialName(String name) {
        return String.isNotBlank(name) && NAMED_CREDENTIAL_NAME.matcher(name.trim()).matches();
    }

    /**
     * Queues the messages to go out from the request creator's mailbox. Writes a failure
     * to Email_Status__c (no send) when the creator has no usable mailbox address or the
     * job cannot be queued. Never throws.
     */
    public static void send(Id requestId, List<Message> messages, String operation) {
        if (messages == null || messages.isEmpty()) {
            return;
        }
        String nc = namedCredential();
        if (!isValidNamedCredentialName(nc)) {
            fail(
                requestId,
                operation,
                'the Microsoft 365 Named Credential setting "' + nc + '" is not a valid API name.'
            );
            return;
        }
        String mailbox = creatorMailbox(requestId);
        if (String.isBlank(mailbox)) {
            fail(
                requestId,
                operation,
                'the user who created this request has no email address that can be used as a Microsoft 365 mailbox.'
            );
            return;
        }
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            fail(
                requestId,
                operation,
                'no background job could be queued in this transaction (Queueable limit reached).'
            );
            return;
        }
        try {
            System.enqueueJob(new SendJob(requestId, nc, mailbox, messages, operation, 1));
        } catch (Exception e) {
            fail(requestId, operation, 'the background send could not be queued: ' + e.getMessage());
        }
    }

    /**
     * Sends a test message from the running user's own mailbox to that same address,
     * synchronously (call it from a transaction with no prior DML). Returns a readable
     * result; throws nothing.
     */
    public static String sendTestToSelf() {
        String nc = namedCredential();
        if (nc == null) {
            return 'Microsoft 365 sending is off: save a Named Credential name first.';
        }
        if (!isValidNamedCredentialName(nc)) {
            return 'The Named Credential setting "' + nc + '" is not a valid API name.';
        }
        String mailbox = UserInfo.getUserEmail();
        if (!isUsableMailbox(mailbox)) {
            return 'Your Salesforce user has no email address that can be used as a Microsoft 365 mailbox.';
        }
        Message m = new Message(
            mailbox,
            UserInfo.getName(),
            'DocGen test: signature emails through Microsoft 365',
            '<p>This test was sent by DocGen through Microsoft Graph from your own mailbox. ' +
            'If it is in your Inbox and your Sent Items, signature emails will be sent the same way.</p>'
        );
        Result r = post(nc, mailbox, m);
        if (r.success) {
            return 'Sent. Check the Inbox and Sent Items of ' + mailbox + '.';
        }
        return 'Failed: ' + r.detail;
    }

    // =========================================================================
    // Queueable
    // =========================================================================

    public class SendJob implements Queueable, Database.AllowsCallouts {
        @TestVisible
        private Id requestId;
        private String namedCredential;
        private String mailbox;
        @TestVisible
        private List<Message> messages;
        private String operation;
        @TestVisible
        private Integer attempt;
        @TestVisible
        private Integer delayMinutes;

        public SendJob(
            Id requestId,
            String namedCredential,
            String mailbox,
            List<Message> messages,
            String operation,
            Integer attempt
        ) {
            this.requestId = requestId;
            this.namedCredential = namedCredential;
            this.mailbox = mailbox;
            this.messages = messages;
            this.operation = operation;
            this.attempt = attempt;
        }

        public void execute(QueueableContext ctx) {
            List<String> statusParts = new List<String>();
            List<String> errors = new List<String>();
            List<Message> retry = new List<Message>();
            List<Message> overflow = new List<Message>();
            Integer retryAfter = null;

            for (Integer i = 0; i < messages.size(); i++) {
                Message m = messages[i];
                if (i >= MAX_CALLOUTS_PER_JOB) {
                    overflow.add(m);
                    continue;
                }
                Result r = post(namedCredential, mailbox, m);
                if (r.success) {
                    statusParts.add(m.toAddress + ': Sent from ' + mailbox + ' via Microsoft 365');
                } else if (r.retryable && attempt < MAX_ATTEMPTS) {
                    retry.add(m);
                    retryAfter = r.retryAfterMinutes;
                    statusParts.add(
                        m.toAddress +
                            ': Microsoft 365 is busy (' +
                            r.detail +
                            '), retrying (attempt ' +
                            (attempt + 1) +
                            ' of ' +
                            MAX_ATTEMPTS +
                            ')'
                    );
                } else {
                    statusParts.add(m.toAddress + ': FAILED via Microsoft 365, ' + r.detail);
                    errors.add(m.toAddress + ': ' + r.detail);
                }
            }

            if (!retry.isEmpty()) {
                SendJob next = new SendJob(requestId, namedCredential, mailbox, retry, operation, attempt + 1);
                next.delayMinutes = clampDelay(retryAfter);
                enqueue(next, next.delayMinutes);
            }
            if (!overflow.isEmpty()) {
                // More recipients than one job may call out for: carry them to a new job.
                enqueue(new SendJob(requestId, namedCredential, mailbox, overflow, operation, attempt), 0);
                statusParts.add(overflow.size() + ' more queued');
            }

            String status = String.join(statusParts, '\n');
            if (!errors.isEmpty()) {
                status = 'EMAIL DELIVERY ERRORS (Microsoft 365)\n' + status + STATUS_FIX_HINT;
                logFailure(requestId, operation, String.join(errors, '\n'));
            }
            updateEmailStatus(requestId, status);
        }
    }

    private static void enqueue(SendJob job, Integer delayMinutes) {
        if (Test.isRunningTest()) {
            lastRetryJob = job;
            return;
        }
        if (delayMinutes != null && delayMinutes > 0) {
            System.enqueueJob(job, delayMinutes);
        } else {
            System.enqueueJob(job);
        }
    }

    @TestVisible
    private static Integer clampDelay(Integer minutes) {
        if (minutes == null || minutes < 1) {
            return DEFAULT_RETRY_MINUTES;
        }
        return Math.min(minutes, MAX_RETRY_MINUTES);
    }

    // =========================================================================
    // Graph call
    // =========================================================================

    @TestVisible
    private class Result {
        public Boolean success = false;
        public Boolean retryable = false;
        public Integer retryAfterMinutes;
        public String detail;
    }

    @TestVisible
    private static String buildPayload(Message m) {
        Map<String, Object> recipient = new Map<String, Object>{
            'emailAddress' => new Map<String, Object>{
                'address' => m.toAddress,
                'name' => String.isBlank(m.toName) ? m.toAddress : m.toName
            }
        };
        Map<String, Object> message = new Map<String, Object>{
            'subject' => m.subject,
            'body' => new Map<String, Object>{ 'contentType' => 'HTML', 'content' => m.htmlBody },
            'toRecipients' => new List<Object>{ recipient }
        };
        return JSON.serialize(new Map<String, Object>{ 'message' => message, 'saveToSentItems' => true });
    }

    private static Result post(String nc, String mailbox, Message m) {
        Result r = new Result();
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + nc + '/v1.0/users/' + EncodingUtil.urlEncode(mailbox, 'UTF-8') + '/sendMail');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000);
            req.setBody(buildPayload(m));
            HttpResponse res = new Http().send(req);
            Integer code = res.getStatusCode();
            if (code == 202 || code == 200) {
                r.success = true;
                return r;
            }
            r.detail = 'HTTP ' + code + describeError(res.getBody());
            r.retryable = (code == 429 || code == 503);
            if (r.retryable) {
                r.retryAfterMinutes = retryAfterMinutes(res.getHeader('Retry-After'));
            }
        } catch (Exception e) {
            // Unknown Named Credential, no principal access, timeout, etc. Not retried.
            r.detail = e.getTypeName() + ': ' + e.getMessage();
        }
        return r;
    }

    /** " ErrorAccessDenied: Access is denied..." from a Graph error body, or blank. */
    @TestVisible
    private static String describeError(String body) {
        if (String.isBlank(body)) {
            return '';
        }
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
            Map<String, Object> err = (Map<String, Object>) parsed.get('error');
            if (err != null) {
                return ' ' + String.valueOf(err.get('code')) + ': ' + String.valueOf(err.get('message')).left(300);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.FINE, 'DocGen: Graph error body was not JSON: ' + e.getMessage());
        }
        return ' ' + body.left(300);
    }

    private static Integer retryAfterMinutes(String header) {
        if (String.isBlank(header) || !header.trim().isNumeric()) {
            return null;
        }
        Integer seconds = Integer.valueOf(header.trim());
        return (seconds + 59) / 60;
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private static Boolean isUsableMailbox(String email) {
        return String.isNotBlank(email) && email.contains('@') && !email.startsWithIgnoreCase('noreply@');
    }

    /** The request creator's email, or null. */
    @TestVisible
    private static String creatorMailbox(Id requestId) {
        if (requestId == null) {
            return null;
        }
        try {
            DocGenFlsGuard.guestAssertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{ 'CreatedById' }
            );
            DocGenFlsGuard.guestAssertAccessible(User.sObjectType, new Set<String>{ 'Email' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> rows = [
                SELECT CreatedBy.Email
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD
            if (rows.isEmpty() || rows[0].CreatedBy == null) {
                return null;
            }
            String email = rows[0].CreatedBy.Email;
            return isUsableMailbox(email) ? email : null;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: could not resolve the request creator mailbox: ' + e.getMessage());
            return null;
        }
    }

    private static void fail(Id requestId, String operation, String reason) {
        updateEmailStatus(requestId, 'EMAIL DELIVERY ERRORS (Microsoft 365)\nNot sent: ' + reason + STATUS_FIX_HINT);
        logFailure(requestId, operation, reason);
    }

    private static void logFailure(Id requestId, String operation, String message) {
        DocGenErrorLogger.Entry entry = new DocGenErrorLogger.Entry();
        entry.severity = 'Warning';
        entry.context = 'Signature Email (Microsoft 365)';
        entry.operation = operation;
        entry.recordId = requestId == null ? null : String.valueOf(requestId);
        entry.message = message;
        DocGenErrorLogger.log(entry);
    }

    private static void updateEmailStatus(Id requestId, String status) {
        if (requestId == null || String.isBlank(status)) {
            return;
        }
        try {
            DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Id = requestId);
            req.Email_Status__c = status.left(1000);
            DocGenFlsGuard.guestAssertUpdateable(req, new Set<String>{ 'Email_Status__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(req, false, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Could not update email status: ' + e.getMessage());
        }
    }
}
