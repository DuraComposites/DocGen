// Dura Composites Ltd.
/**
 * One signer input a DocGen template defines (Form_Fields_Config__c): output of the
 * "DocGen: Get Template Signers" Flow action, so a send screen can let the sender choose
 * which inputs each person fills (DocGenSigner.formFieldKeys).
 *
 * Top-level, global, @AuraEnabled members and a global no-arg constructor: what a managed
 * type needs to be a Flow Apex-Defined variable. Global members are permanent, so this
 * carries only what a send screen needs.
 */
global class DocGenTemplateField {
    global DocGenTemplateField() {
    }

    /** The input's key, as used in DocGenSigner.formFieldKeys and {?key} merge tags. */
    @AuraEnabled
    global String key;

    /** The label the signer sees. */
    @AuraEnabled
    global String label;

    /** True when the template marks the input as required for whoever is asked it. */
    @AuraEnabled
    global Boolean required;

    /** True when the answer is written back to the record: give it to only one signer. */
    @AuraEnabled
    global Boolean writesBack;
}
