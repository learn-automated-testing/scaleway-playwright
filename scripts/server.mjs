// HTTP mode for Scaleway Serverless Containers.
// The Scaleway Queues trigger POSTs each queue message to /run and waits for the reply.
// The body is the message the controller queued: { secret, env: { GITHUB_REPOSITORY, GIT_SHA, ... } }.
//
// Always replies 200 once the message is handled, also when tests fail (the result goes to the
// GitHub check run). A reply >= 300 would make the trigger retry the message up to 3 times.
//
// Env: PORT (default 8080), RUN_SECRET (must match the controller's)
import http from 'node:http';
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';

const PORT = Number(process.env.PORT || 8080);
let busy = false;

const reply = (res, code, body) => {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
};

const sameSecret = (a = '', b = '') => {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && x.length > 0 && crypto.timingSafeEqual(x, y);
};

// Only these variables may be set from a message; everything else comes from the container config.
const ALLOWED_ENV = [
  'GITHUB_REPOSITORY', 'GIT_SHA', 'GITHUB_TOKEN', 'CHECK_RUN_ID', 'INSTALLATION_ID',
  'BASE_URL', 'PW_WORKERS',
];

function runTests(messageEnv) {
  const env = { ...process.env };
  for (const k of ALLOWED_ENV) if (messageEnv[k] != null) env[k] = String(messageEnv[k]);
  return new Promise((resolve) => {
    const started = Date.now();
    const child = spawn('./scripts/run-tests.sh', [], { cwd: '/app', env, stdio: 'inherit' });
    child.on('close', (code) => resolve({ exitCode: code, seconds: Math.round((Date.now() - started) / 1000) }));
  });
}

http.createServer(async (req, res) => {
  if (req.method === 'GET') return reply(res, 200, { ok: true, busy });
  if (req.method !== 'POST' || !req.url.startsWith('/run')) return reply(res, 404, { error: 'not found' });

  let raw = '';
  for await (const chunk of req) raw += chunk;

  let msg;
  try { msg = JSON.parse(raw); } catch { return reply(res, 200, { ignored: 'invalid JSON' }); }
  if (!sameSecret(msg.secret, process.env.RUN_SECRET)) return reply(res, 200, { ignored: 'bad secret' });

  // Scaling is set to 1 request per instance; this guards against overlap anyway.
  if (busy) return reply(res, 503, { error: 'busy, retry' });
  busy = true;
  try {
    console.log(`[server] run ${msg.env?.GITHUB_REPOSITORY}@${msg.env?.GIT_SHA} check ${msg.env?.CHECK_RUN_ID}`);
    const result = await runTests(msg.env || {});
    console.log(`[server] done: exit ${result.exitCode} in ${result.seconds}s`);
    return reply(res, 200, result);
  } finally {
    busy = false;
  }
}).listen(PORT, () => console.log(`[server] listening on ${PORT}`));
