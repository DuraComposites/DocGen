// Dura Composites Ltd. (new file)
//
// Drawing-approval demo for a QA org: an Account with three made-up drawing PDFs,
// an approval template that takes attached documents and markup, and a fresh
// signature request with the drawings attached. Prints the signing link.
//
// Run by scripts/qa/setup-signing-site.sh after the guest Site is up. Safe to
// re-run: the Account, drawings and template are reused; each run makes a new
// request (a new link). Scratch org is --no-namespace. Everything here is test
// data. The drawings are boxes and a title block, not a design.

String ACCOUNT_NAME = 'Drawing Approval Demo';
String TEMPLATE_NAME = 'Drawing Approval (demo)';

// --- 1. Account + signer contact ---
List<Account> accts = [SELECT Id FROM Account WHERE Name = :ACCOUNT_NAME LIMIT 1];
Account acct = accts.isEmpty() ? new Account(Name = ACCOUNT_NAME) : accts[0];
if (acct.Id == null) {
    insert acct;
}
List<Contact> cons = [SELECT Id FROM Contact WHERE AccountId = :acct.Id AND LastName = 'Demo' LIMIT 1];
if (cons.isEmpty()) {
    insert new Contact(FirstName = 'Alex', LastName = 'Demo', Email = 'alex.demo@example.com', AccountId = acct.Id);
}

// --- 2. Three sample drawings (A3 landscape PDFs), made once ---
// Matched by exact title: a signer's marked-up copy ("DEMO-100 ... - markup - ...") lands on
// the same account and must not be attached to the next request as a fourth drawing.
List<String> drawingTitles = new List<String>{
    'DEMO-100 General arrangement',
    'DEMO-101 Section A-A',
    'DEMO-102 Fixing details'
};
List<String> drawingIds = new List<String>();
for (ContentDocumentLink l : [
    SELECT ContentDocument.LatestPublishedVersionId
    FROM ContentDocumentLink
    WHERE LinkedEntityId = :acct.Id AND ContentDocument.Title IN :drawingTitles
    ORDER BY ContentDocument.Title
]) {
    drawingIds.add(l.ContentDocument.LatestPublishedVersionId);
}
if (drawingIds.isEmpty()) {
    List<List<String>> sheets = new List<List<String>>{
        new List<String>{ 'DEMO-100', 'General arrangement', '2' },
        new List<String>{ 'DEMO-101', 'Section A-A', '1' },
        new List<String>{ 'DEMO-102', 'Fixing details', '1' }
    };
    List<ContentVersion> cvs = new List<ContentVersion>();
    for (List<String> s : sheets) {
        String pages = '';
        Integer pageCount = Integer.valueOf(s[2]);
        for (Integer p = 1; p <= pageCount; p++) {
            pages +=
                '<div class="sheet"' +
                (p < pageCount ? ' style="page-break-after:always"' : '') +
                '>' +
                '<div class="frame"></div>' +
                '<div class="box" style="left:60mm;top:40mm;width:140mm;height:90mm"></div>' +
                '<div class="box" style="left:90mm;top:60mm;width:80mm;height:50mm"></div>' +
                '<div class="box" style="left:230mm;top:50mm;width:70mm;height:120mm"></div>' +
                '<div class="dim" style="left:60mm;top:140mm;width:140mm">1400</div>' +
                '<div class="dim" style="left:230mm;top:180mm;width:70mm">700</div>' +
                '<div class="tbw"><table class="tb"><tr><td colspan="2" class="warn">SAMPLE DRAWING FOR TESTING. NOT A REAL DESIGN.</td></tr>' +
                '<tr><td>Title</td><td>' +
                s[1] +
                '</td></tr>' +
                '<tr><td>Drawing no.</td><td>' +
                s[0] +
                '</td></tr>' +
                '<tr><td>Revision</td><td>A</td></tr>' +
                '<tr><td>Sheet</td><td>' +
                p +
                ' of ' +
                pageCount +
                '</td></tr></table></div>' +
                '</div>';
        }
        String html =
            '<html><head><style>' +
            '@page { size: A3 landscape; margin: 10mm; }' +
            'body { font-family: Helvetica, Arial, sans-serif; font-size: 9pt; margin: 0; }' +
            '.sheet { position: relative; width: 400mm; height: 268mm; }' + // under the 277mm page, so a sheet never spills onto a blank page
            '.frame { position: absolute; left: 0; top: 0; width: 398mm; height: 266mm; border: 1.5pt solid #000; }' +
            '.box { position: absolute; border: 1pt solid #1a1a1a; }' +
            '.dim { position: absolute; border-top: 0.5pt solid #555; text-align: center; color: #555; font-size: 8pt; }' +
            // The title block is placed from the top-left: Blob.toPdf fails outright on an absolutely
            // positioned table anchored right/bottom.
            '.tbw { position: absolute; left: 274mm; top: 228mm; width: 120mm; }' +
            '.tb { width: 100%; border-collapse: collapse; }' +
            '.tb td { border: 0.75pt solid #000; padding: 3pt 5pt; }' +
            '.warn { font-weight: bold; color: #b00020; text-align: center; }' +
            '</style></head><body>' +
            pages +
            '</body></html>';
        ContentVersion cv = new ContentVersion();
        cv.Title = s[0] + ' ' + s[1];
        cv.PathOnClient = s[0] + '.pdf';
        cv.VersionData = Blob.toPdf(html);
        cv.FirstPublishLocationId = acct.Id;
        cvs.add(cv);
    }
    insert cvs;
    for (ContentVersion cv : cvs) {
        drawingIds.add(cv.Id);
    }
}

// --- 3. Approval template: takes attached documents, signers can mark them up ---
List<DocGen_Template__c> tpls = [SELECT Id FROM DocGen_Template__c WHERE Name = :TEMPLATE_NAME LIMIT 1];
DocGen_Template__c tpl;
if (!tpls.isEmpty()) {
    tpl = tpls[0];
} else {
    String body =
        '<html><head><style>' +
        '@page { size: A4; margin: 20mm; }' +
        'body { font-family: Helvetica, Arial, sans-serif; font-size: 10.5pt; color: #222; }' +
        'h1 { font-size: 18pt; margin-bottom: 2px; }' +
        '.sub { color: #666; margin-bottom: 16px; }' +
        'table.sig { width: 100%; margin-top: 40px; border-collapse: collapse; }' +
        'table.sig td { width: 50%; padding: 28px 12px 0 0; vertical-align: bottom; }' +
        '.line { border-top: 1px solid #333; padding-top: 4px; font-size: 9pt; color: #666; }' +
        '</style></head><body>' +
        '<h1>Drawing approval</h1>' +
        '<div class="sub">{Name}</div>' +
        '<p>Please review the attached drawings. Approve them as issued, approve them with comments by ' +
        'marking them up, or decline them with your markups.</p>' +
        '<table class="sig"><tr>' +
        '<td><div>{@Signature_Approver:1:Full}</div><div class="line">Approved by</div></td>' +
        '<td><div>{@Signature_Approver:2:Date}</div><div class="line">Date</div></td>' +
        '</tr></table>' +
        '</body></html>';
    ContentVersion bodyCv = new ContentVersion(
        Title = 'Drawing Approval (demo) body',
        PathOnClient = 'drawing-approval.html',
        VersionData = Blob.valueOf(body)
    );
    insert bodyCv;
    tpl = new DocGen_Template__c(
        Name = TEMPLATE_NAME,
        Type__c = 'HTML',
        Base_Object_API__c = 'Account',
        Query_Config__c = 'Name',
        Attached_Documents__c = 'Optional',
        Attached_Document_Markup__c = 'Approve or decline'
    );
    insert tpl;
    insert new DocGen_Template_Version__c(Template__c = tpl.Id, Is_Active__c = true, Content_Version_Id__c = bodyCv.Id);
}

// --- 4. A fresh request with the drawings attached ---
DocGenSignatureSenderController.GuidedPdfSendOptions o = new DocGenSignatureSenderController.GuidedPdfSendOptions();
o.templateId = tpl.Id;
o.relatedRecordId = acct.Id;
o.signersJson = '[{"signerName":"Alex Demo","signerEmail":"alex.demo@example.com","roleName":"Approver"}]';
o.signingOrder = 'Parallel';
o.sendEmails = false;
o.attachedDocumentIds = drawingIds;
o.attachedDocumentPosition = 'Before';
List<DocGenSignatureSenderController.SignerResult> res = DocGenSignatureSenderController.createGuidedPdfSignatureRequestV2(
    o
);

System.debug('DEMO_ACCOUNT=' + acct.Id);
System.debug('DEMO_TEMPLATE=' + tpl.Id);
System.debug('DEMO_DRAWINGS=' + drawingIds.size());
for (DocGenSignatureSenderController.SignerResult r : res) {
    System.debug('DEMO_LINK=' + r.signerUrl);
}
