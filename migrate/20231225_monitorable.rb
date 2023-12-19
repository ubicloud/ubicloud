# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:monitorable) do
      column :id, :uuid, primary_key: true, default: nil
      column :status, :jsonb, null:false, default: "{}"
      column :lease, :timestamptz
      column :lessee, :text, collate: '"C"'
    end
  end
end
