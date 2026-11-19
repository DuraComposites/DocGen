// Dura Composites Ltd.
// CxSAST: Test class — SOQL/DML findings are test data operations, not production code paths
/**
 * Quote e-sign round 2 (all generic): signer inputs per role ("forRoles"), the live
 * {#Signatures} viewing copy for parallel signers, and per-template consent wording
 * recorded on the audit and printed on the certificate.
 */
@IsTest
private class DocGenSigningRound2Test {
    private static final String CUSTOMER_TOKEN = 'c1c2c3c4c5c6c1c2c3c4c5c6c1c2c3c4c5c6c1c2c3c4c5c6c1c2c3c4c5c6c1c2';
    private static final String DIRECTOR_TOKEN = 'd1d2d3d4d5d6d1d2d3d4d5d6d1d2d3d4d5d6d1d2d3d4d5d6d1d2d3d4d5d6d1d2';
    private static final String PO_CONFIG =
        '{"formFields":[' +
        '{"key":"PO_Number","label":"PO number","type":"text","atLeastOneGroup":"po","forRoles":["Customer"],"listOnCertificate":true},' +
        '{"key":"PO_File","label":"PO file","type":"file","atLeastOneGroup":"po","forRoles":"customer, ","listOnCertificate":true},' +
        '{"key":"Notes","label":"Notes","type":"text","listOnCertificate":true}' +
        ']}';

    private static Id buildRequest(String config, String consentText) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Round 2 ' + Crypto.getRandomInteger(),
            Base_Object_API__c = 'Account',
            Form_Fields_Config__c = config,
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Signing_Consent_Text__c = consentText
        );
        insert tmpl;
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Template__c = tmpl.Id,
            Require_Email_Verification__c = false,
            Signing_Order__c = 'Parallel',
            Signer_Name__c = 'Casey Customer',
            Signer_Email__c = 'casey@example.com'
        );
        insert req;
        insert new List<DocGen_Signer__c>{
            new DocGen_Signer__c(
                Signature_Request__c = req.Id,
                Signer_Name__c = 'Casey Customer',
                Signer_Email__c = 'casey@example.com',
                Role_Name__c = ' Customer ',
                Secure_Token__c = CUSTOMER_TOKEN,
                Status__c = 'Pending',
                Sort_Order__c = 1
            ),
            new DocGen_Signer__c(
                Signature_Request__c = req.Id,
                Signer_Name__c = 'Dana Director',
                Signer_Email__c = 'dana@example.com',
                Role_Name__c = 'Managing Director',
                Secure_Token__c = DIRECTOR_TOKEN,
                Status__c = 'Pending',
                Sort_Order__c = 2
            )
        };
        return req.Id;
    }

    private static DocGen_Signer__c signer(String token) {
        return [
            SELECT Id, Signature_Request__c, Field_Data_Json__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
        ];
    }

    // ---------------------------------------------------------------- forRoles

    @IsTest
    static void forRoles_parsesListOrCommaString_andMatchesCaseInsensitively() {
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(PO_CONFIG);
        Assert.areEqual(new List<String>{ 'customer' }, defs[0].forRoles);
        Assert.areEqual(new List<String>{ 'customer' }, defs[1].forRoles, 'comma string, blanks dropped');
        Assert.isTrue(defs[2].forRoles.isEmpty(), 'no key = every signer');
        Assert.isTrue(defs[0].appliesTo('  CUSTOMER '));
        Assert.isFalse(defs[0].appliesTo('Managing Director'));
        Assert.isFalse(defs[0].appliesTo(null));
        Assert.isTrue(defs[2].appliesTo(null));
        Assert.areEqual(3, DocGenFieldWritebackService.forSigner(defs, 'customer').size());
        Assert.areEqual(1, DocGenFieldWritebackService.forSigner(defs, 'Managing Director').size());
        Assert.areEqual(
            new List<String>{ 'a', 'b' },
            DocGenFieldWritebackService.parseRoles(new List<Object>{ 'A', ' b ', null, 'a', '' })
        );
    }

    @IsTest
    static void validateToken_sendsOnlyTheSignersOwnFields() {
        buildRequest(PO_CONFIG, null);
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse cust = DocGenSignatureController.validateToken(CUSTOMER_TOKEN);
        DocGenSignatureController.SignatureInitResponse dir = DocGenSignatureController.validateToken(DIRECTOR_TOKEN);
        Test.stopTest();
        Assert.areEqual(3, cust.formFields.size(), 'Customer is asked for the PO');
        Assert.areEqual(1, dir.formFields.size(), 'The director is only asked the shared field');
        Assert.areEqual('Notes', ((Map<String, Object>) dir.formFields[0]).get('key'));
    }

    @IsTest
    static void capture_enforcesTheGroupOnlyForSignersItAppliesTo() {
        Id reqId = buildRequest(PO_CONFIG, null);
        DocGen_Signer__c cust = signer(CUSTOMER_TOKEN);
        DocGen_Signer__c dir = signer(DIRECTOR_TOKEN);
        Test.startTest();
        // The director gives nothing for the PO group and is not blocked.
        DocGenSignatureController.captureFormFieldData(
            dir.Id,
            reqId,
            DIRECTOR_TOKEN,
            '{"Notes":"ok","PO_Number":"sneaky"}'
        );
        // The customer must still give a PO number or file.
        Boolean blocked = false;
        try {
            DocGenSignatureController.captureFormFieldData(cust.Id, reqId, CUSTOMER_TOKEN, '{}');
        } catch (AuraHandledException e) {
            blocked = e.getMessage().contains('PO number');
        }
        DocGenSignatureController.captureFormFieldData(cust.Id, reqId, CUSTOMER_TOKEN, '{"PO_Number":"PO-9"}');
        Test.stopTest();
        Assert.isTrue(blocked, 'The group still applies to the customer');
        Map<String, Object> dirData = (Map<String, Object>) JSON.deserializeUntyped(
            signer(DIRECTOR_TOKEN).Field_Data_Json__c
        );
        Assert.areEqual('ok', dirData.get('Notes'));
        Assert.isFalse(dirData.containsKey('PO_Number'), 'A field not asked of this role is dropped');
        Map<String, Object> custData = (Map<String, Object>) JSON.deserializeUntyped(
            signer(CUSTOMER_TOKEN).Field_Data_Json__c
        );
        Assert.areEqual('PO-9', custData.get('PO_Number'));
    }

    @IsTest
    static void certificate_listsEachSignersOwnFields_andFileNames() {
        Id reqId = buildRequest(PO_CONFIG, null);
        ContentVersion po = new ContentVersion(
            Title = 'PO 77',
            PathOnClient = 'PO 77.pdf',
            VersionData = Blob.valueOf('%PDF-1.4'),
            FirstPublishLocationId = reqId
        );
        insert po;
        update new List<DocGen_Signer__c>{
            new DocGen_Signer__c(
                Id = signer(CUSTOMER_TOKEN).Id,
                Status__c = 'Signed',
                Field_Data_Json__c = '{"PO_Number":null,"PO_File":"' + po.Id + '","Notes":"c"}'
            ),
            new DocGen_Signer__c(
                Id = signer(DIRECTOR_TOKEN).Id,
                Status__c = 'Signed',
                Field_Data_Json__c = '{"Notes":"d"}'
            )
        };
        List<DocGen_Signer__c> signers = [
            SELECT
                Id,
                Signer_Name__c,
                Signer_Email__c,
                Role_Name__c,
                PIN_Verified_At__c,
                Field_Data_Json__c,
                Signature_Data__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :reqId
            ORDER BY Sort_Order__c
        ];
        Test.startTest();
        String html = DocGenSignatureService.buildVerificationBlockHtml(
            reqId,
            signers,
            DocGenFieldWritebackService.parseConfig(PO_CONFIG),
            null
        );
        Test.stopTest();
        Assert.isTrue(html.contains('PO 77.pdf'), 'The file shows by name');
        Assert.isFalse(html.contains(String.valueOf(po.Id)), 'Never the raw Id');
        Integer poRows = html.countMatches('PO number:');
        Assert.areEqual(1, poRows, 'Only the customer section lists the PO fields');
    }

    // ---------------------------------------------------------------- consent text

    @IsTest
    static void consentText_defaultOrTemplate_isShownAndRecorded() {
        Id reqId = buildRequest('{"formFields":[]}', 'I approve this design to proceed to the next phase.');
        update new DocGen_Signer__c(Id = signer(CUSTOMER_TOKEN).Id, PIN_Verified_At__c = System.now());
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(CUSTOMER_TOKEN);
        DocGenSignatureController.SavePdfSignatureResult saved = DocGenSignatureController.savePdfSignature(
            CUSTOMER_TOKEN,
            'Casey Customer',
            true,
            '203.0.113.7',
            'JUnit',
            '{}'
        );
        Test.stopTest();
        Assert.areEqual('I approve this design to proceed to the next phase.', res.consentText);
        Assert.isTrue(saved.success, String.valueOf(saved));
        DocGen_Signature_Audit__c audit = [
            SELECT Consent_Text__c, Consent_Captured__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c = :reqId AND Signer__c != NULL
            LIMIT 1
        ];
        Assert.areEqual('I approve this design to proceed to the next phase.', audit.Consent_Text__c);

        String html = DocGenSignatureService.buildVerificationBlockHtml(
            reqId,
            [
                SELECT
                    Id,
                    Signer_Name__c,
                    Signer_Email__c,
                    Role_Name__c,
                    PIN_Verified_At__c,
                    Field_Data_Json__c,
                    Signature_Data__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :reqId
            ]
        );
        Assert.isTrue(html.contains('I approve this design'), 'The certificate prints the agreed wording');

        Map<String, Object> cert = DocGenSignatureController.getSignatureCertificate(DIRECTOR_TOKEN);
        Boolean found = false;
        for (Object o : (List<Object>) cert.get('signers')) {
            Map<String, Object> row = (Map<String, Object>) o;
            if (row.get('consentText') == 'I approve this design to proceed to the next phase.') {
                found = true;
            }
        }
        Assert.isTrue(found, 'The page-built certificate gets the recorded wording too');
    }

    @IsTest
    static void consentText_blankTemplateUsesTheStandardWording() {
        Id reqId = buildRequest(null, '   ');
        Assert.areEqual(
            DocGenSignatureController.DEFAULT_CONSENT_TEXT,
            DocGenSignatureController.consentTextFor(reqId)
        );
        Assert.areEqual(DocGenSignatureController.DEFAULT_CONSENT_TEXT, DocGenSignatureController.consentTextFor(null));
        Assert.isFalse(DocGenSignatureController.DEFAULT_CONSENT_TEXT.contains('—'), 'No em dash');
        Assert.isFalse(DocGenSignatureController.DEFAULT_CONSENT_TEXT.contains('–'), 'No en dash');
    }

    // ---------------------------------------------------------------- live viewing copy

    @IsTest
    static void liveView_rerendersTheViewingCopyWithCurrentSigners() {
        Id reqId = buildRequest(null, null);
        ContentVersion firstView = new ContentVersion(
            Title = 'Quote Q-1',
            PathOnClient = 'Quote Q-1.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 pending')
        );
        insert firstView;
        update new DocGen_Signature_Request__c(
            Id = reqId,
            Status__c = 'In Progress',
            Render_Data_Snapshot__c = '{"Name":"Q-1"}',
            Source_Document_Id__c = firstView.Id
        );
        update new DocGen_Signer__c(
            Id = signer(CUSTOMER_TOKEN).Id,
            Status__c = 'Signed',
            Signature_Data__c = 'Casey C'
        );
        // The live rows: the signer who signed shows their signature, the other stays blank.
        List<Map<String, Object>> rows = DocGenSignatureService.buildSignerLoopData(reqId);
        Assert.areEqual('Casey C', rows[0].get('Name'));
        Assert.areEqual('', rows[1].get('Name'), 'An unsigned signer has no signature yet');
        Assert.areEqual('Dana Director', rows[1].get('RegisteredName'), 'but keeps the invited name');
        Assert.areEqual('Pending', rows[1].get('Status'));

        Test.startTest();
        System.enqueueJob(new DocGenSignatureService.TemplateSignaturePdfQueueable(reqId, true));
        Test.stopTest();

        DocGen_Signature_Request__c after = [
            SELECT Source_Document_Id__c, Render_Data_Snapshot__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :reqId
        ];
        Assert.areNotEqual(String.valueOf(firstView.Id), after.Source_Document_Id__c, 'A new viewing copy');
        Assert.areEqual('{"Name":"Q-1"}', after.Render_Data_Snapshot__c, 'The frozen data is untouched');
        ContentVersion live = [
            SELECT Title, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :after.Source_Document_Id__c
        ];
        Assert.areEqual('Quote Q-1', live.Title);
        Assert.areEqual(
            1,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE
                    ContentDocumentId = :live.ContentDocumentId
                    AND LinkedEntityId = :reqId
                    AND Visibility = 'AllUsers'
            ],
            'Shared with the guest signer through the request'
        );
    }

    @IsTest
    static void liveView_skipsFinishedOrNonSnapshotRequests() {
        Id reqId = buildRequest(null, null);
        Test.startTest();
        System.enqueueJob(new DocGenSignatureService.TemplateSignaturePdfQueueable(reqId, true));
        Test.stopTest();
        Assert.isNull(
            [SELECT Source_Document_Id__c FROM DocGen_Signature_Request__c WHERE Id = :reqId].Source_Document_Id__c,
            'No snapshot, nothing to refresh'
        );
    }

    // ---------------------------------------------------------------- sequential order

    @IsTest
    static void sequential_laterSignerWaitsUntilEarlierOnesSign() {
        Id reqId = buildRequest(PO_CONFIG, null);
        update new DocGen_Signature_Request__c(Id = reqId, Signing_Order__c = 'Sequential');
        DocGen_Signer__c dir = signer(DIRECTOR_TOKEN);
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse early = DocGenSignatureController.validateToken(DIRECTOR_TOKEN);
        Boolean refused = false;
        try {
            DocGenSignatureController.assertSignerTurn(dir.Id);
        } catch (AuraHandledException e) {
            refused = e.getMessage().contains('Casey Customer');
        }
        Map<String, Object> upload = DocGenSignatureController.uploadFormFieldFile(
            DIRECTOR_TOKEN,
            'PO_File',
            'po.pdf',
            EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4'))
        );
        DocGenSignatureController.SignatureInitResponse first = DocGenSignatureController.validateToken(CUSTOMER_TOKEN);
        update new DocGen_Signer__c(Id = signer(CUSTOMER_TOKEN).Id, Status__c = 'Signed');
        DocGenSignatureController.SignatureInitResponse later = DocGenSignatureController.validateToken(DIRECTOR_TOKEN);
        DocGenSignatureController.assertSignerTurn(dir.Id); // no throw now
        Test.stopTest();
        Assert.areEqual('Casey Customer', early.waitingFor);
        Assert.isTrue(refused, 'The server refuses an out-of-turn signature');
        Assert.areEqual(false, upload.get('success'));
        Assert.isNull(first.waitingFor, 'The first signer never waits');
        Assert.isNull(later.waitingFor, 'Once earlier signers have signed, it is this signers turn');
    }

    @IsTest
    static void parallel_neverWaits() {
        buildRequest(PO_CONFIG, null);
        Assert.isTrue(DocGenSignatureController.signersAhead(signer(DIRECTOR_TOKEN).Id).isEmpty());
        Assert.isTrue(DocGenSignatureController.signersAhead(null).isEmpty());
        Assert.isNull(DocGenSignatureController.validateToken(DIRECTOR_TOKEN).waitingFor);
    }
}
