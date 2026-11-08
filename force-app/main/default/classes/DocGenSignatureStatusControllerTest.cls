// Dura Composites Ltd. (new file)
@IsTest
private class DocGenSignatureStatusControllerTest {
    private static final String IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148';

    @TestSetup
    static void setup() {
        Account acct = new Account(Name = 'Status Card Test');
        insert acct;
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Status Card Template',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        DocGen_Signature_Request__c older = new DocGen_Signature_Request__c(
            Status__c = 'Signed',
            Template__c = tmpl.Id,
            Related_Record_Id__c = acct.Id,
            Signing_Order__c = 'Sequential'
        );
        DocGen_Signature_Request__c newer = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Template__c = tmpl.Id,
            Related_Record_Id__c = String.valueOf(acct.Id).left(15), // stored as a 15-character Id
            Signing_Order__c = 'Parallel',
            Expires_At__c = System.now().addDays(14)
        );
        DocGen_Signature_Request__c draft = new DocGen_Signature_Request__c(
            Status__c = 'Draft',
            Related_Record_Id__c = acct.Id
        );
        insert new List<DocGen_Signature_Request__c>{ older, newer, draft };

        List<DocGen_Signer__c> signers = new List<DocGen_Signer__c>{
            signer(older.Id, 'Supplier Person', 1, 'Signed'),
            signer(older.Id, 'Client Person', 2, 'Signed'),
            signer(newer.Id, 'Hesitant Buyer', 1, 'Viewed'),
            signer(newer.Id, 'Declining Buyer', 2, 'Declined')
        };
        signers[3].Decline_Reason__c = 'Wrong quantities';
        insert signers;

        insert new DocGen_Signature_Audit__c(
            Signature_Request__c = older.Id,
            Signer__c = signers[0].Id,
            Signer_Name__c = 'Supplier Person',
            Signed_Date__c = Datetime.newInstance(2026, 11, 2, 10, 0, 0)
        );

        Datetime t0 = Datetime.newInstance(2026, 11, 3, 9, 0, 0);
        DocGenSignerVisits.recordVisit(signers[2].Id, IPHONE, t0);
        DocGenSignerVisits.recordVisit(signers[2].Id, IPHONE, t0.addDays(1));
        DocGenSignerVisits.recordVisit(signers[2].Id, IPHONE, t0.addDays(2));
        DocGenSignerVisits.recordVisit(signers[2].Id, 'python-requests/2.32', t0.addDays(2).addMinutes(1));
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
        insert u;
        insert new PermissionSetAssignment(
            AssigneeId = u.Id,
            PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1]
            .Id
        );
        return u;
    }

    @IsTest
    static void listsTheRecordsRequestsWithEachSignersProgress() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Status Card Test'];
        User u = docGenUser();
        List<DocGenSignatureStatusController.RequestStatus> result;
        System.runAs(u) {
            Test.startTest();
            result = DocGenSignatureStatusController.getRequests(acct.Id);
            Test.stopTest();
        }

        Assert.areEqual(2, result.size(), 'Both requests, matched on 18 and 15 characters; the draft is left out');
        DocGenSignatureStatusController.RequestStatus newest = result[0];
        Assert.areEqual('Sent', newest.status, 'Newest first');
        Assert.areEqual('Status Card Template', newest.title);
        Assert.isNotNull(newest.expiresAt);
        Assert.areEqual(2, newest.signers.size());

        DocGenSignatureStatusController.SignerStatus hesitant = newest.signers[0];
        Assert.areEqual('Hesitant Buyer', hesitant.name);
        Assert.areEqual(3, hesitant.visitCount, 'Three visits; the scanner is left out');
        Assert.areEqual(3, hesitant.visits.size());
        Assert.areEqual('Phone', hesitant.visits[0].device);
        Assert.areEqual(Datetime.newInstance(2026, 11, 3, 9, 0, 0), hesitant.firstOpenedAt);

        DocGenSignatureStatusController.SignerStatus declining = newest.signers[1];
        Assert.areEqual('Declined', declining.status);
        Assert.areEqual('Wrong quantities', declining.declineReason);
        Assert.areEqual(0, declining.visitCount);

        DocGenSignatureStatusController.RequestStatus older = result[1];
        Assert.areEqual('Signed', older.status);
        Assert.areEqual('Supplier Person', older.signers[0].name, 'Signers in signing order');
        Assert.areEqual(Datetime.newInstance(2026, 11, 2, 10, 0, 0), older.signers[0].signedAt);
        Assert.isNull(older.signers[1].signedAt, 'No audit entry, no signed time');
        Assert.areEqual(0, older.attachmentCount);
    }

    @IsTest
    static void returnsNothingForOtherRecordsOrNoRecord() {
        Account other = new Account(Name = 'No Requests');
        insert other;
        Test.startTest();
        Assert.areEqual(0, DocGenSignatureStatusController.getRequests(other.Id).size());
        Assert.areEqual(0, DocGenSignatureStatusController.getRequests(null).size());
        Test.stopTest();
    }
}
