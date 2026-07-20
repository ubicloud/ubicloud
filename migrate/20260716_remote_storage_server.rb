# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:remote_storage_server) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      # The pre-shared key (and its TLS-PSK identity) securing the remote stripe
      # protocol connection. :psk is encrypted at the application layer.
      column :psk, :text, collate: '"C"', null: false
      column :psk_identity, :text, collate: '"C"', null: false
      column :port, Integer, null: false
      # The volume this server serves over the remote stripe protocol.
      foreign_key :source_vm_storage_volume_id, :vm_storage_volume, type: :uuid, null: false
    end
  end
end
