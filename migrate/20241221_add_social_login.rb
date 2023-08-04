# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :account_identities do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :account_id, :accounts, null: false, type: :uuid
      String :provider, null: false
      String :uid, null: false
      unique [:provider, :uid]
    end
  end
end
