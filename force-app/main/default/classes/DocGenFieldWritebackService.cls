// Modified by Dura Composites Ltd.
/**
 * Signer form-field capture, validation, and decoupled record writeback.
 *
 * ─────────────────────────────────────────────────────────────────────────
 * WHY THIS IS A SEPARATE, SYSTEM-CONTEXT SUBSYSTEM
 * ─────────────────────────────────────────────────────────────────────────
 *
 * DocGen e-signing lets an admin configure extra "form fields" on a template
 * (DocGen_Template__c.Form_Fields_Config__c → formFields[]), each optionally mapped
 * to a base-object field. The guest signer fills them in during signing; the
 * values are (a) merged into the re-rendered signed PDF at {?key} positions,
 * (b) optionally listed on the signing certificate, and (c) written back to
 * the base record.
 *
 * The GUEST never performs DML on the base record. The guest only persists the
 * collected values as a validated JSON blob on DocGen_Signer__c.Field_Data_Json__c
 * (inside the existing token-bound, allowlisted guest write boundary — see
 * DocGenSignatureGuestSecurity). A platform event (DocGen_Field_Writeback__e),
 * published by the signature finalizer ONLY after the signed PDF is saved, is
 * consumed by DocGenFieldWritebackTrigger running as the Automated Process user;
 * that subscriber calls performWriteback() in system context.
 *
 * TWO INDEPENDENT SECURITY CONTROLS (both enforced here, neither optional):
 *   1. SERVER-DERIVED ALLOWLIST — the set of writable fields is rebuilt from
 *      the template config at write time (writeback==true). The guest's JSON
 *      keys are NEVER trusted to decide what gets written.
 *   2. PER-FIELD FLS — each target field is re-checked with isUpdateable(), and
 *      the DML runs Database.update(..., allOrNone=false, AccessLevel.USER_MODE)
 *      so the automation user's FLS + validation rules apply. A field the
 *      automation user can't write, or a validation-rule failure, is skipped +
 *      logged to DocGen_Signature_Audit__c and NEVER re-thrown into signing.
 *
 * `global without sharing`: global so subscriber Flows can route writeback via
 * the @InvocableMethod; without sharing because the subscriber runs as the
 * Automated Process user and the base-record write is intentionally a
 * system-context operation gated by USER_MODE FLS, not by record sharing.
 * ─────────────────────────────────────────────────────────────────────────
 */
global without sharing class DocGenFieldWritebackService { // NOPMD AvoidGlobalModifier - global required so subscriber Flows can call writeBackFields
    // Stable id grammar for a form-field key. Mirrors the cross-workstream
    // contract pinned with the frontend: key is [A-Za-z0-9_]+.
    private static final Pattern KEY_PATTERN = Pattern.compile('^[A-Za-z0-9_]+$');

    // Dura: signer file uploads (type 'file'). The page sends the file as base64 through
    // Visualforce remoting; the cap keeps the request and the decoded Blob inside the
    // synchronous heap. 2 MB of file is about 2.8 million base64 characters.
    public static final Integer MAX_UPLOAD_BYTES = 2 * 1024 * 1024;
    private static final Integer MAX_UPLOAD_BASE64 = ((MAX_UPLOAD_BYTES + 2) / 3) * 4;
    // A token holder can upload; this caps how many files one request can collect.
    private static final Integer MAX_UPLOADS_PER_REQUEST = 25;
    // Extensions a file field may accept. A field's "accept" list is narrowed to these;
    // anything a browser could run (html, svg, js) is never accepted.
    private static final Set<String> SAFE_UPLOAD_EXTENSIONS = new Set<String>{
        'pdf',
        'png',
        'jpg',
        'jpeg',
        'gif',
        'tif',
        'tiff',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'csv',
        'txt'
    };
    private static final Pattern CONTENT_VERSION_ID = Pattern.compile('^068[A-Za-z0-9]{12}([A-Za-z0-9]{3})?$');
    // Characters not allowed in an uploaded file name (path separators, Windows-reserved).
    private static final Pattern UNSAFE_FILE_NAME_CHARS = Pattern.compile('[\\\\/:*?"<>|\\r\\n\\t]');

    /**
     * One configured signer form field, parsed from the template's
     * Form_Fields_Config__c formFields[] array.
     */
    public class FormFieldDef {
        public String key;
        public String label;
        public String fieldApiName;
        public String type; // text | number | date | checkbox | picklist | file
        public Boolean required = false;
        public Boolean writeback = false;
        public String mergeTag;
        public List<String> choices = new List<String>();
        public Boolean listOnCertificate = false;
        // Dura: fields sharing a group name are "at least one of": the signer must fill
        // one or more of them (e.g. a PO number or a PO file). Blank = no group.
        public String atLeastOneGroup;
        // Dura: for type 'file', the accepted extensions (lower case, no dot). Default pdf.
        public List<String> accept = new List<String>();
    }

    /**
     * Flow-invocable wrapper input — carries only the request Id. The writeback
     * field allowlist is re-derived from the template config (never from Flow
     * input) so this stays a safe automation entry point.
     */
    global class WritebackRequest {
        @InvocableVariable(
            required=true
            label='Signature Request Id'
            description='The DocGen Signature Request whose collected signer form-field values should be written back to the base record.'
        )
        @AuraEnabled
        global String requestId;

        global WritebackRequest() {
        }
    }

    /**
     * Parses the formFields[] array out of a template Form_Fields_Config__c JSON.
     * Tolerant of missing/blank config (returns an empty list) and of malformed
     * JSON (logs + returns empty) — writeback/merge degrade gracefully rather
     * than break the signing transaction. Unknown / malformed entries are
     * skipped; entries without a grammar-valid key are dropped.
     */
    public static List<FormFieldDef> parseConfig(String queryConfigJson) {
        List<FormFieldDef> defs = new List<FormFieldDef>();
        if (String.isBlank(queryConfigJson)) {
            return defs;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(queryConfigJson);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: form-field config parse failed: ' + e.getMessage());
            return defs;
        }
        if (!(parsed instanceof Map<String, Object>)) {
            return defs;
        }
        Object ffRaw = ((Map<String, Object>) parsed).get('formFields');
        if (!(ffRaw instanceof List<Object>)) {
            return defs;
        }
        for (Object item : (List<Object>) ffRaw) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> row = (Map<String, Object>) item;
            String key = stringVal(row.get('key'));
            if (String.isBlank(key) || !KEY_PATTERN.matcher(key).matches()) {
                // No valid stable id — unusable for capture, merge, or writeback.
                continue;
            }
            FormFieldDef def = new FormFieldDef();
            def.key = key;
            def.label = stringVal(row.get('label'));
            def.fieldApiName = stringVal(row.get('fieldApiName'));
            def.type = normalizeType(stringVal(row.get('type')));
            def.required = boolVal(row.get('required'));
            def.writeback = boolVal(row.get('writeback'));
            def.mergeTag = stringVal(row.get('mergeTag'));
            def.listOnCertificate = boolVal(row.get('listOnCertificate'));
            String grp = stringVal(row.get('atLeastOneGroup'));
            def.atLeastOneGroup = String.isBlank(grp) ? null : grp.trim();
            if (def.type == 'file') {
                def.accept = parseAccept(row.get('accept'));
            }
            Object choicesRaw = row.get('choices');
            if (choicesRaw instanceof List<Object>) {
                for (Object c : (List<Object>) choicesRaw) {
                    if (c != null) {
                        def.choices.add(String.valueOf(c));
                    }
                }
            }
            defs.add(def);
        }
        return defs;
    }

    /**
     * PUBLIC-SAFE projection for the guest signing page (validateToken response).
     * Exposes ONLY {key,label,type,required,choices,listOnCertificate} — never the
     * writeback flag or the base-object field API name (the writeback allowlist is
     * re-derived server-side at completion). listOnCertificate is a presentation
     * flag, not a capability, so the drawn-path client can render it on its
     * Certificate of Completion just like the server cert does.
     */
    public static List<Object> publicFormFields(String queryConfigJson) {
        List<Object> publicDefs = new List<Object>();
        for (FormFieldDef def : parseConfig(queryConfigJson)) {
            publicDefs.add(
                new Map<String, Object>{
                    'key' => def.key,
                    'label' => def.label,
                    'type' => def.type,
                    'required' => def.required,
                    'choices' => def.choices,
                    'listOnCertificate' => def.listOnCertificate,
                    'atLeastOneGroup' => def.atLeastOneGroup,
                    'accept' => def.accept,
                    'maxSizeBytes' => def.type == 'file' ? MAX_UPLOAD_BYTES : null
                }
            );
        }
        return publicDefs;
    }

    /**
     * Validates the guest-supplied {key:value} JSON against the template config:
     *   • enforces `required` (throws AuraHandledException naming the field),
     *   • coerces each value by `type`,
     *   • DROPS unknown keys (anything not in the config),
     * and returns a clean, config-ORDERED map ready to serialize onto
     * DocGen_Signer__c.Field_Data_Json__c. Returns null when there are no
     * configured form fields (caller then writes nothing).
     */
    public static Map<String, Object> validateAndClean(List<FormFieldDef> defs, String incomingJson) {
        if (defs == null || defs.isEmpty()) {
            return null;
        }
        Map<String, Object> incoming = new Map<String, Object>();
        if (String.isNotBlank(incomingJson)) {
            try {
                Object parsed = JSON.deserializeUntyped(incomingJson);
                if (parsed instanceof Map<String, Object>) {
                    incoming = (Map<String, Object>) parsed;
                }
            } catch (Exception e) {
                throw new AuraHandledException('The submitted form data could not be read.');
            }
        }
        // Config-ordered clean map — unknown keys in `incoming` are simply never
        // read, so they are dropped.
        Map<String, Object> clean = new Map<String, Object>();
        for (FormFieldDef def : defs) {
            Object raw = incoming.get(def.key);
            Object coerced = coerceByType(raw, def.type);
            Boolean isEmpty = coerced == null || (coerced instanceof String && String.isBlank((String) coerced));
            if (def.required && isEmpty) {
                String fieldLabel = String.isNotBlank(def.label) ? def.label : def.key;
                throw new AuraHandledException('Please complete the required field: ' + fieldLabel + '.');
            }
            clean.put(def.key, coerced);
        }
        assertAtLeastOneGroups(defs, clean);
        return clean;
    }

    /**
     * Dura: the "at least one of" rule. For every atLeastOneGroup, at least one field in
     * the group must have a value (a ticked checkbox counts; an unticked one does not).
     * Throws AuraHandledException naming the fields, so the signer sees what to fill.
     */
    @TestVisible
    private static void assertAtLeastOneGroups(List<FormFieldDef> defs, Map<String, Object> clean) {
        Map<String, List<FormFieldDef>> groups = new Map<String, List<FormFieldDef>>();
        for (FormFieldDef def : defs) {
            if (String.isBlank(def.atLeastOneGroup)) {
                continue;
            }
            if (!groups.containsKey(def.atLeastOneGroup)) {
                groups.put(def.atLeastOneGroup, new List<FormFieldDef>());
            }
            groups.get(def.atLeastOneGroup).add(def);
        }
        for (String grp : groups.keySet()) {
            Boolean filled = false;
            List<String> labels = new List<String>();
            for (FormFieldDef def : groups.get(grp)) {
                labels.add(String.isNotBlank(def.label) ? def.label : def.key);
                if (hasValue(clean.get(def.key))) {
                    filled = true;
                }
            }
            if (!filled) {
                throw new AuraHandledException('Please complete at least one of: ' + String.join(labels, ', ') + '.');
            }
        }
    }

    private static Boolean hasValue(Object v) {
        if (v instanceof Boolean) {
            return (Boolean) v;
        }
        return v != null && String.isNotBlank(String.valueOf(v));
    }

    /**
     * Dura: saves a file the signer uploaded for a 'file' form field. The caller has
     * already resolved the signer from the token (DocGenSignatureAttachments.resolveSigner:
     * token, expiry, state and email PIN). The file is saved as a ContentVersion published
     * to the signature request only; linkUploadedFiles links it to the related record when
     * the signer completes, so a file from an abandoned or declined signing never reaches
     * the record. Returns the ContentVersion Id the page puts in the field's value.
     */
    public static Map<String, Object> saveUploadedFile(
        DocGen_Signer__c signer,
        String fieldKey,
        String fileName,
        String base64Data
    ) {
        Id requestId = signer.Signature_Request__c;
        FormFieldDef def = null;
        for (FormFieldDef d : parseConfig(templateConfigFor(requestId))) {
            if (d.key == fieldKey && d.type == 'file') {
                def = d;
            }
        }
        if (def == null) {
            return uploadFail('This document does not take a file for that field.');
        }
        String name = String.isBlank(fileName) ? '' : UNSAFE_FILE_NAME_CHARS.matcher(fileName.trim()).replaceAll('_');
        Integer dot = name.lastIndexOf('.');
        String ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
        if (!def.accept.contains(ext)) {
            return uploadFail('Please upload a file of type: ' + String.join(def.accept, ', ').toUpperCase() + '.');
        }
        if (String.isBlank(base64Data)) {
            return uploadFail('The file is empty.');
        }
        if (base64Data.length() > MAX_UPLOAD_BASE64) {
            return uploadFail('The file is too large. The limit is ' + (MAX_UPLOAD_BYTES / (1024 * 1024)) + ' MB.');
        }
        if (ext == 'pdf' && !base64Data.startsWith('JVBERi0')) {
            return uploadFail('That file is not a valid PDF.');
        }
        DocGenFlsGuard.guestAssertAccessible(
            ContentDocumentLink.sObjectType,
            new Set<String>{ 'ContentDocumentId', 'LinkedEntityId' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Integer existing = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :requestId
            WITH SYSTEM_MODE
        ];
        if (existing >= MAX_UPLOADS_PER_REQUEST) {
            return uploadFail('No more files can be added to this request. Contact the sender.');
        }
        Blob data;
        try {
            data = EncodingUtil.base64Decode(base64Data);
        } catch (Exception e) {
            return uploadFail('The file could not be read.');
        }
        String who = String.isNotBlank(signer.Signer_Name__c) ? signer.Signer_Name__c : 'the signer';
        String fieldLabel = String.isNotBlank(def.label) ? def.label : def.key;
        ContentVersion cv = new ContentVersion();
        cv.Title = (dot > 0 ? name.substring(0, dot) : name).left(255);
        cv.PathOnClient = name.left(255);
        cv.VersionData = data;
        cv.FirstPublishLocationId = requestId;
        cv.Description = ('Uploaded by ' + who + ' on the signing page for "' + fieldLabel + '".').left(1000);
        DocGenFlsGuard.guestAssertCreateable(
            cv,
            new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'FirstPublishLocationId', 'Description' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.SaveResult sr = Database.insert(cv, false, AccessLevel.SYSTEM_MODE);
        if (!sr.isSuccess()) {
            DocGenErrorLogger.warn(
                'DocGenFieldWritebackService',
                'Signer file upload',
                'A signer file could not be saved: ' + sr.getErrors()[0].getMessage(),
                null,
                String.valueOf(requestId)
            );
            DocGenErrorLogger.flush();
            return uploadFail('The file could not be saved. Please try again.');
        }
        return new Map<String, Object>{
            'success' => true,
            'contentVersionId' => String.valueOf(cv.Id),
            'fileName' => name
        };
    }

    /**
     * Dura: at completion, checks that every file value in the signer's clean field data
     * is a file uploaded to THIS request (so a signer can't point a field at another
     * file), then links each one to the related record. Linking is best effort: a failure
     * is logged, never thrown, so it can't block signing. Throws only when a value is not
     * a file of this request.
     */
    public static void linkUploadedFiles(
        List<FormFieldDef> defs,
        Map<String, Object> clean,
        Id requestId,
        String relatedRecordId
    ) {
        if (defs == null || clean == null || requestId == null) {
            return;
        }
        Map<Id, String> labelByCv = new Map<Id, String>();
        for (FormFieldDef def : defs) {
            Object v = clean.get(def.key);
            if (def.type == 'file' && hasValue(v)) {
                labelByCv.put((Id) String.valueOf(v), String.isNotBlank(def.label) ? def.label : def.key);
            }
        }
        if (labelByCv.isEmpty()) {
            return;
        }
        Set<Id> cvIds = labelByCv.keySet();
        DocGenFlsGuard.guestAssertAccessible(ContentVersion.sObjectType, new Set<String>{ 'ContentDocumentId' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Map<Id, ContentVersion> cvs = new Map<Id, ContentVersion>(
            [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :cvIds WITH SYSTEM_MODE]
        );
        Set<Id> docIds = new Set<Id>();
        for (ContentVersion cv : cvs.values()) {
            docIds.add(cv.ContentDocumentId);
        }
        DocGenFlsGuard.guestAssertAccessible(
            ContentDocumentLink.sObjectType,
            new Set<String>{ 'ContentDocumentId', 'LinkedEntityId' }
        );
        Set<Id> onRequest = new Set<Id>();
        if (!docIds.isEmpty()) {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            for (ContentDocumentLink l : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE ContentDocumentId IN :docIds AND LinkedEntityId = :requestId
                WITH SYSTEM_MODE
            ]) {
                onRequest.add(l.ContentDocumentId);
            }
        }
        for (Id cvId : cvIds) {
            ContentVersion cv = cvs.get(cvId);
            if (cv == null || !onRequest.contains(cv.ContentDocumentId)) {
                throw new AuraHandledException(
                    'The file for ' + labelByCv.get(cvId) + ' could not be found. Please upload it again.'
                );
            }
        }
        Id recordId;
        try {
            recordId = String.isBlank(relatedRecordId) ? null : (Id) relatedRecordId;
        } catch (Exception badId) {
            recordId = null;
        }
        if (recordId == null) {
            return;
        }
        Set<Id> alreadyLinked = new Set<Id>();
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :docIds AND LinkedEntityId = :recordId
            WITH SYSTEM_MODE
        ]) {
            alreadyLinked.add(l.ContentDocumentId);
        }
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (Id docId : docIds) {
            if (!alreadyLinked.contains(docId)) {
                links.add(
                    new ContentDocumentLink(
                        ContentDocumentId = docId,
                        LinkedEntityId = recordId,
                        ShareType = 'V',
                        Visibility = 'AllUsers'
                    )
                );
            }
        }
        if (links.isEmpty()) {
            return;
        }
        DocGenFlsGuard.guestAssertCreateable(
            links[0],
            new Set<String>{ 'ContentDocumentId', 'LinkedEntityId', 'ShareType', 'Visibility' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        for (Database.SaveResult sr : Database.insert(links, false, AccessLevel.SYSTEM_MODE)) {
            if (!sr.isSuccess()) {
                DocGenErrorLogger.warn(
                    'DocGenFieldWritebackService',
                    'Link signer file to record',
                    'An uploaded file could not be linked to the record: ' + sr.getErrors()[0].getMessage(),
                    null,
                    String.valueOf(requestId)
                );
            }
        }
        DocGenErrorLogger.flush();
    }

    private static String templateConfigFor(Id requestId) {
        DocGenFlsGuard.guestAssertAccessible(DocGen_Signature_Request__c.sObjectType, new Set<String>{ 'Template__c' });
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Form_Fields_Config__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> reqs = [
            SELECT Template__r.Form_Fields_Config__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return reqs.isEmpty() || reqs[0].Template__r == null ? null : reqs[0].Template__r.Form_Fields_Config__c;
    }

    private static Map<String, Object> uploadFail(String message) {
        return new Map<String, Object>{ 'success' => false, 'message' => message };
    }

    /** Accepted extensions for a file field: config list or comma string, narrowed to the safe set. */
    @TestVisible
    private static List<String> parseAccept(Object raw) {
        List<String> parts = new List<String>();
        if (raw instanceof List<Object>) {
            for (Object o : (List<Object>) raw) {
                if (o != null) {
                    parts.add(String.valueOf(o));
                }
            }
        } else if (raw != null) {
            parts.addAll(String.valueOf(raw).split(','));
        }
        List<String> accept = new List<String>();
        for (String part : parts) {
            String e = part.trim().removeStart('.').toLowerCase();
            if (SAFE_UPLOAD_EXTENSIONS.contains(e) && !accept.contains(e)) {
                accept.add(e);
            }
        }
        if (accept.isEmpty()) {
            accept.add('pdf');
        }
        return accept;
    }

    /**
     * Aggregates the collected form-field values across every signer on the
     * request into a single {key:value} map for the finalize re-render.
     * Last-writer-wins (signers ordered by Sort_Order__c; later signers'
     * non-null values override earlier ones). Per-signer distinct fields are
     * out of scope this milestone (documented known limitation). Runs in the
     * async finalize (Automated Process) context — SYSTEM_MODE required.
     */
    public static Map<String, Object> collectValues(Id requestId) {
        Map<String, Object> merged = new Map<String, Object>();
        if (requestId == null) {
            return merged;
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Field_Data_Json__c', 'Signature_Request__c', 'Sort_Order__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        // NOTE: Field_Data_Json__c is a LongTextArea and cannot be filtered in a
        // SOQL WHERE clause, so the null/blank filter is applied in Apex below.
        List<DocGen_Signer__c> signers = [
            SELECT Field_Data_Json__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
        for (DocGen_Signer__c s : signers) {
            if (String.isBlank(s.Field_Data_Json__c)) {
                continue;
            }
            try {
                Object parsed = JSON.deserializeUntyped(s.Field_Data_Json__c);
                if (parsed instanceof Map<String, Object>) {
                    for (String k : ((Map<String, Object>) parsed).keySet()) {
                        Object v = ((Map<String, Object>) parsed).get(k);
                        if (v != null) {
                            merged.put(k, v); // last-writer-wins
                        }
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'DocGen: collectValues parse skip: ' + e.getMessage());
            }
        }
        return merged;
    }

    /**
     * Writes collected signer form-field values back to the base record.
     *
     * SECURITY (see class header): the writable allowlist is rebuilt from the
     * template config (writeback==true), NEVER from the guest JSON keys; each
     * field is re-checked with isUpdateable(); the DML runs USER_MODE with
     * allOrNone=false so the automation user's FLS + validation rules apply and
     * a single failure neither escalates nor strands signing. All failures are
     * logged to DocGen_Signature_Audit__c and swallowed — this method must
     * NEVER re-throw into the signing/finalize path.
     */
    public static void performWriteback(Id requestId) {
        if (requestId == null) {
            return;
        }
        try {
            // 1. Load request → Template config + Related_Record_Id__c.
            DocGenFlsGuard.assertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{ 'Template__c', 'Related_Record_Id__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> reqs = [
                SELECT Related_Record_Id__c, Template__r.Form_Fields_Config__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
            if (reqs.isEmpty()) {
                return;
            }
            DocGen_Signature_Request__c req = reqs[0];
            if (String.isBlank(req.Related_Record_Id__c) || req.Template__r == null) {
                return; // capture-only template or no base record — nothing to write.
            }

            List<FormFieldDef> defs = parseConfig(req.Template__r.Form_Fields_Config__c);
            // 2. Allowlist = config fields where writeback==true AND a base field
            //    is mapped. NEVER derived from the guest JSON keys.
            Map<String, FormFieldDef> writebackDefs = new Map<String, FormFieldDef>();
            for (FormFieldDef def : defs) {
                if (def.writeback && String.isNotBlank(def.fieldApiName)) {
                    writebackDefs.put(def.key, def);
                }
            }
            if (writebackDefs.isEmpty()) {
                return;
            }

            // Writeback is single-signer only. On a multi-signer request every signer
            // fills the same template-scoped fields, so there is no unambiguous single
            // value to write (collectValues would merge them last-writer-wins). Skip the
            // record write — capture + per-signer certificate attribution still happen.
            DocGenFlsGuard.assertAccessible(DocGen_Signer__c.sObjectType, new Set<String>{ 'Signature_Request__c' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Integer signerCount = [
                SELECT COUNT()
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :requestId
                WITH SYSTEM_MODE
            ];
            if (signerCount > 1) {
                logWritebackError(
                    requestId,
                    'Form-field writeback skipped — multi-signer request (' +
                        signerCount +
                        ' signers); writeback applies to single-signer requests only.'
                );
                return;
            }

            Map<String, Object> values = collectValues(requestId);
            if (values.isEmpty()) {
                return;
            }

            Id recordId;
            try {
                recordId = (Id) req.Related_Record_Id__c;
            } catch (Exception badId) {
                logWritebackError(requestId, 'Invalid Related Record Id for writeback: ' + badId.getMessage());
                return;
            }
            SObjectType targetType = recordId.getSObjectType();
            Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();

            SObject record = targetType.newSObject(recordId);
            Boolean anySet = false;
            for (String key : writebackDefs.keySet()) {
                FormFieldDef def = writebackDefs.get(key);
                if (!values.containsKey(key)) {
                    continue;
                }
                Schema.SObjectField sof = fieldMap.get(def.fieldApiName.toLowerCase());
                if (sof == null) {
                    logWritebackError(requestId, 'Writeback target field not found: ' + def.fieldApiName);
                    continue;
                }
                Schema.DescribeFieldResult dfr = sof.getDescribe();
                // 3. Per-field FLS re-check (defense in depth alongside USER_MODE).
                if (!dfr.isUpdateable()) {
                    logWritebackError(requestId, 'Writeback target field not updateable: ' + def.fieldApiName);
                    continue;
                }
                try {
                    Object typed = coerceForDisplayType(values.get(key), dfr.getType());
                    record.put(sof, typed);
                    anySet = true;
                } catch (Exception coerceEx) {
                    logWritebackError(
                        requestId,
                        'Writeback coercion failed for ' + def.fieldApiName + ': ' + coerceEx.getMessage()
                    );
                }
            }

            if (!anySet) {
                return;
            }

            // 4. USER_MODE + allOrNone=false: automation user's FLS + validation
            //    rules apply; partial success is allowed.
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.SaveResult sr = Database.update(record, false, AccessLevel.USER_MODE);
            if (!sr.isSuccess()) {
                List<String> msgs = new List<String>();
                for (Database.Error err : sr.getErrors()) {
                    msgs.add(err.getStatusCode() + ': ' + err.getMessage());
                }
                logWritebackError(requestId, 'Writeback DML failed: ' + String.join(msgs, '; '));
            }
        } catch (Exception e) {
            // 5. NEVER re-throw into the signing/finalize path.
            logWritebackError(requestId, e.getTypeName() + ': ' + e.getMessage());
        }
    }

    /**
     * Flow-invocable entry point so an admin can route writeback through a
     * record-triggered Flow instead of the auto-subscriber. Carries only the
     * request Id; the allowlist is re-derived server-side.
     */
    @InvocableMethod(
        label='DocGen: Write Back Signer Form Fields'
        description='Writes the collected signer form-field values for a completed signature request back to its related record. The writable fields are re-derived from the template config; failures are logged, never thrown.'
        category='Document Generation'
    )
    global static void writeBackFields(List<WritebackRequest> requests) {
        if (requests == null) {
            return;
        }
        for (WritebackRequest r : requests) {
            if (r != null && String.isNotBlank(r.requestId)) {
                try {
                    performWriteback((Id) r.requestId);
                } catch (Exception e) {
                    // Defensive: performWriteback already swallows, but a bad Id
                    // cast here must not break the Flow / event batch.
                    System.debug(LoggingLevel.WARN, 'DocGen: writeBackFields skip: ' + e.getMessage());
                }
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────────────

    /**
     * Coerces a raw JSON value to the form-field config `type` for capture/merge
     * (text|number|date|checkbox|picklist). Returns the cleaned value or null.
     */
    @TestVisible
    private static Object coerceByType(Object raw, String type) {
        if (raw == null) {
            return null;
        }
        String s = String.valueOf(raw).trim();
        if (String.isBlank(s)) {
            return type == 'checkbox' ? (Object) false : null;
        }
        if (type == 'number') {
            try {
                return Decimal.valueOf(s);
            } catch (Exception e) {
                throw new AuraHandledException('"' + s + '" is not a valid number.');
            }
        } else if (type == 'checkbox') {
            return s.equalsIgnoreCase('true') || s == '1' || s.equalsIgnoreCase('yes') || s.equalsIgnoreCase('on');
        } else if (type == 'file') {
            // The value is the ContentVersion Id saveUploadedFile returned. Shape only here;
            // linkUploadedFiles checks it belongs to this request.
            if (!CONTENT_VERSION_ID.matcher(s).matches()) {
                throw new AuraHandledException('The uploaded file reference is not valid. Please upload it again.');
            }
            return String.valueOf((Id) s);
        } else if (type == 'date') {
            try {
                // Accept ISO yyyy-MM-dd (native HTML date input) — validate by parse.
                Date.valueOf(s);
                return s;
            } catch (Exception e) {
                throw new AuraHandledException('"' + s + '" is not a valid date.');
            }
        }
        // text | picklist | unknown — store as trimmed string.
        return s;
    }

    /**
     * Coerces a captured value to the target base-field Schema.DisplayType for
     * writeback DML. Conservative — supports the common scalar types; anything
     * unhandled falls through to the String form and lets USER_MODE DML reject
     * it (logged, not thrown).
     */
    @TestVisible
    private static Object coerceForDisplayType(Object value, Schema.DisplayType dt) {
        if (value == null) {
            return null;
        }
        String s = String.valueOf(value).trim();
        if (dt == Schema.DisplayType.DOUBLE || dt == Schema.DisplayType.CURRENCY || dt == Schema.DisplayType.PERCENT) {
            return String.isBlank(s) ? null : Decimal.valueOf(s);
        } else if (dt == Schema.DisplayType.INTEGER) {
            // INTEGER fields reject a Long assignment ("Illegal assignment from Long
            // to Integer"); coerce to Integer explicitly.
            return String.isBlank(s) ? null : Integer.valueOf(Decimal.valueOf(s).intValue());
        } else if (dt == Schema.DisplayType.LONG) {
            return String.isBlank(s) ? null : Long.valueOf(s);
        } else if (dt == Schema.DisplayType.BOOLEAN) {
            return value instanceof Boolean
                ? (Boolean) value
                : (s.equalsIgnoreCase('true') || s == '1' || s.equalsIgnoreCase('yes'));
        } else if (dt == Schema.DisplayType.DATE) {
            return String.isBlank(s) ? null : Date.valueOf(s);
        } else if (dt == Schema.DisplayType.DATETIME) {
            return String.isBlank(s) ? null : (Object) Datetime.valueOf(s.replace('T', ' '));
        }
        // STRING/TEXTAREA/PICKLIST/EMAIL/PHONE/URL/REFERENCE/etc. — string form.
        return s;
    }

    private static String normalizeType(String type) {
        if (String.isBlank(type)) {
            return 'text';
        }
        String t = type.trim().toLowerCase();
        if (t == 'text' || t == 'number' || t == 'date' || t == 'checkbox' || t == 'picklist' || t == 'file') {
            return t;
        }
        return 'text';
    }

    private static String stringVal(Object o) {
        return o == null ? null : String.valueOf(o);
    }

    private static Boolean boolVal(Object o) {
        if (o instanceof Boolean) {
            return (Boolean) o;
        }
        return o != null && String.valueOf(o).equalsIgnoreCase('true');
    }

    /**
     * Logs a writeback failure to DocGen_Signature_Audit__c. Best-effort —
     * swallows its own errors so a logging failure can never escalate.
     */
    private static void logWritebackError(Id requestId, String message) {
        System.debug(LoggingLevel.ERROR, 'DocGen: writeback error (req ' + requestId + '): ' + message);
        // ALSO to DocGen_Error_Log__c, not only to the signature audit trail.
        // Writeback failures used to land exclusively on
        // DocGen_Signature_Audit__c.Error_Message__c, so "check the Error Log"
        // genuinely did not find them and nothing said so. The audit row stays —
        // it is the tamper-evident record for that request — but the error log
        // is where someone debugging actually looks.
        DocGenErrorLogger.warn(
            'DocGenFieldWritebackService',
            'Form-field writeback',
            'Writeback did not complete: ' + message,
            null,
            String.valueOf(requestId)
        );
        DocGenErrorLogger.flush();
        try {
            DocGen_Signature_Audit__c errAudit = new DocGen_Signature_Audit__c();
            errAudit.Signature_Request__c = requestId;
            errAudit.Signer_Name__c = 'SYSTEM (writeback)';
            errAudit.Error_Message__c = message != null ? message.left(32768) : null;
            errAudit.Signed_Date__c = System.now();
            DocGenFlsGuard.assertCreateable(
                errAudit,
                new Set<String>{ 'Signature_Request__c', 'Signer_Name__c', 'Error_Message__c', 'Signed_Date__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.insert(new List<DocGen_Signature_Audit__c>{ errAudit }, false, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: writeback audit log failed: ' + e.getMessage());
        }
    }
}
