// Uploads ./playwright-report to Scaleway Object Storage (S3-compatible) and writes
// the report URL to /tmp/report-url (picked up by github-check.mjs).
//
// Files are public-read under an unguessable path (reports/<sha>-<uuid>/) so the link opens
// in a browser; the bucket itself stays private (not listable) and a lifecycle rule
// deletes reports after 14 days (scaleway/setup-bucket.sh).
//
// Env: REPORT_BUCKET, REPORT_ACCESS_KEY, REPORT_SECRET_KEY, REPORT_REGION (default fr-par), GIT_SHA (optional)
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

const { REPORT_BUCKET, REPORT_ACCESS_KEY, REPORT_SECRET_KEY } = process.env;
const region = process.env.REPORT_REGION || 'fr-par';
const reportDir = path.resolve('playwright-report');

if (!REPORT_BUCKET || !REPORT_ACCESS_KEY || !REPORT_SECRET_KEY) {
  console.log('[upload-report] REPORT_BUCKET / REPORT_ACCESS_KEY / REPORT_SECRET_KEY not set, skipping upload.');
  process.exit(0);
}

const s3 = new S3Client({
  region,
  endpoint: `https://s3.${region}.scw.cloud`,
  credentials: { accessKeyId: REPORT_ACCESS_KEY, secretAccessKey: REPORT_SECRET_KEY },
});

const contentTypes = {
  '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css',
  '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.webm': 'video/webm', '.zip': 'application/zip', '.svg': 'image/svg+xml',
};

async function* walk(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else yield full;
  }
}

const sha = (process.env.GIT_SHA || 'local').slice(0, 7);
const prefix = `reports/${sha}-${randomUUID()}`;
let count = 0;
for await (const file of walk(reportDir)) {
  const key = `${prefix}/${path.relative(reportDir, file).split(path.sep).join('/')}`;
  await s3.send(new PutObjectCommand({
    Bucket: REPORT_BUCKET,
    Key: key,
    Body: await readFile(file),
    ContentType: contentTypes[path.extname(file)] ?? 'application/octet-stream',
    ACL: 'public-read',
    StorageClass: 'ONEZONE_IA', // Scaleway Standard One Zone: half the price, fine for throwaway reports
  }));
  count++;
}

const url = `https://${REPORT_BUCKET}.s3.${region}.scw.cloud/${prefix}/index.html`;
await writeFile('/tmp/report-url', url);
console.log(`[upload-report] Uploaded ${count} files. Report: ${url}`);
