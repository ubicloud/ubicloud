# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:resource_discount) do
      add_column :name, String, null: false, default: ""
    end

    create_table(:resource_credit) do
      # UBID.to_base32_n("r9") => 777
      uuid :id, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 777)
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :project_id, :project, type: :uuid, null: false
      String :name, null: false
      uuid :resource_id
      String :resource_type
      String :resource_family
      String :location
      bool :byoc
      Numeric :amount, null: false
      Time :active_from, null: false
      Time :active_to

      constraint(:resource_credit_amount_range) { amount >= 0 }
      constraint(:resource_credit_resource_id_requires_type) { (resource_id =~ nil) | (resource_type !~ nil) }
      constraint(:resource_credit_active_range) { (active_from < :active_to) | {active_to: nil} }
      month_match = ->(column) { Sequel.expr { date_trunc("month", column, "UTC") =~ column } }
      constraint(:resource_credit_month_aligned) { month_match[:active_from] & ((active_to =~ nil) | month_match[:active_to]) }

      index :project_id
    end
  end
end
