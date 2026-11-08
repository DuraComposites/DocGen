// Dura Composites Ltd. (new file)
/**
 * Records each time a signer opens their signing link, so senders can see who opened a
 * document, when, and how often. A signer coming back to a document several times before
 * signing is useful to the sales team.
 *
 * WHAT COUNTS AS A VISIT
 * The signing page (DocGenSignaturePdf.page, initAfterVerification) calls
 * DocGenSignatureController.recordVisit once the document is on screen, after the email code
 * if one is needed, and sends navigator.userAgent: Visualforce remoting calls carry no request
 * headers for Apex to read. Software that fetches the link without running the page's
 * JavaScript therefore never counts. Page loads less than VISIT_GAP_MINUTES apart on the same
 * kind of device are one visit (a reload, a quick return); the visit's Page_Loads__c and
 * Last_Seen_At__c move on instead. Nothing is recorded:
 *   - before the email code has been entered, when the request needs one;
 *   - for internal previews (DocGen_Signature_Request__c.PDF_Internal_Preview__c);
 *   - for a signer who has already signed, declined or been cancelled;
 *   - beyond MAX_VISITS visits per signer.
 * Link checkers that do run the page are recorded as Device 'Automated' and are left out of
 * the signer's roll-ups (Visit_Count__c, First_Visited_At__c, Last_Visited_At__c).
 *
 * PRIVACY
 * A visit keeps the time, the kind of device and the user agent string. No IP address: the
 * signing audit already keeps that for the signature evidence.
 *
 * SAFETY
 * Guest-callable through the signing controller and bound to the signer's token, like every
 * guest call. It never throws: a visit that can't be written must not stop anyone signing.
 * Like the rest of the guest surface, it reads and writes WITH SYSTEM_MODE behind the
 * per-field guest guard (see DocGenSignatureGuestSecurity for the model).
 */
public without sharing class DocGenSignerVisits {
    @TestVisible
    static final Integer VISIT_GAP_MINUTES = 30;

    /** Enough for any real signer; stops a leaked link being used to flood the table. */
    @TestVisible
    static final Integer MAX_VISITS = 200;

    /** Device values (DocGen_Signer_Visit__c.Device__c). */
    public static final String PHONE = 'Phone';
    public static final String TABLET = 'Tablet';
    public static final String DESKTOP = 'Desktop';
    public static final String AUTOMATED = 'Automated';
    public static final String UNKNOWN = 'Unknown';

    private static final Pattern AUTOMATED_AGENT = Pattern.compile(
        '(?i).*(bot|crawl|spider|slurp|preview|scanner|headless|phantomjs|python|curl|wget|java/|go-http|okhttp|' +
        'safelinks|proofpoint|mimecast|barracuda|symantec|forcepoint|trendmicro|sophos).*'
    );

    /** Records a visit for the signer who holds this token. Never throws. */
    public static void recordForToken(String token, String userAgent) {
        try {
            if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
                return;
            }
            DocGenFlsGuard.guestAssertAccessible(
                DocGen_Signer__c.sObjectType,
                new Set<String>{ 'PIN_Verified_At__c', 'Signature_Request__c', 'Secure_Token__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signer__c> signers = [
                SELECT Id, PIN_Verified_At__c, Signature_Request__r.Require_Email_Verification__c
                FROM DocGen_Signer__c
                WHERE Secure_Token__c = :token
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (signers.isEmpty()) {
                return;
            }
            DocGen_Signer__c signer = signers[0];
            // Same rule as validateSignerToken: verification is required unless switched off.
            Boolean codeNeeded = signer.Signature_Request__r.Require_Email_Verification__c != false;
            if (codeNeeded && signer.PIN_Verified_At__c == null) {
                return;
            }
            recordVisit(signer.Id, userAgent, System.now());
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: signer visit not recorded: ' + e.getMessage());
        }
    }

    @TestVisible
    static void recordVisit(Id signerId, String userAgent, Datetime now) {
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Status__c, Signature_Request__r.PDF_Internal_Preview__c
            FROM DocGen_Signer__c
            WHERE Id = :signerId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (signers.isEmpty()) {
            return;
        }
        DocGen_Signer__c signer = signers[0];
        if (signer.Signature_Request__r.PDF_Internal_Preview__c == true) {
            return;
        }
        if (signer.Status__c == 'Signed' || signer.Status__c == 'Declined' || signer.Status__c == 'Cancelled') {
            return;
        }

        String device = classify(userAgent);
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer_Visit__c> latest = [
            SELECT Id, Last_Seen_At__c, Page_Loads__c, Device__c
            FROM DocGen_Signer_Visit__c
            WHERE Signer__c = :signerId
            WITH SYSTEM_MODE
            ORDER BY Last_Seen_At__c DESC NULLS LAST
            LIMIT 1
        ];
        if (
            !latest.isEmpty() &&
            latest[0].Device__c == device &&
            latest[0].Last_Seen_At__c != null &&
            latest[0].Last_Seen_At__c.addMinutes(VISIT_GAP_MINUTES) > now
        ) {
            DocGen_Signer_Visit__c visit = new DocGen_Signer_Visit__c(
                Id = latest[0].Id,
                Last_Seen_At__c = now,
                Page_Loads__c = (latest[0].Page_Loads__c == null ? 1 : latest[0].Page_Loads__c) + 1
            );
            DocGenFlsGuard.guestAssertUpdateable(visit, new Set<String>{ 'Last_Seen_At__c', 'Page_Loads__c' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(visit, false, AccessLevel.SYSTEM_MODE);
            return;
        }

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        if ([SELECT COUNT() FROM DocGen_Signer_Visit__c WHERE Signer__c = :signerId WITH SYSTEM_MODE] >= MAX_VISITS) {
            return;
        }
        DocGen_Signer_Visit__c visit = new DocGen_Signer_Visit__c(
            Signer__c = signerId,
            Visited_At__c = now,
            Last_Seen_At__c = now,
            Page_Loads__c = 1,
            Device__c = device,
            User_Agent__c = String.isBlank(userAgent) ? null : userAgent.left(255)
        );
        DocGenFlsGuard.guestAssertCreateable(
            visit,
            new Set<String>{
                'Signer__c',
                'Visited_At__c',
                'Last_Seen_At__c',
                'Page_Loads__c',
                'Device__c',
                'User_Agent__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(visit, false, AccessLevel.SYSTEM_MODE);
    }

    /** Phone, Tablet, Desktop, Automated or Unknown, from a user agent string. */
    @TestVisible
    static String classify(String userAgent) {
        if (String.isBlank(userAgent)) {
            return UNKNOWN;
        }
        if (AUTOMATED_AGENT.matcher(userAgent).matches()) {
            return AUTOMATED;
        }
        String ua = userAgent.toLowerCase();
        if (ua.contains('ipad') || ua.contains('tablet') || (ua.contains('android') && !ua.contains('mobile'))) {
            return TABLET;
        }
        if (ua.contains('mobi') || ua.contains('iphone') || ua.contains('android')) {
            return PHONE;
        }
        return DESKTOP;
    }
}
