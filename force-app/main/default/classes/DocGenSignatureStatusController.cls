// Dura Composites Ltd. (new file)
/**
 * Backs the Signature Status card (LWC docGenSignatureStatus): every signature request on a
 * record, newest first, with each signer's status, when they opened their link and how often
 * (DocGen_Signer_Visit__c), when they signed or why they declined, reminders sent, and, for
 * drawing approvals, how many attached documents they opened and marked up.
 *
 * Read-only. Runs as the viewing user: with sharing and WITH USER_MODE, so a user sees only
 * the requests, signers and fields their permission sets allow (DocGen_User / DocGen_Admin).
 * Returns plain DTOs so the component never meets namespace-prefixed field names.
 */
public with sharing class DocGenSignatureStatusController {
    @TestVisible
    static final Integer MAX_REQUESTS = 50;

    public class RequestStatus {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String signingOrder;
        @AuraEnabled
        public Datetime sentAt;
        @AuraEnabled
        public Datetime expiresAt;
        @AuraEnabled
        public String signedFileId;
        @AuraEnabled
        public Integer attachmentCount;
        @AuraEnabled
        public Integer markedUpDocuments;
        @AuraEnabled
        public List<SignerStatus> signers = new List<SignerStatus>();
    }

    public class SignerStatus {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public Integer order;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String email;
        @AuraEnabled
        public String role;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Integer visitCount;
        @AuraEnabled
        public Datetime firstOpenedAt;
        @AuraEnabled
        public Datetime lastOpenedAt;
        @AuraEnabled
        public Datetime signedAt;
        @AuraEnabled
        public String declineReason;
        @AuraEnabled
        public Integer remindersSent;
        @AuraEnabled
        public Datetime lastReminderAt;
        @AuraEnabled
        public Datetime reviewConfirmedAt;
        @AuraEnabled
        public Integer attachmentsOpened;
        @AuraEnabled
        public Integer attachmentsMarkedUp;
        @AuraEnabled
        public List<Visit> visits = new List<Visit>();
    }

    public class Visit {
        @AuraEnabled
        public Datetime visitedAt;
        @AuraEnabled
        public Datetime lastSeenAt;
        @AuraEnabled
        public Integer pageLoads;
        @AuraEnabled
        public String device;
    }

    /** The signature requests whose related record is recordId, newest first. */
    @AuraEnabled(cacheable=true)
    public static List<RequestStatus> getRequests(Id recordId) {
        List<RequestStatus> out = new List<RequestStatus>();
        if (recordId == null) {
            return out;
        }
        try {
            return load(recordId);
        } catch (Exception e) {
            String message = 'Could not load signature requests: ' + e.getMessage();
            AuraHandledException ex = new AuraHandledException(message);
            ex.setMessage(message);
            throw ex;
        }
    }

    private static List<RequestStatus> load(Id recordId) {
        // Related_Record_Id__c is text: match the 18- and 15-character forms of the Id.
        Set<String> ids = new Set<String>{ String.valueOf(recordId), String.valueOf(recordId).left(15) };
        List<DocGen_Signature_Request__c> requests = [
            SELECT
                Id,
                Name,
                Status__c,
                Signing_Order__c,
                CreatedDate,
                Expires_At__c,
                Protected_Signed_Content_Document_Id__c,
                Marked_Up_Documents__c,
                Template__r.Name,
                (
                    SELECT
                        Id,
                        Sort_Order__c,
                        Signer_Name__c,
                        Signer_Email__c,
                        Role_Name__c,
                        Status__c,
                        Decline_Reason__c,
                        Reminders_Sent__c,
                        Reminder_Sent_At__c,
                        Attachments_Reviewed_At__c,
                        Visit_Count__c,
                        First_Visited_At__c,
                        Last_Visited_At__c
                    FROM Signers__r
                    ORDER BY Sort_Order__c ASC NULLS LAST, CreatedDate ASC
                )
            FROM DocGen_Signature_Request__c
            WHERE Related_Record_Id__c IN :ids AND Status__c != 'Draft' AND PDF_Internal_Preview__c = FALSE
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT :MAX_REQUESTS
        ];
        if (requests.isEmpty()) {
            return new List<RequestStatus>();
        }

        Set<Id> requestIds = new Map<Id, DocGen_Signature_Request__c>(requests).keySet();
        Map<Id, List<Visit>> visitsBySigner = visitsFor(requestIds);
        Map<Id, Datetime> signedAtBySigner = signedTimesFor(requestIds);
        Map<Id, Integer> attachmentsByRequest = attachmentCountsFor(requestIds);
        Map<Id, Integer[]> reviewBySigner = attachmentReviewFor(requestIds);

        List<RequestStatus> out = new List<RequestStatus>();
        for (DocGen_Signature_Request__c req : requests) {
            RequestStatus r = new RequestStatus();
            r.id = req.Id;
            r.name = req.Name;
            r.title = req.Template__r != null ? req.Template__r.Name : 'PDF document';
            r.status = req.Status__c;
            r.signingOrder = req.Signing_Order__c;
            r.sentAt = req.CreatedDate;
            r.expiresAt = req.Expires_At__c;
            r.signedFileId = req.Protected_Signed_Content_Document_Id__c;
            r.markedUpDocuments = toInt(req.Marked_Up_Documents__c);
            r.attachmentCount = attachmentsByRequest.containsKey(req.Id) ? attachmentsByRequest.get(req.Id) : 0;
            Integer position = 0;
            for (DocGen_Signer__c s : req.Signers__r) {
                position++;
                SignerStatus ss = new SignerStatus();
                ss.id = s.Id;
                ss.order = s.Sort_Order__c != null ? s.Sort_Order__c.intValue() : position;
                ss.name = s.Signer_Name__c;
                ss.email = s.Signer_Email__c;
                ss.role = s.Role_Name__c;
                ss.status = s.Status__c;
                ss.visitCount = toInt(s.Visit_Count__c);
                ss.firstOpenedAt = s.First_Visited_At__c;
                ss.lastOpenedAt = s.Last_Visited_At__c;
                ss.signedAt = signedAtBySigner.get(s.Id);
                ss.declineReason = s.Decline_Reason__c;
                ss.remindersSent = toInt(s.Reminders_Sent__c);
                ss.lastReminderAt = s.Reminder_Sent_At__c;
                ss.reviewConfirmedAt = s.Attachments_Reviewed_At__c;
                Integer[] review = reviewBySigner.get(s.Id);
                ss.attachmentsOpened = review == null ? 0 : review[0];
                ss.attachmentsMarkedUp = review == null ? 0 : review[1];
                if (visitsBySigner.containsKey(s.Id)) {
                    ss.visits = visitsBySigner.get(s.Id);
                }
                r.signers.add(ss);
            }
            out.add(r);
        }
        return out;
    }

    /** Every visit by these requests' signers, oldest first. Automated visits are left out. */
    private static Map<Id, List<Visit>> visitsFor(Set<Id> requestIds) {
        Map<Id, List<Visit>> out = new Map<Id, List<Visit>>();
        for (DocGen_Signer_Visit__c v : [
            SELECT Signer__c, Visited_At__c, Last_Seen_At__c, Page_Loads__c, Device__c
            FROM DocGen_Signer_Visit__c
            WHERE Signer__r.Signature_Request__c IN :requestIds AND Device__c != :DocGenSignerVisits.AUTOMATED
            WITH USER_MODE
            ORDER BY Visited_At__c ASC
            LIMIT 2000
        ]) {
            Visit visit = new Visit();
            visit.visitedAt = v.Visited_At__c;
            visit.lastSeenAt = v.Last_Seen_At__c;
            visit.pageLoads = toInt(v.Page_Loads__c);
            visit.device = v.Device__c;
            if (!out.containsKey(v.Signer__c)) {
                out.put(v.Signer__c, new List<Visit>());
            }
            out.get(v.Signer__c).add(visit);
        }
        return out;
    }

    /** When each signer signed, from the signature audit (the latest entry per signer). */
    private static Map<Id, Datetime> signedTimesFor(Set<Id> requestIds) {
        Map<Id, Datetime> out = new Map<Id, Datetime>();
        for (DocGen_Signature_Audit__c a : [
            SELECT Signer__c, Signed_Date__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c IN :requestIds AND Signer__c != NULL AND Signed_Date__c != NULL
            WITH USER_MODE
            ORDER BY Signed_Date__c ASC
            LIMIT 2000
        ]) {
            out.put(a.Signer__c, a.Signed_Date__c);
        }
        return out;
    }

    /** How many documents were attached to each request (drawing approval). */
    private static Map<Id, Integer> attachmentCountsFor(Set<Id> requestIds) {
        Map<Id, Integer> out = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Signature_Request__c req, COUNT(Id) n
            FROM DocGen_Signature_Attachment__c
            WHERE Signature_Request__c IN :requestIds
            WITH USER_MODE
            GROUP BY Signature_Request__c
        ]) {
            out.put((Id) ar.get('req'), (Integer) ar.get('n'));
        }
        return out;
    }

    /** Per signer: [attached documents opened, attached documents with a submitted markup]. */
    private static Map<Id, Integer[]> attachmentReviewFor(Set<Id> requestIds) {
        Map<Id, Integer[]> out = new Map<Id, Integer[]>();
        for (DocGen_Signer_Attachment__c sa : [
            SELECT Signer__c, Viewed_At__c, Markup_Submitted_At__c
            FROM DocGen_Signer_Attachment__c
            WHERE Signer__r.Signature_Request__c IN :requestIds
            WITH USER_MODE
            LIMIT 5000
        ]) {
            if (!out.containsKey(sa.Signer__c)) {
                out.put(sa.Signer__c, new List<Integer>{ 0, 0 });
            }
            Integer[] counts = out.get(sa.Signer__c);
            if (sa.Viewed_At__c != null) {
                counts[0]++;
            }
            if (sa.Markup_Submitted_At__c != null) {
                counts[1]++;
            }
        }
        return out;
    }

    private static Integer toInt(Decimal value) {
        return value == null ? 0 : value.intValue();
    }
}
