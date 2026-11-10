#!/usr/bin/env node
// Modified by Dura Composites Ltd.
// Recreate the pagination evidence using a released package in a disposable org.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const org = process.argv[2];
if (!org) throw new Error('Usage: node scripts/knowledgebase/verify-advanced.mjs <scratch-org-alias>');
const sf = (args) =>
    JSON.parse(
        execFileSync('sf', [...args, '--json'], {
            cwd: root,
            encoding: 'utf8',
            stdio: ['ignore', 'pipe', 'inherit']
        })
    );
const info = sf(['org', 'display', '--target-org', org]).result;
if (!info.instanceUrl?.includes('.scratch.')) throw new Error('This lab is restricted to a scratch org.');
const out = path.join(root, '.tmp/advanced-verification');
fs.mkdirSync(out, { recursive: true });
const quote = (s) =>
    "'" + s.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\r', '').replaceAll('\n', '\\n') + "'";
const run = (name, code) => {
    const file = path.join(out, `${name}.apex`);
    fs.writeFileSync(file, code);
    const result = sf(['apex', 'run', '--target-org', org, '--file', file]).result;
    if (!result?.success) throw new Error(result?.exceptionMessage || result?.compileProblem || `${name} failed`);
    return result;
};
const body = fs.readFileSync(path.join(root, 'docs/knowledgebase/examples/repeating-header-lab.html'), 'utf8');
const footer = fs.readFileSync(path.join(root, 'docs/knowledgebase/examples/two-line-footer.html'), 'utf8');
run(
    'seed-lab',
    `
List<duracomp__DocGen_Template__c> matches = [SELECT Id FROM duracomp__DocGen_Template__c WHERE duracomp__API_Name__c='KB_Repeating_Header_Lab' LIMIT 1];
duracomp__DocGen_Template__c template = matches.isEmpty() ? new duracomp__DocGen_Template__c() : matches[0];
template.Name='Repeating header lab'; template.duracomp__API_Name__c='KB_Repeating_Header_Lab';
template.duracomp__Type__c='HTML'; template.duracomp__Output_Format__c='PDF';
template.duracomp__Base_Object_API__c='Account'; template.duracomp__Query_Config__c='Name';
template.duracomp__Is_Active__c=true; template.duracomp__Footer_Html__c=${quote(footer)}; upsert template;
List<duracomp__DocGen_Template_Version__c> versions=[SELECT Id,duracomp__Is_Active__c FROM duracomp__DocGen_Template_Version__c WHERE duracomp__Template__c=:template.Id AND duracomp__Is_Active__c=true];
for(duracomp__DocGen_Template_Version__c version:versions) version.duracomp__Is_Active__c=false;
update versions;
ContentVersion body=new ContentVersion(Title='Repeating header lab',PathOnClient='repeating-header-lab.html',VersionData=EncodingUtil.base64Decode(${quote(Buffer.from(body).toString('base64'))})); insert body;
insert new duracomp__DocGen_Template_Version__c(duracomp__Template__c=template.Id,duracomp__Is_Active__c=true,duracomp__Content_Version_Id__c=body.Id,duracomp__Footer_Html__c=${quote(footer)});
`
);
const result = run(
    'render-lab',
    `
Id templateId=[SELECT Id FROM duracomp__DocGen_Template__c WHERE duracomp__API_Name__c='KB_Repeating_Header_Lab' LIMIT 1].Id;
List<Object> contacts=new List<Object>();
for(Integer i=1;i<=90;i++) contacts.add(new Map<String,Object>{'Name'=>'Practice Contact '+i,'Email'=>'person'+i+'@example.com'});
Map<String,Object> data=new Map<String,Object>{'Name'=>'Northstar Bikes','Contacts'=>new Map<String,Object>{'records'=>contacts}};
Map<String,Object> result=duracomp.DocGenService.generatePdfBlobFromData(templateId,data);
ContentVersion cv=new ContentVersion(Title='KB pagination probe',PathOnClient='pagination-probe.pdf',VersionData=(Blob)result.get('blob')); insert cv;
System.debug('KB_PDF_CV='+cv.Id);
`
);
const cvId = result.logs.match(/KB_PDF_CV=(\w+)/)?.[1];
if (!cvId) throw new Error('Rendered PDF id missing');
const pdfFile = path.join(out, 'pagination-probe.pdf');
execFileSync(
    'sf',
    [
        'api',
        'request',
        'rest',
        `/services/data/v68.0/sobjects/ContentVersion/${cvId}/VersionData`,
        '--target-org',
        org,
        '--stream-to-file',
        pdfFile
    ],
    { stdio: 'inherit' }
);
execFileSync('pdftotext', ['-layout', pdfFile, path.join(out, 'pagination-probe.txt')]);
const pages = fs
    .readFileSync(path.join(out, 'pagination-probe.txt'), 'utf8')
    .split('\f')
    .filter((p) => p.trim());
if (
    pages.length !== 4 ||
    pages.some(
        (p, i) => !p.includes('Contact name') || !p.includes(`Page ${i + 1} of 4`) || !p.includes('hello@example.com')
    )
)
    throw new Error('Pagination/header/footer regression: inspect the generated PDF.');
for (let i = 1; i <= 90; i++)
    if (pages.join('\n').match(new RegExp(`Practice Contact ${i}(?![0-9])`, 'g'))?.length !== 1)
        throw new Error(`Missing or duplicated row ${i}`);
console.log(
    'Verified: four pages, 90 unique rows, repeated headers, correct two-line page-count footers. Inspect the PDF visually before updating screenshot evidence.'
);
