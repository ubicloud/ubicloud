# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:billing_record) do
      add_column :free_quota_amount, :numeric, null: false, default: 0
    end
  end
end
