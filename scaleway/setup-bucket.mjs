// Create the report bucket (private) and a lifecycle rule that deletes old reports.
// Called by setup-bucket.sh. Env: BUCKET, DAYS, REGION, ACCESS_KEY, SECRET_KEY
import {
  S3Client, HeadBucketCommand, CreateBucketCommand,
  PutBucketLifecycleConfigurationCommand, GetBucketLifecycleConfigurationCommand,
} from '@aws-sdk/client-s3';

const { BUCKET, DAYS = '14', REGION = 'fr-par', ACCESS_KEY, SECRET_KEY } = process.env;
const s3 = new S3Client({
  region: REGION,
  endpoint: `https://s3.${REGION}.scw.cloud`,
  credentials: { accessKeyId: ACCESS_KEY, secretAccessKey: SECRET_KEY },
});

try {
  await s3.send(new HeadBucketCommand({ Bucket: BUCKET }));
  console.log(`==> Bucket ${BUCKET} already exists`);
} catch (err) {
  if (err.$metadata?.httpStatusCode === 403) {
    console.error(`Bucket name "${BUCKET}" is taken by another Scaleway account (or your key lacks access). Pick another name.`);
    process.exit(1);
  }
  console.log(`==> Creating private bucket ${BUCKET} in ${REGION}`);
  await s3.send(new CreateBucketCommand({ Bucket: BUCKET }));
}

console.log(`==> Lifecycle: delete reports/ after ${DAYS} days, abort stale multipart uploads after 1 day`);
await s3.send(new PutBucketLifecycleConfigurationCommand({
  Bucket: BUCKET,
  LifecycleConfiguration: {
    Rules: [{
      ID: 'expire-playwright-reports',
      Status: 'Enabled',
      Filter: { Prefix: 'reports/' },
      Expiration: { Days: Number(DAYS) },
      AbortIncompleteMultipartUpload: { DaysAfterInitiation: 1 },
    }],
  },
}));

const { Rules } = await s3.send(new GetBucketLifecycleConfigurationCommand({ Bucket: BUCKET }));
console.log('    active rules:', Rules.map((r) => `${r.ID} (${r.Filter?.Prefix} → ${r.Expiration?.Days} days)`).join(', '));
console.log(`Done. Set REPORT_BUCKET=${BUCKET} in .env`);
