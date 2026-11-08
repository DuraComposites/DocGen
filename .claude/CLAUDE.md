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
- Packaging: `sfdx-project.json` still names Portwood's package, and Dura's namespace isn't registered yet. **Don't run `sf package version create`** until the packaging work sets this up.

## Windows

- **Running `sf` by hand:** use PowerShell, not Git Bash. Under Git Bash, `sf` exits 1 even when it succeeds.
- **The QA shell scripts** (`setup-org.sh`, `fixtures/deploy.sh`) source `scripts/qa/lib/windows-shim.sh`, which fixes that and a missing `python3`. Run them from Git Bash, e.g. `./scripts/qa/setup-org.sh docgen-verify --create --days 7 --hub prod`.
- **`npm run qa`** works on Windows: `scripts/qa/lib/sf.mjs` runs the CLI's `run.js` with node there.
- **Dura's Dev Hub** is the sf alias `prod`.
