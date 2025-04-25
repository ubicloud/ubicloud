# frozen_string_literal: true

RSpec.describe DB do
  it "has no unexpectedly collated columns" do
    expect(described_class[<<SQL].all.map { it[:name] }.join(", ")).to eq ""
SELECT quote_ident(nspname) || '.' || quote_ident(relname) || '.' || quote_ident(attname) AS name
FROM pg_class
JOIN pg_namespace ON pg_class.relnamespace = pg_namespace.oid AND
                     pg_namespace.nspname NOT IN ('pg_catalog', 'information_schema')
JOIN pg_attribute ON pg_class.oid = pg_attribute.attrelid
JOIN pg_collation ON pg_attribute.attcollation = pg_collation.oid AND
                     pg_collation.collcollate <> 'C'
SQL
  end
end
