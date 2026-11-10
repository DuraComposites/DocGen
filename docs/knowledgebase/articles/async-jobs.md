<!-- Modified by Dura Composites Ltd. -->

An accepted background job is not a finished document. Store the returned **Job ID** and wait for the job's terminal state before using a File or telling someone generation is complete.

#### Read the actual job record

In subscriber Apex and Flow, use **DocGen Job** (`duracomp__DocGen_Job__c`) with the access granted to the running user. These are useful API fields:

| Field                                                    | Meaning                                       |
| -------------------------------------------------------- | --------------------------------------------- |
| `duracomp__Status__c`                                    | Persisted job state                           |
| `duracomp__Total_Records__c`                             | Intended record count                         |
| `duracomp__Success_Count__c`, `duracomp__Error_Count__c` | Outcome counts                                |
| `duracomp__Error_Log__c`                                 | Recorded error details                        |
| `duracomp__Merged_PDF_CV__c`                             | Combined output ContentVersion, when produced |

```apex
duracomp__DocGen_Job__c job = [
    SELECT duracomp__Status__c, duracomp__Success_Count__c,
        duracomp__Error_Count__c, duracomp__Merged_PDF_CV__c,
        duracomp__Error_Log__c
    FROM duracomp__DocGen_Job__c
    WHERE Id = :jobId WITH USER_MODE LIMIT 1
];
```

`DocGenBulkController.getJobStatus()` is a package-internal UI endpoint, not a subscriber Apex API. Use the job record or your own authorized wrapper around its query.

#### Distinguish persisted states from screen labels

**Draft**, **Harvesting**, **Processing**, **Stitching**, and **Merging** describe preparation or work still in progress. **Completed**, **Completed with Errors**, and **Failed** are terminal outcomes; inspect counts and logs before deciding whether your business process succeeded. Some screens can use friendlier progress labels; do not build a status comparison against a word that is not actually stored on the record.

A completed individual-file run may have no combined output Id. Giant-query recovery can launch separate child jobs; the original batch's terminal status does not mean every recovery child has finished.

#### Refresh in a screen Flow

1. **Get Records** for the returned Job ID.
2. Use a **Decision** for Completed, Completed with Errors, and Failed.
3. For a nonterminal state, show a **Screen** containing the status and a **Refresh** navigation choice.
4. Connect the refresh route back to Get Records so it re-reads the job.
5. Provide an exit choice; the user does not need to keep a browser open for the job to run.

Do not create a tight Get Records/Decision loop with no screen or asynchronous boundary. It repeats in one transaction and can consume the query limit without giving the background job time to finish.

Screen Flows do not support a Wait element. For unattended processing, choose an automation pattern compatible with its Flow type, such as a record-triggered Flow on the job's completion update, or an autolaunched Flow with a supported Wait configuration. A record-triggered Flow does not simply gain a generic Wait element; check Salesforce's [Flow types](https://help.salesforce.com/s/articleView?id=sf.flow_concepts_type.htm&language=en_US&type=5) and [Wait considerations](https://help.salesforce.com/s/articleView?id=platform.flow_considerations_design_pause.htm&language=en_US&type=5).

#### Handle partial success and recovery

For supported Individual Files runs, oversized records can be queued for giant-query recovery. The current batch caps automatic recovery at **100 records** and records any overflow for manual handling. A combined packet is not automatically reconstructed from recovery results. Confirm the correct parent/child job outputs before retrying failed records; rerunning the whole original filter can duplicate successful Files.
