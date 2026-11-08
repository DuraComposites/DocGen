# Security policy

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately instead: on this repository's **Security** tab, choose **Report a vulnerability**. Only the maintainers can see the report.

Please include:

- what's affected: a page, class or component, or a guest signing link;
- the steps to reproduce it;
- the impact you think it has.

We'll acknowledge the report within five working days. We'll work with you on a fix before anything is made public.

## Scope

This policy covers the code in this repository. That includes Dura's additions, such as drawing approval and markup on the guest signing pages.

If the problem is also in Portwood's original code, please report it to Portwood as well, using [their security policy](../SECURITY.md). If you'd rather not, tell us and we'll pass it on.

## Supported versions

Only the latest `main` is supported. There are no released versions of this fork yet.

## Security design

The fork keeps Portwood's security model, described in [Portwood's SECURITY.md](../SECURITY.md#security-design):

- no external callouts;
- CRUD and field-level security enforced on user-facing queries;
- guest signing gated by a 64-character token, with a per-field allowlist.

New guest-facing code here follows the same rules.
