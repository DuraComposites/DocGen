<!-- Modified by Dura Composites Ltd. -->

See every signature request on a record as a timeline: when it was sent, who opened it and when, reminders, resends, and how it ended.

**Before you start:** You are a Salesforce administrator who can edit Lightning record pages. Signers use the public signing page set up in [Set up external signing](#setup-signatures).

#### Add the card to a record page

1. Open a record that has signature requests, such as a Quote.
2. Open Salesforce's **Setup** gear and choose **Edit Page**.
3. Search the component list for **Signature Status** and drag it into a region. A sidebar column suits it.
4. Click **Save**, then **Activate** for the intended app and profiles.

**You are done when:** The card lists the record's signature requests, newest first.

#### See the requests on related records

On a parent record you can list the requests sent from its child records too, for example every quote on an Opportunity. Select the card in Lightning App Builder and fill in **Also show requests on related records** with the child object and its lookup to this record:

| Page        | Setting                                |
| ----------- | -------------------------------------- |
| Opportunity | `SBQQ__Quote__c.SBQQ__Opportunity2__c` |
| Account     | `Contact.AccountId`                    |

Separate several with commas. The card then groups requests under each related record, one line each; open one to see its timeline.

#### What the card shows

Each request has a status, the people it went to and a one-line summary, such as **Last opened 9 Nov, 16:40**. The newest request on a record opens its timeline straight away; open older ones with **Show timeline**.

| Timeline entry                           | Where it comes from                                      |
| ---------------------------------------- | -------------------------------------------------------- |
| **Sent to ...**                          | When the request was created                             |
| **... opened · phone / desktop**         | A visit to the signing link (see below)                  |
| **Reminder sent to ...**                 | Each automatic reminder                                  |
| **Link resent to ... by ...**            | **Resend** in the Signature Sender, and who used it      |
| **Revoked by ...**                       | **Revoke**, and who used it                              |
| **... signed** / **... declined: "..."** | The signature audit, with the reason given for a decline |
| **Link expired**                         | The link's expiry, if nobody finished first              |
| **... tried to open the expired link**   | The signer came back after the link lapsed               |
| **Link extended to ... by ...**          | Someone extended or reopened the link (see below)        |
| **Reminders every ... by ...**           | Someone changed or stopped the reminders                 |
| **Waiting on ...**                       | Who still has to sign, and how long since it was sent    |

Until a request is finished, a line under the summary gives its plan, such as **Link expires 22 Nov · Reminders every 2 days until 20 Nov**, with **Extend link** and **Reminders** to change it. See [Set link expiry and reminders](#signature-expiry-reminders).

For drawing approvals, a line under the timeline says how many attached documents each signer opened and marked up.

Requests sent before these entries were recorded show what DocGen kept at the time: the latest reminder only, and the time of a revoke from the request's history.

#### What counts as a visit

A visit is recorded when the document is actually on the signer's screen: after the email code, when the request asks for one. Page loads less than 30 minutes apart on the same kind of device are one visit, so a reload or a quick return doesn't inflate the count. Moving from phone to desktop starts a new visit.

Nothing is recorded for internal previews, or once the signer has signed or declined. Email security scanners that open links before the person does are usually not counted: software that doesn't run the page never registers, and recognised scanners are kept but left out of the counts.

The signer record carries the totals as **Visits**, **First Opened** and **Last Opened**, and each request has a **Signature Events** related list, so you can report on both.

#### Tell signers

Visits record the time, the kind of device and the browser's user agent. No IP address is kept for visits; the signature audit already keeps that as signing evidence. Using how often someone opens a document to follow up is a purpose beyond the signature itself, so say so: a line on your signing page or in your privacy notice such as "We record when this document is opened." Check the wording with whoever handles data protection.

#### If the card is empty or shows an error

The card runs as the viewing user. **DocGen User** and **DocGen Admin** include what it needs. With your own permission sets, give read access to the DocGen Signature Request, Signer, Signature Audit, Signature Attachment, Signer Attachment, Signer Visit and Signature Event objects, the fields the card shows, and the `DocGenSignatureStatusController` Apex class. To extend links and change reminders, also give the **Change Sent Signature Requests** custom permission.

Requests are matched on the record they were sent from. A request sent from another record appears on that record, or under it on a parent page set up as above.
