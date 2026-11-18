// Dura Composites Ltd.
/**
 * One signer role a DocGen template asks for: output of the "DocGen: Get Template Signers"
 * Flow action (DocGenGetTemplateSignersAction).
 *
 * Top-level, global, @AuraEnabled members and a global no-arg constructor: everything a
 * managed-package type needs to appear as a Flow Apex-Defined variable (see DocGenSigner).
 * Global members can never be removed once released, so this stays at two fields.
 */
global class DocGenTemplateSigner {
    global DocGenTemplateSigner() {
    }

    /** The role from the template's {@Signature_Role...} tag, underscores shown as spaces. */
    @AuraEnabled
    global String role;

    /** The signing order the tag gives (the number in {@Signature_Role:Order:Type}); 1 when absent. */
    @AuraEnabled
    global Integer signingOrder;
}
