// Dura Composites Ltd. (new file)
/**
 * Per-request link expiry and reminder schedules.
 *
 * A template can set defaults (DocGen_Template__c):
 *   Signature_Expiry_Days__c          link expires after N days (blank: org default);
 *   Signature_Reminder_Every_Days__c  remind every N days (0: none; blank: org schedule);
 *   Signature_Reminder_For_Days__c    keep reminding for N days (blank: until expiry).
 *
 * At send time (applyAtSend, from DocGenSignatureSenderController.sendGuidedPdfRequest, which the
 * Signature Sender and the Create Signature Request Flow action share) the sender's choices win,
 * then the template's, then the org's. The request keeps the result:
 *   Expires_At__c, Reminder_Every_Days__c (blank: org schedule; 0: none), Reminders_Until__c.
 *
 * The hourly reminder job (DocGenSignatureReminderSchedulable) calls sendDueReminders for requests
 * with their own rule and leaves them out of the org schedule. A signer is reminded when N days
 * have passed since their last reminder (or the send), before Reminders_Until__c and the link's
 * expiry. On a sequential request only the signer whose turn it is gets reminded.
 *
 * After sending, changeExpiry and changeReminders let a user extend the link or change or stop the
 * reminders; each change goes on the request's timeline (DocGenSignatureEvents) with who made it.
 * Days only.
 */
public with sharing class DocGenSignatureReminderRules {
    public static final String MODE_TEMPLATE = 'TEMPLATE';
    public static final String MODE_ORG = 'ORG';
    public static final String MODE_NONE = 'NONE';
    public static final String MODE_EVERY = 'EVERY';

    public static final String EXPIRY_CHANGED = 'Expiry changed';
    public static final String REMINDERS_CHANGED = 'Reminders changed';

    private static final Integer MAX_DAYS = 365;
    @TestVisible
    static final String CHANGE_PERMISSION = 'DocGen_Change_Signature_Requests';

    // ------------------------------------------------------------------ at send time

    /**
     * Sets Expires_At__c, Reminder_Every_Days__c and Reminders_Until__c on a new request from the
     * send options, then the template, then the org. Returns the fields it set, for the caller's
     * create guard.
     */
    public static Set<String> applyAtSend(
        DocGen_Signature_Request__c req,
        DocGenSignatureSenderController.GuidedPdfSendOptions options
    ) {
        DocGen_Template__c tmpl = templateDefaults(options != null ? options.templateId : null);
        Datetime now = System.now();

        // Expiry: a date chosen at send, then days chosen at send, then the template, then the org.
        if (options != null && options.expiresOn != null) {
            checkDate(options.expiresOn, 'The link expiry date');
            req.Expires_At__c = endOfDay(options.expiresOn);
        } else if (options != null && options.expirationDays != null) {
            req.Expires_At__c = DocGenSignatureExpiry.computeExpiry(options.expirationDays);
        } else if (tmpl != null && tmpl.Signature_Expiry_Days__c != null) {
            req.Expires_At__c = DocGenSignatureExpiry.computeExpiry(tmpl.Signature_Expiry_Days__c.intValue());
        } else {
            req.Expires_At__c = DocGenSignatureExpiry.computeExpiry(null);
        }

        // Reminders.
        String mode = options != null && String.isNotBlank(options.reminderMode)
            ? options.reminderMode.toUpperCase()
            : MODE_TEMPLATE;
        Integer every;
        Datetime until;
        if (mode == MODE_EVERY) {
            every = clampDays(options.reminderEveryDays);
            if (options.remindersUntil != null) {
                checkDate(options.remindersUntil, 'The last reminder date');
                until = endOfDay(options.remindersUntil);
            }
        } else if (mode == MODE_NONE) {
            every = 0;
        } else if (mode == MODE_TEMPLATE && tmpl != null && tmpl.Signature_Reminder_Every_Days__c != null) {
            every = Math.max(0, tmpl.Signature_Reminder_Every_Days__c.intValue());
            if (options != null && options.remindersUntil != null) {
                until = endOfDay(options.remindersUntil);
            } else if (tmpl.Signature_Reminder_For_Days__c != null) {
                until = now.addDays(tmpl.Signature_Reminder_For_Days__c.intValue());
            }
        }
        // MODE_ORG, or a template without a rule: blank, so the org schedule applies.
        req.Reminder_Every_Days__c = every;
        req.Reminders_Until__c = (every != null && every > 0) ? until : null;
        return new Set<String>{ 'Expires_At__c', 'Reminder_Every_Days__c', 'Reminders_Until__c' };
    }

    /** Send-time dates must be from today and within a year. DocGenException, so a Flow can report it. */
    private static void checkDate(Date d, String what) {
        if (d < Date.today()) {
            throw new DocGenException(what + ' is in the past.');
        }
        if (d > Date.today().addDays(MAX_DAYS)) {
            throw new DocGenException(what + ' must be within a year.');
        }
    }

    /**
     * What the Signature Sender needs to show the defaults: the org's link lifetime in days, and
     * whether the reminder job is switched on (Signature Settings).
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSendDefaults() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        return new Map<String, Object>{
            'expiryDays' => DocGenSignatureExpiry.defaultDays(),
            'remindersOn' => settings != null &&
            settings.Signature_Reminder_Enabled__c == true,
            'maxDays' => MAX_DAYS
        };
    }

    private static DocGen_Template__c templateDefaults(Id templateId) {
        if (templateId == null) {
            return null;
        }
        DocGenFlsGuard.advisoryAssertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{
                'Signature_Expiry_Days__c',
                'Signature_Reminder_Every_Days__c',
                'Signature_Reminder_For_Days__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> rows = [
            SELECT Signature_Expiry_Days__c, Signature_Reminder_Every_Days__c, Signature_Reminder_For_Days__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The expiry for a resend (DocGenSignatureSenderController.resendSignatureRequest): a fresh window
     * of the template's length, else the org default, but never earlier than the current expiry.
     */
    public static Datetime resendExpiry(Datetime current, Decimal templateDays) {
        Datetime fresh = DocGenSignatureExpiry.computeExpiry(templateDays == null ? null : templateDays.intValue());
        return (current != null && current > fresh) ? current : fresh;
    }

    // ------------------------------------------------------------------ the reminder job

    /**
     * Sends the reminders now due on requests with their own rule. Called by the hourly reminder
     * job; returns how many reminders went out.
     */
    public static Integer sendDueReminders() {
        Datetime now = System.now();
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> candidates = [
            SELECT
                Id,
                Signer_Name__c,
                Signer_Email__c,
                Role_Name__c,
                Secure_Token__c,
                Contact__c,
                Sort_Order__c,
                Reminder_Sent_At__c,
                Reminders_Sent__c,
                CreatedDate,
                Signature_Request__c,
                Signature_Request__r.CreatedDate,
                Signature_Request__r.Status__c,
                Signature_Request__r.Signing_Order__c,
                Signature_Request__r.Expires_At__c,
                Signature_Request__r.Reminder_Every_Days__c,
                Signature_Request__r.Reminders_Until__c,
                Signature_Request__r.Render_Data_Snapshot__c,
                Signature_Request__r.Source_Document_Id__c,
                Signature_Request__r.Template__c,
                Signature_Request__r.Template__r.Name
            FROM DocGen_Signer__c
            WHERE
                Status__c IN ('Pending', 'Viewed')
                AND Signature_Request__r.Status__c NOT IN ('Signed', 'Cancelled', 'Declined', 'Draft')
                AND Signature_Request__r.Reminder_Every_Days__c > 0
                AND Signature_Request__r.PDF_Internal_Preview__c = FALSE
                AND (Signature_Request__r.Reminders_Until__c = NULL
                OR Signature_Request__r.Reminders_Until__c > :now)
            WITH SYSTEM_MODE
            ORDER BY Signature_Request__c, Sort_Order__c ASC NULLS LAST
            LIMIT 200
        ];
        if (candidates.isEmpty()) {
            return 0;
        }

        String siteUrl = DocGenSignatureSenderController.getSiteBaseUrl();
        Set<Id> firstTurnTaken = new Set<Id>();
        List<DocGenSignatureEmailService.SignerEmail> emails = new List<DocGenSignatureEmailService.SignerEmail>();
        List<DocGen_Signer__c> reminded = new List<DocGen_Signer__c>();
        for (DocGen_Signer__c s : candidates) {
            DocGen_Signature_Request__c req = s.Signature_Request__r;
            // Sequential: only the first signer still to sign is being waited on.
            if (req.Signing_Order__c == 'Sequential') {
                if (firstTurnTaken.contains(s.Signature_Request__c)) {
                    continue;
                }
                firstTurnTaken.add(s.Signature_Request__c);
            }
            if (!isDue(s, now)) {
                continue;
            }
            String path = DocGenSignatureSenderController.resolveSigningPath(req);
            emails.add(
                new DocGenSignatureEmailService.SignerEmail(
                    s.Signer_Name__c,
                    s.Signer_Email__c,
                    s.Role_Name__c,
                    siteUrl + path + '?token=' + s.Secure_Token__c,
                    s.Contact__c
                )
            );
            s.Reminder_Sent_At__c = now;
            s.Reminders_Sent__c = (s.Reminders_Sent__c == null ? 0 : s.Reminders_Sent__c) + 1;
            reminded.add(s);
        }
        if (reminded.isEmpty()) {
            return 0;
        }
        DocGenSignatureEmailService.sendSignatureReminderEmails(emails, 'Document awaiting your signature', null);
        DocGenFlsGuard.assertUpdateable(reminded, new Set<String>{ 'Reminder_Sent_At__c', 'Reminders_Sent__c' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(reminded, false, AccessLevel.SYSTEM_MODE);
        DocGenSignatureEvents.logForSigners(null, reminded, DocGenSignatureEvents.REMINDER_SENT, false);
        return reminded.size();
    }

    /** Due when N days have passed since the last reminder, or since the request was sent. */
    @TestVisible
    static Boolean isDue(DocGen_Signer__c s, Datetime now) {
        DocGen_Signature_Request__c req = s.Signature_Request__r;
        if (DocGenSignatureExpiry.isExpired(req.Expires_At__c, req.CreatedDate)) {
            return false;
        }
        Integer every = req.Reminder_Every_Days__c == null ? 0 : req.Reminder_Every_Days__c.intValue();
        if (every <= 0) {
            return false;
        }
        Datetime since = s.Reminder_Sent_At__c != null ? s.Reminder_Sent_At__c : req.CreatedDate;
        // A few minutes' slack, so an hourly job doesn't slip a day on a send made at :05.
        return since.addDays(every).addMinutes(-10) <= now;
    }

    // ------------------------------------------------------------------ after sending

    /**
     * Moves the link's expiry to the end of the given day. Reopens a lapsed link. The timeline says
     * which: extended, brought forward or reopened (a sender extending is a buying signal).
     */
    public static void changeExpiry(Id requestId, Date expiresOn) {
        DocGen_Signature_Request__c current = openRequest(requestId);
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Id = requestId);
        if (expiresOn == null || expiresOn < Date.today()) {
            throw fail('Choose a date from today onwards.');
        }
        if (expiresOn > Date.today().addDays(MAX_DAYS)) {
            throw fail('Choose a date within a year.');
        }
        req.Expires_At__c = endOfDay(expiresOn);
        Datetime before = current.Expires_At__c != null ? current.Expires_At__c : current.CreatedDate.addHours(48); // legacy lifetime, as DocGenSignatureExpiry
        String detail;
        if (DocGenSignatureExpiry.isExpired(current.Expires_At__c, current.CreatedDate)) {
            detail = 'Link reopened until ' + day(expiresOn);
        } else if (req.Expires_At__c > before) {
            detail = 'Link extended to ' + day(expiresOn);
        } else {
            detail = 'Link expiry brought forward to ' + day(expiresOn);
        }
        // Allowed by DocGen_Change_Signature_Requests on a request the user can see (openRequest);
        // sales users have no Edit on the request object, by design.
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(req, AccessLevel.SYSTEM_MODE);
        DocGenSignatureEvents.logChange(requestId, EXPIRY_CHANGED, detail);
    }

    /**
     * Changes the reminders on a sent request: EVERY (every N days, optionally until a date),
     * NONE (stop), or ORG (back to the org schedule).
     */
    public static void changeReminders(Id requestId, String mode, Integer everyDays, Date until) {
        openRequest(requestId);
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Id = requestId);
        String m = String.isBlank(mode) ? '' : mode.toUpperCase();
        String detail;
        if (m == MODE_EVERY) {
            Integer every = clampDays(everyDays);
            if (until != null && until < Date.today()) {
                throw fail('Choose an end date from today onwards.');
            }
            req.Reminder_Every_Days__c = every;
            req.Reminders_Until__c = until != null ? endOfDay(until) : null;
            detail =
                'Reminders every ' +
                (every == 1 ? 'day' : every + ' days') +
                (until != null ? ' until ' + day(until) : ' until the link expires');
        } else if (m == MODE_NONE) {
            req.Reminder_Every_Days__c = 0;
            req.Reminders_Until__c = null;
            detail = 'Reminders stopped';
        } else if (m == MODE_ORG) {
            req.Reminder_Every_Days__c = null;
            req.Reminders_Until__c = null;
            detail = 'Reminders on the standard schedule';
        } else {
            throw fail('Unknown reminder choice.');
        }
        // Allowed by DocGen_Change_Signature_Requests on a request the user can see (openRequest).
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(req, AccessLevel.SYSTEM_MODE);
        DocGenSignatureEvents.logChange(requestId, REMINDERS_CHANGED, detail);
    }

    /** "Reminders every 2 days until 20 Nov", "No reminders" or "Reminders on the standard schedule". */
    public static String describe(Decimal everyDays, Datetime until) {
        if (everyDays == null) {
            return 'Reminders on the standard schedule';
        }
        Integer every = everyDays.intValue();
        if (every <= 0) {
            return 'No reminders';
        }
        return 'Reminders every ' +
            (every == 1 ? 'day' : every + ' days') +
            (until != null ? ' until ' + until.format('d MMM') : ' until the link expires');
    }

    /**
     * The request as the user sees it (sharing applies); refuses a finished one, and a user without
     * the Change Sent Signature Requests permission (DocGen_User and DocGen_Admin have it).
     */
    private static DocGen_Signature_Request__c openRequest(Id requestId) {
        if (!FeatureManagement.checkPermission(CHANGE_PERMISSION)) {
            throw fail('You need the Change Sent Signature Requests permission to change this request.');
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{ 'Status__c', 'Expires_At__c' }
        );
        List<DocGen_Signature_Request__c> rows = [
            SELECT Id, Status__c, Expires_At__c, CreatedDate
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw fail('That signature request could not be found.');
        }
        String status = rows[0].Status__c;
        if (status == 'Signed' || status == 'Declined' || status == 'Cancelled') {
            throw fail('This request is finished, so it can no longer be changed.');
        }
        return rows[0];
    }

    /** An AuraHandledException whose getMessage() is the message too (tests, Flow errors). */
    private static AuraHandledException fail(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    private static Integer clampDays(Integer days) {
        if (days == null || days < 1) {
            return 1;
        }
        return days > MAX_DAYS ? MAX_DAYS : days;
    }

    /** The end of that day in the user's time zone. */
    @TestVisible
    static Datetime endOfDay(Date d) {
        return Datetime.newInstance(d, Time.newInstance(23, 59, 59, 0));
    }

    private static String day(Date d) {
        return Datetime.newInstance(d, Time.newInstance(12, 0, 0, 0)).format('d MMM yyyy');
    }
}
