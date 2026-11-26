// Create (or fetch, CreateQueue is idempotent) the queue the controller writes runs to.
// Prints the queue URL. Env: SQS_ENDPOINT, REGION, ACCESS_KEY, SECRET_KEY, QUEUE_NAME
import { sqsClient } from '../controller/sqs.js';

const { SQS_ENDPOINT, REGION = 'fr-par', ACCESS_KEY, SECRET_KEY, QUEUE_NAME = 'playwright-runs' } = process.env;
const sqs = sqsClient({ endpoint: SQS_ENDPOINT, region: REGION, accessKeyId: ACCESS_KEY, secretAccessKey: SECRET_KEY });
const url = await sqs.createQueue(QUEUE_NAME, {
  VisibilityTimeout: 900,        // a run may take up to the container timeout before redelivery
  MessageRetentionPeriod: 3600,  // runs older than 1 hour are pointless: drop them
});
if (!url) throw new Error('CreateQueue returned no QueueUrl');
console.log(url);
