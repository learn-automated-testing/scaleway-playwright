// Scaleway Serverless Function: GitHub App webhook -> Scaleway Serverless Job.
//
//   push / "Re-run" in GitHub  ->  create check run (queued)  ->  start job run for that commit
//   cron {"action":"sweep"}    ->  mark checks failed whose job run crashed/timed out
//
// No dependencies: only node:crypto and fetch (Node 22).
//
// Env (secrets marked *):
//   GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY_B64*, GITHUB_WEBHOOK_SECRET*
//   JOBS_SECRET_KEY* (Scaleway API key allowed to start jobs), JOBS_REGION, JOB_DEFINITION_ID
//   (Scaleway reserves SCW_* names, so none are used here)
//   ALLOWED_REPOS (comma-separated owner/repo; only these can start runs)
//   BASE_URL, BRANCHES (optional, comma-separated; empty = all branches)
//   REPORT_BUCKET, REPORT_ACCESS_KEY*, REPORT_SECRET_KEY* (optional report upload)
'use strict';
const crypto = require('node:crypto');

const CHECK_NAME = 'Playwright E2E (Scaleway)';
const env = process.env;
const REGION = env.JOBS_REGION || 'fr-par';
const JOBS_API = `https://api.scaleway.com/serverless-jobs/v1alpha2/regions/${REGION}`;

// ---------- GitHub App auth ----------
const b64url = (buf) => Buffer.from(buf).toString('base64url');

function appJwt() {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: env.GITHUB_APP_ID }));
  const key = Buffer.from(env.GITHUB_APP_PRIVATE_KEY_B64, 'base64').toString('utf8');
  const sig = crypto.createSign('RSA-SHA256').update(`${header}.${payload}`).sign(key);
  return `${header}.${payload}.${b64url(sig)}`;
}

async function gh(path, { token, method = 'GET', body } = {}) {
  const res = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'scaleway-playwright-controller',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`GitHub ${method} ${path} -> ${res.status} ${await res.text()}`);
  return res.status === 204 ? null : res.json();
}

// Installation tokens live 1 hour: long enough for one test run, useless afterwards.
async function installationToken(installationId, repoName) {
  const { token } = await gh(`/app/installations/${installationId}/access_tokens`, {
    token: appJwt(),
    method: 'POST',
    body: { repositories: [repoName], permissions: { contents: 'read', checks: 'write' } },
  });
  return token;
}

// ---------- Scaleway Jobs ----------
async function scw(path, { method = 'GET', body } = {}) {
  const res = await fetch(`${JOBS_API}${path}`, {
    method,
    headers: { 'X-Auth-Token': env.JOBS_SECRET_KEY, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`Scaleway ${method} ${path} -> ${res.status} ${await res.text()}`);
  return res.json();
}

async function startJob(vars) {
  const res = await scw(`/job-definitions/${env.JOB_DEFINITION_ID}/start`, {
    method: 'POST',
    body: { environment_variables: vars },
  });
  return (res.job_runs ?? [res])[0].id;
}

// ---------- Webhook ----------
function validSignature(raw, header) {
  if (!header || !env.GITHUB_WEBHOOK_SECRET) return false;
  const expected = 'sha256=' + crypto.createHmac('sha256', env.GITHUB_WEBHOOK_SECRET).update(raw).digest('hex');
  const a = Buffer.from(expected);
  const b = Buffer.from(header);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function repoAllowed(repo) {
  const list = (env.ALLOWED_REPOS || '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
  return list.includes(String(repo).toLowerCase()); // empty list = nothing allowed (fail closed)
}

function branchAllowed(branch) {
  const list = (env.BRANCHES || '').split(',').map((s) => s.trim()).filter(Boolean);
  return list.length === 0 || list.includes(branch);
}

// Decide whether this event should start a run. Returns { sha, branch, force } or null.
function triggerFrom(event, p) {
  if (event === 'push') {
    if (p.deleted || !p.ref?.startsWith('refs/heads/') || /^0+$/.test(p.after)) return null;
    return { sha: p.after, branch: p.ref.slice('refs/heads/'.length), force: false };
  }
  if (event === 'check_run' && p.action === 'rerequested' && p.check_run?.name === CHECK_NAME) {
    return { sha: p.check_run.head_sha, branch: p.check_run.check_suite?.head_branch, force: true };
  }
  if (event === 'check_suite' && p.action === 'rerequested') {
    return { sha: p.check_suite.head_sha, branch: p.check_suite.head_branch, force: true };
  }
  return null;
}

async function onWebhook(event, payload) {
  if (event === 'ping') return reply(200, { ok: true, msg: 'pong' });

  const repo = payload.repository?.full_name;
  if (!repoAllowed(repo)) return reply(403, { ignored: `repo ${repo} not in ALLOWED_REPOS` });

  const trigger = triggerFrom(event, payload);
  if (!trigger) return reply(200, { ignored: `${event}.${payload.action ?? ''}` });
  if (trigger.branch && !branchAllowed(trigger.branch)) return reply(200, { ignored: `branch ${trigger.branch}` });

  const installationId = payload.installation.id;
  const token = await installationToken(installationId, payload.repository.name);

  // GitHub can redeliver a webhook: never start two runs for the same push.
  if (!trigger.force) {
    const existing = await gh(
      `/repos/${repo}/commits/${trigger.sha}/check-runs?check_name=${encodeURIComponent(CHECK_NAME)}`,
      { token },
    );
    if (existing.total_count > 0) return reply(200, { ignored: 'check run already exists' });
  }

  const check = await gh(`/repos/${repo}/check-runs`, {
    token,
    method: 'POST',
    body: {
      name: CHECK_NAME,
      head_sha: trigger.sha,
      status: 'queued',
      output: { title: 'Queued on Scaleway Serverless Jobs', summary: 'Waiting for the job to start…' },
    },
  });

  try {
    const runId = await startJob({
      GITHUB_REPOSITORY: repo,
      GIT_SHA: trigger.sha,
      GITHUB_TOKEN: token,
      CHECK_RUN_ID: String(check.id),
      INSTALLATION_ID: String(installationId),
      BASE_URL: env.BASE_URL || 'https://www.practiceautomatedtesting.com',
      REPORT_REGION: REGION,
      ...(env.REPORT_BUCKET
        ? { REPORT_BUCKET: env.REPORT_BUCKET, REPORT_ACCESS_KEY: env.REPORT_ACCESS_KEY, REPORT_SECRET_KEY: env.REPORT_SECRET_KEY }
        : {}),
    });
    await gh(`/repos/${repo}/check-runs/${check.id}`, { token, method: 'PATCH', body: { external_id: runId } });
    return reply(202, { started: runId, check_run: check.id, sha: trigger.sha });
  } catch (err) {
    await gh(`/repos/${repo}/check-runs/${check.id}`, {
      token,
      method: 'PATCH',
      body: {
        status: 'completed',
        conclusion: 'failure',
        output: { title: 'Could not start the Scaleway job', summary: '```\n' + String(err.message).slice(0, 2000) + '\n```' },
      },
    });
    throw err;
  }
}

// ---------- Sweeper: job runs that died without reporting ----------
async function sweep() {
  const { job_runs: runs = [] } = await scw(
    `/job-runs?job_definition_id=${env.JOB_DEFINITION_ID}&order_by=created_at_desc&page_size=50`,
  );
  const cutoff = Date.now() - 3 * 60 * 60 * 1000;
  const dead = runs.filter(
    (r) => ['failed', 'canceled', 'interrupted'].includes(r.state)
      && Date.parse(r.created_at) > cutoff
      && r.environment_variables?.CHECK_RUN_ID,
  );

  const fixed = [];
  for (const run of dead) {
    const { GITHUB_REPOSITORY: repo, CHECK_RUN_ID: checkId, INSTALLATION_ID: inst } = run.environment_variables;
    try {
      const token = await installationToken(inst, repo.split('/')[1]);
      const check = await gh(`/repos/${repo}/check-runs/${checkId}`, { token });
      if (check.status === 'completed') continue; // the job reported itself (normal test failure)
      await gh(`/repos/${repo}/check-runs/${checkId}`, {
        token,
        method: 'PATCH',
        body: {
          status: 'completed',
          conclusion: run.state === 'canceled' ? 'cancelled' : 'failure',
          output: {
            title: `Scaleway job run ${run.state} (${run.reason || 'unknown reason'})`,
            summary: [
              'The job stopped before it could report results (timeout, out of memory, or infrastructure error).',
              '',
              `- Job run: \`${run.id}\``,
              `- Exit code: \`${run.exit_code ?? 'n/a'}\``,
              run.error_message ? `- Error: \`${String(run.error_message).trim().slice(0, 500)}\`` : '',
              '',
              'Logs: Scaleway console → Serverless Jobs → Job runs → Logs.',
            ].join('\n'),
          },
        },
      });
      fixed.push(run.id);
    } catch (err) {
      console.error(`sweep ${run.id}:`, err.message);
    }
  }
  return reply(200, { checked: dead.length, fixed });
}

// ---------- Entry point ----------
function reply(statusCode, body) {
  return { statusCode, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
}

module.exports.handle = async (event) => {
  try {
    const headers = Object.fromEntries(Object.entries(event.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
    const raw = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : event.body || '';
    const ghEvent = headers['x-github-event'];

    if (!ghEvent) {
      // Cron trigger (or manual call). Sweeping is harmless, so it needs no signature.
      let body = {};
      try { body = JSON.parse(raw || '{}'); } catch { /* ignore */ }
      return body.action === 'sweep' ? await sweep() : reply(400, { error: 'not a GitHub webhook' });
    }

    if (!validSignature(raw, headers['x-hub-signature-256'])) return reply(401, { error: 'invalid signature' });
    return await onWebhook(ghEvent, JSON.parse(raw));
  } catch (err) {
    console.error(err);
    return reply(500, { error: err.message });
  }
};
