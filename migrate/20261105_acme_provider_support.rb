# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:acme_provider) do
      uuid :id, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 474) # "et" ubid type
      text :name, null: false, unique: true
      text :directory_url, null: false, unique: true
      text :email, null: false
      text :kid, null: false
      text :key, null: false
      bool :per_cert_accounts, null: false, default: false
      Integer :priority, null: false # < 1 is disabled
    end

    alter_table(:cert) do
      add_foreign_key :acme_provider_id, :acme_provider, type: :uuid
      add_column :reissue_requested_at, :timestamptz
    end
  end
end
