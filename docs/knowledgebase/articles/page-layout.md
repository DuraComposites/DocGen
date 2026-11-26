<!-- Modified by Dura Composites Ltd. -->

Set the paper, margins, repeated page content, and page background.

#### Choose paper and margins

- **Canvas:** Open **Page**. Choose the paper size, orientation, and margins there.
- **HTML designer:** Use **Page Orientation**, **Page Size** and **Page Margins** in the template editor, or an `@page` rule in the HTML.
- **Word:** Set page size and margins in Word, then check the generated PDF.

When the HTML has its own `@page` rule, the editor says so above the page fields. Leave them on **Portrait**, **Letter** and **Default** to use the HTML's page. **Landscape**, **A4** or **Legal** replaces the HTML's page size, and with one of those set, a **Page Margins** choice other than **Default** replaces its margins too.

A Canvas template always sets its own page, so the editor hides these fields for it.

#### Add a header or footer

Use the template's **Header HTML** and **Footer HTML** fields or the designer's **Header/Footer** panel. Put repeating company details in these areas rather than copying them onto each page.

Leave enough margin for the content. An oversized logo can collide with the document even when the logo itself looks fine.

#### Number the pages

Use the supported header/footer tags:

```text
Page {PageNumber} of {TotalPages}
```

Keep page-number tags in the Header/Footer HTML fields, where page numbering is supported. They are different from a field such as `{AccountNumber}`.

#### Add a watermark or background

1. Save the template at least once.
2. Open **Watermark / Background** in the template editor.
3. Upload a correctly sized image.
4. Choose **Light**, **Medium**, **Strong**, or **Original** strength.
5. Generate a PDF and confirm the text remains readable.

For a Letter page, use **816 × 1056 pixels** at 96 DPI. For A4, use **794 × 1123 pixels**; for Legal, **816 × 1344 pixels**.

Use a picture for a text watermark such as DRAFT. Word's text-watermark and rotation settings do not reliably carry into PDF; a pre-rendered image is easier to control.

#### Check more than the first page

Use a record with long text and many table rows. Inspect headers, footers, the last row of a page, blank space, and the last page. In Word, section breaks and different-first-page settings can also affect the PDF.

For troubleshooting widths, AutoFit, and HTML styling, use the [layout reference](https://github.com/DuraComposites/DocGen/blob/main/docs/reference/template-layout.md).
