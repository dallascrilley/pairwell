-- Load a bounded target set from the downloaded public filing records.
-- Revenue-source rows are synthetic and derived deterministically from that
-- public target set; no production permit or client data is used.

INSERT INTO companies (company_name, city, address_line_1, is_non_subscriber_in_tx)
SELECT company_name, city, address_1, true
FROM (
  SELECT DISTINCT ON (filing_id)
    filing_id,
    company_name,
    city,
    address_1,
    record_type
  FROM public_filing_records
  WHERE COALESCE(company_name, '') <> ''
  ORDER BY filing_id, (record_type = 'Parent') DESC, record_type
) filings
ORDER BY filing_id
LIMIT 200;

INSERT INTO tx_franchise_permits_raw (
  tabc_permit_number,
  taxpayer_name,
  taxpayer_city,
  taxpayer_address,
  total_receipts,
  liquor_receipts,
  wine_receipts,
  beer_receipts
)
SELECT
  'SYNTH-' || LPAD(row_number() OVER (ORDER BY company_name)::TEXT, 4, '0'),
  regexp_replace(UPPER(company_name), '[^A-Z0-9 ]', '', 'g') || ' HOLDINGS',
  UPPER(city),
  UPPER(address_line_1),
  100000 + row_number() OVER (ORDER BY company_name) * 5000,
  25000 + row_number() OVER (ORDER BY company_name) * 1000,
  25000 + row_number() OVER (ORDER BY company_name) * 1000,
  50000 + row_number() OVER (ORDER BY company_name) * 3000
FROM companies
WHERE COALESCE(company_name, '') <> ''
ORDER BY company_name
LIMIT 20;

SELECT refresh_tabc_enrichments(0.75) AS accepted_matches;

SELECT
  c.company_name,
  c.city,
  ce.source_record_id AS synthetic_permit,
  ce.match_confidence,
  ce.match_details->>'total_receipts' AS synthetic_receipts
FROM company_enrichments ce
JOIN companies c ON c.id = ce.company_id
WHERE ce.source_id = 'tabc_permits'
ORDER BY ce.match_confidence DESC, c.company_name
LIMIT 10;
