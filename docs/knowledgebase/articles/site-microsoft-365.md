<!-- Copyright Dura Composites Ltd. Licensed under the Apache License, Version 2.0. -->

By default DocGen sends signature emails through Salesforce, from an Org-Wide Email Address such as noreply@yourcompany.com. If you use Microsoft 365, you can instead send signature requests from the mailbox of the person who sent them. The customer sees the salesperson's own address, and a copy lands in that person's **Sent Items**.

**Before you start:** You need a Salesforce administrator and a Microsoft 365 administrator who can register apps in Microsoft Entra ID and run Exchange Online PowerShell. Allow about an hour. Finish [Configure signing email and verification](#site-email) first: the Org-Wide Email Address is still needed for some emails.

#### What changes

| Email                                                | Sent from                                   |
| ---------------------------------------------------- | ------------------------------------------- |
| Signature request, including later signers in order  | The request creator's Microsoft 365 mailbox |
| Reminder                                             | The request creator's Microsoft 365 mailbox |
| Request revoked                                      | The request creator's Microsoft 365 mailbox |
| PIN verification code                                | The Org-Wide Email Address (unchanged)      |
| Completion confirmation to signers, with the PDF     | The Org-Wide Email Address (unchanged)      |
| Notices to the sender (signed, declined, all signed) | The Org-Wide Email Address (unchanged)      |

The sender is always the user who created the signature request. Nobody chooses the sender, and DocGen never sends as anyone else. Exchange limits the mailboxes the app can send as to a group you control.

If a Microsoft 365 send fails, DocGen does **not** fall back to the Org-Wide Email Address. The request's **Email Status** shows the error. Busy or throttled responses from Microsoft (HTTP 429 or 503) are retried automatically up to three times, a few minutes apart. Anything else is left for you to fix; then use **Resend** on the request.

Each user's **Email** in Salesforce must be their Microsoft 365 sign-in address (user principal name).

#### 1. Register the app in Microsoft Entra ID

1. In the Microsoft Entra admin center, open **App registrations → New registration**.
2. Name it, for example `Salesforce DocGen signature mail`. Choose **Accounts in this organizational directory only**. Leave the redirect URI blank. Register it.
3. Copy the **Application (client) ID** and the **Directory (tenant) ID**.
4. Open **Certificates & secrets → New client secret**. Pick an expiry and copy the secret **value** at once; it is shown only once. Put the expiry date in a calendar: emails stop when the secret expires.
5. Open **Enterprise applications**, find the same app, and copy its **Object ID**. This is the service principal's ID, not the app registration's ID.

Do **not** add the Microsoft Graph `Mail.Send` permission under **API permissions** if you use step 2 below. Granted there, it lets the app send as every mailbox in the organization, and Exchange's limit no longer applies.

#### 2. Limit the app to the people who send for signature

Use Exchange Online's **RBAC for Applications**, which gives the app `Mail.Send` only for the mailboxes in a scope.

1. Create a **mail-enabled security group**, for example `DocGen signature senders`, and add everyone who sends documents for signature.
2. In Exchange Online PowerShell (`Connect-ExchangeOnline`), run, with your own values:

```powershell
# The group's distinguished name, for the scope filter
$dn = (Get-Group "DocGen signature senders").DistinguishedName

New-ServicePrincipal -AppId <client-id> -ObjectId <enterprise-app-object-id> -DisplayName "Salesforce DocGen signature mail"
New-ManagementScope -Name "DocGen signature senders" -RecipientRestrictionFilter "MemberOfGroup -eq '$dn'"
New-ManagementRoleAssignment -App <client-id> -Role "Application Mail.Send" -CustomResourceScope "DocGen signature senders"
```

3. Check it: `Test-ServicePrincipalAuthorization -Identity <client-id> -Resource <a-sender@yourcompany.com>` should show `InScope = True`. Try someone outside the group too; they should show `False`.

Changes can take up to two hours to apply. Adding a new salesperson later means adding them to the group only.

**Alternative:** the older **Application Access Policy** also works. Grant the Graph `Mail.Send` application permission with admin consent, then run `New-ApplicationAccessPolicy -AppId <client-id> -PolicyScopeGroupId <group-email> -AccessRight RestrictAccess`. Microsoft is replacing these policies with RBAC for Applications, so use RBAC for a new set-up.

#### 3. Create the External Credential in Salesforce

1. In **Setup**, search for **Named Credentials** and open the **External Credentials** tab. Click **New**.
2. Label `Microsoft Graph`, Name `Microsoft_Graph`. Authentication Protocol **OAuth 2.0**, Authentication Flow Type **Client Credentials with Client Secret**.
3. Identity Provider URL: `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token`. Scope: `https://graph.microsoft.com/.default`. Save.
4. Under **Principals**, click **New**. Parameter name `DocGenSignatureMail`, Identity Type **Named Principal**. Enter the client ID and the client secret value. Save.

#### 4. Create the Named Credential

1. Open the **Named Credentials** tab and click **New**.
2. Label `Microsoft Graph`, Name `Microsoft_Graph`. URL `https://graph.microsoft.com`. External Credential: `Microsoft Graph`.
3. Keep **Generate Authorization Header** ticked. Save.

#### 5. Give access to the users that send

The send runs in a background job as whoever caused it. Each of these users needs access to the External Credential's principal:

- everyone who sends documents for signature, by button or Flow;
- the user who scheduled DocGen's signature reminders (the owner of the **DocGen Signature Reminders** scheduled job);
- the **Automated Process** user, which sends the next signer's request in sequential signing.

The signing Site's guest user does not need it: the emails sent from the signing page (PIN codes and completion confirmations) still go through Salesforce.

1. Create a permission set, for example `DocGen Microsoft 365 Mail` (API name `DocGen_Microsoft_365_Mail`).
2. Open **External Credential Principal Access**, click **Edit**, and add `Microsoft_Graph - DocGenSignatureMail`. Save.
3. Assign it to the people above in the usual way.
4. Assign it to the Automated Process user as described under **Automated Process access** below.

#### 6. Turn it on in DocGen

1. Open **DocGen → Signatures**.
2. In **Send From Microsoft 365 (Optional)**, enter the Named Credential's API name, `Microsoft_Graph`. Click **Save**.
3. Click **Send a test from my mailbox**. DocGen sends a test from your own mailbox to yourself.
4. You are done when the test is in your Inbox **and** your Sent Items, and **Re-check Setup** shows **Microsoft 365 sending** as passed.

Then send a practice document to an inbox you control. Check that it comes from the sender's own address, is in their Sent Items, and that the request's **Email Status** says `Sent from <sender> via Microsoft 365`.

To switch back to Salesforce email, clear the field and save.

#### Automated Process access

Salesforce runs the sequential-signing trigger as the Automated Process user. Setup doesn't list that user, but you can assign the permission set to it through the API. In **Developer Console → Debug → Open Execute Anonymous Window**, run:

```apex
insert new PermissionSetAssignment(
    AssigneeId = [SELECT Id FROM User WHERE Alias = 'autoproc' LIMIT 1].Id,
    PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Microsoft_365_Mail' LIMIT 1].Id
);
```

Use your permission set's API name. Without this, the first signer's email goes out but later signers' emails fail, and the request's **Email Status** says the credential couldn't be accessed.

#### If it doesn't work

| Email Status or test result                                            | Likely cause and fix                                                                                                          |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `ErrorAccessDenied` or `Access to OData is disabled`                   | The sender isn't in the scoped group, or the RBAC change hasn't applied yet. Check with `Test-ServicePrincipalAuthorization`. |
| `ErrorInvalidUser` or `ResourceNotFound`                               | The user's Salesforce **Email** isn't their Microsoft 365 sign-in address.                                                    |
| `HTTP 401` or `invalid_client`                                         | The secret is wrong or has expired. Create a new one in Entra and update the principal.                                       |
| `CalloutException` mentioning the Named Credential or principal access | The user who triggered the send doesn't have the permission set from step 5, or the Named Credential name is mistyped.        |
| `Not sent: the user who created this request has no email address...`  | The request was created by a user without a real mailbox, such as an integration user. Send it from a person's account.       |
| `Microsoft 365 is busy ... retrying`                                   | Microsoft throttled the send. DocGen retries automatically; the status updates when it finishes.                              |

Microsoft's own references: [RBAC for Applications in Exchange Online](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac) and [user: sendMail](https://learn.microsoft.com/en-us/graph/api/user-sendmail).
