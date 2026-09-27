# frozen_string_literal: true

Sequel.migration do
  change do
    # One gateway fleet per location, behind the location's TCP load balancer
    # and a wildcard certificate.
    create_table(:postgres_gateway) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 540) # UBID.to_base32_n("gw")
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :location_id, :location, type: :uuid, null: false, unique: true
      foreign_key :load_balancer_id, :load_balancer, type: :uuid
      foreign_key :private_subnet_id, :private_subnet, type: :uuid
      # Appended after the ember id, e.g. "pgc.ubicloud.app".
      column :hostname_suffix, :text, collate: '"C"', null: false
      column :replica_count, Integer, null: false, default: 2
    end

    create_table(:postgres_gateway_replica) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 531) # UBID.to_base32_n("gk")
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :postgres_gateway_id, :postgres_gateway, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false
      column :state, :text, collate: '"C"', null: false, default: "creating"
      constraint(:postgres_gateway_replica_state_check, state: %w[creating running draining])

      # IPsec keys for this end of the gateway-to-host mesh, encrypted at the
      # application layer, and when they were last rotated and last pushed.
      # The hop between a gateway and an ember is encrypted here rather than in
      # PostgreSQL's TLS, because a TLS-terminating gateway cannot satisfy
      # SCRAM channel binding.
      column :tunnel_keys, :text, collate: '"C"'
      column :tunnel_rekeyed_at, :timestamptz
      column :tunnel_pushed_at, :timestamptz

      index [:postgres_gateway_id], name: "postgres_gateway_replica_gateway_idx"
    end

    # The host end of the mesh, one row for each ember host the gateway peers
    # with. It shares the host's id, the way host_provider does.
    create_table(:postgres_gateway_host) do
      foreign_key :id, :vm_host, type: :uuid, primary_key: true, on_delete: :cascade
      foreign_key :postgres_gateway_id, :postgres_gateway, type: :uuid, null: false, on_delete: :cascade
      column :tunnel_keys, :text, collate: '"C"'
      column :tunnel_rekeyed_at, :timestamptz
      column :tunnel_pushed_at, :timestamptz

      index [:postgres_gateway_id], name: "postgres_gateway_host_gateway_idx"
    end
  end
end
