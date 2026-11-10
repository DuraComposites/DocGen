Give each template its own link expiry and reminder schedule, let the sender adjust both when sending, and extend a link or change the reminders after it has gone out.

**Before you start:** Signature reminders are switched on in **Portwood → Signatures** and the reminder job is scheduled; see [Track, resend, or stop a request](#manage-signatures). You are a Portwood administrator for the template settings, and a sender with **Portwood User** or **Portwood Admin** for the rest.

#### Set the defaults on a template

1. Open the template in **Portwood → Templates** and go to **E-Signature Defaults**.
2. Fill in any of these, in days:

| Setting                       | What it does                                                             | Blank means                          |
| ----------------------------- | ------------------------------------------------------------------------ | ------------------------------------ |
| **Link Expires After (Days)** | How long signing links stay valid                                        | The org default (Signature Settings) |
| **Remind Every (Days)**       | Days between reminder emails to anyone who hasn't signed. `0` sends none | The org reminder schedule            |
| **Keep Reminding For (Days)** | Stop reminding this many days after sending                              | Remind until the link expires        |

3. Check the line under the settings, which reads them back, for example "Links expire after 14 days; a reminder every 2 days for 10 days."
4. Click **Save as New Version**. Nothing else about the template changes.

**You are done when:** The template's line reads the schedule you want after you reopen it.

#### Change them when sending

In the **Signature Sender**, a single-template send shows:

- **Link expires on**: a date, filled in from the template (or the org default). Links work until the end of that day.
- **Reminders**: **Every few days** (with **Every (days)** and an optional **Until** date), **Standard schedule** (the org schedule in Signature Settings), or **No reminders**. It starts on the template's choice.

The line under **Reminders** says what will happen, and warns when reminders are switched off for the org. Packets (several templates in one send) use the org defaults.

A Flow does the same with the **Create Signature Request** action's **Link Expires On**, **Remind Every (Days)** and **Keep Reminding For (Days)** inputs. Leave them blank to use the template's settings.

#### Extend a link or change the reminders later

On the record's [Signature Status card](#signature-status), a request that hasn't been signed, declined or revoked shows its plan, for example "Link expires 22 Nov · Reminders every 2 days until 20 Nov", with two actions:

- **Extend link** (or **Reopen link** once it has lapsed): pick a new date. Signers' existing links work again until the end of that day; nobody gets a new email.
- **Reminders**: change how often, until when, back to the standard schedule, or stop them.

Each change goes on the request's timeline with your name, such as "Link extended to 22 Nov 2026 by Sam Rivers". A sender extending at the customer's request is worth knowing about later.

**Resend** in the Signature Sender also gives the link a fresh window: the template's length (or the org default), never shorter than a date someone already extended it to.

Changing a sent request needs the **Change Sent Signature Requests** permission, which **Portwood User** and **Portwood Admin** include.

#### How the reminders go out

The hourly reminder job checks each request with its own schedule. A signer is reminded when the chosen number of days has passed since their last reminder (or since sending), as long as the link hasn't expired and the **Until** date hasn't passed. On a request signed in order, only the person whose turn it is gets reminded. Requests with their own schedule are left out of the org schedule, so nobody gets both.

Each reminder appears on the timeline as **Reminder sent to ...**.
