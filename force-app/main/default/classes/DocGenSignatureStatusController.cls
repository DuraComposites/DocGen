// Modified by Dura Composites Ltd.
// Dura Composites Ltd. (new file)
/**
 * Backs the Signature Status card (LWC docGenSignatureStatus): every signature request on a
 * record as a timeline of what happened, oldest first. Merges:
 *   - sent: the request's CreatedDate;
 *   - opened: DocGen_Signer_Visit__c (automated visits left out), with device and page loads;
 *   - reminder sent, link resent, revoked, expired link opened, and a user changing the link's
 *     expiry or the reminders after sending: DocGen_Signature_Event__c;
 *   - signed and declined: DocGen_Signature_Audit__c (DocGen writes one for both), with the
 *     decline reason from the signer;
 *   - link expired: the expiry time, when the request is still open (DocGenSignatureExpiry);
 *   - fallbacks for requests from before the event log: the signer's latest reminder, and the
 *     revoke time from the request's status history.
 *
 * Grouping: on a parent record (e.g. an Opportunity) the card can also show the requests on
 * related child records (e.g. its Quotes). relatedRecords names them as
 * "ChildObject.LookupField", comma-separated, e.g. "SBQQ__Quote__c.SBQQ__Opportunity2__c".
 * Each must be a lookup from the child to this record's object; anything else is ignored.
 *
 * Runs as the viewing user: with sharing and WITH USER_MODE. Returns plain DTOs so the component
 * never meets namespace-prefixed field names. The only writes are changeExpiry and
 * changeReminders (DocGenSignatureReminderRules), for a request that isn't finished.
 */
public with sharing class DocGenSignatureStatusController {
    @TestVisible
    static final Integer MAX_REQUESTS = 100;
    @TestVisible
    static final Integer MAX_RELATED_RECORDS = 200;

    public class RecordGroup {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String recordName;
        @AuraEnabled
        public Boolean isThisRecord;
        @AuraEnabled
        public List<RequestStatus> requests = new List<RequestStatus>();
    }

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
        public String statusLabel;
        /** success, danger, accent or neutral */
        @AuraEnabled
        public String statusTone;
        @AuraEnabled
        public String signerNames;
        @AuraEnabled
        public Datetime sentAt;
        @AuraEnabled
        public Datetime expiresAt;
        @AuraEnabled
        public Boolean isOpen;
        /** Not signed, declined or revoked: the link can be extended and reminders changed. */
        @AuraEnabled
        public Boolean canChange;
        /** "Link expires 22 Nov · Reminders every 2 days until 20 Nov", while unfinished. */
        @AuraEnabled
        public String plan;
        /** The expiry and reminder settings, to pre-fill the card's editors. */
        @AuraEnabled
        public Date expiresOn;
        @AuraEnabled
        public Integer reminderEvery;
        @AuraEnabled
        public Date remindersUntil;
        @AuraEnabled
        public String summary;
        @AuraEnabled
        public String signedFileId;
        @AuraEnabled
        public List<String> drawingLines = new List<String>();
        @AuraEnabled
        public List<TimelineItem> timeline = new List<TimelineItem>();
    }

    public class TimelineItem {
        @AuraEnabled
        public Datetime at;
        /**
         * sent, opened, reminder, resent, revoked, signed, declined, expired, expired-open,
         * expiry-changed, reminders-changed, waiting
         */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String text;
    }

    /** Requests on recordId, and on related child records when relatedRecords names them. */
    @AuraEnabled(cacheable=true)
    public static List<RecordGroup> getTimeline(Id recordId, String relatedRecords) {
        if (recordId == null) {
            return new List<RecordGroup>();
        }
        try {
            return load(recordId, relatedRecords);
        } catch (Exception e) {
            String message = 'Could not load signature requests: ' + e.getMessage();
            AuraHandledException ex = new AuraHandledException(message);
            ex.setMessage(message);
            throw ex;
        }
    }

    /** Moves the link's expiry to the end of the given day; recorded on the timeline. */
    @AuraEnabled
    public static void changeExpiry(Id requestId, Date expiresOn) {
        try {
            DocGenSignatureReminderRules.changeExpiry(requestId, expiresOn);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw handled('Could not change the expiry: ' + e.getMessage());
        }
    }

    /** EVERY (every N days, optionally until a date), NONE or ORG; recorded on the timeline. */
    @AuraEnabled
    public static void changeReminders(Id requestId, String mode, Integer everyDays, Date until) {
        try {
            DocGenSignatureReminderRules.changeReminders(requestId, mode, everyDays, until);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw handled('Could not change the reminders: ' + e.getMessage());
        }
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }

    private static List<RecordGroup> load(Id recordId, String relatedRecords) {
        // Which records, in display order: this one first, then related ones, newest first.
        List<RecordGroup> groups = new List<RecordGroup>();
        RecordGroup self = new RecordGroup();
        self.recordId = recordId;
        self.isThisRecord = true;
        groups.add(self);
        groups.addAll(relatedGroups(recordId, relatedRecords));

        Map<String, RecordGroup> groupByKey = new Map<String, RecordGroup>();
        Set<String> keys = new Set<String>();
        for (RecordGroup g : groups) {
            String id18 = String.valueOf(g.recordId);
            groupByKey.put(id18, g);
            groupByKey.put(id18.left(15), g);
            keys.add(id18);
            keys.add(id18.left(15));
        }

        List<DocGen_Signature_Request__c> requests = [
            SELECT
                Id,
                Name,
                Status__c,
                CreatedDate,
                LastModifiedDate,
                Expires_At__c,
                Reminder_Every_Days__c,
                Reminders_Until__c,
                Related_Record_Id__c,
                Protected_Signed_Content_Document_Id__c,
                Marked_Up_Documents__c,
                Template__r.Name,
                (
                    SELECT
                        Id,
                        Sort_Order__c,
                        Signer_Name__c,
                        Status__c,
                        Decline_Reason__c,
                        Reminders_Sent__c,
                        Reminder_Sent_At__c,
                        Visit_Count__c,
                        Last_Visited_At__c
                    FROM Signers__r
                    ORDER BY Sort_Order__c ASC NULLS LAST, CreatedDate ASC
                )
            FROM DocGen_Signature_Request__c
            WHERE Related_Record_Id__c IN :keys AND Status__c != 'Draft' AND PDF_Internal_Preview__c = FALSE
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT :MAX_REQUESTS
        ];

        Set<Id> requestIds = new Map<Id, DocGen_Signature_Request__c>(requests).keySet();
        Map<Id, List<DocGen_Signer_Visit__c>> visits = visitsFor(requestIds);
        Map<Id, List<DocGen_Signature_Event__c>> events = eventsFor(requestIds);
        Map<Id, Datetime> auditTimes = auditTimesFor(requestIds);
        Map<Id, Integer[]> drawings = drawingReviewFor(requestIds);
        Map<Id, Integer> attachmentCounts = attachmentCountsFor(requestIds);
        Map<Id, Datetime> cancelledAt = cancelledTimesFor(requests);

        for (DocGen_Signature_Request__c req : requests) {
            RecordGroup g = groupByKey.get(req.Related_Record_Id__c);
            if (g == null) {
                continue;
            }
            g.requests.add(
                build(
                    req,
                    visits.get(req.Id),
                    events.get(req.Id),
                    auditTimes,
                    drawings,
                    attachmentCounts.get(req.Id),
                    cancelledAt.get(req.Id)
                )
            );
        }

        List<RecordGroup> out = new List<RecordGroup>();
        for (RecordGroup g : groups) {
            if (g.isThisRecord || !g.requests.isEmpty()) {
                out.add(g);
            }
        }
        return out;
    }

    private static RequestStatus build(
        DocGen_Signature_Request__c req,
        List<DocGen_Signer_Visit__c> visits,
        List<DocGen_Signature_Event__c> events,
        Map<Id, Datetime> auditTimes,
        Map<Id, Integer[]> drawings,
        Integer attachmentCount,
        Datetime cancelledAt
    ) {
        RequestStatus r = new RequestStatus();
        r.id = req.Id;
        r.name = req.Name;
        r.title = req.Template__r != null ? req.Template__r.Name : 'PDF document';
        r.status = req.Status__c;
        r.sentAt = req.CreatedDate;
        r.signedFileId = req.Protected_Signed_Content_Document_Id__c;

        Map<Id, String> names = new Map<Id, String>();
        List<String> nameList = new List<String>();
        List<String> waitingOn = new List<String>();
        Integer signedCount = 0;
        for (DocGen_Signer__c s : req.Signers__r) {
            names.put(s.Id, s.Signer_Name__c);
            nameList.add(s.Signer_Name__c);
            if (s.Status__c == 'Signed') {
                signedCount++;
            } else if (s.Status__c == 'Pending' || s.Status__c == 'Viewed') {
                waitingOn.add(s.Signer_Name__c);
            }
        }
        r.signerNames = String.join(nameList, ', ');

        Datetime expiry = req.Expires_At__c != null ? req.Expires_At__c : req.CreatedDate.addHours(48);
        r.expiresAt = expiry;
        Boolean finished = req.Status__c == 'Signed' || req.Status__c == 'Declined' || req.Status__c == 'Cancelled';
        Boolean expired = !finished && DocGenSignatureExpiry.isExpired(req.Expires_At__c, req.CreatedDate);
        r.isOpen = !finished && !expired;
        r.canChange = !finished;
        r.expiresOn = expiry.date();
        r.reminderEvery = req.Reminder_Every_Days__c == null ? null : req.Reminder_Every_Days__c.intValue();
        r.remindersUntil = req.Reminders_Until__c == null ? null : req.Reminders_Until__c.date();
        if (!finished) {
            r.plan =
                (expired ? 'Link expired ' : 'Link expires ') +
                expiry.format('d MMM') +
                ' · ' +
                DocGenSignatureReminderRules.describe(req.Reminder_Every_Days__c, req.Reminders_Until__c);
            Boolean wantsReminders = req.Reminder_Every_Days__c == null || req.Reminder_Every_Days__c > 0;
            if (wantsReminders && !remindersOn()) {
                r.plan += ' (reminders are off in Signature Settings)';
            }
        }

        // --- the timeline ---
        add(r, req.CreatedDate, 'sent', 'Sent to ' + joinNames(nameList));

        Integer totalVisits = 0;
        Datetime lastOpened;
        if (visits != null) {
            for (DocGen_Signer_Visit__c v : visits) {
                totalVisits++;
                Datetime seen = v.Last_Seen_At__c != null ? v.Last_Seen_At__c : v.Visited_At__c;
                if (lastOpened == null || seen > lastOpened) {
                    lastOpened = seen;
                }
                String device = v.Device__c == null ? 'unknown device' : v.Device__c.toLowerCase();
                String text = names.get(v.Signer__c) + ' opened · ' + device;
                if (v.Page_Loads__c != null && v.Page_Loads__c > 1) {
                    text += ' · ' + v.Page_Loads__c.intValue() + ' page loads';
                }
                add(r, v.Visited_At__c, 'opened', text);
            }
        }

        Set<Id> signersWithReminderEvents = new Set<Id>();
        Boolean hasRevokeEvent = false;
        if (events != null) {
            for (DocGen_Signature_Event__c e : events) {
                String who = e.Signer__c != null ? names.get(e.Signer__c) : 'the signer';
                String byWho = e.Actor__r != null ? ' by ' + e.Actor__r.Name : '';
                if (e.Type__c == DocGenSignatureEvents.REMINDER_SENT) {
                    signersWithReminderEvents.add(e.Signer__c);
                    add(r, e.Occurred_At__c, 'reminder', 'Reminder sent to ' + who);
                } else if (e.Type__c == DocGenSignatureEvents.LINK_RESENT) {
                    add(r, e.Occurred_At__c, 'resent', 'Link resent to ' + who + byWho);
                } else if (e.Type__c == DocGenSignatureEvents.REVOKED) {
                    hasRevokeEvent = true;
                    add(r, e.Occurred_At__c, 'revoked', 'Revoked' + byWho);
                } else if (e.Type__c == DocGenSignatureEvents.EXPIRED_LINK_OPENED) {
                    add(r, e.Occurred_At__c, 'expired-open', who + ' tried to open the expired link');
                } else if (e.Type__c == DocGenSignatureReminderRules.EXPIRY_CHANGED) {
                    String what = String.isBlank(e.Detail__c) ? 'Link expiry changed' : e.Detail__c;
                    add(r, e.Occurred_At__c, 'expiry-changed', what + byWho);
                } else if (e.Type__c == DocGenSignatureReminderRules.REMINDERS_CHANGED) {
                    String what = String.isBlank(e.Detail__c) ? 'Reminders changed' : e.Detail__c;
                    add(r, e.Occurred_At__c, 'reminders-changed', what + byWho);
                }
            }
        }

        for (DocGen_Signer__c s : req.Signers__r) {
            // Reminders from before the event log: the signer only keeps the latest one.
            if (!signersWithReminderEvents.contains(s.Id) && s.Reminder_Sent_At__c != null) {
                Integer n = s.Reminders_Sent__c == null ? 1 : s.Reminders_Sent__c.intValue();
                add(
                    r,
                    s.Reminder_Sent_At__c,
                    'reminder',
                    'Reminder sent to ' + s.Signer_Name__c + (n > 1 ? ' (latest of ' + n + ')' : '')
                );
            }
            Datetime decided = auditTimes.get(s.Id);
            if (s.Status__c == 'Signed') {
                add(r, decided, 'signed', s.Signer_Name__c + ' signed');
            } else if (s.Status__c == 'Declined') {
                String reason = String.isBlank(s.Decline_Reason__c) ? '' : ': "' + s.Decline_Reason__c.left(200) + '"';
                add(r, decided, 'declined', s.Signer_Name__c + ' declined' + reason);
            }
            if (attachmentCount != null && attachmentCount > 0) {
                Integer[] d = drawings.get(s.Id);
                Integer opened = d == null ? 0 : d[0];
                Integer marked = d == null ? 0 : d[1];
                r.drawingLines.add(
                    s.Signer_Name__c +
                        ' opened ' +
                        opened +
                        ' of ' +
                        attachmentCount +
                        ' attached documents' +
                        (marked > 0 ? ', marked up ' + marked : '')
                );
            }
        }

        if (req.Status__c == 'Cancelled' && !hasRevokeEvent) {
            add(r, cancelledAt != null ? cancelledAt : req.LastModifiedDate, 'revoked', 'Revoked');
        }
        if (expired) {
            add(r, expiry, 'expired', 'Link expired');
        }

        r.timeline.sort(new ByTime());
        if (r.isOpen && !waitingOn.isEmpty()) {
            TimelineItem now = new TimelineItem();
            now.kind = 'waiting';
            now.text = 'Waiting on ' + joinNames(waitingOn) + ' · ' + ago(req.CreatedDate) + ' since sent';
            r.timeline.add(now);
        }

        // --- status pill and one-line summary ---
        Integer signerCount = req.Signers__r.size();
        if (req.Status__c == 'Signed') {
            Boolean comments = req.Marked_Up_Documents__c != null && req.Marked_Up_Documents__c > 0;
            r.statusLabel = comments ? 'Approved with comments' : 'Signed';
            r.statusTone = 'success';
            r.summary = 'Signed ' + fmt(lastTime(r, 'signed'));
        } else if (req.Status__c == 'Declined') {
            r.statusLabel = 'Declined';
            r.statusTone = 'danger';
            r.summary = 'Declined ' + fmt(lastTime(r, 'declined'));
        } else if (req.Status__c == 'Cancelled') {
            r.statusLabel = 'Revoked';
            r.statusTone = 'neutral';
            r.summary = 'Revoked ' + fmt(lastTime(r, 'revoked'));
        } else if (expired) {
            r.statusLabel = 'Expired';
            r.statusTone = 'neutral';
            r.summary = 'Link expired ' + fmt(expiry) + (totalVisits == 0 ? ' · never opened' : '');
        } else if (signerCount > 1) {
            r.statusLabel = signedCount + ' of ' + signerCount + ' signed';
            r.statusTone = 'accent';
            r.summary = totalVisits > 0
                ? 'Last opened ' + fmt(lastOpened)
                : 'Not opened yet · sent ' + fmt(req.CreatedDate);
        } else if (totalVisits > 0) {
            r.statusLabel = totalVisits == 1 ? 'Opened once' : 'Opened ' + totalVisits + '×';
            r.statusTone = 'accent';
            r.summary = 'Last opened ' + fmt(lastOpened);
        } else {
            r.statusLabel = 'Not opened';
            r.statusTone = 'neutral';
            r.summary = 'Sent ' + fmt(req.CreatedDate);
        }
        return r;
    }

    private static Boolean remindersOnCache;

    /** Whether the reminder job is switched on (Signature Settings). */
    private static Boolean remindersOn() {
        if (remindersOnCache == null) {
            DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
            remindersOnCache = settings != null && settings.Signature_Reminder_Enabled__c == true;
        }
        return remindersOnCache;
    }

    private static void add(RequestStatus r, Datetime at, String kind, String text) {
        if (at == null) {
            return;
        }
        TimelineItem item = new TimelineItem();
        item.at = at;
        item.kind = kind;
        item.text = text;
        r.timeline.add(item);
    }

    private class ByTime implements Comparator<TimelineItem> {
        public Integer compare(TimelineItem a, TimelineItem b) {
            if (a.at == b.at) {
                return 0;
            }
            return a.at < b.at ? -1 : 1;
        }
    }

    private static Datetime lastTime(RequestStatus r, String kind) {
        Datetime last;
        for (TimelineItem t : r.timeline) {
            if (t.kind == kind && (last == null || t.at > last)) {
                last = t.at;
            }
        }
        return last;
    }

    private static String joinNames(List<String> names) {
        if (names.isEmpty()) {
            return 'no signers';
        }
        if (names.size() == 1) {
            return names[0];
        }
        List<String> head = new List<String>();
        for (Integer i = 0; i < names.size() - 1; i++) {
            head.add(names[i]);
        }
        return String.join(head, ', ') + ' and ' + names[names.size() - 1];
    }

    /** "8 Nov, 21:04" in the viewing user's time zone. */
    @TestVisible
    static String fmt(Datetime value) {
        return value == null ? '' : value.format('d MMM, HH:mm');
    }

    @TestVisible
    static String ago(Datetime since) {
        Long minutes = (System.now().getTime() - since.getTime()) / 60000;
        if (minutes < 60) {
            return minutes + ' min';
        }
        Long hours = minutes / 60;
        if (hours < 48) {
            return hours + (hours == 1 ? ' hour' : ' hours');
        }
        return (hours / 24) + ' days';
    }

    /** Child records that point at recordId, from "ChildObject.LookupField" specs. */
    private static List<RecordGroup> relatedGroups(Id recordId, String relatedRecords) {
        List<RecordGroup> out = new List<RecordGroup>();
        if (String.isBlank(relatedRecords)) {
            return out;
        }
        Schema.SObjectType parentType = recordId.getSObjectType();
        Map<String, Schema.SObjectType> allTypes = Schema.getGlobalDescribe();
        for (String spec : relatedRecords.split(',')) {
            List<String> parts = spec.trim().split('\\.');
            if (parts.size() != 2 || !allTypes.containsKey(parts[0].toLowerCase())) {
                continue;
            }
            Schema.DescribeSObjectResult child = allTypes.get(parts[0].toLowerCase()).getDescribe();
            Schema.SObjectField lookup = child.fields.getMap().get(parts[1].toLowerCase());
            if (lookup == null || !child.isAccessible()) {
                continue;
            }
            Schema.DescribeFieldResult lf = lookup.getDescribe();
            if (lf.getType() != Schema.DisplayType.REFERENCE || !lf.getReferenceTo().contains(parentType)) {
                continue;
            }
            String nameField = 'Id';
            for (Schema.SObjectField f : child.fields.getMap().values()) {
                if (f.getDescribe().isNameField()) {
                    nameField = f.getDescribe().getName();
                    break;
                }
            }
            String soql =
                'SELECT Id, ' +
                (nameField == 'Id' ? '' : nameField + ', ') +
                'CreatedDate FROM ' +
                child.getName() +
                ' WHERE ' +
                lf.getName() +
                ' = :recordId ORDER BY CreatedDate DESC LIMIT ' +
                MAX_RELATED_RECORDS;
            for (
                SObject row : Database.queryWithBinds(
                    soql,
                    new Map<String, Object>{ 'recordId' => recordId },
                    AccessLevel.USER_MODE
                )
            ) {
                RecordGroup g = new RecordGroup();
                g.recordId = row.Id;
                g.recordName = nameField == 'Id' ? String.valueOf(row.Id) : String.valueOf(row.get(nameField));
                g.isThisRecord = false;
                out.add(g);
            }
        }
        return out;
    }

    private static Map<Id, List<DocGen_Signer_Visit__c>> visitsFor(Set<Id> requestIds) {
        Map<Id, List<DocGen_Signer_Visit__c>> out = new Map<Id, List<DocGen_Signer_Visit__c>>();
        for (DocGen_Signer_Visit__c v : [
            SELECT Signer__c, Signer__r.Signature_Request__c, Visited_At__c, Last_Seen_At__c, Page_Loads__c, Device__c
            FROM DocGen_Signer_Visit__c
            WHERE Signer__r.Signature_Request__c IN :requestIds AND Device__c != :DocGenSignerVisits.AUTOMATED
            WITH USER_MODE
            ORDER BY Visited_At__c ASC
            LIMIT 5000
        ]) {
            Id req = v.Signer__r.Signature_Request__c;
            if (!out.containsKey(req)) {
                out.put(req, new List<DocGen_Signer_Visit__c>());
            }
            out.get(req).add(v);
        }
        return out;
    }

    private static Map<Id, List<DocGen_Signature_Event__c>> eventsFor(Set<Id> requestIds) {
        Map<Id, List<DocGen_Signature_Event__c>> out = new Map<Id, List<DocGen_Signature_Event__c>>();
        for (DocGen_Signature_Event__c e : [
            SELECT Signature_Request__c, Signer__c, Type__c, Occurred_At__c, Detail__c, Actor__r.Name
            FROM DocGen_Signature_Event__c
            WHERE Signature_Request__c IN :requestIds
            WITH USER_MODE
            ORDER BY Occurred_At__c ASC
            LIMIT 5000
        ]) {
            if (!out.containsKey(e.Signature_Request__c)) {
                out.put(e.Signature_Request__c, new List<DocGen_Signature_Event__c>());
            }
            out.get(e.Signature_Request__c).add(e);
        }
        return out;
    }

    /** When each signer signed or declined: DocGen writes a signature audit for both. */
    private static Map<Id, Datetime> auditTimesFor(Set<Id> requestIds) {
        Map<Id, Datetime> out = new Map<Id, Datetime>();
        for (DocGen_Signature_Audit__c a : [
            SELECT Signer__c, Signed_Date__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c IN :requestIds AND Signer__c != NULL AND Signed_Date__c != NULL
            WITH USER_MODE
            ORDER BY Signed_Date__c ASC
            LIMIT 5000
        ]) {
            out.put(a.Signer__c, a.Signed_Date__c);
        }
        return out;
    }

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
    private static Map<Id, Integer[]> drawingReviewFor(Set<Id> requestIds) {
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

    /** Revokes from before the event log: when the request's status history went to Cancelled. */
    private static Map<Id, Datetime> cancelledTimesFor(List<DocGen_Signature_Request__c> requests) {
        Map<Id, Datetime> out = new Map<Id, Datetime>();
        Set<Id> cancelled = new Set<Id>();
        for (DocGen_Signature_Request__c r : requests) {
            if (r.Status__c == 'Cancelled') {
                cancelled.add(r.Id);
            }
        }
        if (cancelled.isEmpty()) {
            return out;
        }
        try {
            for (
                SObject h : Database.queryWithBinds(
                    'SELECT ParentId, CreatedDate, NewValue FROM DocGen_Signature_Request__History ' +
                    'WHERE ParentId IN :ids AND Field = :field ORDER BY CreatedDate ASC',
                    // The field's API name carries the package namespace once installed.
                    new Map<String, Object>{
                        'ids' => cancelled,
                        'field' => DocGen_Signature_Request__c.Status__c.getDescribe().getName()
                    },
                    AccessLevel.USER_MODE
                )
            ) {
                if (String.valueOf(h.get('NewValue')) == 'Cancelled') {
                    out.put((Id) h.get('ParentId'), (Datetime) h.get('CreatedDate'));
                }
            }
        } catch (Exception e) {
            // No history access: the caller falls back to LastModifiedDate.
            System.debug(LoggingLevel.FINE, 'DocGen: no status history: ' + e.getMessage());
        }
        return out;
    }
}
