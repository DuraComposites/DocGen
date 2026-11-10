// Modified by Dura Composites Ltd.
// ============================================================================
// SDocs-replacement demo — print the signing URL for the newest pending signer.
//
// WHY YOU NEED THIS: a fresh scratch org has no Org-Wide Email Address, so
// DocGen creates the request and the signing links but reports
// "Emails not sent — no Org-Wide Email Address configured". The signing
// experience itself is completely intact; only the delivery email is missing.
// Paste the URL below into a browser — an incognito window is closest to what
// the client sees — and sign.
//
// WHICH PAGE: two signing pages ship in the package, and picking the wrong one
// by hand is a real hazard. The package routes by the SAME rule reproduced
// below (DocGenSignatureSenderController.resolveSigningPath): a request that
// carries Render_Data_Snapshot__c or Source_Document_Id__c is a guided-PDF
// request, everything else is the classic typed-name page. The Create Signature
// Request action used by the demo Flow sets Source_Document_Id__c, so it
// resolves to the PDF viewer.
//
// Do not hand-edit the URL to the other page. In v3.54.0 the typed-name page
// (/apex/duracomp__DocGenSignature) cannot finish a signature — it hangs
// on "Saving your signature..." because its saveSignature remoting call passes
// five arguments to a six-argument method. Fixed in the repo, not in the
// installed package.
// ============================================================================

duracomp__DocGen_Signer__c s = [
    SELECT
        Id,
        duracomp__Signer_Name__c,
        duracomp__Signer_Email__c,
        duracomp__Secure_Token__c,
        duracomp__Status__c,
        duracomp__Signature_Request__r.Name,
        duracomp__Signature_Request__r.duracomp__Render_Data_Snapshot__c,
        duracomp__Signature_Request__r.duracomp__Source_Document_Id__c
    FROM duracomp__DocGen_Signer__c
    WHERE duracomp__Status__c = 'Pending'
    ORDER BY CreatedDate DESC
    LIMIT 1
];

Boolean isPdfViewer =
    s.duracomp__Signature_Request__r.duracomp__Render_Data_Snapshot__c != null ||
    s.duracomp__Signature_Request__r.duracomp__Source_Document_Id__c != null;
String page = isPdfViewer ? 'DocGenSignaturePdf' : 'DocGenSignature';
String base = URL.getOrgDomainUrl().toExternalForm();

System.debug('SIGN-URL request = ' + s.duracomp__Signature_Request__r.Name);
System.debug('SIGN-URL signer  = ' + s.duracomp__Signer_Name__c + ' <' + s.duracomp__Signer_Email__c + '>');
System.debug('SIGN-URL page    = ' + page + (isPdfViewer ? ' (guided PDF viewer)' : ' (classic typed-name)'));
System.debug('SIGN-URL open    = ' + base + '/apex/duracomp__' + page + '?token=' + s.duracomp__Secure_Token__c);
