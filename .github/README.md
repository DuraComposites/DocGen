# DocGen: Dura Composites fork

This is Dura Composites' fork of [Portwood](https://github.com/Portwood-Global-Solutions/Portwood) (formerly DocGen), the free, native Salesforce document-generation package.

We use DocGen in our own Salesforce org. This fork holds the features we need that aren't planned upstream, starting with approval and markup of engineering drawings at signing time. Changes that would help everyone go to Portwood as pull requests too.

> **This is not the official Portwood repository.** Portwood LLC does not endorse or support this fork. For the official package, documentation and support, go to [portwood.dev](https://portwood.dev) or the [upstream repository](https://github.com/Portwood-Global-Solutions/Portwood).

## Changes from Portwood

The list of what this fork changes. Every pull request that changes behaviour adds a row.

| Change                                                                                                                                                                               | Pull request                                          |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------- |
| Signing page renders PDFs at the device's resolution and stays sharp when zoomed                                                                                                     | [#2](https://github.com/DuraComposites/DocGen/pull/2) |
| Drawing approval: attach PDFs from the record to a signature request; signers must open and confirm them; an approval register in the signed PDF                                     | [#3](https://github.com/DuraComposites/DocGen/pull/3) |
| Drawing markup: signers mark up attached documents; markups saved to the record; "approved with comments"                                                                            | [#4](https://github.com/DuraComposites/DocGen/pull/4) |
| Signature Status card: a timeline per request (sent, opened, reminders, resends, revokes, expiry, signed or declined), grouped across related records                                | [#8](https://github.com/DuraComposites/DocGen/pull/8) |
| Link expiry and reminder schedule per template (days), editable at send time and in Flow; extend a link or change reminders from the Signature Status card, recorded on the timeline | [#9](https://github.com/DuraComposites/DocGen/pull/9) |

## Install

There's no installable package yet. To try the fork, deploy it from source to a scratch org: see [CONTRIBUTING](CONTRIBUTING.md#set-up-an-org).

## Documentation

Portwood's own documentation is still accurate for everything this fork hasn't changed. That covers the [main README](../README.md), the [User Guide](../UserGuide.md) and [`docs/`](../docs). Features added here document themselves in the pull request that adds them.

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md). In short:

- `main` is protected. Changes go in by pull request, and only the DocGen maintainers can merge.
- Portwood releases come in through a pull request, as described under [Take a Portwood release](CONTRIBUTING.md#take-a-portwood-release).
- To report a security problem, see [SECURITY](SECURITY.md). Don't open a public issue.

## Licence

This fork is licensed under the [Apache License 2.0](../LICENSE), like Portwood itself.

- [NOTICE](../NOTICE) gives the attribution, and [THIRD-PARTY-NOTICES](../THIRD-PARTY-NOTICES.md) lists the bundled libraries.
- "Portwood" is Portwood LLC's name. The Apache licence doesn't grant the right to use it, so nothing this fork ships is called Portwood.
