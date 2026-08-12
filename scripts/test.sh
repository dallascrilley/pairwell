#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --test "$repo_root/tests/fetch-public-filings.test.mjs"
image="${POSTGRES_IMAGE:-postgres:17-alpine}"
container="pairwell-test-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker run --detach --rm \
  --name "$container" \
  --env POSTGRES_PASSWORD=pairwell-test \
  "$image" >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$container" pg_isready --username postgres --dbname postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker exec "$container" pg_isready --username postgres --dbname postgres >/dev/null

for sql_file in \
  tests/000_bootstrap.sql \
  sql/001_enrichment_schema.sql \
  sql/002_optimized_matching.sql \
  tests/010_fixtures.sql \
  tests/020_assertions.sql
do
  docker exec --interactive "$container" \
    psql --username postgres --dbname postgres --set ON_ERROR_STOP=1 \
    < "$repo_root/$sql_file"
done

printf 'Pairwell SQL integration tests passed.\n'
