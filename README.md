# Playwright on Scaleway Serverless Jobs, triggered by a GitHub App

End-to-end tests for [practiceautomatedtesting.com](https://www.practiceautomatedtesting.com).
This setup uses **no GitHub Actions runner minutes**. A GitHub App webhook starts a Scaleway Serverless Job, and the results come back to GitHub as a native **check run**.

```
git push / "Re-run" button
   │  GitHub App webhook (free)
   ▼
Controller: Scaleway Serverless Function (controller/handler.js)
   │  1. verify webhook signature
   │  2. create check run "Playwright E2E (Scaleway)" → queued
   │  3. start Serverless Job with commit SHA + 1-hour installation token
   ▼
Serverless Job (2 vCPU / 4 GiB, billed per second)
   │  check → in progress
   │  download tests for that commit → npx playwright test
   │  upload HTML report → Object Storage (public link, unguessable path, 14 days)
   ▼
Check run completed ✅/❌ with:
   • passed / failed / flaky / duration table
   • failing tests with error messages
   • annotations on the failing line in the PR diff
   • "Details" → full HTML report on Scaleway (videos, traces, screenshots)

Cron every 15 min → controller sweeper: a job that died without reporting
(timeout, out of memory) gets its check run marked as failed.
```

## Cost

| Part | Cost |
|---|---|
| GitHub | €0: no Actions runners are used |
| Controller function | One short invocation per push, within Scaleway's monthly free tier |
| Serverless Job | €0.00001 per vCPU-s plus €0.000002 per GB-s, after a monthly free tier of 200k vCPU-s and 400k GB-s |
| Object Storage | One Zone, about €0.008 per GB per month; reports are deleted after 14 days |
| Registry | The image is rebuilt only when dependencies change; old tags are cleaned up automatically |

## Run locally

```bash
npm ci
npx playwright install chromium
npm test            # headless
npm run report      # open the HTML report
```

## Setup (one-time)

### 1. Scaleway: image, job and report bucket

```bash
cp .env.example .env            # fill in as you go
set -a && . ./.env && set +a
./scaleway/ensure-job.sh        # prints JOB_DEFINITION_ID → put it in .env
REPORT_BUCKET=my-pw-reports ./scaleway/setup-bucket.sh 14   # optional: reports + 14-day expiry
```

Re-run `ensure-job.sh` after changing `package.json`, `Dockerfile` or `scripts/`. Changing tests needs no rebuild.

### 2. Create the GitHub App

GitHub → Settings → Developer settings → GitHub Apps → **New GitHub App**:

| Setting | Value |
|---|---|
| Webhook URL | temporary placeholder; you set the real one in step 4 |
| Webhook secret | `openssl rand -hex 32` → also `GITHUB_WEBHOOK_SECRET` in `.env` |
| Repository permissions | **Checks: Read & write**, **Contents: Read-only**, Metadata: Read-only |
| Subscribe to events | **Push**, **Check run**, **Check suite** |
| Where can it be installed | Only on this account |

Then:
- Note the **App ID** and put it in `GITHUB_APP_ID`.
- Generate a **private key** (`.pem`) and set its path in `GITHUB_APP_PRIVATE_KEY_FILE`. `*.pem` files are git-ignored.
- **Install** the app on the `scaleway-playwright` repository.

### 3. Deploy the controller

```bash
./scaleway/deploy-controller.sh
# → Webhook URL for your GitHub App:  https://<id>.functions.fnc.fr-par.scw.cloud
```

### 4. Connect

Paste that URL into the GitHub App's **Webhook URL** field. GitHub sends a `ping`, which should get a green ✔ under App → Advanced → Recent deliveries. Push a commit: the check appears on the commit and the PR within seconds.

### 5. (Recommended) Block merges on red tests

Repo → Settings → Branches → branch protection for `main` → **Require status checks to pass** → add `Playwright E2E (Scaleway)`.

## How you know a run succeeded

- **Commit / PR:** the `Playwright E2E (Scaleway)` check shows ✅ or ❌. Click it to see the summary and failing tests, or **Details** to open the HTML report.
- **Pull request "Files changed":** failing tests are marked on the exact line.
- **Merging:** blocked while red, if you set up step 5.
- **Re-run:** the **Re-run** button on the check starts a new Scaleway run.
- **Scaleway:** the job run state is *succeeded* or *failed*, matching the Playwright exit code. Logs are in the console under Serverless Jobs → Job runs → Logs.

## Cleanup (automatic)

| What | How it's cleaned |
|---|---|
| Reports in Object Storage | Lifecycle rule deletes `reports/` after 14 days (`setup-bucket.sh`) |
| Image tags in the registry | After each new image push, `cleanup-images.sh` keeps the newest 3 plus the one in use. Manual: `./scaleway/cleanup-images.sh --dry-run` |
| Job run history | Metadata only, no cost |

## Security notes

- The controller rejects webhooks without a valid `X-Hub-Signature-256`.
- The job only receives a **1-hour installation token** limited to this repo, with `contents:read` and `checks:write`. Variables passed to a job run are visible in the Scaleway console, which is why no long-lived GitHub credentials go there.
- The report upload keys are passed to each run and are visible in the same way. Use a dedicated API key with Object Storage access only.
- Reports are public-read under an unguessable path, and the bucket cannot be listed. Don't use this setup if reports could contain secrets or customer data.
- Pushes to forks don't trigger the app, so pull requests from forks don't run on your Scaleway account.

## Files

| Path | Purpose |
|---|---|
| `tests/*.spec.ts` | Home, Web Elements and Shopping tests |
| `playwright.config.ts` | `BASE_URL`, HTML + JSON reporters, CI retries/workers |
| `controller/handler.js` | Serverless Function: webhook → check run → start job, plus the sweeper. No dependencies |
| `Dockerfile` | `mcr.microsoft.com/playwright` + `npm ci`. Keep its tag equal to `@playwright/test` |
| `scripts/run-tests.sh` | Job entrypoint: check in progress → fetch tests → run → upload → complete check |
| `scripts/github-check.mjs` | Turns `results.json` into the check run summary and annotations |
| `scripts/upload-report.mjs` | Uploads the HTML report to Object Storage and returns its link |
| `scaleway/ensure-job.sh` | Registry namespace, image (only when dependencies change), job definition |
| `scaleway/deploy-controller.sh` | Deploys the controller function and the sweeper cron, and prints the webhook URL |
| `scaleway/setup-bucket.sh` | Report bucket plus the 14-day lifecycle rule |
| `scaleway/cleanup-images.sh` | Deletes old image tags |
