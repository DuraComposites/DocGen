<!-- Modified by Dura Composites Ltd. -->

Signers can mark up the attached documents on the signing page: draw on a drawing, highlight, box an area, add an arrow or a revision cloud, and type notes. Each signer's marked-up copy of a document is saved to the related record as a new file. The attached originals are never changed.

**Turning it on.** In Command Hub → My Templates, edit a template that takes attached documents and set **Attached Document Markup (e-sign)**:

- **Off** (the default): no markup. The signing page shows the documents only.
- **Decline only (approvals are as-is)**: markups go with a decline. Once a signer has marked anything up, they can't approve until they clear their marks ("Clear your marks to approve"), and Decline becomes the main button ("Decline with markups"). Use this when an approval must mean "approved exactly as drawn".
- **Approve (with or without comments) or decline**: markups can go with either outcome. An approval that carries markups is **approved with comments**: in construction, "approved as noted" or Status B, meaning go ahead but incorporate the comments. There is no extra status; the request is still approved or declined, and you can tell the two kinds of approval apart (see below).

**The tools.** A toolbar sits above the drawing. Hover over a button for its name and shortcut key.

| Tool               | Key                          | What it does                                                                                    |
| ------------------ | ---------------------------- | ----------------------------------------------------------------------------------------------- |
| Select             | V                            | Click a mark to select it, then move it, delete it or change its colour or width                |
| Pan                | H                            | Drag to move around the drawing (the default)                                                   |
| Pen                | P                            | Freehand drawing                                                                                |
| Highlighter        | U                            | A wide, see-through stroke, yellow unless you pick another colour                               |
| Shapes             | R, O, L                      | Rectangle, ellipse or straight line: drag from corner to corner, or from end to end             |
| Arrow              | A                            | Drag from the tail to the point                                                                 |
| Revision cloud     | C                            | Drag to draw a cloud around an area                                                             |
| Text               | T                            | Click to place a note and type; Enter starts a new line                                         |
| Width, Colour      |                              | Line width and text size, and six colours. They apply to the next mark, and to the selected one |
| Undo, Redo, Delete | Ctrl+Z, Ctrl+Shift+Z, Delete | Undo or redo the last change; remove the selected mark                                          |
| Clear all          |                              | Removes every mark on the document; click twice to confirm                                      |

On a touch screen, one finger draws and two fingers move and zoom the drawing, whichever tool is on; with Pan, one finger moves it too. Each stroke is its own mark and keeps the colour and width it was drawn with, and a new stroke can start on top of an earlier one.

**Saving.** The signer doesn't need to save. When they move to another document, its marks are saved in the background as a draft file on the related record, titled `<document> - markup - <signer> <date> (draft)`. Approving or declining submits the drafts, and "(draft)" drops from the titles. If the signer reloads the page or comes back later, they see their saved draft, and new marks add to it. **Clear all** removes the draft. If the signer tries to leave with marks that aren't saved yet, the browser asks them to confirm.

**Approving with comments.** Under _Approve (with or without comments) or decline_, the final signing step tells the signer how their approval will go: "You marked up 2 documents, so your approval will be sent as approved with comments, with your markups", or "You haven't marked up any document, so your approval will be sent as approved as-is." So a stray mark is their choice, not an accident.

**What you get:**

- **The marked-up files** on the related record, one per signer per document.
- **The signed PDF's register** ([Attach record PDFs for approval](#sign-attached-documents)) lists each submitted markup under its document: who marked it up, when, and the markup's SHA-256.
- **Marked-Up Documents** on the signature request: how many attached documents carry a submitted markup. On a signed request, more than 0 means it was approved with comments.
- **The sender's emails.** The decline email adds which documents the signer opened and marked up ("Attached documents: 1 of 3 opened. Not opened: ... Marked up: ..."). On templates where approvals can carry markups, the completion email adds "Approved with comments. Marked up: ..." or "Approved as-is: none of the 3 attached documents were marked up."

**Routing approvals with comments in Flow.** Treat "signed" as two outcomes, not one, so the comments on an approval with comments aren't lost on the way to the next step. In a record-triggered Flow on **DocGen Signature Request**, when **Status** changes to **Signed**, add a Decision on **Marked-Up Documents** greater than 0. On that path, update your own record (found through the request's **Related Record Id**) to say it was approved with comments, and create a task for whoever does the next piece of work, so the comments get incorporated. The other path is your usual approval.

**Limits and notes:**

- Marks are standard PDF annotations (ink and free text) appended to the original, so they open in Acrobat, Bluebeam and other readers. Shapes and clouds open there as freehand ink, not as editable shape objects.
- After a reload, earlier pen and shape marks can't be selected or moved; text notes stay editable, and **Clear all** removes everything.
- Pictures can't be added to a markup.
- One copy is kept per signer and document: each save replaces the last, and the old file is deleted. Each document can be saved up to 20 times, and clearing marks doesn't reset that. A markup can be at most 2 MB or 10% larger than the original, whichever is more.
- **A markup file is the signer's own content.** DocGen checks its size, that it comes from the signer's own link, and which copy it was built on. It doesn't check what the marks draw. Treat it like a file the signer emailed back.
- **Your own permission sets?** Give admins edit on the template's Attached Document Markup field, and senders read on the Markup fields of DocGen Signer Attachment and on Marked-Up Documents. The Site guest user needs nothing beyond what [Attach record PDFs for approval](#sign-attached-documents) lists.
