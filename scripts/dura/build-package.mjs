#!/usr/bin/env node
// Dura Composites Ltd. Licensed under the Apache License 2.0 (see LICENSE).
//
// Builds a DocGen package version, but only from merged code:
//
//   npm run package:build                  check, then build
//   npm run package:build -- --dry-run     check only; print the command it would run
//
// It refuses unless all of these hold:
//   1. the current branch is `main`,
//   2. the working tree is clean (no staged, unstaged or untracked changes),
//   3. HEAD is exactly `origin/main` after a fetch, so what gets built is what was merged,
//   4. `sfdx-project.json` has `"default": true` on the `force-app` entry.
//
// Then it runs:
//   sf package version create --package DocGen --installation-key-bypass --code-coverage --wait 240 --target-dev-hub prod
//
// The build rewrites `sfdx-project.json` (it adds the new alias). Afterwards the script checks that
// `force-app` kept `"default": true` and prints the new alias. Record that alias in a small PR from a
// branch; the build itself never happens anywhere but `main`.
//
// It never promotes anything.

import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveSf } from '../qa/lib/sf.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PROJECT = join(ROOT, 'sfdx-project.json');
const BUILD_ARGS = [
    'package',
    'version',
    'create',
    '--package',
    'DocGen',
    '--installation-key-bypass',
    '--code-coverage',
    '--wait',
    '240',
    '--target-dev-hub',
    'prod'
];

const dryRun = process.argv.includes('--dry-run');

function git(...args) {
    return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8' }).trimEnd();
}

function readProject() {
    return JSON.parse(readFileSync(PROJECT, 'utf8'));
}

/** Problems with the `force-app` entry, or [] when it is the default package directory. */
function forceAppProblems(project) {
    const entry = (project.packageDirectories || []).find((d) => d.path === 'force-app');
    if (!entry) return ['sfdx-project.json has no `force-app` package directory.'];
    if (entry.default !== true) return ['sfdx-project.json: the `force-app` entry has lost `"default": true`.'];
    return [];
}

function refuse(problems) {
    console.error('Refusing to build DocGen:');
    for (const p of problems) console.error(`  - ${p}`);
    console.error('\nPackage versions are built only from merged code: check out `main`, pull, and try again.');
    process.exit(1);
}

// ---- Checks -------------------------------------------------------------------------------------

const problems = [];

const branch = git('rev-parse', '--abbrev-ref', 'HEAD');
if (branch !== 'main') problems.push(`the current branch is \`${branch}\`, not \`main\`.`);

const dirty = git('status', '--porcelain');
if (dirty) {
    const lines = dirty.split('\n');
    problems.push(
        `the working tree is not clean (${lines.length} change${lines.length === 1 ? '' : 's'}):\n` +
            lines
                .slice(0, 10)
                .map((l) => `      ${l}`)
                .join('\n') +
            (lines.length > 10 ? '\n      ...' : '')
    );
}

try {
    git('fetch', 'origin', 'main');
} catch (e) {
    problems.push(`\`git fetch origin main\` failed: ${String(e.stderr || e.message).trim()}`);
}
let head = '';
let remote = '';
try {
    head = git('rev-parse', 'HEAD');
    remote = git('rev-parse', 'origin/main');
} catch (e) {
    problems.push(`could not read HEAD or origin/main: ${String(e.stderr || e.message).trim()}`);
}
if (head && remote && head !== remote) {
    const ahead = git('rev-list', '--count', 'origin/main..HEAD');
    const behind = git('rev-list', '--count', 'HEAD..origin/main');
    problems.push(
        `HEAD (${head.slice(0, 8)}) is not origin/main (${remote.slice(0, 8)}): ${ahead} ahead, ${behind} behind.`
    );
}

const before = readProject();
problems.push(...forceAppProblems(before));

if (problems.length) refuse(problems);

const [cmd, lead] = resolveSf();
console.log(`All checks pass: building from main at ${head.slice(0, 8)} (= origin/main), clean tree.`);

if (dryRun) {
    console.log('\nDry run. Would run:');
    console.log(`  sf ${BUILD_ARGS.join(' ')}`);
    console.log(`  (via ${[cmd, ...lead].join(' ')})`);
    process.exit(0);
}

// ---- Build --------------------------------------------------------------------------------------

console.log(`\nsf ${BUILD_ARGS.join(' ')}\n`);
const run = spawnSync(cmd, [...lead, ...BUILD_ARGS], { cwd: ROOT, stdio: 'inherit' });
if (run.error) {
    console.error(`\nCould not start the Salesforce CLI: ${run.error.message}`);
    process.exit(1);
}
if (run.status !== 0) {
    console.error(`\nThe build failed (exit ${run.status}). Nothing to record.`);
    process.exit(run.status || 1);
}

// ---- After --------------------------------------------------------------------------------------

const after = readProject();
const afterProblems = forceAppProblems(after);
const oldAliases = before.packageAliases || {};
const newAliases = Object.entries(after.packageAliases || {}).filter(([name]) => !(name in oldAliases));

console.log('');
if (newAliases.length) {
    for (const [name, id] of newAliases) console.log(`New alias: ${name} -> ${id}`);
} else {
    console.log('The build reported success but added no alias to sfdx-project.json. Check the CLI output above.');
}

if (afterProblems.length) {
    for (const p of afterProblems) console.error(`WARNING: ${p} Put it back before committing.`);
    process.exitCode = 1;
}

console.log(
    '\nNext: record the alias in a small PR from a branch (as #13 did). Promoting is a separate step, never part of a build.'
);
