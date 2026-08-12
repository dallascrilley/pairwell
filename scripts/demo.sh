#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${POSTGRES_IMAGE:-postgres:17-alpine}"
container="pairwell-demo-$$"
tmp_dir="$(mktemp -d)"
csv_file="$tmp_dir/tdi-public-filings-21875.csv"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

node "$repo_root/scripts/fetch-public-filings.mjs" \
  --limit=21875 \
  --output="$csv_file"

docker run --detach --rm \
  --name "$container" \
  --env POSTGRES_PASSWORD=pairwell-demo \
  "$image" >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$container" pg_isready --host 127.0.0.1 --username postgres --dbname postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! docker exec "$container" pg_isready --host 127.0.0.1 --username postgres --dbname postgres >/dev/null; then
  printf 'PostgreSQL did not become ready within 60 seconds.\n' >&2
  exit 1
fi

for sql_file in \
  tests/000_bootstrap.sql \
  sql/001_enrichment_schema.sql \
  sql/002_optimized_matching.sql
do
  docker exec --interactive "$container" \
    psql --username postgres --dbname postgres --set ON_ERROR_STOP=1 \
    < "$repo_root/$sql_file" >/dev/null
done

docker exec "$container" psql --username postgres --dbname postgres --set ON_ERROR_STOP=1 \
  --command "CREATE TABLE public_filing_records (filing_id TEXT, filing_date_received TEXT, record_type TEXT, company_name TEXT, address_1 TEXT, city TEXT, state TEXT, zip_code TEXT);" \
  >/dev/null

docker exec --interactive "$container" psql --username postgres --dbname postgres --set ON_ERROR_STOP=1 \
  --command "COPY public_filing_records FROM STDIN WITH (FORMAT CSV, HEADER true);" \
  < "$csv_file" >/dev/null

docker exec "$container" psql --username postgres --dbname postgres \
  --command "SELECT COUNT(*) AS public_filing_records FROM public_filing_records;"
docker exec --interactive "$container" psql --username postgres --dbname postgres --set ON_ERROR_STOP=1 \
  < "$repo_root/demo/load_public_sample.sql"
