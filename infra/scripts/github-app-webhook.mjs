// Point the GitHub App's webhook at the controller: PATCH /app/hook/config (authenticated as the App).
// Env: GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY_PATH, WEBHOOK_URL, WEBHOOK_SECRET
import crypto from 'node:crypto';
import { readFileSync } from 'node:fs';

const { GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY_PATH, WEBHOOK_URL, WEBHOOK_SECRET } = process.env;
const b64url = (b) => Buffer.from(b).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const head = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
const body = b64url(JSON.stringify({ iat: now - 60, exp: now + 300, iss: GITHUB_APP_ID }));
const sig = crypto.createSign('RSA-SHA256').update(`${head}.${body}`).sign(readFileSync(GITHUB_APP_PRIVATE_KEY_PATH));
const jwt = `${head}.${body}.${b64url(sig)}`;

const res = await fetch('https://api.github.com/app/hook/config', {
  method: 'PATCH',
  headers: {
    Authorization: `Bearer ${jwt}`,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'playwright-e2e-tofu',
  },
  body: JSON.stringify({ url: WEBHOOK_URL, secret: WEBHOOK_SECRET, content_type: 'json', insecure_ssl: '0' }),
});
if (!res.ok) {
  console.error(`GitHub App webhook update failed: ${res.status} ${await res.text()}`);
  process.exit(1);
}
console.log(`GitHub App webhook -> ${WEBHOOK_URL} (secret updated)`);
