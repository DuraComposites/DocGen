# Dura fork: read this with /CLAUDE.md

This checkout is **DuraComposites/DocGen**, Dura Composites' fork of Portwood. The root `CLAUDE.md` is Portwood's.

- Its technical sections still apply: the merge-tag paths, zero-heap PDF, managed-package rules and the release checks.
- Its **"How this project runs"** section is Portwood's own process and **does not apply here**. Fixing things and opening pull requests is normal in this fork.
- `.github/CONTRIBUTING.md` is the process for this fork. Follow it.

## Where things go

- Remotes: `origin` is DuraComposites/DocGen and `upstream` is Portwood-Global-Solutions/Portwood.
- Pull requests go to `DuraComposites/DocGen` `main`. **Never open a pull request, issue or comment on Portwood's repository unless the user asks for that specific one.** It's a public action under Dura's name.
- `main` is PR-only, and only the `docgen-maintainers` team can merge. Don't try to push to it.
- Merge with merge commits; squash and rebase are switched off.
- Never delete a branch that has an open Portwood pull request. Deleting it closes that pull request.

## Rules for changes

- Add `Modified by Dura Composites Ltd.` near the top of any Portwood file you change, as a comment in that file's syntax (Apache-2.0 §4(b)). Add it once per file.
- Add a row to "Changes from Portwood" in `.github/README.md` for every behaviour change.
- `UserGuide.md` is generated from `docs/knowledgebase/` (articles + `guide.json`) by `npm run guide:build`. Never edit it by hand; CI runs `npm run guide:check`.
- The repository is public. Never commit customer data, real drawings, org IDs, usernames or credentials.
- The product is **DocGen**. Nothing this fork ships may say Portwood or use Portwood's logo, links or support addresses. After merging any Portwood code (a release or a fix), run `node scripts/dura/rebrand.mjs`, then fix the links it lists. Portwood's name stays only in the licence, attribution, Portwood's own history and these fork docs.
- Packaging: DocGen is the managed 2GP package `DocGen` in the `prod` Dev Hub, namespace `duracomp`. `duracomp` is Dura's shared namespace, so other Dura packages can join it later; DocGen's component names are taken within it.
    - Build a beta with `sf package version create --package DocGen --installation-key-bypass --code-coverage --wait 240 --target-dev-hub prod` (from PowerShell). Betas install only in sandboxes and scratch orgs.
    - **Never promote a version** (`sf package version promote`) unless Nathan asks for that version. Promoting freezes its API names for good.
    - `sf package create` and `sf package version create` rewrite `sfdx-project.json`. Check the `force-app` entry afterwards and keep `"default": true`.
    - `agentforce-ext` is a plain source folder, not a package. Portwood ships it as a separate extension; we don't package it.
    - `guide.json` still takes its release alias from Portwood 3.63. Point it at DocGen's first promoted version when there is one.

## Windows

- **Running `sf` by hand:** use PowerShell, not Git Bash. Under Git Bash, `sf` exits 1 even when it succeeds.
- **The QA shell scripts** (`setup-org.sh`, `fixtures/deploy.sh`) source `scripts/qa/lib/windows-shim.sh`, which fixes that and a missing `python3`. Run them from Git Bash, e.g. `./scripts/qa/setup-org.sh docgen-verify --create --days 7 --hub prod`.
- **`npm run qa`** works on Windows: `scripts/qa/lib/sf.mjs` runs the CLI's `run.js` with node there.
- **Testing signing by hand:** after `setup-org.sh`, run `./scripts/qa/setup-signing-site.sh <org>` (Site at /sign, guest permission set, settings URL, drawing-approval demo). It prints a guest signing link.
- **Dura's Dev Hub** is the sf alias `prod`.
