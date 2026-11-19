// Dura Composites Ltd.
// CxSAST: Test class — SOQL/DML findings are test data operations, not production code paths
/**
 * Quote e-sign release 1b, all generic: signer file fields and "at least one of" groups
 * (DocGenFieldWritebackService + DocGenSignatureController.uploadFormFieldFile), the
 * "DocGen: Get Template Signers" Flow action, and the signing-page badge label.
 */
@IsTest
private class DocGenSignerFormFilesTest {
    private static final String TOKEN = 'b1c2d3e4f5a6b1c2d3e4f5a6b1c2d3e4f5a6b1c2d3e4f5a6b1c2d3e4f5a6b1c2';
    private static final String PDF_B64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 test purchase order'));
    private static final String PO_CONFIG =
        '{"formFields":[' +
        '{"key":"PO_Number","label":"PO number","type":"text","atLeastOneGroup":"po"},' +
        '{"key":"PO_File","label":"PO file","type":"file","atLeastOneGroup":"po","accept":"pdf, .PNG, html"}' +
        ']}';

    private static Id buildRequest(String config, Id relatedRecordId, Id brandId) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Files Template ' + Crypto.getRandomInteger(),
            Base_Object_API__c = 'Account',
            Form_Fields_Config__c = config,
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Brand__c = brandId
        );
        insert tmpl;
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Template__c = tmpl.Id,
            Related_Record_Id__c = relatedRecordId,
            Require_Email_Verification__c = false,
            Signer_Name__c = 'File Signer',
            Signer_Email__c = 'files@test.com'
        );
        insert req;
        insert new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'File Signer',
            Signer_Email__c = 'files@test.com',
            Role_Name__c = 'Customer',
            Secure_Token__c = TOKEN,
            Status__c = 'Pending',
            Sort_Order__c = 1
        );
        return req.Id;
    }

    private static Map<String, Object> upload(String key, String name, String b64) {
        return DocGenSignatureController.uploadFormFieldFile(TOKEN, key, name, b64);
    }

    // ---------------------------------------------------------------- config

    @IsTest
    static void parseConfig_readsFileAcceptAndGroup() {
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(PO_CONFIG);
        System.assertEquals(2, defs.size());
        System.assertEquals('po', defs[0].atLeastOneGroup);
        System.assertEquals('file', defs[1].type);
        System.assertEquals(new List<String>{ 'pdf', 'png' }, defs[1].accept, 'html is never accepted');

        List<Object> pub = DocGenFieldWritebackService.publicFormFields(PO_CONFIG);
        Map<String, Object> filePub = (Map<String, Object>) pub[1];
        System.assertEquals('po', filePub.get('atLeastOneGroup'));
        System.assertEquals(DocGenFieldWritebackService.MAX_UPLOAD_BYTES, filePub.get('maxSizeBytes'));
        System.assertEquals(null, ((Map<String, Object>) pub[0]).get('maxSizeBytes'));
    }

    @IsTest
    static void parseAccept_defaultsToPdf() {
        System.assertEquals(new List<String>{ 'pdf' }, DocGenFieldWritebackService.parseAccept(null));
        System.assertEquals(new List<String>{ 'pdf' }, DocGenFieldWritebackService.parseAccept('exe,svg'));
        System.assertEquals(
            new List<String>{ 'docx', 'jpg' },
            DocGenFieldWritebackService.parseAccept(new List<Object>{ 'DOCX', '.jpg', null, 'docx' })
        );
    }

    // ---------------------------------------------------------------- at least one of

    @IsTest
    static void atLeastOne_noneFilled_throwsNamingFields() {
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(PO_CONFIG);
        try {
            DocGenFieldWritebackService.validateAndClean(defs, '{"PO_Number":"  "}');
            System.assert(false, 'expected the group rule to fail');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('PO number, PO file'), e.getMessage());
        }
    }

    @IsTest
    static void atLeastOne_oneFilled_passes() {
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(PO_CONFIG);
        Map<String, Object> clean = DocGenFieldWritebackService.validateAndClean(defs, '{"PO_Number":"PO-123"}');
        System.assertEquals('PO-123', clean.get('PO_Number'));
        System.assertEquals(null, clean.get('PO_File'));
    }

    @IsTest
    static void atLeastOne_checkboxCountsOnlyWhenTicked() {
        String cfg =
            '{"formFields":[' +
            '{"key":"a","label":"A","type":"checkbox","atLeastOneGroup":"g"},' +
            '{"key":"b","label":"B","type":"text","atLeastOneGroup":"g"}]}';
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(cfg);
        System.assertEquals(true, DocGenFieldWritebackService.validateAndClean(defs, '{"a":true}').get('a'));
        try {
            DocGenFieldWritebackService.validateAndClean(defs, '{"a":false}');
            System.assert(false, 'an unticked box does not satisfy the group');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('at least one of'), e.getMessage());
        }
    }

    @IsTest
    static void fileValue_badShape_throws() {
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(PO_CONFIG);
        try {
            DocGenFieldWritebackService.validateAndClean(defs, '{"PO_File":"001000000000001"}');
            System.assert(false, 'a non-ContentVersion Id is refused');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('not valid'), e.getMessage());
        }
    }

    // ---------------------------------------------------------------- upload

    @IsTest
    static void upload_savesFileOnRequest_andCaptureLinksItToRecord() {
        Account acct = new Account(Name = 'Files Co');
        insert acct;
        Id reqId = buildRequest(PO_CONFIG, acct.Id, null);

        Test.startTest();
        Map<String, Object> res = upload('PO_File', 'PO 123.pdf', PDF_B64);
        System.assertEquals(true, res.get('success'), String.valueOf(res));
        Id cvId = (Id) String.valueOf(res.get('contentVersionId'));
        ContentVersion cv = [SELECT ContentDocumentId, Title, PathOnClient FROM ContentVersion WHERE Id = :cvId];
        System.assertEquals('PO 123', cv.Title);
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :cv.ContentDocumentId AND LinkedEntityId = :reqId
            ]
        );
        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :cv.ContentDocumentId AND LinkedEntityId = :acct.Id
            ],
            'not on the record until the signer completes'
        );

        DocGen_Signer__c signer = [SELECT Id FROM DocGen_Signer__c WHERE Secure_Token__c = :TOKEN];
        DocGenSignatureController.captureFormFieldData(signer.Id, reqId, TOKEN, '{"PO_File":"' + cvId + '"}');
        // A second capture must not link twice.
        DocGenSignatureController.captureFormFieldData(signer.Id, reqId, TOKEN, '{"PO_File":"' + cvId + '"}');
        Test.stopTest();

        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :cv.ContentDocumentId AND LinkedEntityId = :acct.Id
            ]
        );
        Map<String, Object> saved = (Map<String, Object>) JSON.deserializeUntyped(
            [SELECT Field_Data_Json__c FROM DocGen_Signer__c WHERE Id = :signer.Id].Field_Data_Json__c
        );
        System.assertEquals(String.valueOf(cvId), saved.get('PO_File'), 'the field data holds the file Id');
    }

    @IsTest
    static void capture_fileFromAnotherRecord_isRefused() {
        Account acct = new Account(Name = 'Files Co');
        insert acct;
        Id reqId = buildRequest(PO_CONFIG, acct.Id, null);
        ContentVersion other = new ContentVersion(
            Title = 'Not yours',
            PathOnClient = 'x.pdf',
            VersionData = Blob.valueOf('%PDF-1.4'),
            FirstPublishLocationId = acct.Id
        );
        insert other;
        DocGen_Signer__c signer = [SELECT Id FROM DocGen_Signer__c WHERE Secure_Token__c = :TOKEN];
        Test.startTest();
        try {
            DocGenSignatureController.captureFormFieldData(signer.Id, reqId, TOKEN, '{"PO_File":"' + other.Id + '"}');
            System.assert(false, 'a file not uploaded to this request is refused');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('PO file'), e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void upload_refusesBadInput() {
        buildRequest(PO_CONFIG, null, null);
        Test.startTest();
        System.assertEquals(false, upload('PO_Number', 'a.pdf', PDF_B64).get('success'), 'not a file field');
        System.assertEquals(false, upload('Nope', 'a.pdf', PDF_B64).get('success'), 'unknown field');
        System.assertEquals(false, upload('PO_File', 'a.exe', PDF_B64).get('success'), 'type not accepted');
        System.assertEquals(false, upload('PO_File', 'noext', PDF_B64).get('success'), 'no extension');
        System.assertEquals(false, upload('PO_File', 'a.pdf', '').get('success'), 'empty');
        System.assertEquals(
            false,
            upload('PO_File', 'a.pdf', EncodingUtil.base64Encode(Blob.valueOf('not a pdf'))).get('success'),
            'not a PDF'
        );
        String big = 'JVBERi0' + 'A'.repeat(2800000);
        System.assertEquals(false, upload('PO_File', 'a.pdf', big).get('success'), 'too large');
        System.assertEquals(
            true,
            upload('PO_File', 'scan.png', EncodingUtil.base64Encode(Blob.valueOf('png'))).get('success'),
            'png is in this field\'s accept list'
        );
        Test.stopTest();
    }

    @IsTest
    static void upload_badTokenOrClosedRequest_refused() {
        Id reqId = buildRequest(PO_CONFIG, null, null);
        Test.startTest();
        System.assertEquals(
            false,
            DocGenSignatureController.uploadFormFieldFile('bad', 'PO_File', 'a.pdf', PDF_B64).get('success')
        );
        update new DocGen_Signature_Request__c(Id = reqId, Status__c = 'Cancelled');
        System.assertEquals(false, upload('PO_File', 'a.pdf', PDF_B64).get('success'));
        Test.stopTest();
    }

    @IsTest
    static void linkUploadedFiles_noFilesOrNoRecord_noOp() {
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(PO_CONFIG);
        DocGenFieldWritebackService.linkUploadedFiles(null, null, null, null);
        DocGenFieldWritebackService.linkUploadedFiles(defs, new Map<String, Object>{ 'PO_Number' => 'x' }, null, null);
        Id reqId = buildRequest(PO_CONFIG, null, null);
        Map<String, Object> res = upload('PO_File', 'po.pdf', PDF_B64);
        Test.startTest();
        DocGenFieldWritebackService.linkUploadedFiles(
            defs,
            new Map<String, Object>{ 'PO_File' => res.get('contentVersionId') },
            reqId,
            'not-an-id'
        );
        Test.stopTest();
        System.assertEquals(true, res.get('success'));
    }

    // ---------------------------------------------------------------- Get Template Signers

    private static Id htmlTemplate(String body) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Signers Template ' + Crypto.getRandomInteger(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            API_Name__c = 'Signers_Test_' + Crypto.getRandomInteger()
        );
        insert tmpl;
        ContentVersion cv = new ContentVersion(
            Title = 'body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true,
            Type__c = 'HTML'
        );
        return tmpl.Id;
    }

    @IsTest
    static void getTemplateSigners_dedupesAndOrdersRoles() {
        Id tmplId = htmlTemplate(
            '<p>{@Signature_Dura_Sales:2:Full}</p><p>{@Signature_Customer:1:Full}</p>' +
            '<p>{@Signature_Customer:1:Date}</p><p>{@Signature_Customer:3:Initials}</p>'
        );
        DocGenGetTemplateSignersAction.Request req = new DocGenGetTemplateSignersAction.Request();
        req.templateId = tmplId;
        Test.startTest();
        List<DocGenGetTemplateSignersAction.Result> out = DocGenGetTemplateSignersAction.getSigners(
            new List<DocGenGetTemplateSignersAction.Request>{ req }
        );
        Test.stopTest();
        System.assertEquals(1, out.size());
        System.assertEquals(false, out[0].hasSignaturesBlock);
        System.assertEquals(2, out[0].signers.size(), String.valueOf(out[0].signers));
        System.assertEquals('Customer', out[0].signers[0].role);
        System.assertEquals(1, out[0].signers[0].signingOrder);
        System.assertEquals('Dura Sales', out[0].signers[1].role);
        System.assertEquals(2, out[0].signers[1].signingOrder);
    }

    @IsTest
    static void getTemplateSigners_byApiName_withSignaturesBlock() {
        Id tmplId = htmlTemplate('<table>{#Signatures}<tr><td>{SignerName}</td></tr>{/Signatures}</table>');
        DocGenGetTemplateSignersAction.Request req = new DocGenGetTemplateSignersAction.Request();
        req.templateApiName = [SELECT API_Name__c FROM DocGen_Template__c WHERE Id = :tmplId].API_Name__c;
        Test.startTest();
        DocGenGetTemplateSignersAction.Result res = DocGenGetTemplateSignersAction.getSigners(
            new List<DocGenGetTemplateSignersAction.Request>{ req }
        )[0];
        Test.stopTest();
        System.assertEquals(true, res.hasSignaturesBlock);
        System.assertEquals(0, res.signers.size());
    }

    @IsTest
    static void getTemplateSigners_noTemplate_throws() {
        try {
            DocGenGetTemplateSignersAction.getSigners(
                new List<DocGenGetTemplateSignersAction.Request>{ new DocGenGetTemplateSignersAction.Request() }
            );
            System.assert(false, 'expected an error');
        } catch (DocGenException e) {
            System.assert(e.getMessage().contains('Template'), e.getMessage());
        }
    }

    @IsTest
    static void toSigners_ordersByLowestOrderThenFirstSeen() {
        List<DocGenSignatureSenderController.PlacementInfo> ps = new List<DocGenSignatureSenderController.PlacementInfo>{
            new DocGenSignatureSenderController.PlacementInfo('B', 2, 'Full', 't1'),
            new DocGenSignatureSenderController.PlacementInfo('A', 2, 'Full', 't2'),
            new DocGenSignatureSenderController.PlacementInfo('C', 1, 'Full', 't3'),
            new DocGenSignatureSenderController.PlacementInfo('b', 1, 'Date', 't4'),
            null
        };
        List<DocGenTemplateSigner> out = DocGenGetTemplateSignersAction.toSigners(ps);
        System.assertEquals(3, out.size());
        System.assertEquals('B', out[0].role, 'B drops to order 1 and was seen before C');
        System.assertEquals(1, out[0].signingOrder);
        System.assertEquals('C', out[1].role);
        System.assertEquals('A', out[2].role);
    }

    // ---------------------------------------------------------------- badge

    @IsTest
    static void badge_usesBrandLabelElseCompanyName() {
        DocGen_Brand__c brand = new DocGen_Brand__c(
            Name = 'Badge Brand',
            Company_Name__c = 'Acme Ltd',
            Signing_Badge_Label__c = 'Acme Sales',
            Is_Active__c = true
        );
        insert brand;
        buildRequest(null, null, brand.Id);
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(TOKEN);
        System.assertEquals('Acme Sales', res.badgeLabel);
        System.assertEquals('Customer', res.roleName, 'the role is unchanged');

        List<DocGenBrandController.BrandDto> dtos = DocGenBrandController.getBrands();
        System.assertEquals('Acme Sales', dtos[0].signingBadgeLabel);
        Test.stopTest();
    }
}
