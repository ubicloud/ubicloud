# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      # Remote-stripe source configuration for volumes that fetch their
      # content from a remote-stripe-server (see ubiblk docs/remote-stripe.md).
      # Both columns are set together at volume creation and cleared once the
      # volume has caught up.
      add_column :remote_stripe_endpoint, String
      add_foreign_key :remote_stripe_kek_id, :storage_key_encryption_key, type: :uuid
    end
  end
end
