// Modified by Dura Composites Ltd.
/** Run after the originating transaction commits, outside trigger rendering. */
public with sharing class KBGenerateAccountBrief implements Queueable, Database.AllowsCallouts {
    private Id recordId;
    public KBGenerateAccountBrief(Id recordId) {
        this.recordId = recordId;
    }
    public void execute(QueueableContext context) {
        Id templateId = [
            SELECT Id
            FROM duracomp__DocGen_Template__c
            WHERE duracomp__API_Name__c = 'KB_Account_Brief' AND duracomp__Is_Active__c = TRUE
            WITH USER_MODE
            LIMIT 1
        ]
        .Id;
        // The global service renders first and then saves the File on the Account.
        Id fileId = duracomp.DocGenService.generateDocument(templateId, recordId, 'PDF');
        System.debug(LoggingLevel.INFO, 'Created Account brief File: ' + fileId);
        // In a real process, persist success or handle failure in your job-monitoring design.
    }
}
