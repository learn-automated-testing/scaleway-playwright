// Updates the GitHub check run created by the controller.
//   node scripts/github-check.mjs start      -> in_progress
//   node scripts/github-check.mjs complete   -> success/failure + summary, failures, annotations, report link
//   node scripts/github-check.mjs crash      -> failure (job could not run the tests)
// Env: GITHUB_REPOSITORY, GITHUB_TOKEN, CHECK_RUN_ID. Does nothing when CHECK_RUN_ID is not set.
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const { GITHUB_REPOSITORY: repo, GITHUB_TOKEN: token, CHECK_RUN_ID: checkId } = process.env;
const mode = process.argv[2];
const REPORT_URL_FILE = '/tmp/report-url';
const APP_DIR = process.cwd();

if (!checkId || !token || !repo) process.exit(0);

async function patch(body) {
  const res = await fetch(`https://api.github.com/repos/${repo}/check-runs/${checkId}`, {
    method: 'PATCH',
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
      'User-Agent': 'scaleway-playwright-job',
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`check run update failed: ${res.status} ${await res.text()}`);
}

const stripAnsi = (s = '') => s.replace(/\u001b\[[0-9;]*m/g, '');
const readMaybe = (f) => readFile(f, 'utf8').catch(() => null);

// Walk Playwright's JSON report and collect failed / flaky tests.
function collect(report) {
  const failed = [];
  const flaky = [];
  const rootDir = report.config?.rootDir ?? path.join(APP_DIR, 'tests');
  const walk = (suite, titles) => {
    for (const child of suite.suites ?? []) walk(child, [...titles, child.title].filter(Boolean));
    for (const spec of suite.specs ?? []) {
      for (const t of spec.tests ?? []) {
        if (t.status !== 'unexpected' && t.status !== 'flaky') continue;
        const last = t.results?.at(-1) ?? {};
        const err = last.errors?.[0] ?? last.error ?? {};
        const loc = err.location ?? { file: path.join(rootDir, spec.file), line: spec.line };
        const entry = {
          title: [...titles, spec.title].join(' › '),
          message: stripAnsi(err.message ?? 'Test failed').trim(),
          path: path.relative(APP_DIR, loc.file),
          line: loc.line ?? spec.line ?? 1,
        };
        (t.status === 'flaky' ? flaky : failed).push(entry);
      }
    }
  };
  for (const suite of report.suites ?? []) walk(suite, suite.title ? [suite.title] : []);
  return { failed, flaky };
}

if (mode === 'start') {
  await patch({
    status: 'in_progress',
    started_at: new Date().toISOString(),
    output: { title: process.env.RUNNER_MODE === 'server' ? 'Running on Scaleway Serverless Containers' : 'Running on Scaleway Serverless Jobs', summary: `Testing \`${process.env.BASE_URL ?? ''}\`` },
  });
} else if (mode === 'crash') {
  await patch({
    status: 'completed',
    conclusion: 'failure',
    completed_at: new Date().toISOString(),
    output: {
      title: 'Job failed before tests finished',
      summary: process.argv[3] || 'The job could not run the tests. Check the job run logs in the Scaleway console.',
    },
  });
} else if (mode === 'complete') {
  const reportUrl = (await readMaybe(REPORT_URL_FILE))?.trim() || null;
  const json = await readMaybe(path.join(APP_DIR, 'playwright-report/results.json'));
  if (!json) {
    await patch({
      status: 'completed', conclusion: 'failure', completed_at: new Date().toISOString(),
      details_url: reportUrl ?? undefined,
      output: { title: 'No test results produced', summary: 'Playwright did not write results.json. Check the job logs.' },
    });
    process.exit(0);
  }

  const report = JSON.parse(json);
  const s = report.stats;
  const { failed, flaky } = collect(report);
  const passed = s.unexpected === 0;
  const secs = (s.duration / 1000).toFixed(1);

  const lines = [
    '| ✅ passed | ❌ failed | ⚠️ flaky | ⏭ skipped | ⏱ duration |',
    '|---|---|---|---|---|',
    `| ${s.expected} | ${s.unexpected} | ${s.flaky} | ${s.skipped} | ${secs}s |`,
    '',
    reportUrl
      ? `📊 **[Open the full HTML report](${reportUrl})** (screenshots, videos, traces; kept 14 days)`
      : process.env.REPORT_BUCKET
        ? '⚠️ _Report upload to Object Storage failed: check the job logs (often: API key lacks `ObjectStorageFullAccess`)._'
        : '_No report uploaded (REPORT_BUCKET not set)._',
  ];
  const fmt = (list, heading) => list.length && lines.push('', `### ${heading}`, ...list.slice(0, 20).map(
    (f) => `<details><summary><code>${f.path}:${f.line}</code> — ${f.title}</summary>\n\n\`\`\`\n${f.message.slice(0, 1500)}\n\`\`\`\n</details>`,
  ));
  fmt(failed, 'Failed tests');
  fmt(flaky, 'Flaky tests (passed on retry)');

  const annotations = [
    ...failed.map((f) => ({ ...f, annotation_level: 'failure' })),
    ...flaky.map((f) => ({ ...f, annotation_level: 'warning' })),
  ].slice(0, 50).map((f) => ({
    path: f.path,
    start_line: f.line,
    end_line: f.line,
    annotation_level: f.annotation_level,
    title: f.title.slice(0, 255),
    message: f.message.slice(0, 4000),
  }));

  await patch({
    status: 'completed',
    conclusion: passed ? 'success' : 'failure',
    completed_at: new Date().toISOString(),
    details_url: reportUrl ?? undefined,
    output: {
      title: passed ? `${s.expected} passed${s.flaky ? `, ${s.flaky} flaky` : ''} in ${secs}s` : `${s.unexpected} failed, ${s.expected} passed`,
      summary: lines.join('\n').slice(0, 65000),
      annotations,
    },
  });
} else {
  console.error('usage: github-check.mjs start|complete|crash');
  process.exit(1);
}
