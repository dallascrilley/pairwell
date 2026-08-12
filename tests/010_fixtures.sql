INSERT INTO companies (id, company_name, city, address_line_1, is_non_subscriber_in_tx)
VALUES
  ('11111111-1111-4111-8111-111111111111', 'Acme Industrial Services', 'Austin', '100 Main Street', true),
  ('22222222-2222-4222-8222-222222222222', 'Blue Mesa Foods LLC', 'Dallas', '200 Elm Street', true),
  ('33333333-3333-4333-8333-333333333333', 'Lone Cedar Holdings', 'Waco', '300 Oak Avenue', true),
  ('44444444-4444-4444-8444-444444444444', 'Inactive Example', 'Austin', '400 Pine Street', false);

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
VALUES
  ('P-ACME-BEST', 'ACME INDUSTRIAL SERVICE LLC', 'AUSTIN', '100 MAIN STREET', 1250000, 500000, 250000, 500000),
  ('P-ACME-MID', 'ACME INDUSTRIAL SERVICES', 'HOUSTON', '999 MARKET ROAD', 650000, 150000, 150000, 350000),
  ('P-ACME-LOW', 'ACME FOODS', 'HOUSTON', '999 MARKET ROAD', 400000, 100000, 100000, 200000),
  ('P-BLUE', 'BLUE MESA FOODS LLC', 'DALLAS', '200 ELM STREET', 875000, 250000, 250000, 375000),
  ('P-INACTIVE', 'INACTIVE EXAMPLE', 'AUSTIN', '400 PINE STREET', 500000, 125000, 125000, 250000),
  ('P-UNRELATED', 'SOUTH PLAINS RETAIL', 'LUBBOCK', '12 BROADWAY', 300000, 100000, 100000, 100000);
