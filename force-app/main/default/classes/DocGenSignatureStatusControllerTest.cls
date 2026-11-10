// Dura Composites Ltd. (new file)
@IsTest
private class DocGenSignatureStatusControllerTest {
    private static final String IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148';

    @TestSetup
    static void setup() {
        Account acct = new Account(Name = 'Status Card Test');
        insert acct;
        Contact buyer = new Contact(LastName = 'Buyer', AccountId = acct.Id);
        insert buyer;
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Status Card Template',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        DocGen_Signature_Request__c signed = new DocGen_Signature_Request__c(
            Status__c = 'Signed',
            Template__c = tmpl.Id,
            Related_Record_Id__c = acct.Id,
            Signing_Order__c = 'Sequential'
        );
        DocGen_Signature_Request__c open = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Template__c = tmpl.Id,
            Related_Record_Id__c = String.valueOf(acct.Id).left(15), // stored as a 15-character Id
            Expires_At__c = System.now().addDays(14)
        );
        DocGen_Signature_Request__c draft = new DocGen_Signature_Request__c(
            Status__c = 'Draft',
            Related_Record_Id__c = acct.Id
        );
        // On a related record (a Contact of the account), for the grouped view.
        DocGen_Signature_Request__c onContact = new DocGen_Signature_Request__c(
            Status__c = 'Declined',
            Template__c = tmpl.Id,
            Related_Record_Id__c = buyer.Id
        );
        insert new List<DocGen_Signature_Request__c>{ signed, open, draft, onContact };
        // Sent before the visits and audits below, as in real life.
        Test.setCreatedDate(signed.Id, Datetime.newInstance(2026, 11, 1, 8, 0, 0));
        Test.setCreatedDate(open.Id, Datetime.newInstance(2026, 11, 3, 8, 0, 0));
        Test.setCreatedDate(onContact.Id, Datetime.newInstance(2026, 11, 4, 8, 0, 0));

        List<DocGen_Signer__c> signers = new List<DocGen_Signer__c>{
            signer(signed.Id, 'Supplier Person', 1, 'Signed'),
            signer(signed.Id, 'Client Person', 2, 'Signed'),
            signer(open.Id, 'Hesitant Buyer', 1, 'Viewed'),
            signer(onContact.Id, 'Declining Buyer', 1, 'Declined')
        };
        signers[1].Reminder_Sent_At__c = Datetime.newInstance(2026, 11, 1, 9, 0, 0);
        signers[1].Reminders_Sent__c = 2;
        signers[3].Decline_Reason__c = 'Wrong quantities';
        insert signers;

        insert new List<DocGen_Signature_Audit__c>{
            new DocGen_Signature_Audit__c(
                Signature_Request__c = signed.Id,
                Signer__c = signers[0].Id,
                Signer_Name__c = 'Supplier Person',
                Signed_Date__c = Datetime.newInstance(2026, 11, 2, 10, 0, 0)
            ),
            new DocGen_Signature_Audit__c(
                Signature_Request__c = onContact.Id,
                Signer__c = signers[3].Id,
                Signer_Name__c = 'Declining Buyer',
                Signed_Date__c = Datetime.newInstance(2026, 11, 4, 15, 0, 0)
            )
        };

        Datetime t0 = Datetime.newInstance(2026, 11, 3, 9, 0, 0);
        DocGenSignerVisits.recordVisit(signers[2].Id, IPHONE, t0);
        DocGenSignerVisits.recordVisit(signers[2].Id, IPHONE, t0.addDays(1));
        DocGenSignerVisits.recordVisit(signers[2].Id, IPHONE, t0.addDays(2));
        DocGenSignerVisits.recordVisit(signers[2].Id, 'python-requests/2.32', t0.addDays(2).addMinutes(1));
        DocGenSignatureEvents.logForSigners(
            open.Id,
            new List<DocGen_Signer__c>{ signers[2] },
            DocGenSignatureEvents.REMINDER_SENT,
            false
        );
    }

    private static DocGen_Signer__c signer(Id requestId, String name, Integer order, String status) {
        return new DocGen_Signer__c(
            Signature_Request__c = requestId,
            Signer_Name__c = name,
            Signer_Email__c = name.replace(' ', '.').toLowerCase() + '@example.com',
            Role_Name__c = 'Signer',
            Secure_Token__c = EncodingUtil.convertToHex(Crypto.generateAesKey(256)),
            Status__c = status,
            Sort_Order__c = order
        );
    }

    /** A user with only the DocGen User permission set, so the card's permissions are tested too. */
    private static User docGenUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User u = new User(
            ProfileId = p.Id,
            Username = 'status.card.' + unique + '@example.com.test',
            Email = 'status.card@example.com',
            LastName = 'Card',
            Alias = 'scard',
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_GB',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        // In its own context, so a test can create the user after inserting records (no MIXED_DML_OPERATION).
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            insert new PermissionSetAssignment(
                AssigneeId = u.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1]
                .Id
            );
        }
        return u;
    }

    private static List<String> texts(DocGenSignatureStatusController.RequestStatus r) {
        List<String> out = new List<String>();
        for (DocGenSignatureStatusController.TimelineItem t : r.timeline) {
            out.add(t.kind + ': ' + t.text);
        }
        return out;
    }

    @IsTest
    static void buildsATimelinePerRequest() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Status Card Test'];
        User u = docGenUser();
        List<DocGenSignatureStatusController.RecordGroup> groups;
        System.runAs(u) {
            Test.startTest();
            groups = DocGenSignatureStatusController.getTimeline(acct.Id, null);
            Test.stopTest();
        }

        Assert.areEqual(1, groups.size(), 'Just this record');
        List<DocGenSignatureStatusController.RequestStatus> reqs = groups[0].requests;
        Assert.areEqual(2, reqs.size(), 'Both requests, matched on 18 and 15 characters; the draft is left out');

        DocGenSignatureStatusController.RequestStatus open = reqs[0];
        Assert.areEqual('Sent', open.status, 'Newest first');
        Assert.areEqual('Opened 3×', open.statusLabel, 'Three visits; the scanner is left out');
        Assert.areEqual('accent', open.statusTone);
        Assert.isTrue(open.isOpen);
        List<String> t = texts(open);
        Assert.areEqual('sent: Sent to Hesitant Buyer', t[0], String.join(t, ' | '));
        Assert.areEqual('opened: Hesitant Buyer opened · phone', t[1]);
        Assert.isTrue(t.contains('reminder: Reminder sent to Hesitant Buyer'), String.join(t, ' | '));
        Assert.isTrue(t[t.size() - 1].startsWith('waiting: Waiting on Hesitant Buyer'), 'Ends with who it waits on');
        Assert.isNull(open.timeline[open.timeline.size() - 1].at, 'The waiting line has no time');

        DocGenSignatureStatusController.RequestStatus signed = reqs[1];
        Assert.areEqual('Signed', signed.statusLabel);
        Assert.areEqual('success', signed.statusTone);
        List<String> st = texts(signed);
        Assert.isTrue(st.contains('signed: Supplier Person signed'), String.join(st, ' | '));
        Assert.isTrue(
            st.contains('reminder: Reminder sent to Client Person (latest of 2)'),
            'A reminder from before the event log: ' + String.join(st, ' | ')
        );
        Assert.isFalse(signed.isOpen);
    }

    @IsTest
    static void groupsRequestsOnRelatedRecords() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Status Card Test'];
        // As a DocGen user: in a clean org (the package build org) the running user has no access to
        // DocGen's fields, and a USER_MODE query reports a field it can't see as "No such column".
        User u = docGenUser();
        List<DocGenSignatureStatusController.RecordGroup> groups;
        System.runAs(u) {
            Test.startTest();
            groups = DocGenSignatureStatusController.getTimeline(
                acct.Id,
                'Contact.AccountId, NotAnObject__c.Foo__c, Contact.Name'
            );
            Test.stopTest();
        }

        Assert.areEqual(2, groups.size(), 'This record, then the contact; bad specs are ignored');
        Assert.isTrue(groups[0].isThisRecord);
        DocGenSignatureStatusController.RecordGroup contactGroup = groups[1];
        Assert.isFalse(contactGroup.isThisRecord);
        Assert.areEqual('Buyer', contactGroup.recordName);
        DocGenSignatureStatusController.RequestStatus declined = contactGroup.requests[0];
        Assert.areEqual('Declined', declined.statusLabel);
        Assert.areEqual('danger', declined.statusTone);
        Assert.isTrue(
            texts(declined).contains('declined: Declining Buyer declined: "Wrong quantities"'),
            String.join(texts(declined), ' | ')
        );
    }

    @IsTest
    static void revokedAndExpiredRequestsSaySo() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Status Card Test'];
        DocGen_Signature_Request__c expired = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Related_Record_Id__c = acct.Id,
            Expires_At__c = System.now().addDays(-1)
        );
        DocGen_Signature_Request__c revoked = new DocGen_Signature_Request__c(
            Status__c = 'Cancelled',
            Related_Record_Id__c = acct.Id
        );
        insert new List<DocGen_Signature_Request__c>{ expired, revoked };
        DocGen_Signer__c lapsed = signer(expired.Id, 'Late Person', 1, 'Pending');
        insert lapsed;
        DocGenSignatureEvents.logExpiredOpen(expired.Id, lapsed.Id);
        DocGenSignatureEvents.logForRequest(revoked.Id, DocGenSignatureEvents.REVOKED, true);

        User u = docGenUser();
        List<DocGenSignatureStatusController.RecordGroup> groups;
        System.runAs(u) {
            Test.startTest();
            groups = DocGenSignatureStatusController.getTimeline(acct.Id, null);
            Test.stopTest();
        }

        Map<Id, DocGenSignatureStatusController.RequestStatus> byId = new Map<Id, DocGenSignatureStatusController.RequestStatus>();
        for (DocGenSignatureStatusController.RequestStatus r : groups[0].requests) {
            byId.put(r.id, r);
        }
        DocGenSignatureStatusController.RequestStatus e = byId.get(expired.Id);
        Assert.areEqual('Expired', e.statusLabel);
        Assert.isFalse(e.isOpen);
        List<String> et = texts(e);
        Assert.isTrue(et.contains('expired: Link expired'), String.join(et, ' | '));
        Assert.isTrue(et.contains('expired-open: Late Person tried to open the expired link'), String.join(et, ' | '));
        Assert.isTrue(e.summary.contains('never opened'), e.summary);

        DocGenSignatureStatusController.RequestStatus rv = byId.get(revoked.Id);
        Assert.areEqual('Revoked', rv.statusLabel);
        List<String> rt = texts(rv);
        Assert.isTrue(rt[rt.size() - 1].startsWith('revoked: Revoked by '), String.join(rt, ' | '));
    }

    @IsTest
    static void extendingAndChangingRemindersShowOnTheCard() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Status Card Test'];
        DocGen_Signature_Request__c open = [
            SELECT Id
            FROM DocGen_Signature_Request__c
            WHERE Status__c = 'Sent' AND Template__c != NULL
            LIMIT 1
        ];
        DocGen_Signature_Request__c signed = [SELECT Id FROM DocGen_Signature_Request__c WHERE Status__c = 'Signed'];
        User u = docGenUser();
        List<DocGenSignatureStatusController.RecordGroup> groups;
        System.runAs(u) {
            Test.startTest();
            DocGenSignatureStatusController.changeExpiry(open.Id, Date.today().addDays(60));
            DocGenSignatureStatusController.changeReminders(open.Id, 'EVERY', 2, null);
            try {
                DocGenSignatureStatusController.changeExpiry(signed.Id, Date.today().addDays(3));
                Assert.fail('A signed request cannot be changed');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('finished'), e.getMessage());
            }
            try {
                DocGenSignatureStatusController.changeReminders(signed.Id, 'NONE', null, null);
                Assert.fail('A signed request cannot be changed');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('finished'), e.getMessage());
            }
            groups = DocGenSignatureStatusController.getTimeline(acct.Id, null);
            Test.stopTest();
        }

        DocGenSignatureStatusController.RequestStatus r;
        for (DocGenSignatureStatusController.RequestStatus each : groups[0].requests) {
            if (each.id == open.Id) {
                r = each;
            }
        }
        Assert.isTrue(r.canChange);
        Assert.areEqual(Date.today().addDays(60), r.expiresOn);
        Assert.areEqual(2, r.reminderEvery);
        Assert.isTrue(r.plan.startsWith('Link expires '), r.plan);
        Assert.isTrue(r.plan.contains('Reminders every 2 days until the link expires'), r.plan);
        Assert.isTrue(r.plan.contains('reminders are off in Signature Settings'), 'The job is off in tests: ' + r.plan);
        List<String> t = texts(r);
        Assert.isTrue(
            String.join(t, ' | ').contains('expiry-changed: Link extended to '),
            'Extending is a signal for sales: ' + String.join(t, ' | ')
        );
        Assert.isTrue(
            t.contains('reminders-changed: Reminders every 2 days until the link expires by Card'),
            String.join(t, ' | ')
        );
        for (DocGenSignatureStatusController.RequestStatus each : groups[0].requests) {
            if (each.id == signed.Id) {
                Assert.isFalse(each.canChange);
                Assert.isNull(each.plan, 'No plan line once finished');
            }
        }
    }

    @IsTest
    static void smallHelpers() {
        Assert.areEqual(0, DocGenSignatureStatusController.getTimeline(null, null).size());
        Assert.areEqual('', DocGenSignatureStatusController.fmt(null));
        Assert.isTrue(DocGenSignatureStatusController.ago(System.now().addMinutes(-30)).endsWith(' min'));
        Assert.isTrue(DocGenSignatureStatusController.ago(System.now().addHours(-5)).endsWith(' hours'));
        Assert.isTrue(DocGenSignatureStatusController.ago(System.now().addHours(-73)).endsWith(' days'));
    }
}
