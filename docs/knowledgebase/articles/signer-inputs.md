<!-- Modified by Dura Composites Ltd. -->

Ask a signer for a PO number, selected date, acknowledgement, or other information while they sign. These are signer inputs, separate from the Salesforce fields merged when the request is created.

#### Configure an input

1. Open the template editor and choose **Signer Inputs**.
2. Click **Add Field**.
3. Set the **Label** and **Type**: text, number, date, checkbox, picklist, or file upload. Supply choices for a picklist.
4. Choose **Required** if the signer must answer.
5. Copy the generated **Merge Tag**. Its stable key uses letters, numbers, and underscores.
6. Choose **On Certificate** if the answer should appear on the completion certificate.
7. To update Salesforce after signing, select a suitable **Mapped Field** on the related record and enable **Write Back**.
8. Save the intended version and test a practice signing request.

#### Ask for a file

A **File upload** input lets the signer attach a file, such as a purchase order, before they sign. PDF is accepted by default, up to 2 MB. The file is saved on the signature request when the signer presses **Continue**, and is linked to the related record when they finish signing; a file from a signing that is abandoned or declined never reaches the record. The input's answer is the file's ContentVersion Id, so writeback and Flows can find it. The certificate shows the file name.

To accept other types, add an `accept` list to the input in the template's form-field configuration, for example `"accept": "pdf,png,jpg"`. Only document and image types are allowed (pdf, png, jpg, jpeg, gif, tif, tiff, doc, docx, xls, xlsx, csv, txt).

#### Ask for at least one of several inputs

Give two or more inputs the same **At-least-one group** name (under the label in the editor) and the signer must fill at least one of them. For example, a PO number or a PO file:

```json
{
    "formFields": [
        { "key": "PO_Number", "label": "PO number", "type": "text", "atLeastOneGroup": "po" },
        { "key": "PO_File", "label": "PO file", "type": "file", "atLeastOneGroup": "po", "accept": "pdf" }
    ]
}
```

Leave **Required** off on grouped inputs. The signing page and the server both check the rule. A ticked checkbox counts as filled; an unticked one does not.

#### Choose who fills which inputs

The template defines the inputs and which are **Required**. Who is asked what is chosen when the request is sent, so the same template can ask the buyer for a PO and ask a director only to sign.

- From Flow, set **Assign Inputs Per Signer** on **DocGen: Create Signature Request**, and give each signer the input keys they fill in their **Form Field Keys** (for example `PO_Number,PO_File`). A signer with no keys only signs. **DocGen: Get Template Signers** returns the template's inputs (**Form Fields**: key, label, required) for a send screen to offer as checkboxes.
- Without that option, every signer is asked every input, as before.
- **Required** and **At-least-one group** apply only to the inputs a signer was given. A signer with none goes straight to signing, without the **Your Information** step.
- The certificate lists each signer's own answers.

#### Place the answer

```text
{?poNumber}
{?poNumber|N/A}
```

The second form supplies a fallback when no answer is available. Use the key copied from the editor; typing a new key into the document does not create an input. Reserve its own line or table cell for the value so it has room to render without overprinting a static label.

The signer fills these fields during signing. Answers can appear in the finished document and, when configured, on the certificate. This feature is separate from mapping an uploaded PDF's AcroForm fields or manually placing signature spots in the uploaded-PDF preparation screen.

#### Understand writeback

Writeback runs after the completed signed PDF is saved. It updates only fields explicitly mapped and enabled in the template configuration. The guest does not receive general permission to edit the related Account, Opportunity, or other base record.

**Writeback supports single-signer requests.** With several signers, answers are captured and attributed on the certificate, but record writeback is skipped because there is no unambiguous single answer for a shared field. Do not design a multi-signer packet expecting the last answer to overwrite Salesforce.

Field access, supported value conversion, and validation rules still apply. A failed record update is logged; it does not undo a completed signing request. Check the related record and **DocGen Signature Audits** for writeback failures rather than treating a Signed status as proof of a successful field update.

#### Retry a failed update

Correct the mapped field, permissions, or validation issue first. The global **Write Back Signer Form Fields** action accepts only the completed request Id and re-derives the allowed fields from its configuration. It does not accept arbitrary field/value instructions from the guest.

```apex
duracomp.DocGenFieldWritebackService.WritebackRequest retry =
    new duracomp.DocGenFieldWritebackService.WritebackRequest();
retry.requestId = completedRequestId;
duracomp.DocGenFieldWritebackService.writeBackFields(
    new List<duracomp.DocGenFieldWritebackService.WritebackRequest>{retry});
```

The action returns no success DTO and logs failures instead of throwing them back into signing. Verify the target value and audit after a retry. Test an optional blank answer, required answer, invalid value, inaccessible field, validation-rule failure, and multi-signer request before enabling this in a business process.
