#!/usr/bin/env node
// Dura Composites Ltd. Licensed under the Apache License 2.0 (see LICENSE).
//
// Renames Portwood to DocGen across the fork, so nothing this fork ships carries Portwood's
// name, links or namespace. Re-run it after every Portwood release is merged in:
//
//   node scripts/dura/rebrand.mjs            rewrite files, rename paths, add the notice
//   node scripts/dura/rebrand.mjs --check    change nothing; list what would change (exit 1 if anything)
//
// What it does, in order:
//   1. Leaves alone the files that must keep Portwood's name (licence, attribution, Portwood's own
//      history and process docs, packaging config) and links to Portwood's own issues and PRs.
//   2. Points links at this fork: GitHub URLs, the User Guide, demo company names and addresses.
//   3. Renames the namespace (portwoodglobal -> duracomp) and the product (Portwood -> DocGen).
//   4. Adds "Modified by Dura Composites Ltd." to each changed file (Apache-2.0 section 4(b)).
//
// Anything it can't decide (a portwood.dev link it doesn't know, a Slack thread, a support address)
// is left unchanged and listed at the end. Fix those by hand.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const CHECK = process.argv.includes('--check');
const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
const NOTICE = 'Modified by Dura Composites Ltd.';
const GUIDE = 'https://github.com/DuraComposites/DocGen/blob/main/UserGuide.md';

/** Files that keep Portwood's name, and why. */
const KEEP = [
    /^(LICENSE|NOTICE|THIRD-PARTY-NOTICES\.md)$/, // licence and attribution
    /^CHANGELOG\.md$/, // Portwood's release history
    /^(README|CONTRIBUTING|CODE_OF_CONDUCT|SECURITY|CONTRIBUTORS|ROADMAP|TRIAGE|CLAUDE)\.md$/, // Portwood's project docs
    /^(designer-snapshot|picker|extorg)\.md$/, // Portwood's working notes
    /^docs\/[^/]*(-plan|_PLAN)\.md$/, // plans that record history
    /^\.github\//, // the fork's own docs, which name Portwood as upstream on purpose
    /^\.claude\/CLAUDE\.md$/,
    /^assets\//, // Portwood's logo
    /^sfdx-project\.json$/, // packaging config: changes with the packaging work
    /^(UserGuide\.md|docs\/knowledgebase\/(catalog|apex-surface)\.json)$/, // generated: run npm run guide:build
    /^scripts\/qa\/report\//, // generated QA output
    /^scripts\/dura\// // this script
];

/** Kept exactly as written everywhere: references to Portwood itself, not to the product we ship. */
const PROTECT = [
    /github\.com\/Portwood-Global-Solutions\/Portwood\/(?:issues|pull|discussions|releases|commit|compare)\/[\w.-]+/g,
    /\bPortwood@\d[\w.-]*/g,
    /\bPortwood LLC\b/g,
    // Test fixtures checked byte for byte: the test font's internal names (DocGenFontTest) and an invoice
    // URL whose QR code is compared with stored rows (BarcodeGeneratorTest).
    /\bPortwood ?Test ?Script\b/g,
    /https:\/\/pay\.portwoodglobalsolutions\.com\/puco\/invoice\/[^'"\s]*/g
];

/** Links and demo data, applied before the names. */
const LINKS = [
    [/https:\/\/github\.com\/Portwood-Global-Solutions\/Portwood/g, 'https://github.com/DuraComposites/DocGen'],
    [/github\.com\/Portwood-Global-Solutions\/Portwood/g, 'github.com/DuraComposites/DocGen'],
    [
        /raw\.githubusercontent\.com\/Portwood-Global-Solutions\/Portwood/g,
        'raw.githubusercontent.com/DuraComposites/DocGen'
    ],
    [/https:\/\/portwood\.dev\/guide\/?(?![\w/-])/g, GUIDE],
    [/PORTWOOD GLOBAL SOLUTIONS/g, 'EXAMPLE CONSULTING GROUP'],
    [/Portwood Global Solutions/g, 'Example Consulting Group'],
    [/Portwood Global - Production/g, 'prod'],
    [/Portwood Global\b/g, 'Example Consulting'],
    [/portwoodglobalsolutions\.com/g, 'example.com'],
    [/portwoodglobal\.example\.com/g, 'consulting.example.com'],
    [/\b(?!support@|hello@)([\w.+-]+)@portwood\.dev(\.demo)?\b/g, '$1@example.com$2'],
    [/\b([a-z0-9-]+)\.portwood\.dev\b/g, '$1.example.com']
];

/** Left unchanged and reported: a person decides where these should point. */
const ASK = [/[\w.+-]*@?portwood\.dev\b[^\s"'<>)\]`]*/g, /https?:\/\/portwoodcommunity\.slack\.com[^\s"'<>)\]`]*/g];

/** The namespace and the product name. */
const NAMES = [
    [/portwoodglobal/g, 'duracomp'],
    [/Portwood DocGen/g, 'DocGen'],
    [/PORTWOOD DOCGEN/g, 'DOCGEN'],
    [/PORTWOOD/g, 'DOCGEN'],
    [/Portwood/g, 'DocGen'],
    [/portwood/g, 'docgen'],
    [/DocGen DocGen/g, 'DocGen'],
    [/DOCGEN DOCGEN/g, 'DOCGEN']
];

const kept = (file) => KEEP.some((re) => re.test(file));

function rewrite(text, file, asks) {
    const held = [];
    const hold = (match) => {
        held.push(match);
        return `\u0000${held.length - 1}\u0000`;
    };
    let out = text;
    for (const re of PROTECT) out = out.replace(re, hold);
    for (const [re, to] of LINKS) out = out.replace(re, to);
    for (const re of ASK)
        out = out.replace(re, (match) => {
            if (!/portwood/i.test(match)) return match;
            asks.push(`${file}: ${match}`);
            return hold(match);
        });
    for (const [re, to] of NAMES) out = out.replace(re, to);
    return out.replace(/\u0000(\d+)\u0000/g, (_, i) => held[Number(i)]);
}

const renamePath = (file) => NAMES.reduce((p, [re, to]) => p.replace(re, to), file);

/** Puts the notice where the file's syntax allows a comment, or returns null when it has none. */
function withNotice(text, file) {
    if (text.includes(NOTICE)) return text;
    const ext = path.extname(file).toLowerCase();
    const lines = text.split('\n');
    const afterShebang = (comment) => {
        if (lines[0].startsWith('#!')) lines.splice(1, 0, comment);
        else lines.unshift(comment);
        return lines.join('\n');
    };
    // Straight after the root element's opening tag, even when the file packs several tags onto one line.
    const afterOpenTag = (pattern) => {
        const match = pattern.exec(text);
        const close = match ? text.indexOf('>', match.index) : -1;
        if (close < 0) return null;
        return `${text.slice(0, close + 1)}\n    <!-- ${NOTICE} -->${text.slice(close + 1)}`;
    };
    if (['.cls', '.trigger', '.apex', '.js', '.mjs', '.cjs', '.ts'].includes(ext)) return afterShebang(`// ${NOTICE}`);
    if (['.sh', '.py', '.yml', '.yaml'].includes(ext)) return afterShebang(`# ${NOTICE}`);
    if (ext === '.css') return `/* ${NOTICE} */\n${text}`;
    if (ext === '.md') {
        if (lines[0] === '---') {
            const close = lines.indexOf('---', 1);
            if (close > 0) {
                lines.splice(close + 1, 0, '', `<!-- ${NOTICE} -->`);
                return lines.join('\n');
            }
        }
        return `<!-- ${NOTICE} -->\n\n${text}`;
    }
    if (ext === '.html' && file.includes('/lwc/')) return afterOpenTag(/<template[\s>]/);
    if (['.html', '.htm'].includes(ext)) {
        if (/^\s*<!doctype/i.test(lines[0])) {
            lines.splice(1, 0, `<!-- ${NOTICE} -->`);
            return lines.join('\n');
        }
        return `<!-- ${NOTICE} -->\n${text}`;
    }
    if (['.page', '.component'].includes(ext)) return `<!-- ${NOTICE} -->\n${text}`;
    if (
        ['.cmp', '.app', '.design', '.auradoc', '.evt', '.svg'].includes(ext) ||
        /\.(xml|flexipage|object|genAiPromptTemplate)$/i.test(file)
    ) {
        return afterOpenTag(/<(?![?!/])[A-Za-z]/);
    }
    return null;
}

const tracked = execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean);
const withText = new Set(
    execFileSync('git', ['grep', '-z', '-Ili', 'portwood'], { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean)
);

const asks = [];
const noNotice = [];
const changed = [];
const moves = [];

for (const file of tracked) {
    if (kept(file)) continue;
    const target = renamePath(file);
    const textual = withText.has(file);
    if (!textual && target === file) continue;
    const abs = path.join(root, file);
    let text = fs.readFileSync(abs, 'utf8');
    const original = text;
    if (textual) text = rewrite(text, file, asks);
    if (text === original && target === file) continue;
    const noticed = withNotice(text, file);
    if (noticed === null) noNotice.push(file);
    else text = noticed;
    changed.push(file);
    if (target !== file) moves.push([file, target]);
    if (!CHECK) fs.writeFileSync(abs, text);
}

if (!CHECK) {
    for (const [from, to] of moves) {
        fs.mkdirSync(path.dirname(path.join(root, to)), { recursive: true });
        execFileSync('git', ['mv', from, to], { cwd: root });
    }
}

console.log(`${CHECK ? 'Would change' : 'Changed'} ${changed.length} files; ${moves.length} renamed.`);
for (const [from, to] of moves) console.log(`  rename: ${from} -> ${to}`);
if (noNotice.length) {
    console.log(`\nNo comment syntax, so no notice (the NOTICE file and .github/README.md cover these):`);
    for (const f of noNotice) console.log(`  ${f}`);
}
if (asks.length) {
    console.log(`\nLeft for a person to decide (${asks.length}):`);
    for (const a of [...new Set(asks)]) console.log(`  ${a}`);
}
if (CHECK && changed.length) process.exitCode = 1;
