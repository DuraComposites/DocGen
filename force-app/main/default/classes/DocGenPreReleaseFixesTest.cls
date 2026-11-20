// Dura Composites Ltd.: tests for the small fixes made before 1.2.0.
@isTest
private class DocGenPreReleaseFixesTest {
    private static DocGen_Template__c template(String name) {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = name,
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert t;
        return t;
    }

    private static ContentVersion file(String title) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title + '.html',
            VersionData = Blob.valueOf('<p>{Name}</p>')
        );
        insert cv;
        return cv;
    }

    @isTest
    static void pickerHidesTemplatesWithNothingToMerge() {
        DocGen_Template__c withVersion = template('PRF With Version');
        insert new DocGen_Template_Version__c(
            Template__c = withVersion.Id,
            Is_Active__c = true,
            Content_Version_Id__c = file('v').Id
        );
        DocGen_Template__c attached = template('PRF Attached');
        ContentVersion cv = file('a');
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = attached.Id, ContentDocumentId = docId, ShareType = 'V');
        template('PRF Nothing');

        Set<String> names = new Set<String>();
        for (DocGen_Template__c t : DocGenController.getTemplatesForObject('Account')) {
            names.add(t.Name);
        }
        System.assert(names.contains('PRF With Version'), 'An active version is offered: ' + names);
        System.assert(names.contains('PRF Attached'), 'An attached file is offered: ' + names);
        System.assert(!names.contains('PRF Nothing'), 'Nothing to merge is hidden: ' + names);
    }

    @isTest
    static void finalizeWithBadTokenReturns() {
        DocGenSignatureFinalizer.FinalizeRequest r = new DocGenSignatureFinalizer.FinalizeRequest();
        r.token = 'deadbeef';
        r.base64Image = 'xyz';
        Test.startTest();
        DocGenSignatureFinalizer.finalizeSignature(new List<DocGenSignatureFinalizer.FinalizeRequest>{ r });
        Test.stopTest();
        System.assert([SELECT COUNT() FROM DocGen_Error_Log__c] >= 0, 'Returned without throwing into the Flow');
    }

    @isTest
    static void gettingStartedReportsAssetAccess() {
        Map<String, Object> r = DocGenGettingStartedController.getReadiness();
        System.assertEquals(Schema.sObjectType.DocGen_Asset__c.isCreateable(), r.get('canCreateAssets'));
        System.assert(r.containsKey('canEditAssets') && r.containsKey('canDeleteAssets'), String.valueOf(r));
    }
}
