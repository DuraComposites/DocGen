// Dura Composites Ltd. (new file)
@IsTest
private class DocGenSignerVisitsTest {
    private static final String IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148';
    private static final String WINDOWS = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36';

    private static DocGen_Signer__c makeSigner(Boolean requireCode, Boolean internalPreview) {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Require_Email_Verification__c = requireCode,
            PDF_Internal_Preview__c = internalPreview
        );
        insert req;
        DocGen_Signer__c s = new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Alex Demo',
            Signer_Email__c = 'alex.demo@example.com',
            Role_Name__c = 'Signer',
            Secure_Token__c = EncodingUtil.convertToHex(Crypto.generateAesKey(256)),
            Status__c = 'Pending',
            Sort_Order__c = 1
        );
        insert s;
        return s;
    }

    private static List<DocGen_Signer_Visit__c> visits(Id signerId) {
        return [
            SELECT Visited_At__c, Last_Seen_At__c, Page_Loads__c, Device__c, User_Agent__c
            FROM DocGen_Signer_Visit__c
            WHERE Signer__c = :signerId
            ORDER BY Visited_At__c
        ];
    }

    private static DocGen_Signer__c rollups(Id signerId) {
        return [
            SELECT Visit_Count__c, First_Visited_At__c, Last_Visited_At__c
            FROM DocGen_Signer__c
            WHERE Id = :signerId
        ];
    }

    @IsTest
    static void classifiesDevices() {
        Assert.areEqual('Phone', DocGenSignerVisits.classify(IPHONE));
        Assert.areEqual('Desktop', DocGenSignerVisits.classify(WINDOWS));
        Assert.areEqual(
            'Tablet',
            DocGenSignerVisits.classify('Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15')
        );
        Assert.areEqual(
            'Tablet',
            DocGenSignerVisits.classify(
                'Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 Chrome/131.0 Safari/537.36'
            )
        );
        Assert.areEqual(
            'Phone',
            DocGenSignerVisits.classify(
                'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/131.0 Mobile Safari/537.36'
            )
        );
        Assert.areEqual('Automated', DocGenSignerVisits.classify('Mozilla/5.0 (compatible; Googlebot/2.1)'));
        Assert.areEqual('Automated', DocGenSignerVisits.classify('python-requests/2.32'));
        Assert.areEqual('Automated', DocGenSignerVisits.classify('Mozilla/5.0 HeadlessChrome/131.0'));
        Assert.areEqual('Unknown', DocGenSignerVisits.classify(null));
        Assert.areEqual('Unknown', DocGenSignerVisits.classify('  '));
    }

    @IsTest
    static void pageLoadsWithinThirtyMinutesAreOneVisit() {
        DocGen_Signer__c s = makeSigner(false, false);
        Datetime t0 = Datetime.newInstance(2026, 11, 9, 9, 0, 0);

        Test.startTest();
        DocGenSignerVisits.recordVisit(s.Id, IPHONE, t0);
        DocGenSignerVisits.recordVisit(s.Id, IPHONE, t0.addMinutes(10)); // a reload
        DocGenSignerVisits.recordVisit(s.Id, IPHONE, t0.addMinutes(35)); // within 30 min of the last load
        DocGenSignerVisits.recordVisit(s.Id, IPHONE, t0.addMinutes(70)); // 35 min later: a new visit
        Test.stopTest();

        List<DocGen_Signer_Visit__c> v = visits(s.Id);
        Assert.areEqual(2, v.size(), 'Two visits, not four page loads');
        Assert.areEqual(3, v[0].Page_Loads__c.intValue());
        Assert.areEqual(t0, v[0].Visited_At__c);
        Assert.areEqual(t0.addMinutes(35), v[0].Last_Seen_At__c, 'The visit runs to its last page load');
        Assert.areEqual(1, v[1].Page_Loads__c.intValue());
        Assert.areEqual('Phone', v[0].Device__c);
        Assert.areEqual(IPHONE, v[0].User_Agent__c);

        DocGen_Signer__c r = rollups(s.Id);
        Assert.areEqual(2, r.Visit_Count__c.intValue());
        Assert.areEqual(t0, r.First_Visited_At__c);
        Assert.areEqual(t0.addMinutes(70), r.Last_Visited_At__c);
    }

    @IsTest
    static void anotherDeviceIsANewVisit() {
        DocGen_Signer__c s = makeSigner(false, false);
        Datetime t0 = Datetime.newInstance(2026, 11, 9, 9, 0, 0);

        Test.startTest();
        DocGenSignerVisits.recordVisit(s.Id, IPHONE, t0);
        DocGenSignerVisits.recordVisit(s.Id, WINDOWS, t0.addMinutes(5));
        Test.stopTest();

        List<DocGen_Signer_Visit__c> v = visits(s.Id);
        Assert.areEqual(2, v.size(), 'Phone then desktop is two visits');
        Assert.areEqual('Phone', v[0].Device__c);
        Assert.areEqual('Desktop', v[1].Device__c);
    }

    @IsTest
    static void automatedVisitsAreKeptButNotCounted() {
        DocGen_Signer__c s = makeSigner(false, false);
        Datetime t0 = Datetime.newInstance(2026, 11, 9, 9, 0, 0);

        Test.startTest();
        DocGenSignerVisits.recordVisit(s.Id, 'Mozilla/5.0 (compatible; SafeLinks checker)', t0);
        DocGenSignerVisits.recordVisit(s.Id, WINDOWS, t0.addMinutes(2));
        Test.stopTest();

        Assert.areEqual(2, visits(s.Id).size(), 'The scanner visit is recorded');
        DocGen_Signer__c r = rollups(s.Id);
        Assert.areEqual(1, r.Visit_Count__c.intValue(), 'but only the person counts');
        Assert.areEqual(t0.addMinutes(2), r.First_Visited_At__c);
    }

    @IsTest
    static void nothingIsRecordedForPreviewsOrFinishedSigners() {
        DocGen_Signer__c preview = makeSigner(false, true);
        DocGen_Signer__c signed = makeSigner(false, false);
        update new DocGen_Signer__c(Id = signed.Id, Status__c = 'Signed');

        Test.startTest();
        DocGenSignerVisits.recordVisit(preview.Id, WINDOWS, System.now());
        DocGenSignerVisits.recordVisit(signed.Id, WINDOWS, System.now());
        DocGenSignatureController.recordVisit(signed.Secure_Token__c, WINDOWS);
        Test.stopTest();

        Assert.areEqual(0, visits(preview.Id).size(), 'Internal previews are not visits');
        Assert.areEqual(0, visits(signed.Id).size(), 'A signer who has signed is not visiting to sign');
    }

    @IsTest
    static void theSigningPageRecordsAVisit() {
        DocGen_Signer__c s = makeSigner(false, false);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(
            s.Secure_Token__c
        );
        DocGenSignatureController.recordVisit(s.Secure_Token__c, IPHONE);
        Test.stopTest();

        Assert.isTrue(res.isValid, 'Link should be valid: ' + res.errorMessage);
        List<DocGen_Signer_Visit__c> v = visits(s.Id);
        Assert.areEqual(1, v.size(), 'The page reports the visit once the document is shown');
        Assert.areEqual('Phone', v[0].Device__c);
        Assert.areEqual(IPHONE, v[0].User_Agent__c);
        Assert.areEqual('Viewed', [SELECT Status__c FROM DocGen_Signer__c WHERE Id = :s.Id].Status__c);
    }

    @IsTest
    static void noVisitUntilTheEmailCodeIsEntered() {
        DocGen_Signer__c s = makeSigner(true, false);

        Test.startTest();
        DocGenSignatureController.recordVisit(s.Secure_Token__c, IPHONE);
        Integer before = visits(s.Id).size();
        update new DocGen_Signer__c(Id = s.Id, PIN_Verified_At__c = System.now());
        DocGenSignatureController.recordVisit(s.Secure_Token__c, IPHONE);
        Test.stopTest();

        Assert.areEqual(0, before, 'The document is not shown before the code is entered, so no visit');
        Assert.areEqual(1, visits(s.Id).size(), 'Once the code is entered, it counts');
    }

    @IsTest
    static void badTokensAreIgnored() {
        DocGen_Signer__c s = makeSigner(false, false);

        Test.startTest();
        DocGenSignatureController.recordVisit(null, IPHONE);
        DocGenSignatureController.recordVisit('not-a-token', IPHONE);
        DocGenSignatureController.recordVisit('a'.repeat(64), IPHONE); // well-formed, no such signer
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM DocGen_Signer_Visit__c], 'Nothing recorded for unknown links');
    }

    @IsTest
    static void visitsPerSignerAreCapped() {
        DocGen_Signer__c s = makeSigner(false, false);
        List<DocGen_Signer_Visit__c> existing = new List<DocGen_Signer_Visit__c>();
        Datetime longAgo = Datetime.newInstance(2026, 1, 1, 9, 0, 0);
        for (Integer i = 0; i < DocGenSignerVisits.MAX_VISITS; i++) {
            existing.add(
                new DocGen_Signer_Visit__c(
                    Signer__c = s.Id,
                    Visited_At__c = longAgo.addHours(i),
                    Last_Seen_At__c = longAgo.addHours(i),
                    Page_Loads__c = 1,
                    Device__c = 'Desktop'
                )
            );
        }
        insert existing;

        Test.startTest();
        DocGenSignerVisits.recordVisit(s.Id, IPHONE, System.now());
        Test.stopTest();

        Assert.areEqual(DocGenSignerVisits.MAX_VISITS, visits(s.Id).size(), 'No visit beyond the cap');
    }
}
