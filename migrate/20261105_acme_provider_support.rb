# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:acme_provider) do
      uuid :id, primary_key: true
      text :name, null: false, unique: true
      text :directory_url, null: false, unique: true
      text :email
      text :eab_kid
      text :eab_hmac_key
      column :per_cert_accounts, :bool, null: false, default: false
      Integer :priority, null: false
      column :enabled, :bool, null: false, default: true
      timestamptz :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    create_table(:acme_account) do
      uuid :id, primary_key: true
      foreign_key :acme_provider_id, :acme_provider, type: :uuid, null: false, unique: true
      text :account_key, null: false
      text :kid, null: false
      timestamptz :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    alter_table(:cert) do
      add_foreign_key :acme_provider_id, :acme_provider, type: :uuid
      add_column :reissue_requested_at, :timestamptz
    end
  end
end
