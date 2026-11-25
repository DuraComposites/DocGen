<!-- Copyright Dura Composites Ltd. Licensed under the Apache License, Version 2.0. -->

By default DocGen sends signature emails through Salesforce, from an Org-Wide Email Address such as noreply@yourcompany.com. If you use Microsoft 365, you can instead send signature requests from the mailbox of the person who sent them. The customer sees the salesperson's own address, and a copy lands in that person's **Sent Items**.

This article covers the first set-up, the routine jobs afterwards (new starters, secret renewal, sandboxes) and troubleshooting. Keep it with your admin notes.

**Before you start:**

- **Microsoft 365:** someone with the **Application Administrator** (or Cloud Application Administrator) role in Microsoft Entra ID, and the **Exchange Administrator** role.
- **Salesforce:** a System Administrator. DocGen 1.3.0 or later must be installed.
- **Already done:** [Configure signing email and verification](#site-email). The Org-Wide Email Address is still needed for some emails.
- **Time:** about an hour, plus up to two hours for Exchange changes to take effect.

#### What changes

| Email                                                | Sent from                                   |
| ---------------------------------------------------- | ------------------------------------------- |
| Signature request, including later signers in order  | The request creator's Microsoft 365 mailbox |
| Reminder                                             | The request creator's Microsoft 365 mailbox |
| Request revoked                                      | The request creator's Microsoft 365 mailbox |
| PIN verification code                                | The Org-Wide Email Address (unchanged)      |
| Completion confirmation to signers, with the PDF     | The Org-Wide Email Address (unchanged)      |
| Notices to the sender (signed, declined, all signed) | The Org-Wide Email Address (unchanged)      |

The sender is always the user who created the signature request. Nobody chooses the sender, and DocGen never sends as anyone else. Exchange limits the mailboxes the app can send as to the people you choose.

If a Microsoft 365 send fails, DocGen does **not** fall back to the Org-Wide Email Address. The request's **Email Status** shows the error, and the failure is logged on the **DocGen Error Logs** tab. Busy or throttled responses from Microsoft (HTTP 429 or 503) are retried automatically up to three times, a few minutes apart. Anything else is left for you to fix; then use **Resend** on the request.

Each sender's **Email** in Salesforce must be their Microsoft 365 sign-in address (user principal name).

#### How the pieces fit

| Piece                                      | Where               | What it does                                             |
| ------------------------------------------ | ------------------- | -------------------------------------------------------- |
| App registration and client secret         | Microsoft Entra     | The identity Salesforce signs in to Microsoft Graph with |
| Management scope and role assignment       | Exchange Online     | Lets that app send mail only as the people in the scope  |
| External Credential and Named Credential   | Salesforce Setup    | Hold the app's ID and secret, and the Graph address      |
| Permission set                             | Salesforce Setup    | Lets the users who trigger a send use the credential     |
| **Microsoft 365 Named Credential** setting | DocGen → Signatures | Turns the route on                                       |

#### Production and test: use two apps

The app can send as anyone in its scope, from whichever Salesforce org holds its secret. Sandboxes contain copies of real customer contacts, so a test in a sandbox that uses the production app could email a real customer from a real salesperson's mailbox. Register **two** apps:

| App                                       | Exchange scope                             | Used by                    |
| ----------------------------------------- | ------------------------------------------ | -------------------------- |
| `Salesforce DocGen signature mail`        | The people who send for signature          | Production only            |
| `Salesforce DocGen signature mail (test)` | A test group: the admin, or a test mailbox | Sandboxes and scratch orgs |

Follow steps 1 and 2 once for each app, with its own scope name. The Salesforce steps are the same in every org, with that org's app ID and secret.

#### 1. Register the app in Microsoft Entra ID

1. Open the Microsoft Entra admin center at [entra.microsoft.com](https://entra.microsoft.com) and go to **Identity → Applications → App registrations → New registration**.
2. Name it `Salesforce DocGen signature mail` (or the test name). Choose **Accounts in this organizational directory only**. Leave the redirect URI blank. Click **Register**.
3. On the app's **Overview**, copy the **Application (client) ID** and the **Directory (tenant) ID**.
4. Open **Certificates & secrets → Client secrets → New client secret**. Give it a description and the longest expiry your policy allows, then copy the secret's **Value** at once: it is shown only once. Record the expiry date somewhere it will be acted on (see **Renew the client secret** below).
5. Go to **Identity → Applications → Enterprise applications**, open the app with the same name, and copy its **Object ID**. This is the service principal's ID; it is different from the Object ID on the app registration.

Do **not** add any permissions under **API permissions**. Granting Microsoft Graph `Mail.Send` there lets the app send as every mailbox in the organization, whatever the Exchange scope says. Exchange grants the permission in step 2 instead, limited to the scope.

#### 2. Limit the app to the people who send for signature

Exchange Online's **RBAC for Applications** gives the app `Mail.Send` only for the mailboxes in a **management scope**. Run these in Exchange Online PowerShell (`Install-Module ExchangeOnlineManagement` once, then `Connect-ExchangeOnline`).

##### 2a. Choose who is in the scope

Pick one of these. All of them have the same effect; they differ in what you maintain.

| Option                                       | Choose it when                                                                  | When a new salesperson starts                  |
| -------------------------------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------- |
| **A. An existing group, with nested groups** | Senders are already in a distribution list, often through department sub-groups | Add them to their department group, as usual   |
| **B. A dedicated group**                     | There is no suitable group                                                      | Add them to the dedicated group as well        |
| **C. A user attribute** such as Department   | Every sender's Department (or another attribute) is kept accurate in Entra      | Nothing, if the attribute is set at onboarding |

Things that apply to all options:

- The group must be one Exchange can see: a **distribution list** or a **mail-enabled security group**. A **Microsoft 365 group** (the kind behind a Team, shown as `GroupMailbox`) does **not** work: a scope pointed at one matches nobody.
- A scope only counts **direct** members of a group. People who are in a group _inside_ your group are not covered unless that inner group is named in the scope too. Option A's command does this for you.
- Shared mailboxes that are members of the group fall inside the scope as well. That's harmless: DocGen only sends as the person who created the request.

**Find the group.** Several groups can share a display name. List them with their types first:

```powershell
Get-Group -Identity "Sales" | Format-Table Name, DisplayName, RecipientTypeDetails, DistinguishedName -AutoSize
```

Use the one whose type is `MailUniversalDistributionGroup` or `MailUniversalSecurityGroup`. Check who is in it:

```powershell
Get-DistributionGroupMember -Identity "<group name or email>" -ResultSize Unlimited | Format-Table DisplayName, RecipientTypeDetails, PrimarySmtpAddress -AutoSize
```

Rows whose type ends in `Group` are nested groups.

##### 2b. Create the scope

**Option A: an existing group, including every group nested inside it.** This one command finds the group and every distribution or mail-enabled security group inside it at any depth. It then creates the scope, or updates it if it already exists, and prints the groups it included. Change `Sales` and the scope name to yours:

```powershell
$scopeName = "DocGen E-signature senders"; $dn = (Get-Group -Identity "Sales" | Where-Object RecipientTypeDetails -in 'MailUniversalDistributionGroup','MailUniversalSecurityGroup').DistinguishedName; $queue = [System.Collections.Generic.Queue[string]]::new(); $queue.Enqueue($dn); $dns = @(); while ($queue.Count) { $g = $queue.Dequeue(); if ($dns -contains $g) { continue }; $dns += $g; Get-DistributionGroupMember -Identity $g -ResultSize Unlimited | Where-Object { $_.RecipientTypeDetails -in 'MailUniversalDistributionGroup','MailUniversalSecurityGroup','MailNonUniversalGroup' } | ForEach-Object { $queue.Enqueue($_.DistinguishedName) } }; $filter = ($dns | ForEach-Object { "MemberOfGroup -eq '$_'" }) -join ' -or '; if (Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue) { Set-ManagementScope -Identity $scopeName -RecipientRestrictionFilter $filter } else { New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $filter }; $dns
```

Keep this command with your admin notes. **Run it again whenever a new group is added inside the top group** (for example, a new department). Adding people to existing groups needs nothing.

**Option B: a dedicated group.** Create a mail-enabled security group in the Exchange admin center ([admin.exchange.microsoft.com](https://admin.exchange.microsoft.com) → **Recipients → Groups → Mail-enabled security**), add the senders directly, then:

```powershell
$dn = (Get-Group -Identity "DocGen signature senders").DistinguishedName
```

```powershell
New-ManagementScope -Name "DocGen E-signature senders" -RecipientRestrictionFilter "MemberOfGroup -eq '$dn'"
```

**Option C: a user attribute.** For example, everyone whose Department starts with "Sales":

```powershell
New-ManagementScope -Name "DocGen E-signature senders" -RecipientRestrictionFilter "Department -like 'Sales*'"
```

If `$dn` prints more than one line, two groups matched the name: pick one by its email address or type, as above.

##### 2c. Give the app Mail.Send within the scope

Use the client ID and the enterprise application Object ID from step 1:

```powershell
New-ServicePrincipal -AppId <client-id> -ObjectId <enterprise-app-object-id> -DisplayName "Salesforce DocGen signature mail"
```

```powershell
New-ManagementRoleAssignment -App <client-id> -Role "Application Mail.Send" -CustomResourceScope "DocGen E-signature senders"
```

##### 2d. Check it

Test three people: a direct member, someone who is only in a nested group (option A), and someone who should **not** be able to send:

```powershell
Test-ServicePrincipalAuthorization -Identity <client-id> -Resource <sender@yourcompany.com>
```

Senders should show `InScope : True`, and the outsider `InScope : False`. Changes can take up to two hours to apply. If a nested-group member shows `False` after that, check that their group appears in the list the option A command printed, and re-run it.

**Alternative to RBAC:** the older **Application Access Policy** also works. Grant the Graph `Mail.Send` application permission with admin consent, then run `New-ApplicationAccessPolicy -AppId <client-id> -PolicyScopeGroupId <group-email> -AccessRight RestrictAccess`. Microsoft is replacing these policies with RBAC for Applications, so use RBAC for a new set-up.

**Hand to the Salesforce admin:** the tenant ID, the client ID and the secret value, through a secure channel such as a password manager, never plain email or chat.

#### 3. Create the External Credential in Salesforce

1. In **Setup**, search for **Named Credentials** and open the **External Credentials** tab. Click **New**.
2. Label `Microsoft Graph`, Name `Microsoft_Graph`. Authentication Protocol **OAuth 2.0**, Authentication Flow Type **Client Credentials with Client Secret**.
3. Identity Provider URL: `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token`. Scope: `https://graph.microsoft.com/.default`. Save.
4. Under **Principals**, click **New**. Parameter name `DocGenSignatureMail`, Identity Type **Named Principal**. Enter the client ID and the client secret value. Save.

#### 4. Create the Named Credential

1. Open the **Named Credentials** tab and click **New**.
2. Label `Microsoft Graph`, Name `Microsoft_Graph`. URL `https://graph.microsoft.com`. External Credential: `Microsoft Graph`.
3. Keep **Generate Authorization Header** ticked.
4. Under **Callout Options**, set **Allowed Namespaces for Callouts** to `duracomp`. DocGen is a managed package, and Salesforce only lets a package use a Named Credential that names its namespace. Without it every send fails with "The callout couldn't access the endpoint".
5. Save.

#### 5. Give access to the users that send

The send runs in a background job as whoever caused it. Each of these users needs access to the External Credential's principal:

- everyone who sends documents for signature, by button or Flow;
- the user who scheduled DocGen's signature reminders (the owner of the **DocGen Signature Reminders** scheduled job, in **Setup → Scheduled Jobs**);
- the **Automated Process** user, which sends the next signer's request in sequential signing.

The signing Site's guest user does not need it: the emails sent from the signing page (PIN codes and completion confirmations) still go through Salesforce.

1. Create a permission set, for example `DocGen Microsoft 365 Mail` (API name `DocGen_Microsoft_365_Mail`).
2. Open **External Credential Principal Access**, click **Edit**, and add `Microsoft_Graph - DocGenSignatureMail`. Save.
3. Assign it to the senders and the reminder-job owner. To make new starters automatic, add it to the permission set group (or other bundle) you already assign to sales users, rather than assigning it person by person.
4. Assign it to the Automated Process user as described under **Automated Process access** below.

#### 6. Turn it on in DocGen

1. Open **DocGen → Signatures**.
2. In **Send From Microsoft 365 (Optional)**, enter the Named Credential's API name, `Microsoft_Graph`. Click **Save**.
3. Click **Send a test from my mailbox**. DocGen sends a test from your own mailbox to yourself. Your own mailbox must be in the scope for this to work.
4. You are done when the test is in your Inbox **and** your Sent Items, and **Re-check Setup** shows **Microsoft 365 sending** as passed.

Then send a practice document to an inbox you control. Check that it comes from the sender's own address, is in their Sent Items, and that the request's **Email Status** says `Sent from <sender> via Microsoft 365`. If you use sequential signing, test with two signers so the Automated Process path is checked too.

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

#### Routine jobs

##### A new salesperson starts

1. **Microsoft 365:** add them to the group the scope covers (option A: their department group; option B: the dedicated group; option C: make sure the attribute is set).
2. **Salesforce:** they get the permission set from step 5, directly or through their permission set group, and their Salesforce **Email** is their Microsoft 365 sign-in address.
3. Optional check: `Test-ServicePrincipalAuthorization` for their address shows `InScope : True`.

##### A new department group is created inside the top group (option A)

Run the option A command from step 2b again. It prints the groups it now covers.

##### Someone leaves or stops sending

Remove them from the group (or change the attribute). Requests they created can no longer send reminders through Microsoft 365: the reminder fails with `ErrorAccessDenied` on the request. Reassign or recreate any open requests.

##### Renew the client secret

Do this before the expiry date from step 1, in each org that uses that app:

1. In Entra, open the app → **Certificates & secrets → New client secret**, and copy the value.
2. In Salesforce **Setup → Named Credentials → External Credentials → Microsoft Graph**, edit the principal `DocGenSignatureMail` and paste the new secret. Save.
3. Click **Send a test from my mailbox** in DocGen → Signatures.
4. Delete the old secret in Entra.

If a secret expires first, every Microsoft 365 send fails with `HTTP 401` or `invalid_client` until it is replaced. Nothing goes out from noreply instead.

##### Sandboxes and scratch orgs

- Use the **test** app, not the production one.
- After a sandbox refresh, check the External Credential's principal: re-enter the test app's client ID and secret if they are blank, or if they belong to the production app.
- Sandbox user emails have `.invalid` added to them. Correct the email of whoever is testing, or Graph rejects the send with `ErrorInvalidUser`.
- A scratch org needs the whole Salesforce part (steps 3 to 6) set up again.

#### If it doesn't work

| Email Status or test result                                              | Likely cause and fix                                                                                                                                                                                   |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ErrorAccessDenied` or `Access to OData is disabled`                     | The sender isn't in the scope, or the change hasn't applied yet (allow two hours). Check with `Test-ServicePrincipalAuthorization`. For nested groups, re-run the option A command.                    |
| `ErrorInvalidUser` or `ResourceNotFound`                                 | The user's Salesforce **Email** isn't their Microsoft 365 sign-in address, or (in a sandbox) still ends in `.invalid`.                                                                                 |
| `HTTP 401` or `invalid_client`                                           | The secret is wrong or has expired, or the tenant ID in the Identity Provider URL is wrong. Create a new secret and update the principal.                                                              |
| `CalloutException` mentioning the Named Credential or principal access   | The user who triggered the send doesn't have the permission set from step 5, the Named Credential doesn't list `duracomp` under **Allowed Namespaces for Callouts** (step 4), or its name is mistyped. |
| Only later signers fail, with a credential error                         | The Automated Process user doesn't have the permission set. See **Automated Process access**.                                                                                                          |
| Only reminders fail, with a credential error                             | The owner of the **DocGen Signature Reminders** scheduled job doesn't have the permission set.                                                                                                         |
| `Not sent: the user who created this request has no email address...`    | The request was created by a user without a real mailbox, such as an integration user. Send it from a person's account.                                                                                |
| `Microsoft 365 is busy ... retrying`                                     | Microsoft throttled the send. DocGen retries automatically; the status updates when it finishes.                                                                                                       |
| A scope command says a value "could not be converted to type ADObjectId" | Two groups matched the name, so two distinguished names were joined. Pick one group by its email address or type, as in step 2a.                                                                       |

Microsoft's own references: [RBAC for Applications in Exchange Online](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac) and [user: sendMail](https://learn.microsoft.com/en-us/graph/api/user-sendmail).
