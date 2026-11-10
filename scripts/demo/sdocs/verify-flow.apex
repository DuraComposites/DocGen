// Modified by Dura Composites Ltd.
// ============================================================================
// SDocs-replacement demo — prove the auto-send Flow actually fires.
//
// Flips a project into "Pending Client Approval" and then reads back what the
// Flow produced. A Flow that deploys and activates but silently does nothing is
// the exact failure this demo is meant to argue against, so it gets checked
// rather than assumed.
//
// Uses P-2088 (Northwind) so the showcase record P-2041 stays clean for the
// live walkthrough.
// ============================================================================

Demo_Project__c p = [
    SELECT Id, Name, Project_Code__c, Status__c, Approval_Sent_On__c, Last_Signature_Request_Id__c
    FROM Demo_Project__c
    WHERE Project_Code__c = 'P-2088'
    LIMIT 1
];
System.debug('FLOW-TEST before: status=' + p.Status__c + ' sentOn=' + p.Approval_Sent_On__c);

// Reset first so the "changed to meet criteria" entry condition can fire again.
p.Status__c = 'In Flight';
p.Approval_Sent_On__c = null;
p.Last_Signature_Request_Id__c = null;
update p;

p.Status__c = 'Pending Client Approval';
update p;

Demo_Project__c after = [
    SELECT Id, Status__c, Approval_Sent_On__c, Last_Signature_Request_Id__c
    FROM Demo_Project__c
    WHERE Id = :p.Id
];
System.debug(
    'FLOW-TEST after: status=' +
        after.Status__c +
        ' sentOn=' +
        after.Approval_Sent_On__c +
        ' requestId=' +
        after.Last_Signature_Request_Id__c
);

if (after.Last_Signature_Request_Id__c == null) {
    System.debug('FLOW-TEST FAIL — no signature request id stamped on the project');
} else {
    Id reqId = (Id) after.Last_Signature_Request_Id__c;
    for (duracomp__DocGen_Signature_Request__c r : [
        SELECT Id, Name, duracomp__Status__c, duracomp__Related_Record_Id__c
        FROM duracomp__DocGen_Signature_Request__c
        WHERE Id = :reqId
    ]) {
        System.debug(
            'FLOW-TEST REQUEST ' +
                r.Name +
                ' status=' +
                r.duracomp__Status__c +
                ' related=' +
                r.duracomp__Related_Record_Id__c
        );
    }
    for (duracomp__DocGen_Signer__c s : [
        SELECT
            Id,
            duracomp__Signer_Name__c,
            duracomp__Signer_Email__c,
            duracomp__Role_Name__c,
            duracomp__Status__c,
            duracomp__Secure_Token__c
        FROM duracomp__DocGen_Signer__c
        WHERE duracomp__Signature_Request__c = :reqId
    ]) {
        System.debug(
            'FLOW-TEST SIGNER ' +
                s.duracomp__Signer_Name__c +
                ' <' +
                s.duracomp__Signer_Email__c +
                '>' +
                ' role=' +
                s.duracomp__Role_Name__c +
                ' status=' +
                s.duracomp__Status__c +
                ' token=' +
                (String.isBlank(s.duracomp__Secure_Token__c) ? 'MISSING' : 'present')
        );
    }
    // The generated document should be linked to the project, not floating.
    for (ContentDocumentLink l : [
        SELECT ContentDocument.Title, ContentDocument.FileExtension
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :p.Id
    ]) {
        System.debug('FLOW-TEST FILE ' + l.ContentDocument.Title + '.' + l.ContentDocument.FileExtension);
    }
}
