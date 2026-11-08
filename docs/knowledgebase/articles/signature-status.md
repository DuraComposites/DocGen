See every signature request on a record at a glance: who has opened their link, how often, and who has signed or declined.

**Before you start:** You are a Salesforce administrator who can edit Lightning record pages. Signers use the public signing page set up in [Set up external signing](#setup-signatures).

#### Add the card to a record page

1. Open a record that has signature requests, such as an Account or an Opportunity.
2. Open Salesforce's **Setup** gear and choose **Edit Page**.
3. Search the component list for **Signature Status** and drag it into a region, for example beside **Portwood Signature Sender**.
4. Click **Save**, then **Activate** for the intended app and profiles.

**You are done when:** The card lists the record's signature requests, newest first.

#### What the card shows

For each request: the document, its status, when it was sent and when the link expires, and a link to the signed PDF once everyone has signed. For each signer, in signing order:

| Line                                               | Meaning                                                                             |
| -------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **Opened 3 times · first 9 Nov, 09:12 · last ...** | Visits to the signing link (see below)                                              |
| **Keeps coming back**                              | Opened three or more times and not yet signed or declined                           |
| **Not opened yet**                                 | The signer hasn't opened their link                                                 |
| **Signed** / **Declined: reason**                  | When they signed, from the signature audit, or the reason they gave                 |
| **Opened 2 of 3 attached documents, marked up 1**  | Drawing approval progress, when documents were [attached](#sign-attached-documents) |
| **2 reminders sent**                               | Automatic reminders, with the last one's time                                       |

**Show visits** lists each visit with its time, the kind of device and how many page loads it covered.

#### What counts as a visit

A visit is recorded when the document is actually on the signer's screen: after the email code, when the request asks for one. Page loads less than 30 minutes apart on the same kind of device are one visit, so a reload or a quick return doesn't inflate the count. Moving from phone to desktop starts a new visit.

Nothing is recorded for internal previews, or once the signer has signed or declined. Email security scanners that open links before the person does are usually not counted: software that doesn't run the page never registers, and recognised scanners are kept but left out of the counts.

The signer record carries the totals as **Visits**, **First Opened** and **Last Opened**, so you can report on them, for example requests opened three or more times and still unsigned after three days.

#### Tell signers

Visits record the time, the kind of device and the browser's user agent. No IP address is kept for visits; the signature audit already keeps that as signing evidence. Using how often someone opens a document to follow up is a purpose beyond the signature itself, so say so: a line on your signing page or in your privacy notice such as "We record when this document is opened." Check the wording with whoever handles data protection.

#### If the card is empty or shows an error

The card runs as the viewing user. **Portwood User** and **Portwood Admin** include what it needs. With your own permission sets, give read access to the Portwood Signature Request, Signer, Signature Audit, Signature Attachment, Signer Attachment and Signer Visit objects, their fields shown above, and the `DocGenSignatureStatusController` Apex class.

Requests are matched on the record they were sent from. A request sent from a different record appears on that record instead.
