-- Data Enrichment System for Texas Non-Subscriber Dashboard
-- Run this in Supabase SQL Editor
--
-- This creates an extensible enrichment system that can match companies
-- with multiple data sources (TABC permits, sales tax permits, etc.)

-- ============================================================
-- STEP 1: Enable fuzzy matching extension
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- STEP 2: Create enrichment sources registry
-- ============================================================
CREATE TABLE IF NOT EXISTS enrichment_sources (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  source_table TEXT NOT NULL,
  match_config JSONB NOT NULL,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE enrichment_sources IS 'Registry of external data sources for company enrichment';

-- ============================================================
-- STEP 3: Create company-to-enrichment junction table
-- ============================================================
CREATE TABLE IF NOT EXISTS company_enrichments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  source_id TEXT NOT NULL REFERENCES enrichment_sources(id),
  source_record_id TEXT NOT NULL,
  match_confidence DECIMAL(3,2) NOT NULL CHECK (match_confidence BETWEEN 0 AND 1),
  match_details JSONB,
  is_verified BOOLEAN DEFAULT false,
  matched_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (company_id, source_id, source_record_id)
);

CREATE INDEX IF NOT EXISTS idx_enrichments_company ON company_enrichments(company_id);
CREATE INDEX IF NOT EXISTS idx_enrichments_source ON company_enrichments(source_id);
CREATE INDEX IF NOT EXISTS idx_enrichments_confidence ON company_enrichments(match_confidence DESC);

COMMENT ON TABLE company_enrichments IS 'Junction table linking companies to enrichment source records';

-- ============================================================
-- STEP 4: Add enrichment summary columns to companies table
-- ============================================================
ALTER TABLE companies ADD COLUMN IF NOT EXISTS has_revenue_data BOOLEAN DEFAULT false;
ALTER TABLE companies ADD COLUMN IF NOT EXISTS total_annual_revenue DECIMAL(15,2);
ALTER TABLE companies ADD COLUMN IF NOT EXISTS enrichment_count INTEGER DEFAULT 0;
ALTER TABLE companies ADD COLUMN IF NOT EXISTS best_match_confidence DECIMAL(3,2);

CREATE INDEX IF NOT EXISTS idx_companies_has_revenue ON companies(has_revenue_data) WHERE has_revenue_data = true;
CREATE INDEX IF NOT EXISTS idx_companies_name_trgm ON companies USING gin (company_name gin_trgm_ops);

-- ============================================================
-- STEP 5: Create TABC permit matching function
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
  SELECT DISTINCT ON (c.id)
    c.id AS company_id,
    t.tabc_permit_number AS permit_number,
    (
      similarity(UPPER(COALESCE(c.company_name, '')), COALESCE(t.taxpayer_name, '')) * 0.6 +
      CASE WHEN UPPER(COALESCE(c.city, '')) = COALESCE(t.taxpayer_city, '') THEN 0.25 ELSE 0 END +
      similarity(UPPER(COALESCE(c.address_line_1, '')), COALESCE(t.taxpayer_address, '')) * 0.15
    )::DECIMAL(3,2) AS confidence,
    jsonb_build_object(
      'name_similarity', similarity(UPPER(COALESCE(c.company_name, '')), COALESCE(t.taxpayer_name, '')),
      'city_match', UPPER(COALESCE(c.city, '')) = COALESCE(t.taxpayer_city, ''),
      'source_name', t.taxpayer_name,
      'source_city', t.taxpayer_city,
      'total_receipts', t.total_receipts,
      'liquor_receipts', t.liquor_receipts,
      'wine_receipts', t.wine_receipts,
      'beer_receipts', t.beer_receipts
    ) AS details
  FROM companies c
  CROSS JOIN tx_franchise_permits_raw t
  WHERE c.is_non_subscriber_in_tx = true
    AND similarity(UPPER(COALESCE(c.company_name, '')), COALESCE(t.taxpayer_name, '')) > 0.3
  ORDER BY c.id, confidence DESC;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION match_tabc_permits IS 'Finds best TABC permit match for each non-subscriber company using fuzzy name matching';

-- ============================================================
-- STEP 6: Create enrichment refresh function
-- ============================================================
CREATE OR REPLACE FUNCTION refresh_tabc_enrichments(
  p_min_confidence DECIMAL DEFAULT 0.60
) RETURNS INTEGER AS $$
DECLARE
  v_count INTEGER;
BEGIN
  -- Clear existing TABC matches (will re-compute)
  DELETE FROM company_enrichments WHERE source_id = 'tabc_permits';

  -- Insert new matches above confidence threshold
  INSERT INTO company_enrichments (company_id, source_id, source_record_id, match_confidence, match_details)
  SELECT company_id, 'tabc_permits', permit_number, confidence, details
  FROM match_tabc_permits(p_min_confidence)
  WHERE confidence >= p_min_confidence;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Update denormalized summary columns on companies table
  UPDATE companies c SET
    has_revenue_data = EXISTS (
      SELECT 1 FROM company_enrichments ce WHERE ce.company_id = c.id
    ),
    total_annual_revenue = (
      SELECT (ce.match_details->>'total_receipts')::DECIMAL
      FROM company_enrichments ce WHERE ce.company_id = c.id
      ORDER BY ce.match_confidence DESC LIMIT 1
    ),
    enrichment_count = (SELECT COUNT(*) FROM company_enrichments WHERE company_id = c.id),
    best_match_confidence = (SELECT MAX(match_confidence) FROM company_enrichments WHERE company_id = c.id)
  WHERE c.is_non_subscriber_in_tx = true;

  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION refresh_tabc_enrichments IS 'Recomputes all TABC permit matches and updates company enrichment summaries';

-- ============================================================
-- STEP 7: Seed TABC enrichment source
-- ============================================================
INSERT INTO enrichment_sources (id, display_name, source_table, match_config)
VALUES (
  'tabc_permits',
  'TABC Liquor Permits',
  'tx_franchise_permits_raw',
  '[
    {"sourceField": "taxpayer_name", "targetField": "company_name", "matchType": "fuzzy", "weight": 0.6},
    {"sourceField": "taxpayer_city", "targetField": "city", "matchType": "exact", "weight": 0.25},
    {"sourceField": "taxpayer_address", "targetField": "address_line_1", "matchType": "fuzzy", "weight": 0.15}
  ]'::jsonb
)
ON CONFLICT (id) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  match_config = EXCLUDED.match_config;

-- ============================================================
-- STEP 8: Run initial enrichment (may take a few minutes)
-- ============================================================
-- Uncomment to run immediately:
-- SELECT refresh_tabc_enrichments(0.60);

-- ============================================================
-- VERIFICATION QUERIES (run after refresh)
-- ============================================================

-- Check match statistics:
-- SELECT
--   COUNT(*) FILTER (WHERE match_confidence >= 0.85) as high_confidence,
--   COUNT(*) FILTER (WHERE match_confidence >= 0.60 AND match_confidence < 0.85) as medium_confidence,
--   COUNT(*) as total_matches
-- FROM company_enrichments WHERE source_id = 'tabc_permits';

-- Check companies with revenue data:
-- SELECT COUNT(*) as enriched_companies FROM companies WHERE has_revenue_data = true;

-- Sample enriched companies:
-- SELECT company_name, city, total_annual_revenue, best_match_confidence
-- FROM companies
-- WHERE has_revenue_data = true
-- ORDER BY total_annual_revenue DESC NULLS LAST
-- LIMIT 10;
