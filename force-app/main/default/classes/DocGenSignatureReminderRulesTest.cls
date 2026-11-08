// Dura Composites Ltd. (new file)
// Per-request link expiry and reminder schedules (DocGenSignatureReminderRules): the defaults at
// send time, the reminder job's pass, and changing a request after it was sent.
@IsTest
private class DocGenSignatureReminderRulesTest {
    @TestSetup
    static void setup() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User seller = new User(
            Alias = 'remsell',
            Email = 'reminder-seller@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Reminder Seller QA',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_GB',
            TimeZoneSidKey = 'Europe/London',
            ProfileId = standard.Id,
            Username = 'remseller' + UserInfo.getOrganizationId() + System.now().getTime() + '@example.invalid'
        );
        User outsider = seller.clone(false, false, false, false);
        outsider.Alias = 'remout';
        outsider.LastName = 'Reminder Outsider QA';
        outsider.Username = 'remoutsider' + UserInfo.getOrganizationId() + System.now().getTime() + '@example.invalid';
        insert new List<User>{ seller, outsider };
        Id userPs = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1].Id;
        insert new PermissionSetAssignment(AssigneeId = seller.Id, PermissionSetId = userPs);
    }

    private static User seller() {
        return [SELECT Id FROM User WHERE Alias = 'remsell' LIMIT 1];
    }

    private static User outsider() {
        return [SELECT Id FROM User WHERE Alias = 'remout' LIMIT 1];
    }

    private static void remindersOn() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Signature_Reminder_Enabled__c = true;
        settings.Signature_Reminder_Hours__c = 24;
        settings.Signature_Reminder_Schedule__c = '24,72';
        settings.Signature_Expiration_Days__c = 5;
        upsert settings;
    }

    private static DocGen_Template__c template(Decimal expiryDays, Decimal every, Decimal forDays) {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'Reminder Rules Template',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Signature_Expiry_Days__c = expiryDays,
            Signature_Reminder_Every_Days__c = every,
            Signature_Reminder_For_Days__c = forDays
        );
        insert t;
        return t;
    }

    private static DocGenSignatureSenderController.GuidedPdfSendOptions options(Id templateId) {
        DocGenSignatureSenderController.GuidedPdfSendOptions o = new DocGenSignatureSenderController.GuidedPdfSendOptions();
        o.templateId = templateId;
        return o;
    }

    /** An open request with one or more pending signers, sent daysAgo days ago. */
    private static DocGen_Signature_Request__c request(Decimal every, Integer daysAgo, Integer signerCount) {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Expires_At__c = System.now().addDays(10),
            Reminder_Every_Days__c = every,
            Require_Email_Verification__c = false,
            Signing_Order__c = 'Parallel'
        );
        insert req;
        Test.setCreatedDate(req.Id, System.now().addDays(-daysAgo));
        List<DocGen_Signer__c> signers = new List<DocGen_Signer__c>();
        for (Integer i = 1; i <= signerCount; i++) {
            signers.add(
                new DocGen_Signer__c(
                    Signature_Request__c = req.Id,
                    Signer_Name__c = 'Signer ' + i,
                    Signer_Email__c = 'signer' + i + '@example.com',
                    Role_Name__c = 'Signer',
                    Secure_Token__c = EncodingUtil.convertToHex(Crypto.generateAesKey(256)),
                    Status__c = 'Pending',
                    Sort_Order__c = i
                )
            );
        }
        insert signers;
        return req;
    }

    private static List<DocGen_Signer__c> signers(Id requestId) {
        return [
            SELECT Id, Reminders_Sent__c, Reminder_Sent_At__c, Sort_Order__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId
            ORDER BY Sort_Order__c
        ];
    }

    private static List<DocGen_Signature_Event__c> events(Id requestId) {
        return [
            SELECT Type__c, Detail__c, Actor__c, Signer__c
            FROM DocGen_Signature_Event__c
            WHERE Signature_Request__c = :requestId
            ORDER BY Occurred_At__c, Id
        ];
    }

    // ------------------------------------------------------------------ at send time

    @IsTest
    static void aDateChosenAtSendWinsAndEndsThatDay() {
        DocGen_Template__c t = template(3, 2, 14);
        DocGenSignatureSenderController.GuidedPdfSendOptions o = options(t.Id);
        o.expiresOn = Date.today().addDays(9);
        o.expirationDays = 4;
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        Set<String> touched = DocGenSignatureReminderRules.applyAtSend(req, o);
        Assert.areEqual(DocGenSignatureReminderRules.endOfDay(Date.today().addDays(9)), req.Expires_At__c);
        Assert.isTrue(touched.contains('Expires_At__c'));
        Assert.isTrue(touched.contains('Reminders_Until__c'));
    }

    @IsTest
    static void expiryFallsBackFromDaysToTemplateToOrg() {
        remindersOn(); // org default: 5 days
        DocGen_Template__c t = template(3, null, null);

        DocGenSignatureSenderController.GuidedPdfSendOptions withDays = options(t.Id);
        withDays.expirationDays = 7;
        DocGen_Signature_Request__c a = new DocGen_Signature_Request__c();
        DocGenSignatureReminderRules.applyAtSend(a, withDays);
        Assert.isTrue(
            Math.abs(a.Expires_At__c.getTime() - System.now().addDays(7).getTime()) < 60000,
            'Send-time days'
        );

        DocGen_Signature_Request__c b = new DocGen_Signature_Request__c();
        DocGenSignatureReminderRules.applyAtSend(b, options(t.Id));
        Assert.isTrue(Math.abs(b.Expires_At__c.getTime() - System.now().addDays(3).getTime()) < 60000, 'Template days');

        DocGen_Signature_Request__c c = new DocGen_Signature_Request__c();
        DocGenSignatureReminderRules.applyAtSend(c, options(null));
        Assert.isTrue(Math.abs(c.Expires_At__c.getTime() - System.now().addDays(5).getTime()) < 60000, 'Org default');
    }

    @IsTest
    static void theTemplateRuleAppliesUnlessTheSenderChanges() {
        DocGen_Template__c t = template(null, 2, 14);

        DocGen_Signature_Request__c byTemplate = new DocGen_Signature_Request__c();
        DocGenSignatureReminderRules.applyAtSend(byTemplate, options(t.Id));
        Assert.areEqual(2, byTemplate.Reminder_Every_Days__c);
        Assert.isTrue(
            Math.abs(byTemplate.Reminders_Until__c.getTime() - System.now().addDays(14).getTime()) < 60000,
            'Keep reminding for the template days'
        );

        DocGenSignatureSenderController.GuidedPdfSendOptions every = options(t.Id);
        every.reminderMode = 'every';
        every.reminderEveryDays = 3;
        every.remindersUntil = Date.today().addDays(6);
        DocGen_Signature_Request__c bySender = new DocGen_Signature_Request__c();
        DocGenSignatureReminderRules.applyAtSend(bySender, every);
        Assert.areEqual(3, bySender.Reminder_Every_Days__c);
        Assert.areEqual(DocGenSignatureReminderRules.endOfDay(Date.today().addDays(6)), bySender.Reminders_Until__c);

        DocGenSignatureSenderController.GuidedPdfSendOptions none = options(t.Id);
        none.reminderMode = DocGenSignatureReminderRules.MODE_NONE;
        DocGen_Signature_Request__c noReminders = new DocGen_Signature_Request__c();
        DocGenSignatureReminderRules.applyAtSend(noReminders, none);
        Assert.areEqual(0, noReminders.Reminder_Every_Days__c);
        Assert.isNull(noReminders.Reminders_Until__c);

        DocGenSignatureSenderController.GuidedPdfSendOptions org = options(t.Id);
        org.reminderMode = DocGenSignatureReminderRules.MODE_ORG;
        DocGen_Signature_Request__c orgSchedule = new DocGen_Signature_Request__c();
        DocGenSignatureReminderRules.applyAtSend(orgSchedule, org);
        Assert.isNull(orgSchedule.Reminder_Every_Days__c, 'Blank = the org schedule');
    }

    @IsTest
    static void aTemplateWithoutARuleLeavesTheOrgSchedule() {
        DocGen_Template__c t = template(null, null, 10);
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        DocGenSignatureReminderRules.applyAtSend(req, options(t.Id));
        Assert.isNull(req.Reminder_Every_Days__c);
        Assert.isNull(req.Reminders_Until__c);
    }

    @IsTest
    static void sendDatesMustBeFromTodayAndWithinAYear() {
        DocGenSignatureSenderController.GuidedPdfSendOptions past = options(null);
        past.expiresOn = Date.today().addDays(-1);
        try {
            DocGenSignatureReminderRules.applyAtSend(new DocGen_Signature_Request__c(), past);
            Assert.fail('A past expiry date should be refused');
        } catch (DocGenException e) {
            Assert.isTrue(e.getMessage().contains('in the past'), e.getMessage());
        }
        DocGenSignatureSenderController.GuidedPdfSendOptions far = options(null);
        far.reminderMode = DocGenSignatureReminderRules.MODE_EVERY;
        far.reminderEveryDays = 2;
        far.remindersUntil = Date.today().addDays(400);
        try {
            DocGenSignatureReminderRules.applyAtSend(new DocGen_Signature_Request__c(), far);
            Assert.fail('A reminder end date beyond a year should be refused');
        } catch (DocGenException e) {
            Assert.isTrue(e.getMessage().contains('within a year'), e.getMessage());
        }
    }

    @IsTest
    static void theSenderGetsTheOrgDefaults() {
        remindersOn();
        Map<String, Object> d = DocGenSignatureReminderRules.getSendDefaults();
        Assert.areEqual(5, d.get('expiryDays'));
        Assert.areEqual(true, d.get('remindersOn'));
        Assert.areEqual(365, d.get('maxDays'));
    }

    @IsTest
    static void aResendUsesTheTemplateLengthAndNeverShortens() {
        remindersOn(); // org default: 5 days
        Datetime byTemplate = DocGenSignatureReminderRules.resendExpiry(System.now().addDays(1), 14);
        Assert.isTrue(Math.abs(byTemplate.getTime() - System.now().addDays(14).getTime()) < 60000, 'Template length');
        Datetime byOrg = DocGenSignatureReminderRules.resendExpiry(null, null);
        Assert.isTrue(Math.abs(byOrg.getTime() - System.now().addDays(5).getTime()) < 60000, 'Org default');
        Datetime extended = System.now().addDays(40);
        Assert.areEqual(extended, DocGenSignatureReminderRules.resendExpiry(extended, 14), 'Keeps a later expiry');
    }

    // ------------------------------------------------------------------ the reminder job

    @IsTest
    static void remindsWhenTheIntervalHasPassed() {
        remindersOn();
        DocGen_Signature_Request__c due = request(2, 3, 1);
        DocGen_Signature_Request__c notYet = request(2, 1, 1);
        Test.startTest();
        Integer sent = DocGenSignatureReminderRules.sendDueReminders();
        Test.stopTest();

        Assert.areEqual(1, sent);
        Assert.areEqual(1, signers(due.Id)[0].Reminders_Sent__c);
        Assert.isNotNull(signers(due.Id)[0].Reminder_Sent_At__c);
        Assert.isNull(signers(notYet.Id)[0].Reminder_Sent_At__c);
        List<DocGen_Signature_Event__c> e = events(due.Id);
        Assert.areEqual(1, e.size());
        Assert.areEqual(DocGenSignatureEvents.REMINDER_SENT, e[0].Type__c);
    }

    @IsTest
    static void countsFromTheLastReminder() {
        remindersOn();
        DocGen_Signature_Request__c recent = request(3, 10, 1);
        DocGen_Signer__c s = signers(recent.Id)[0];
        s.Reminder_Sent_At__c = System.now().addDays(-1);
        s.Reminders_Sent__c = 2;
        update s;
        DocGen_Signature_Request__c older = request(3, 10, 1);
        DocGen_Signer__c o = signers(older.Id)[0];
        o.Reminder_Sent_At__c = System.now().addDays(-3);
        o.Reminders_Sent__c = 2;
        update o;

        Test.startTest();
        DocGenSignatureReminderRules.sendDueReminders();
        Test.stopTest();

        Assert.areEqual(2, signers(recent.Id)[0].Reminders_Sent__c, 'Reminded a day ago: not due');
        Assert.areEqual(3, signers(older.Id)[0].Reminders_Sent__c, 'Reminded 3 days ago: due');
    }

    @IsTest
    static void stopsAfterTheEndDateOrExpiryOrWhenSetToNone() {
        remindersOn();
        DocGen_Signature_Request__c ended = request(1, 5, 1);
        ended.Reminders_Until__c = System.now().addHours(-1);
        DocGen_Signature_Request__c expired = request(1, 5, 1);
        expired.Expires_At__c = System.now().addHours(-1);
        update new List<DocGen_Signature_Request__c>{ ended, expired };
        DocGen_Signature_Request__c none = request(0, 5, 1);

        Test.startTest();
        Integer sent = DocGenSignatureReminderRules.sendDueReminders();
        Test.stopTest();

        Assert.areEqual(0, sent);
        Assert.isNull(signers(ended.Id)[0].Reminder_Sent_At__c);
        Assert.isNull(signers(expired.Id)[0].Reminder_Sent_At__c);
        Assert.isNull(signers(none.Id)[0].Reminder_Sent_At__c);
    }

    @IsTest
    static void sequentialRequestsRemindOnlyWhoseTurnItIs() {
        remindersOn();
        DocGen_Signature_Request__c req = request(1, 2, 2);
        req.Signing_Order__c = 'Sequential';
        update req;

        Test.startTest();
        DocGenSignatureReminderRules.sendDueReminders();
        Test.stopTest();

        List<DocGen_Signer__c> s = signers(req.Id);
        Assert.areEqual(1, s[0].Reminders_Sent__c, 'First in line');
        Assert.isNull(s[1].Reminder_Sent_At__c, 'Not their turn yet');
    }

    @IsTest
    static void theOrgScheduleLeavesRequestsWithTheirOwnRule() {
        remindersOn();
        DocGen_Signature_Request__c own = request(0, 5, 1); // no reminders, by choice
        DocGen_Signature_Request__c org = request(null, 5, 1);
        DocGenSignatureReminderSchedulable.testThresholdOverride = System.now().addDays(1);

        Test.startTest();
        new DocGenSignatureReminderSchedulable().execute(null);
        Test.stopTest();

        Assert.isNull(signers(own.Id)[0].Reminder_Sent_At__c, 'Own rule (none) wins over the org schedule');
        Assert.isNotNull(signers(org.Id)[0].Reminder_Sent_At__c, 'The org schedule still runs');
    }

    @IsTest
    static void theJobRunsTheOwnRulePassToo() {
        remindersOn();
        DocGen_Signature_Request__c own = request(2, 3, 1);
        Test.startTest();
        new DocGenSignatureReminderSchedulable().execute(null);
        Test.stopTest();
        Assert.areEqual(1, signers(own.Id)[0].Reminders_Sent__c, 'Reminded once, by its own rule');
        Assert.areEqual(1, events(own.Id).size());
    }

    // ------------------------------------------------------------------ after sending

    @IsTest
    static void extendingTheLinkIsRecordedWithWhoDidIt() {
        User u = seller();
        DocGen_Signature_Request__c req;
        System.runAs(u) {
            req = request(null, 1, 1);
            Test.startTest();
            DocGenSignatureReminderRules.changeExpiry(req.Id, Date.today().addDays(20));
            Test.stopTest();
        }
        DocGen_Signature_Request__c after = [SELECT Expires_At__c FROM DocGen_Signature_Request__c WHERE Id = :req.Id];
        Assert.areEqual(DocGenSignatureReminderRules.endOfDay(Date.today().addDays(20)), after.Expires_At__c);
        List<DocGen_Signature_Event__c> e = events(req.Id);
        Assert.areEqual(1, e.size());
        Assert.areEqual(DocGenSignatureReminderRules.EXPIRY_CHANGED, e[0].Type__c);
        Assert.isTrue(e[0].Detail__c.startsWith('Link extended to '), e[0].Detail__c);
        Assert.areEqual(u.Id, e[0].Actor__c);
    }

    @IsTest
    static void aLapsedLinkIsReopenedAndAnEarlierDateBroughtForward() {
        System.runAs(seller()) {
            DocGen_Signature_Request__c lapsed = request(null, 9, 1);
            lapsed.Expires_At__c = System.now().addDays(-1);
            DocGen_Signature_Request__c later = request(null, 1, 1);
            later.Expires_At__c = System.now().addDays(30);
            update new List<DocGen_Signature_Request__c>{ lapsed, later };

            Test.startTest();
            DocGenSignatureReminderRules.changeExpiry(lapsed.Id, Date.today().addDays(3));
            DocGenSignatureReminderRules.changeExpiry(later.Id, Date.today().addDays(3));
            Test.stopTest();

            Assert.isTrue(events(lapsed.Id)[0].Detail__c.startsWith('Link reopened until '));
            Assert.isTrue(events(later.Id)[0].Detail__c.startsWith('Link expiry brought forward to '));
        }
    }

    @IsTest
    static void changingTheRemindersIsRecorded() {
        System.runAs(seller()) {
            DocGen_Signature_Request__c req = request(null, 1, 1);
            Test.startTest();
            DocGenSignatureReminderRules.changeReminders(req.Id, 'EVERY', 2, Date.today().addDays(7));
            DocGen_Signature_Request__c every = [
                SELECT Reminder_Every_Days__c, Reminders_Until__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :req.Id
            ];
            Assert.areEqual(2, every.Reminder_Every_Days__c);
            Assert.areEqual(DocGenSignatureReminderRules.endOfDay(Date.today().addDays(7)), every.Reminders_Until__c);

            DocGenSignatureReminderRules.changeReminders(req.Id, 'NONE', null, null);
            Assert.areEqual(
                0,
                [SELECT Reminder_Every_Days__c FROM DocGen_Signature_Request__c WHERE Id = :req.Id]
                .Reminder_Every_Days__c
            );
            DocGenSignatureReminderRules.changeReminders(req.Id, 'ORG', null, null);
            Assert.isNull(
                [SELECT Reminder_Every_Days__c FROM DocGen_Signature_Request__c WHERE Id = :req.Id]
                .Reminder_Every_Days__c
            );
            Test.stopTest();

            List<DocGen_Signature_Event__c> e = events(req.Id);
            Assert.areEqual(3, e.size());
            Assert.isTrue(e[0].Detail__c.startsWith('Reminders every 2 days until '), e[0].Detail__c);
            Assert.areEqual('Reminders stopped', e[1].Detail__c);
            Assert.areEqual('Reminders on the standard schedule', e[2].Detail__c);
        }
    }

    @IsTest
    static void changesAreRefusedWhenFinishedPastOrNotPermitted() {
        DocGen_Signature_Request__c signed;
        DocGen_Signature_Request__c open;
        System.runAs(seller()) {
            signed = request(null, 1, 1);
            signed.Status__c = 'Signed';
            update signed;
            open = request(null, 1, 1);
            expectRefusal(signed.Id, Date.today().addDays(3), 'finished');
            expectRefusal(open.Id, Date.today().addDays(-1), 'from today');
            expectRefusal(open.Id, Date.today().addDays(400), 'within a year');
            try {
                DocGenSignatureReminderRules.changeReminders(open.Id, 'SOMETIMES', 1, null);
                Assert.fail('An unknown choice should be refused');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Unknown'), e.getMessage());
            }
        }
        System.runAs(outsider()) {
            expectRefusal(open.Id, Date.today().addDays(3), 'permission');
        }
        Assert.areEqual(0, events(open.Id).size());
    }

    private static void expectRefusal(Id requestId, Date d, String fragment) {
        try {
            DocGenSignatureReminderRules.changeExpiry(requestId, d);
            Assert.fail('Expected a refusal containing "' + fragment + '"');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains(fragment), e.getMessage());
        }
    }

    @IsTest
    static void describeReadsLikeTheCard() {
        Assert.areEqual('Reminders on the standard schedule', DocGenSignatureReminderRules.describe(null, null));
        Assert.areEqual('No reminders', DocGenSignatureReminderRules.describe(0, null));
        Assert.areEqual('Reminders every day until the link expires', DocGenSignatureReminderRules.describe(1, null));
        Datetime until = Datetime.newInstance(2026, 11, 20, 12, 0, 0);
        Assert.areEqual('Reminders every 2 days until 20 Nov', DocGenSignatureReminderRules.describe(2, until));
    }

    // ------------------------------------------------------------------ Flow and template editor

    @IsTest
    static void flowInputsBecomeSendOptions() {
        DocGenSignatureFlowAction.Request blank = new DocGenSignatureFlowAction.Request();
        blank.reminderForDays = 10;
        DocGenSignatureSenderController.GuidedPdfSendOptions a = new DocGenSignatureSenderController.GuidedPdfSendOptions();
        DocGenSignatureFlowAction.applyReminderInputs(blank, a);
        Assert.areEqual(DocGenSignatureReminderRules.MODE_TEMPLATE, a.reminderMode);
        Assert.areEqual(Date.today().addDays(10), a.remindersUntil);

        DocGenSignatureFlowAction.Request none = new DocGenSignatureFlowAction.Request();
        none.reminderEveryDays = 0;
        DocGenSignatureSenderController.GuidedPdfSendOptions b = new DocGenSignatureSenderController.GuidedPdfSendOptions();
        DocGenSignatureFlowAction.applyReminderInputs(none, b);
        Assert.areEqual(DocGenSignatureReminderRules.MODE_NONE, b.reminderMode);

        DocGenSignatureFlowAction.Request every = new DocGenSignatureFlowAction.Request();
        every.reminderEveryDays = 3;
        DocGenSignatureSenderController.GuidedPdfSendOptions c = new DocGenSignatureSenderController.GuidedPdfSendOptions();
        DocGenSignatureFlowAction.applyReminderInputs(every, c);
        Assert.areEqual(DocGenSignatureReminderRules.MODE_EVERY, c.reminderMode);
        Assert.areEqual(3, c.reminderEveryDays);
        Assert.isNull(c.remindersUntil);
    }

    @IsTest
    static void templateDaysAreWholeNumbersInRangeOrBlank() {
        Assert.areEqual(14, DocGenController.templateDays('14', 1));
        Assert.areEqual(0, DocGenController.templateDays(0, 0));
        Assert.areEqual(7, DocGenController.templateDays(7.0, 1));
        Assert.isNull(DocGenController.templateDays(null, 1));
        Assert.isNull(DocGenController.templateDays('', 1));
        Assert.isNull(DocGenController.templateDays('abc', 1));
        Assert.isNull(DocGenController.templateDays(0, 1), 'Below the minimum');
        Assert.isNull(DocGenController.templateDays(366, 1), 'Over a year');
        Assert.isNull(DocGenController.templateDays(2.5, 1), 'Days only');
    }
}
