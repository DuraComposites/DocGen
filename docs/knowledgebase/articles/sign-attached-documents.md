Some approvals are about documents that already exist: a set of engineering drawings on an Issued Drawing record, a specification, a site survey. You can show those PDFs to signers **alongside** the signing template, without re-generating or merging them. The template becomes the approval form ("I approve the drawings listed below"), and each attached PDF is shown as its own document on the signing page.

**Turning it on.** Attached documents are off until a template opts in. In Command Hub → My Templates, edit the approval template and set **Attached Documents (e-sign)**:

- **Off** (the default): no attached documents. Senders see no change.
- **Optional**: the sender may attach PDFs from the record.
- **Required**: every send of this template must attach at least one. Use this for an approval form that means nothing without its drawings.

The setting is enforced for the Signature Sender and the Flow action alike. A template set to Required can't be sent in a multi-template packet.

Attached documents need **Decline** available, because the signer approves or declines what they reviewed. A send with attached documents is refused while **Hide Decline Button** is on, either on the template or org-wide in Signature Settings, and the template editor warns about it.

**Sending.** In the Signature Sender, pick a template that takes attached documents. An **Attach PDFs from this record** list appears: tick the files (or **Select all**) and choose whether they come **Before** or **After** the template. For a Required template, **Send** stays disabled until at least one is ticked. **Preview** lists the attached documents in the order signers will see them, and **View files** opens them in Salesforce's file viewer. From Flow, pass **Attached Documents** (ContentDocument or ContentVersion Ids) and, optionally, **Attached Documents Position** to **Portwood: Create Signature Request**.

**Pinning.** Each file is pinned to the exact version it had at send time. Uploading a new version later doesn't change what the signer sees; to send the new revision, send a new request. If a pinned file is deleted, or its content no longer matches, the signer is told to contact the sender instead of being shown something else.

**Signing.** The signing page adds a banner saying how many attached documents there are to review, with an **Open the next one** button, and a row of tabs: one per attached document, plus one for the template marked **Sign here**. Each tab shows whether its document has been opened (and a pen mark once the signer has marked it up, [markup](#sign-markup)). With many documents the tabs scroll sideways, and the arrow keys move between them. Once every document is open, the banner shrinks to a single line. Attached documents load one at a time, straight from the record. Signers drag to move around a drawing and zoom with Ctrl + scroll, a trackpad or touch-screen pinch, or the + / − / Fit buttons; only the drawing zooms, not the page around it. **The signer must open every attached document, then confirm they reviewed them, before they can finish signing.** The confirmation is a tick box at the final step ("I confirm I have reviewed the N attached documents"), and it can only be recorded once every document has been opened. The page enforces both, and so does the server: a signature submitted with an unopened attachment, or without the confirmation, is refused. Decline is always available on these requests, even if Decline is hidden after the request was sent, so a signer who finds a problem with a drawing can decline with a reason without opening the rest. If they decline before opening every document, the decline screen lists each document as opened, marked up or not opened, and offers **Review the rest first** before **Decline anyway**. The sender's decline email then says which documents the signer opened.

**The signed PDF** is the approval record: the template pages with the signatures, then an **Attached Documents** register, then the Certificate of Completion. The register lists every attached document with its version, size, SHA-256 fingerprint and who opened it when, followed by each signer's review confirmation and its time. The confirmation records what the signer confirmed; it does not show that every page was read. The attached PDFs themselves are not merged into the signed copy. They stay unchanged on the record, and the fingerprint ties the approval to their exact bytes: anyone can hash a file and compare.

**Limits and rules:**

- PDFs only, attached to the request's related record, and visible to the sender.
- By default, up to **100** attached documents per request, **20 MB** each and **200 MB** in total. Change these in **Signature Settings → Attached Documents** (up to 200 documents and 50 MB each). Each document downloads to the signer in one piece; sizes above 20 MB are untested.
- Single-template sends only (not packets). Not available for templates that sign through a `{#Signatures}` loop block; use `{@Signature_…}` tags, or no signature tags at all.
- Requests with attached documents always finalize on the signing page itself; the server-side re-render fallback is not used for them.
- Guest access to the attached documents goes through the Site's Apex REST endpoint (`/services/apexrest/…/signature-attachment`), keyed by the signer's own link token and gated by the same email PIN, expiry and status rules as the signing page. The **Portwood Guest Signature** permission set grants the class access it needs.
- **Where to see it.** A signature request's **Signature Attachments** related list shows what was attached: title, version, position and SHA-256. Each signer's **Signer Attachments** related list shows when each document was delivered to them and when they opened it, and the signer's **Attached Documents Reviewed At** field shows when they confirmed their review.
- **Your own permission sets?** If you use your own permission sets instead of Portwood's:
    - give senders create and read on Portwood Signature Attachment and Portwood Signer Attachment;
    - give admins edit on the template's Attached Documents field, and on the three Attached Documents limit fields in Portwood Settings;
    - give the Site guest user access to the `DocGenSignatureAttachmentRest` Apex class.

    Sends without attached documents need none of these.
