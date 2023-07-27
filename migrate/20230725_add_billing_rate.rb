# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:billing_rate) do
      column :id, :uuid, primary_key: true, default: nil
      column :resource_type, :text, collate: '"C"', null: false
      column :resource_family, :text, collate: '"C"', null: false
      column :location, :text, collate: '"C"', null: false
      column :unit_price, :numeric, null: false
      index [:resource_type, :resource_family, :location], unique: true
    end

    # These are valid UBIDs for TYPE_BILLING_RATE
    run "INSERT INTO billing_rate VALUES('0b87e0b8-85de-8978-9a60-ba72cb21eedc', 'VmCores', 'c5a', 'hetzner-fsn1', 0.000171296)"
    run "INSERT INTO billing_rate VALUES('d44d4d44-3c8c-8578-9bf6-4d668a1cba8f', 'VmCores', 'c5a', 'hetzner-hel1', 0.000154167)"
    run "INSERT INTO billing_rate VALUES('139d9a67-8182-8578-a303-235cabd5161c', 'VmCores', 'm5a', 'hetzner-fsn1', 0.000171296)"
    run "INSERT INTO billing_rate VALUES('08c502f7-df5d-8978-9896-feafa0ec5c40', 'VmCores', 'm5a', 'hetzner-hel1', 0.000154167)"
  end

  down do
    drop_table :billing_rate
  end
end
