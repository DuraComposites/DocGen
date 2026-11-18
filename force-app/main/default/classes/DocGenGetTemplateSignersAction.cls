// Dura Composites Ltd.
/**
 * Flow action "DocGen: Get Template Signers": the signer roles a template asks for, so a
 * send flow can build one signer row per role without anyone placing signature boxes.
 *
 * In: a template Id or its API Name. Out: the roles from the template's
 * {@Signature_Role:Order:Type} tags, deduplicated and in signing order, as DocGenTemplateSigner
 * { role, signingOrder }; and whether the template has a {#Signatures} repeating block (the
 * flow may then add more signers).
 *
 * Reuses DocGenSignatureSenderController's tag parsing (the same code the sender and the
 * send paths use). Global members are permanent in a managed package, so the surface is
 * kept to two inputs and two outputs.
 */
global with sharing class DocGenGetTemplateSignersAction { // NOPMD AvoidGlobalModifier - required for @InvocableMethod visibility in subscriber orgs
    global class Request {
        global Request() {
        }

        @InvocableVariable(
            label='Template Id'
            description='The Id of a DocGen Template. Provide this OR Template API Name.'
        )
        global Id templateId;

        @InvocableVariable(
            label='Template API Name'
            description='The template\'s API Name field, a stable key that survives sandbox-to-production deploys. Provide this OR Template Id.'
        )
        global String templateApiName;
    }

    global class Result {
        global Result() {
        }

        @InvocableVariable(
            label='Signers'
            description='One DocGen Template Signer per role in the template, in signing order: Role and Signing Order.'
        )
        global List<DocGenTemplateSigner> signers;

        @InvocableVariable(
            label='Has Signatures Block'
            description='True when the template has a {#Signatures} repeating block, so the document can take more signers than its fixed roles.'
        )
        global Boolean hasSignaturesBlock;
    }

    @InvocableMethod(
        label='DocGen: Get Template Signers'
        description='Returns the signer roles a DocGen template asks for ({@Signature_Role:Order:Type} tags), deduplicated and in signing order, and whether it has a {#Signatures} repeating block.'
        category='Document Generation'
    )
    global static List<Result> getSigners(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(describe(req));
        }
        return results;
    }

    private static Result describe(Request req) {
        Id templateId = req == null ? null : req.templateId;
        if (templateId == null && req != null && String.isNotBlank(req.templateApiName)) {
            templateId = DocGenService.templateIdByApiName(req.templateApiName.trim());
        }
        if (templateId == null) {
            throw new DocGenException('Pass a DocGen Template Id or Template API Name.');
        }
        DocGenSignatureSenderController.TemplateSignatureSummary summary = DocGenSignatureSenderController.describeTemplateSignatures(
            templateId
        );
        Result res = new Result();
        res.hasSignaturesBlock = summary.hasSignaturesBlock;
        res.signers = toSigners(summary.placements);
        return res;
    }

    /**
     * One signer per role. A role's order is the lowest order among its tags; roles with the
     * same order keep the order they first appear in. Placements arrive sorted by order.
     */
    @TestVisible
    private static List<DocGenTemplateSigner> toSigners(
        List<DocGenSignatureSenderController.PlacementInfo> placements
    ) {
        Map<String, DocGenTemplateSigner> byRole = new Map<String, DocGenTemplateSigner>();
        List<String> firstSeen = new List<String>();
        for (DocGenSignatureSenderController.PlacementInfo p : placements) {
            if (p == null || String.isBlank(p.role)) {
                continue;
            }
            String key = p.role.toLowerCase();
            DocGenTemplateSigner s = byRole.get(key);
            if (s == null) {
                s = new DocGenTemplateSigner();
                s.role = p.role;
                s.signingOrder = p.sequence;
                byRole.put(key, s);
                firstSeen.add(key);
            } else if (p.sequence != null && (s.signingOrder == null || p.sequence < s.signingOrder)) {
                s.signingOrder = p.sequence;
            }
        }
        List<DocGenTemplateSigner> ordered = new List<DocGenTemplateSigner>();
        for (String key : firstSeen) {
            DocGenTemplateSigner s = byRole.get(key);
            Integer at = ordered.size();
            while (at > 0 && ordered[at - 1].signingOrder > s.signingOrder) {
                at--;
            }
            if (at == ordered.size()) {
                ordered.add(s);
            } else {
                ordered.add(at, s);
            }
        }
        return ordered;
    }
}
