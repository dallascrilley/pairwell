#!/usr/bin/env node

import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ENDPOINT = 'https://data.texas.gov/api/v3/views/azae-8krr/query.json';
const DEFAULT_LIMIT = 21_875;
const PAGE_SIZE = 1_000;
const COLUMNS = [
  'filing_id',
  'filing_date_received',
  'record_type',
  'company_name',
  'address_1',
  'city',
  'state',
  'zip_code',
];

function parseArgs(argv) {
  let limit = DEFAULT_LIMIT;
  let output = resolve('data', `tdi-public-filings-${DEFAULT_LIMIT}.csv`);

  for (const arg of argv) {
    if (arg.startsWith('--limit=')) {
      limit = Number.parseInt(arg.slice('--limit='.length), 10);
    } else if (arg.startsWith('--output=')) {
      output = resolve(arg.slice('--output='.length));
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!Number.isInteger(limit) || limit <= 0 || limit > 100_000) {
    throw new Error('--limit must be an integer between 1 and 100000');
  }

  return { limit, output };
}

function csvCell(value) {
  const text = value == null ? '' : String(value);
  return `"${text.replaceAll('"', '""').replaceAll('\r', ' ').replaceAll('\n', ' ')}"`;
}

export function toCsv(rows) {
  const lines = [COLUMNS.map(csvCell).join(',')];
  for (const row of rows) {
    lines.push(COLUMNS.map((column) => csvCell(row[column])).join(','));
  }
  return `${lines.join('\n')}\n`;
}

export async function fetchPublicFilings(limit, fetchImpl = fetch) {
  const query = `SELECT ${COLUMNS.join(', ')} ORDER BY filing_id, record_type, company_name`;
  const rows = [];

  for (let pageNumber = 1; rows.length < limit; pageNumber += 1) {
    const pageSize = PAGE_SIZE;
    const response = await fetchImpl(ENDPOINT, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ query, page: { pageNumber, pageSize } }),
    });

    if (!response.ok) {
      throw new Error(`Texas Open Data request failed: HTTP ${response.status}`);
    }

    const page = await response.json();
    if (!Array.isArray(page)) {
      throw new Error('Texas Open Data response was not an array');
    }

    rows.push(...page);
    if (page.length < pageSize) break;
  }

  if (rows.length < limit) {
    throw new Error(`Requested ${limit} records, but the endpoint returned ${rows.length}`);
  }

  return rows.slice(0, limit);
}

async function main() {
  const { limit, output } = parseArgs(process.argv.slice(2));
  const rows = await fetchPublicFilings(limit);
  await mkdir(dirname(output), { recursive: true });
  await writeFile(output, toCsv(rows), 'utf8');
  console.log(`Downloaded ${rows.length} public filing records from ${ENDPOINT}`);
  console.log(`Wrote ${output}`);
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
