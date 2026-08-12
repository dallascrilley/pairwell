\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION test_assert(ok BOOLEAN, message TEXT)
RETURNS VOID AS $$
BEGIN
  IF NOT COALESCE(ok, false) THEN
    RAISE EXCEPTION 'assertion failed: %', message;
  END IF;
END;
$$ LANGUAGE plpgsql;

SELECT test_assert(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE indexname = 'idx_tabc_taxpayer_name_trgm'
  ),
  'optimized taxpayer-name trigram index exists'
);

SELECT test_assert(
  refresh_tabc_enrichments(0.60) = 2,
  'standard refresh returns two accepted matches'
);

SELECT test_assert(
  (SELECT COUNT(*) FROM company_enrichments WHERE source_id = 'tabc_permits') = 2,
  'standard refresh persists exactly two matches'
);

SELECT test_assert(
  (SELECT source_record_id FROM company_enrichments
   WHERE company_id = '11111111-1111-4111-8111-111111111111') = 'P-ACME-BEST',
  'weighted score selects the best Acme candidate'
);

SELECT test_assert(
  (SELECT source_record_id FROM company_enrichments
   WHERE company_id = '22222222-2222-4222-8222-222222222222') = 'P-BLUE',
  'exact name, city, and address select Blue Mesa'
);

SELECT test_assert(
  (SELECT total_annual_revenue FROM companies
   WHERE id = '11111111-1111-4111-8111-111111111111') = 1250000,
  'refresh copies receipts from the selected source record'
);

SELECT test_assert(
  NOT (SELECT has_revenue_data FROM companies
       WHERE id = '33333333-3333-4333-8333-333333333333'),
  'unmatched companies remain unenriched'
);

SELECT test_assert(
  NOT (SELECT has_revenue_data FROM companies
       WHERE id = '44444444-4444-4444-8444-444444444444'),
  'out-of-scope companies are not matched'
);

SELECT test_assert(
  refresh_tabc_enrichments(0.60) = 2
  AND (SELECT COUNT(*) FROM company_enrichments WHERE source_id = 'tabc_permits') = 2,
  'refresh is idempotent'
);

SELECT test_assert(
  refresh_tabc_enrichments(1.00) = 1,
  'confidence threshold excludes the non-exact match'
);

DO $$
DECLARE
  result RECORD;
BEGIN
  SELECT * INTO result FROM refresh_tabc_enrichments_batch(0.60, 2);
  PERFORM test_assert(result.batches_processed = 2, 'batch refresh processes two batches');
  PERFORM test_assert(result.total_matches = 2, 'batch refresh returns two matches');
  PERFORM test_assert(
    (SELECT source_record_id FROM company_enrichments
     WHERE company_id = '11111111-1111-4111-8111-111111111111') = 'P-ACME-BEST'
    AND (SELECT source_record_id FROM company_enrichments
         WHERE company_id = '22222222-2222-4222-8222-222222222222') = 'P-BLUE'
    AND (SELECT total_annual_revenue FROM companies
         WHERE id = '11111111-1111-4111-8111-111111111111') = 1250000,
    'batch refresh persists the same two matches'
  );
END;
$$;

DROP FUNCTION test_assert(BOOLEAN, TEXT);
