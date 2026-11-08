# Contributing to the Dura DocGen fork

This guide covers how this fork is run: who merges, how branches work, how Portwood releases come in, and how fixes go back to Portwood.

For how the codebase itself works, read Portwood's [CONTRIBUTING.md](../CONTRIBUTING.md), [CLAUDE.md](../CLAUDE.md) and the skills in [`.claude/skills/`](../.claude/skills). They still apply here. The one exception is the "How this project runs" section of Portwood's CLAUDE.md, which describes Portwood's own process.

## Get the code

```bash
git clone https://github.com/DuraComposites/DocGen.git
cd DocGen
git remote add upstream https://github.com/Portwood-Global-Solutions/Portwood.git
gh repo set-default DuraComposites/DocGen
npm install
```

- `origin` is this fork. `upstream` is Portwood.
- Run `gh repo set-default` once. This repo is a fork, so `gh pr create` and `gh issue create` otherwise aim at Portwood.

## Branches

| Branch                                      | Purpose                                                         |
| ------------------------------------------- | --------------------------------------------------------------- |
| `main`                                      | What Dura runs: a Portwood release plus our changes. Protected. |
| `feat/<issue>-<name>`, `fix/<issue>-<name>` | One change each, branched from `main`                           |
| `docs/<name>`                               | Documentation only                                              |
| `sync/upstream-vX.Y.Z`                      | Bringing in a Portwood release                                  |

`main` is protected by a ruleset:

- every change goes in by pull request;
- nobody can push to it directly or force-push;
- only members of the **DocGen maintainers** team can merge.

Anyone with access can push other branches and open pull requests.

## Make a change

1. Branch from an up-to-date `main`.
2. Make the change, following Portwood's code guidelines.
3. **If you change a file that came from Portwood, add a notice near the top:** `Modified by Dura Composites Ltd.`, as a comment in that file's syntax. The Apache licence requires this ([§4(b)](../LICENSE)). Once a file has the line, it doesn't need another.
4. If the change affects behaviour, add a row to **Changes from Portwood** in [README](README.md).
5. **If users need to know about it, write or edit an article in `docs/knowledgebase/articles/`,** register it in `docs/knowledgebase/guide.json`, and run `npm run guide:build`. **Never edit `UserGuide.md` by hand:** it's generated, and the Knowledgebase check fails on hand edits. Then follow Portwood's [MAINTAINING guide](../docs/knowledgebase/MAINTAINING.md).
6. Run the checks:
    ```bash
    npm run format:check      # CI runs this on every pull request and blocks the merge if it fails
    npm run guide:check       # the User Guide is up to date with its articles and the code
    npm run qa -- --offline   # quick checks that need no org
    npm run qa                # the full set, against your scratch org
    ```
7. Push the branch and open a pull request against `main` on `DuraComposites/DocGen`.

### Merging

- **Always use "Create a merge commit".** Squash and rebase are switched off, because they rewrite commits and break the next Portwood merge.
- **Don't delete a branch that also has a pull request open on Portwood.** Deleting the branch closes that pull request.

## Set up an org

Portwood's setup script creates a scratch org and configures it end to end. The [`dev-setup` skill](../.claude/skills/dev-setup/SKILL.md) explains each step.

```bash
./scripts/qa/setup-org.sh docgen-verify --create --hub <dev-hub-alias>   # new scratch org, configured
./scripts/qa/setup-org.sh <existing-alias>                               # configure an org you already have
npm run qa                                                               # every test suite, against docgen-verify
```

- **You need a Dev Hub.** Pass its alias with `--hub`, or set `DOCGEN_DEVHUB` once. Without either, the script falls back to Portwood's own Dev Hub name. Dura staff: ask a maintainer for access to Dura's.
- **Scratch org lifetime:** `--days 7` is plenty for testing one branch. The default is 30.
- **One step has to be done by hand:** Setup → Release Updates → "Use the Visualforce PDF Rendering Service for `Blob.toPdf()` Invocations" → **Enable**.
- **Windows:**
    - Run the setup script from a **Git Bash** terminal. `npm run org:new` won't work there, because npm runs scripts through cmd.exe.
    - `scripts/qa/lib/windows-shim.sh` fixes the two things that used to stop it: `sf` returning exit code 1 under Git Bash, and `python3` being missing.
    - `npm run qa` works from any terminal.

### Test signing by hand

`setup-org.sh` gives you an org for the automated tests. Signing by hand needs a public Site too:

```bash
./scripts/qa/setup-signing-site.sh docgen-verify             # Site, guest access, and a drawing-approval demo
./scripts/qa/setup-signing-site.sh docgen-verify --no-demo   # just the Site
```

The script:

- deploys a Visualforce Site at `/sign` and gives its guest user `DocGen_Guest_Signature`;
- points DocGen's settings at the Site, then checks that an anonymous visitor can reach the signing pages;
- seeds a demo:
    - a **Drawing Approval Demo** account with three made-up drawing PDFs;
    - a **Drawing Approval (demo)** template with attached documents and markup switched on;
    - a ready signature request.

It prints the signing link: open it on your phone or in a private window. To send your own request, open the account and choose **Signatures → New signature request → Portwood template**. Re-run the script for a fresh link.

## Take a Portwood release

Portwood releases arrive as a pull request, like any other change. Merge a release **tag**, not upstream `main`, so `main` only ever contains released Portwood code.

```bash
git fetch upstream --tags
git switch -c sync/upstream-v3.63.0 origin/main
git merge v3.63.0                    # resolve any conflicts, then run the checks
git push -u origin sync/upstream-v3.63.0
git push origin v3.63.0              # keep a copy of the release tag
gh pr create --base main --title "Sync Portwood v3.63.0"
```

Merge it with a merge commit. The next sync then only brings in what's new.

## Send a fix to Portwood

If a fix isn't specific to Dura, offer it to Portwood as well:

1. Branch from the Portwood release tag our `main` is on, e.g. `git switch -c fix/123-name v3.63.0`.
    - Not our `main`: Dura-only commits would ride along into Portwood.
    - Not `upstream/main`: unreleased Portwood work would come with it when the branch is merged here.
2. Push the branch to `origin`.
3. Open the pull request with `gh pr create --repo Portwood-Global-Solutions/Portwood`.
4. Leave the "Modified by Dura" notice off that branch. It's for our own changes, not for code we hand to Portwood.

To ship the fix here before Portwood releases it, also open a pull request from the same branch into our `main`. Merge it with a merge commit. When Portwood releases it, the sync then sees the commits are already in.

## Issues and security

- Use [issues](https://github.com/DuraComposites/DocGen/issues) for bugs and ideas about this fork. Problems in Portwood's own code belong on Portwood's issue tracker.
- Report security problems privately. See [SECURITY](SECURITY.md).
- Keep customer data, real drawings and company-specific records out of issues, pull requests and test fixtures. This repository is public.

## Licence

By contributing, you agree that your contribution is licensed under the [Apache License 2.0](../LICENSE).

- Don't use the Portwood name or logo for anything this fork ships.
- Keep [LICENSE](../LICENSE), [NOTICE](../NOTICE) and [THIRD-PARTY-NOTICES](../THIRD-PARTY-NOTICES.md) intact.
