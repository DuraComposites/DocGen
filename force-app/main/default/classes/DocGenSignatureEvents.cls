// Dura Composites Ltd. (new file)
/**
 * Records what happens to a signature request and when, for the Signature Status timeline:
 * reminders, resends, revokes, and a signer trying to open a link that has expired.
 * One DocGen_Signature_Event__c per event, on the request, and on the signer it concerns.
 *
 * Sends, visits, signatures and declines are not repeated here: the request's CreatedDate, the
 * signer's DocGen_Signer_Visit__c rows and the signature audit (which Portwood writes for a
 * decline too, with the reason on the signer) already carry them. An expiry needs no
 * row either: the expiry time is known (DocGenSignatureExpiry).
 *
 * Called from Portwood's own code paths, one line each, after their own save:
 *   - DocGenSignatureReminderSchedulable.execute: Reminder sent (no actor: it's automatic);
 *   - DocGenSignatureSenderController.resendSignatureRequest: Link resent, by the user;
 *   - DocGenSignatureSenderController.cancelSignatureRequest: Revoked, by the user;
 *   - DocGenSignatureController.validateToken: Expired link opened (guest), once per
 *     signer per EXPIRED_OPEN_GAP_MINUTES.
 *
 * Never throws: a timeline entry that can't be written must not stop a reminder, a resend,
 * a revoke or a signer. Writes WITH SYSTEM_MODE behind the guest-aware field guard, like the
 * rest of the signing surface.
 */
public without sharing class DocGenSignatureEvents {
    public static final String REMINDER_SENT = 'Reminder sent';
    public static final String LINK_RESENT = 'Link resent';
    public static final String REVOKED = 'Revoked';
    public static final String EXPIRED_LINK_OPENED = 'Expired link opened';

    @TestVisible
    static final Integer EXPIRED_OPEN_GAP_MINUTES = 30;

    private static final Set<String> FIELDS = new Set<String>{
        'Signature_Request__c',
        'Signer__c',
        'Type__c',
        'Occurred_At__c',
        'Actor__c',
        'Detail__c'
    };

    /** One event per signer, e.g. a reminder or a resend. */
    public static void logForSigners(Id requestId, List<DocGen_Signer__c> signers, String type, Boolean byUser) {
        try {
            List<DocGen_Signature_Event__c> events = new List<DocGen_Signature_Event__c>();
            for (DocGen_Signer__c s : signers) {
                Id req = requestId != null ? requestId : s.Signature_Request__c;
                if (req != null && s.Id != null) {
                    events.add(build(req, s.Id, type, null, byUser));
                }
            }
            save(events);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: signature events not recorded: ' + e.getMessage());
        }
    }

    /** One event for the whole request, e.g. a revoke. */
    public static void logForRequest(Id requestId, String type, Boolean byUser) {
        try {
            if (requestId != null) {
                save(new List<DocGen_Signature_Event__c>{ build(requestId, null, type, null, byUser) });
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: signature event not recorded: ' + e.getMessage());
        }
    }

    /**
     * A user changed the request after sending, e.g. extended the link (DocGenSignatureReminderRules).
     * Called only after that change was allowed (the Change Sent Signature Requests permission), so
     * the row is written as the system: sales users have no create on events, so that they can't
     * add timeline entries of their own.
     */
    public static void logChange(Id requestId, String type, String detail) {
        try {
            if (requestId != null) {
                insertRows(new List<DocGen_Signature_Event__c>{ build(requestId, null, type, detail, true) });
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: change event not recorded: ' + e.getMessage());
        }
    }

    /** A signer opened their link after it expired. At most once per signer per gap. */
    public static void logExpiredOpen(Id requestId, Id signerId) {
        try {
            if (requestId == null || signerId == null) {
                return;
            }
            Datetime since = System.now().addMinutes(-EXPIRED_OPEN_GAP_MINUTES);
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Integer recent = [
                SELECT COUNT()
                FROM DocGen_Signature_Event__c
                WHERE Signer__c = :signerId AND Type__c = :EXPIRED_LINK_OPENED AND Occurred_At__c > :since
                WITH SYSTEM_MODE
            ];
            if (recent == 0) {
                save(
                    new List<DocGen_Signature_Event__c>{ build(requestId, signerId, EXPIRED_LINK_OPENED, null, false) }
                );
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: expired-open event not recorded: ' + e.getMessage());
        }
    }

    private static DocGen_Signature_Event__c build(
        Id requestId,
        Id signerId,
        String type,
        String detail,
        Boolean byUser
    ) {
        Boolean isGuest = UserInfo.getUserType() == 'Guest';
        return new DocGen_Signature_Event__c(
            Signature_Request__c = requestId,
            Signer__c = signerId,
            Type__c = type,
            Occurred_At__c = System.now(),
            Actor__c = (byUser == true && !isGuest) ? UserInfo.getUserId() : null,
            Detail__c = String.isBlank(detail) ? null : detail.left(255)
        );
    }

    private static void save(List<DocGen_Signature_Event__c> events) {
        if (events.isEmpty()) {
            return;
        }
        DocGenFlsGuard.guestAssertCreateable(events, FIELDS);
        insertRows(events);
    }

    private static void insertRows(List<DocGen_Signature_Event__c> events) {
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(events, false, AccessLevel.SYSTEM_MODE);
    }
}
