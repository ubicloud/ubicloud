# frozen_string_literal: true

Sequel.migration do
  up do
    drop_table(:archived_record)
  end

  down do
    create_table(:archived_record, partition_by: :archived_at, partition_type: :range) do
      column :archived_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :model_name, :text, null: false
      column :model_values, :jsonb, null: false, default: "{}"
      index [:model_name, :archived_at]
    end

    Array.new(5) { |i| Date.new(2026, 8, 1).next_month(i) }.each do |month|
      create_table("archived_record_#{month.strftime("%Y_%m")}", partition_of: :archived_record) do
        from month
        to month.next_month
      end
    end
  end
end
