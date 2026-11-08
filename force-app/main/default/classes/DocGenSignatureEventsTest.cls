// Dura Composites Ltd. (new file)
// Each Portwood code path that now records a timeline event, driven through Portwood's own
// entry points: the reminder job, resend, revoke and a signer opening an expired link.
@IsTest
private class DocGenSignatureEventsTest {
    private static DocGen_Signer__c makeSigner(String status, Datetime expiresAt) {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Expires_At__c = expiresAt,
            Require_Email_Verification__c = false
        );
        insert req;
        DocGen_Signer__c s = new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Sam Fielding',
            Signer_Email__c = 'sam.fielding@example.com',
            Role_Name__c = 'Signer',
            Secure_Token__c = EncodingUtil.convertToHex(Crypto.generateAesKey(256)),
            Status__c = status,
            Sort_Order__c = 1
        );
        insert s;
        return [
            SELECT Id, Signature_Request__c, Secure_Token__c, Signer_Name__c, Signer_Email__c
            FROM DocGen_Signer__c
            WHERE Id = :s.Id
        ];
    }

    private static List<DocGen_Signature_Event__c> events(Id requestId) {
        return [
            SELECT Type__c, Signer__c, Actor__c, Occurred_At__c
            FROM DocGen_Signature_Event__c
            WHERE Signature_Request__c = :requestId
            ORDER BY Occurred_At__c
        ];
    }

    @IsTest
    static void resendRecordsOneEventPerSignerWithWhoDidIt() {
        DocGen_Signer__c s = makeSigner('Viewed', System.now().addDays(5));
        Test.startTest();
        DocGenSignatureSenderController.resendSignatureRequest(s.Signature_Request__c);
        Test.stopTest();

        List<DocGen_Signature_Event__c> e = events(s.Signature_Request__c);
        Assert.areEqual(1, e.size());
        Assert.areEqual(DocGenSignatureEvents.LINK_RESENT, e[0].Type__c);
        Assert.areEqual(s.Id, e[0].Signer__c);
        Assert.areEqual(UserInfo.getUserId(), e[0].Actor__c, 'Who resent it');
    }

    @IsTest
    static void revokeRecordsAnEventWithWhoDidIt() {
        DocGen_Signer__c s = makeSigner('Pending', System.now().addDays(5));
        Test.startTest();
        DocGenSignatureSenderController.cancelSignatureRequest(s.Signature_Request__c);
        Test.stopTest();

        List<DocGen_Signature_Event__c> e = events(s.Signature_Request__c);
        Assert.areEqual(1, e.size());
        Assert.areEqual(DocGenSignatureEvents.REVOKED, e[0].Type__c);
        Assert.isNull(e[0].Signer__c, 'A revoke is about the whole request');
        Assert.areEqual(UserInfo.getUserId(), e[0].Actor__c);
    }

    @IsTest
    static void theReminderJobRecordsEachReminder() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Signature_Reminder_Enabled__c = true;
        settings.Signature_Reminder_Hours__c = 24;
        settings.Signature_Reminder_Schedule__c = '24,72';
        upsert settings;
        DocGen_Signer__c s = makeSigner('Pending', System.now().addDays(5));
        DocGenSignatureReminderSchedulable.testThresholdOverride = System.now().addDays(1);
        Test.startTest();
        new DocGenSignatureReminderSchedulable().execute(null);
        Test.stopTest();

        List<DocGen_Signature_Event__c> e = events(s.Signature_Request__c);
        Assert.areEqual(1, e.size(), 'One reminder, one event');
        Assert.areEqual(DocGenSignatureEvents.REMINDER_SENT, e[0].Type__c);
        Assert.areEqual(s.Id, e[0].Signer__c);
        Assert.isNull(e[0].Actor__c, 'Reminders are automatic');
    }

    @IsTest
    static void openingAnExpiredLinkIsRecordedOncePerHalfHour() {
        DocGen_Signer__c s = makeSigner('Pending', System.now().addDays(-1));
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse first = DocGenSignatureController.validateToken(
            s.Secure_Token__c
        );
        DocGenSignatureController.validateToken(s.Secure_Token__c);
        Test.stopTest();

        Assert.isFalse(first.isValid);
        Assert.isTrue(first.errorMessage.contains('expired'), first.errorMessage);
        List<DocGen_Signature_Event__c> e = events(s.Signature_Request__c);
        Assert.areEqual(1, e.size(), 'Two attempts within half an hour are one event');
        Assert.areEqual(DocGenSignatureEvents.EXPIRED_LINK_OPENED, e[0].Type__c);
    }

    @IsTest
    static void loggingNeverThrows() {
        Test.startTest();
        DocGenSignatureEvents.logForRequest(null, DocGenSignatureEvents.REVOKED, true);
        DocGenSignatureEvents.logExpiredOpen(null, null);
        DocGenSignatureEvents.logForSigners(
            null,
            new List<DocGen_Signer__c>{ new DocGen_Signer__c() },
            'Nonsense',
            false
        );
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM DocGen_Signature_Event__c]);
    }
}
