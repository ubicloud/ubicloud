# frozen_string_literal: true

Sequel.migration do
  change do
    first_month = Date.new(2026, 3)

    ["", "admin_"].each do |prefix|
      table = :"#{prefix}account_authentication_audit_log"

      create_table(table, partition_by: :at, partition_type: :range) do
        column :id, :uuid, default: Sequel.function(:gen_random_ubid_uuid, 321)
        column :account_id, :uuid, null: false # Deliberately not foreign key
        DateTime :at, null: false, default: Sequel::CURRENT_TIMESTAMP
        String :message, null: false
        column :metadata, :jsonb, null: false, default: Sequel.pg_json({})

        primary_key [:id, :at] # partition key must be part of primary key
        index [:account_id, Sequel.desc(:at)], name: :"#{prefix}audit_account_at_idx"
        index Sequel.desc(:at), name: :"#{prefix}audit_at_idx"
        index :metadata, name: :"#{prefix}audit_metadata_idx", type: :gin
      end

      # Rest of 2026
      Array.new(10) { |i| first_month.next_month(i) }.each do |month|
        create_table(:"#{table}_#{month.strftime("%Y_%m")}", partition_of: table) do
          from month
          to month.next_month
        end
      end
    end
  end
end
