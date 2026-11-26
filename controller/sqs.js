// Minimal SQS client for Scaleway Queues (AWS SQS query protocol + SigV4), no dependencies.
import crypto from 'node:crypto';

const hmac = (key, data) => crypto.createHmac('sha256', key).update(data).digest();
const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');

export function sqsClient({ endpoint, region, accessKeyId, secretAccessKey }) {
  const host = new URL(endpoint).host;

  async function call(action, params, path = '/') {
    const body = new URLSearchParams({ Action: action, Version: '2012-11-05', ...params }).toString();
    const now = new Date();
    const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
    const day = amzDate.slice(0, 8);
    const scope = `${day}/${region}/sqs/aws4_request`;
    const bodyHash = sha256(body);
    const headers = {
      'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
      host,
      'x-amz-content-sha256': bodyHash,
      'x-amz-date': amzDate,
    };
    const signedHeaders = Object.keys(headers).sort().join(';');
    const canonical = [
      'POST', path, '',
      ...Object.keys(headers).sort().map((k) => `${k}:${headers[k]}`), '',
      signedHeaders, bodyHash,
    ].join('\n');
    const toSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256(canonical)].join('\n');
    const key = hmac(hmac(hmac(hmac(`AWS4${secretAccessKey}`, day), region), 'sqs'), 'aws4_request');
    const signature = crypto.createHmac('sha256', key).update(toSign).digest('hex');

    const res = await fetch(`${endpoint}${path}`, {
      method: 'POST',
      headers: {
        ...headers,
        Authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
      },
      body,
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`SQS ${action} -> ${res.status} ${text.slice(0, 500)}`);
    return text;
  }

  const tag = (xml, name) => xml.match(new RegExp(`<${name}>([^<]*)</${name}>`))?.[1];
  const pathOf = (queueUrl) => new URL(queueUrl).pathname;

  return {
    async createQueue(name, attributes = {}) {
      const params = { QueueName: name };
      Object.entries(attributes).forEach(([k, v], i) => {
        params[`Attribute.${i + 1}.Name`] = k;
        params[`Attribute.${i + 1}.Value`] = String(v);
      });
      return tag(await call('CreateQueue', params), 'QueueUrl');
    },
    async sendMessage(queueUrl, messageBody) {
      return tag(await call('SendMessage', { QueueUrl: queueUrl, MessageBody: messageBody }, pathOf(queueUrl)), 'MessageId');
    },
  };
}
