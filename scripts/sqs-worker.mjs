// Worker mode for Kubernetes + KEDA.
// KEDA watches the Scaleway Queue and starts one Kubernetes Job per waiting message.
// Each Job runs this script: take one message, delete it (so KEDA does not start another Job for it),
// run the tests, exit. The result goes to the GitHub check run, so the exit code is informational.
//
// Env: SQS_QUEUE_URL, SQS_REGION, SQS_ACCESS_KEY, SQS_SECRET_KEY, RUN_SECRET (must match the controller's)
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { sqsClient } from '../controller/sqs.js';

const { SQS_QUEUE_URL, SQS_REGION = 'fr-par', SQS_ACCESS_KEY, SQS_SECRET_KEY, RUN_SECRET } = process.env;

// Only these variables may be set from a message; everything else comes from the pod spec.
const ALLOWED_ENV = [
  'GITHUB_REPOSITORY', 'GIT_SHA', 'GITHUB_TOKEN', 'CHECK_RUN_ID', 'INSTALLATION_ID',
  'BASE_URL', 'PW_WORKERS',
];

const sameSecret = (a = '', b = '') => {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && x.length > 0 && crypto.timingSafeEqual(x, y);
};

const sqs = sqsClient({
  endpoint: new URL(SQS_QUEUE_URL).origin,
  region: SQS_REGION,
  accessKeyId: SQS_ACCESS_KEY,
  secretAccessKey: SQS_SECRET_KEY,
});

const msg = await sqs.receiveMessage(SQS_QUEUE_URL);
if (!msg) {
  console.log('[worker] queue empty, nothing to do');
  process.exit(0);
}
await sqs.deleteMessage(SQS_QUEUE_URL, msg.receiptHandle);

let run;
try { run = JSON.parse(msg.body); } catch { console.log('[worker] ignored: invalid JSON'); process.exit(0); }
if (!sameSecret(run.secret, RUN_SECRET)) { console.log('[worker] ignored: bad secret'); process.exit(0); }

const env = { ...process.env };
for (const k of ALLOWED_ENV) if (run.env?.[k] != null) env[k] = String(run.env[k]);
// The worker's own queue credentials are not needed by the tests.
for (const k of ['SQS_ACCESS_KEY', 'SQS_SECRET_KEY', 'RUN_SECRET']) delete env[k];

console.log(`[worker] run ${env.GITHUB_REPOSITORY}@${env.GIT_SHA} check ${env.CHECK_RUN_ID}`);
const started = Date.now();
const child = spawn('./scripts/run-tests.sh', [], { cwd: '/app', env, stdio: 'inherit' });
child.on('close', (code) => {
  console.log(`[worker] done: exit ${code} in ${Math.round((Date.now() - started) / 1000)}s`);
  process.exit(code ?? 1);
});
