-- Minimal public schema required by the extracted engine.
-- Production tables are intentionally not copied into this repository.

CREATE TABLE companies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_name TEXT,
  city TEXT,
  address_line_1 TEXT,
  is_non_subscriber_in_tx BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE tx_franchise_permits_raw (
  tabc_permit_number TEXT PRIMARY KEY,
  taxpayer_name TEXT,
  taxpayer_city TEXT,
  taxpayer_address TEXT,
  total_receipts NUMERIC(15,2),
  liquor_receipts NUMERIC(15,2),
  wine_receipts NUMERIC(15,2),
  beer_receipts NUMERIC(15,2)
);
