/**
 * Copyright Dura Composites Ltd. Licensed under the Apache License, Version 2.0.
 *
 * Test helper: proves the DocGen User permission set can do what the sender-side code asks for.
 *
 * DocGenFlsGuard skips the field-level verdict in tests, so a field missing from DocGen_User used
 * to pass every test and fail only in a real org ("Insufficient FLS to create
 * DocGen_Signature_Request__c.Render_Data_Snapshot__c" for the first salesperson to send).
 *
 * Usage, around a call that a DocGen User makes (send, resend, cancel, in-person verification):
 *   DocGenSenderAccessCheck.start();
 *   ...the call...
 *   DocGenSenderAccessCheck.assertDocGenUserCovers('what was called');
 *
 * It compares every DocGen object and field the guard checked with the object and field
 * permissions of DocGen_User (this package's copy), and fails listing what is missing. Standard
 * objects (ContentVersion and the like) and fields that cannot carry field permissions
 * (master-detail, required, formula) are skipped.
 */
@IsTest
public class DocGenSenderAccessCheck {
    public static void start() {
        DocGenFlsGuard.recordedChecks = new Set<String>();
    }

    public static void assertDocGenUserCovers(String context) {
        Set<String> checks = DocGenFlsGuard.recordedChecks;
        DocGenFlsGuard.recordedChecks = null;
        Assert.isTrue(checks != null && !checks.isEmpty(), context + ': the guard recorded nothing');
        List<String> missing = missingFor('DocGen_User', checks);
        Assert.isTrue(
            missing.isEmpty(),
            context + ': the DocGen User permission set is missing ' + String.join(missing, ', ')
        );
    }

    @TestVisible
    private static List<String> missingFor(String permissionSetName, Set<String> checks) {
        String ns = namespace();
        Set<String> granted = new Set<String>();
        for (ObjectPermissions op : [
            SELECT SobjectType, PermissionsRead, PermissionsCreate, PermissionsEdit, Parent.NamespacePrefix
            FROM ObjectPermissions
            WHERE Parent.Name = :permissionSetName
        ]) {
            if (!sameNamespace(op.Parent.NamespacePrefix, ns)) {
                continue;
            }
            if (op.PermissionsRead) {
                granted.add('read:' + op.SobjectType);
            }
            if (op.PermissionsCreate) {
                granted.add('create:' + op.SobjectType);
            }
            if (op.PermissionsEdit) {
                granted.add('edit:' + op.SobjectType);
            }
        }
        for (FieldPermissions fp : [
            SELECT Field, PermissionsRead, PermissionsEdit, Parent.NamespacePrefix
            FROM FieldPermissions
            WHERE Parent.Name = :permissionSetName
        ]) {
            if (!sameNamespace(fp.Parent.NamespacePrefix, ns)) {
                continue;
            }
            if (fp.PermissionsRead) {
                granted.add('read:' + fp.Field);
            }
            if (fp.PermissionsEdit) {
                granted.add('create:' + fp.Field);
                granted.add('edit:' + fp.Field);
            }
        }

        Map<String, Schema.SObjectType> globalTypes = Schema.getGlobalDescribe();
        List<String> missing = new List<String>();
        for (String check : checks) {
            String target = check.substringAfter(':');
            String objectName = target.substringBefore('.');
            if (!objectName.contains('DocGen_') || !objectName.endsWith('__c')) {
                continue;
            }
            if (target.contains('.')) {
                Schema.SObjectType sot = globalTypes.get(objectName.toLowerCase());
                Schema.SObjectField f = sot == null
                    ? null
                    : sot.getDescribe().fields.getMap().get(target.substringAfter('.').toLowerCase());
                if (f == null || !f.getDescribe().isPermissionable()) {
                    continue;
                }
            }
            if (!granted.contains(check)) {
                missing.add(check);
            }
        }
        missing.sort();
        return missing;
    }

    private static String namespace() {
        String name = DocGen_Signer__c.SObjectType.getDescribe().getName();
        return name.contains('__DocGen_') ? name.substringBefore('__DocGen_') : null;
    }

    private static Boolean sameNamespace(String a, String b) {
        return (String.isBlank(a) && String.isBlank(b)) || a == b;
    }

    @IsTest
    static void reportsWhatIsMissing() {
        Set<String> checks = new Set<String>{
            'read:' + DocGen_Signature_Request__c.SObjectType.getDescribe().getName(),
            'create:Account.Name',
            'edit:' +
            DocGen_Signer__c.SObjectType.getDescribe().getName() +
            '.Not_A_Field__c'
        };
        List<String> missing = missingFor('DocGen_User', checks);
        Assert.areEqual(
            0,
            missing.size(),
            'DocGen User reads requests; standard objects and unknown fields are skipped'
        );

        missing = missingFor('No_Such_Permission_Set', checks);
        Assert.areEqual(1, missing.size(), String.join(missing, ', '));
    }
}
