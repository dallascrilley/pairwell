import assert from 'node:assert/strict';
import test from 'node:test';

import { fetchPublicFilings, toCsv } from '../scripts/fetch-public-filings.mjs';

test('fetchPublicFilings paginates deterministically to the requested limit', async () => {
  const sourceRows = Array.from({ length: 1001 }, (_, index) => ({
    filing_id: String(index + 1),
    company_name: `Company ${index + 1}`,
  }));
  const requests = [];
  const fetchImpl = async (_url, options) => {
    const body = JSON.parse(options.body);
    requests.push(body);
    const { pageNumber, pageSize } = body.page;
    const offset = (pageNumber - 1) * pageSize;
    return {
      ok: true,
      json: async () => sourceRows.slice(offset, offset + pageSize),
    };
  };

  const rows = await fetchPublicFilings(1001, fetchImpl);

  assert.equal(rows.length, 1001);
  assert.equal(rows.at(-1).filing_id, '1001');
  assert.deepEqual(requests.map((request) => request.page), [
    { pageNumber: 1, pageSize: 1000 },
    { pageNumber: 2, pageSize: 1000 },
  ]);
  assert.match(requests[0].query, /ORDER BY filing_id, record_type, company_name$/);
});

test('fetchPublicFilings fails when the public endpoint returns too few rows', async () => {
  const fetchImpl = async () => ({ ok: true, json: async () => [] });

  await assert.rejects(
    () => fetchPublicFilings(10, fetchImpl),
    /Requested 10 records, but the endpoint returned 0/,
  );
});

test('fetchPublicFilings surfaces HTTP failures without response data', async () => {
  const fetchImpl = async () => ({ ok: false, status: 503 });

  await assert.rejects(
    () => fetchPublicFilings(1, fetchImpl),
    /Texas Open Data request failed: HTTP 503/,
  );
});

test('toCsv quotes commas, quotes, and line breaks', () => {
  const csv = toCsv([{ filing_id: '1', company_name: 'Acme, "North"\nDivision' }]);

  assert.match(csv, /^"filing_id",/);
  assert.match(csv, /"Acme, ""North"" Division"/);
  assert.equal(csv.endsWith('\n'), true);
});
