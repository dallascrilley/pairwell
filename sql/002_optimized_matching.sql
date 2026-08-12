-- Optimized TABC Matching for Large Datasets
-- Run this AFTER 001_enrichment_schema.sql
--
-- The original CROSS JOIN approach times out on large datasets.
-- This version uses:
-- 1. GIN index on TABC taxpayer_name for faster trigram lookups
-- 2. Batch processing to avoid timeouts
-- 3. More selective initial filtering

-- ============================================================
-- STEP 1: Add trigram index to TABC table for fast fuzzy search
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_tabc_taxpayer_name_trgm
ON tx_franchise_permits_raw USING gin (taxpayer_name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_tabc_taxpayer_city
ON tx_franchise_permits_raw (taxpayer_city);

-- ============================================================
-- STEP 2: Optimized matching function using trigram index
-- ============================================================
CREATE OR REPLACE FUNCTION match_tabc_permits(
  p_min_confidence DECIMAL DEFAULT 0.60
) RETURNS TABLE (
  company_id UUID,
  permit_number TEXT,
  confidence DECIMAL,
  details JSONB
) AS $$
BEGIN
  RETURN QUERY
  WITH candidate_matches AS (
    -- Use trigram index to find candidate matches efficiently
    SELECT
      c.id AS company_id,
      c.company_name,
      c.city AS company_city,
      c.address_line_1,
      t.tabc_permit_number,
      t.taxpayer_name,
      t.taxpayer_city,
      t.taxpayer_address,
      t.total_receipts,
      t.liquor_receipts,
      t.wine_receipts,
      t.beer_receipts,
      similarity(UPPER(COALESCE(c.company_name, '')), COALESCE(t.taxpayer_name, '')) AS name_sim
    FROM companies c
    JOIN tx_franchise_permits_raw t
      ON COALESCE(t.taxpayer_name, '') % UPPER(COALESCE(c.company_name, ''))  -- Uses GIN index
    WHERE c.is_non_subscriber_in_tx = true
      AND c.company_name IS NOT NULL
      AND c.company_name != ''
  )
  SELECT DISTINCT ON (cm.company_id)
    cm.company_id,
    cm.tabc_permit_number AS permit_number,
    (
      cm.name_sim * 0.6 +
      CASE WHEN UPPER(COALESCE(cm.company_city, '')) = COALESCE(cm.taxpayer_city, '') THEN 0.25 ELSE 0 END +
      similarity(UPPER(COALESCE(cm.address_line_1, '')), COALESCE(cm.taxpayer_address, '')) * 0.15
    )::DECIMAL(3,2) AS confidence,
    jsonb_build_object(
      'name_similarity', cm.name_sim,
      'city_match', UPPER(COALESCE(cm.company_city, '')) = COALESCE(cm.taxpayer_city, ''),
      'source_name', cm.taxpayer_name,
      'source_city', cm.taxpayer_city,
      'total_receipts', cm.total_receipts,
      'liquor_receipts', cm.liquor_receipts,
      'wine_receipts', cm.wine_receipts,
      'beer_receipts', cm.beer_receipts
    ) AS details
  FROM candidate_matches cm
  WHERE cm.name_sim > 0.3
  ORDER BY cm.company_id, confidence DESC;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- STEP 3: Batch processing function for very large datasets
-- ============================================================
CREATE OR REPLACE FUNCTION refresh_tabc_enrichments_batch(
  p_min_confidence DECIMAL DEFAULT 0.60,
  p_batch_size INTEGER DEFAULT 5000
) RETURNS TABLE (
  batches_processed INTEGER,
  total_matches INTEGER
) AS $$
DECLARE
  v_offset INTEGER := 0;
  v_batch_count INTEGER := 0;
  v_total_matches INTEGER := 0;
  v_batch_matches INTEGER;
  v_company_count INTEGER;
BEGIN
  -- Get total company count
  SELECT COUNT(*) INTO v_company_count
  FROM companies WHERE is_non_subscriber_in_tx = true;

  -- Clear existing matches
  DELETE FROM company_enrichments WHERE source_id = 'tabc_permits';

  -- Reset enrichment columns
  UPDATE companies SET
    has_revenue_data = false,
    total_annual_revenue = NULL,
    enrichment_count = 0,
    best_match_confidence = NULL
  WHERE is_non_subscriber_in_tx = true;

  -- Process in batches
  WHILE v_offset < v_company_count LOOP
    -- Insert matches for this batch
    WITH batch_companies AS (
      SELECT id, company_name, city, address_line_1
      FROM companies
      WHERE is_non_subscriber_in_tx = true
        AND company_name IS NOT NULL
        AND company_name != ''
      ORDER BY id
      LIMIT p_batch_size OFFSET v_offset
    ),
    batch_matches AS (
      SELECT DISTINCT ON (bc.id)
        bc.id AS company_id,
        t.tabc_permit_number,
        (
          similarity(UPPER(bc.company_name), COALESCE(t.taxpayer_name, '')) * 0.6 +
          CASE WHEN UPPER(COALESCE(bc.city, '')) = COALESCE(t.taxpayer_city, '') THEN 0.25 ELSE 0 END +
          similarity(UPPER(COALESCE(bc.address_line_1, '')), COALESCE(t.taxpayer_address, '')) * 0.15
        )::DECIMAL(3,2) AS confidence,
        jsonb_build_object(
          'name_similarity', similarity(UPPER(bc.company_name), COALESCE(t.taxpayer_name, '')),
          'city_match', UPPER(COALESCE(bc.city, '')) = COALESCE(t.taxpayer_city, ''),
          'source_name', t.taxpayer_name,
          'source_city', t.taxpayer_city,
          'total_receipts', t.total_receipts,
          'liquor_receipts', t.liquor_receipts,
          'wine_receipts', t.wine_receipts,
          'beer_receipts', t.beer_receipts
        ) AS details
      FROM batch_companies bc
      JOIN tx_franchise_permits_raw t
        ON COALESCE(t.taxpayer_name, '') % UPPER(bc.company_name)
      WHERE similarity(UPPER(bc.company_name), COALESCE(t.taxpayer_name, '')) > 0.3
      ORDER BY bc.id, confidence DESC
    )
    INSERT INTO company_enrichments (company_id, source_id, source_record_id, match_confidence, match_details)
    SELECT company_id, 'tabc_permits', tabc_permit_number, confidence, details
    FROM batch_matches
    WHERE confidence >= p_min_confidence;

    GET DIAGNOSTICS v_batch_matches = ROW_COUNT;
    v_total_matches := v_total_matches + v_batch_matches;
    v_batch_count := v_batch_count + 1;
    v_offset := v_offset + p_batch_size;

    -- Commit progress (implicit in function)
    RAISE NOTICE 'Batch % complete: % matches (% total)', v_batch_count, v_batch_matches, v_total_matches;
  END LOOP;

  -- Update denormalized columns
  UPDATE companies c SET
    has_revenue_data = true,
    total_annual_revenue = (ce.match_details->>'total_receipts')::DECIMAL,
    enrichment_count = 1,
    best_match_confidence = ce.match_confidence
  FROM company_enrichments ce
  WHERE ce.company_id = c.id
    AND ce.source_id = 'tabc_permits';

  RETURN QUERY SELECT v_batch_count, v_total_matches;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- STEP 4: Simple refresh function (uses optimized match function)
-- ============================================================
CREATE OR REPLACE FUNCTION refresh_tabc_enrichments(
  p_min_confidence DECIMAL DEFAULT 0.60
) RETURNS INTEGER AS $$
DECLARE
  v_count INTEGER;
BEGIN
  -- Clear existing TABC matches
  DELETE FROM company_enrichments WHERE source_id = 'tabc_permits';

  -- Insert new matches using optimized function
  INSERT INTO company_enrichments (company_id, source_id, source_record_id, match_confidence, match_details)
  SELECT company_id, 'tabc_permits', permit_number, confidence, details
  FROM match_tabc_permits(p_min_confidence)
  WHERE confidence >= p_min_confidence;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Reset all non-subscriber companies first
  UPDATE companies SET
    has_revenue_data = false,
    total_annual_revenue = NULL,
    enrichment_count = 0,
    best_match_confidence = NULL
  WHERE is_non_subscriber_in_tx = true;

  -- Update companies that have enrichments
  UPDATE companies c SET
    has_revenue_data = true,
    total_annual_revenue = (ce.match_details->>'total_receipts')::DECIMAL,
    enrichment_count = 1,
    best_match_confidence = ce.match_confidence
  FROM company_enrichments ce
  WHERE ce.company_id = c.id
    AND ce.source_id = 'tabc_permits';

  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- HOW TO USE
-- ============================================================
--
-- Option 1: Standard refresh (should work now with GIN index)
--   SELECT refresh_tabc_enrichments(0.60);
--
-- Option 2: If still timing out, use batch processing
--   SELECT * FROM refresh_tabc_enrichments_batch(0.60, 2000);
--
-- Check results:
--   SELECT COUNT(*) FROM company_enrichments WHERE source_id = 'tabc_permits';
--   SELECT COUNT(*) FROM companies WHERE has_revenue_data = true;
