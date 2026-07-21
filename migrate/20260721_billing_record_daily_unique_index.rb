# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :billing_record, [:resource_id, :billing_rate_id, Sequel.pg_jsonb_op(:resource_tags).get_text("day")],
      name: :billing_record_daily_unique_index,
      unique: true,
      where: Sequel.pg_jsonb_op(:resource_tags).has_key?("day"),
      concurrently: true
  end
end
