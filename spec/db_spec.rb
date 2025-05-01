# frozen_string_literal: true

RSpec.describe "Database" do
  it "has no unexpectedly collated columns" do
    collated_columns = DB[:pg_class]
      .join(:pg_namespace, oid: :relnamespace) { |j| Sequel.qualify(j, :nspname) !~ ["pg_catalog", "information_schema"] }
      .join(:pg_attribute, attrelid: Sequel[:pg_class][:oid])
      .join(:pg_collation, oid: :attcollation) { |j| Sequel.qualify(j, :collcollate) !~ "C" }
      .select_map(Sequel.join(%i[nspname relname attname].map { Sequel.function(:quote_ident, it) }, ".").as(:name))

    expect(collated_columns).to eq []
  end
end
