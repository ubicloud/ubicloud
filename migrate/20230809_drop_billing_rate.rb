# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:billing_record) do
      drop_foreign_key :billing_rate_id
      add_column :billing_rate_id, :uuid, null: false
    end

    drop_table :billing_rate
  end

  down do
    create_table(:billing_rate) do
      column :id, :uuid, primary_key: true, default: nil
      column :resource_type, :text, collate: '"C"', null: false
      column :resource_family, :text, collate: '"C"', null: false
      column :location, :text, collate: '"C"', null: false
      column :unit_price, :numeric, null: false
      index [:resource_type, :resource_family, :location], unique: true
    end

    run "TRUNCATE billing_rate CASCADE"
    copy_into :billing_rate, data: <<COPY
139d9a67-8182-8578-a303-235cabd5161c	VmCores	standard	hetzner-fsn1	0.000171296
08c502f7-df5d-8978-9896-feafa0ec5c40	VmCores	standard	hetzner-hel1	0.000154167
COPY

    alter_table(:billing_record) do
      add_foreign_key :billing_rate_id, :billing_rate, type: :uuid
    end
  end
end
