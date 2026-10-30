# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_connect_request) do
      uuid :id, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 474) # UBID.to_base32_n("et") => 474
      foreign_key :project_id, :project, type: :uuid, null: false
      String :state, null: false, unique: true
      Bignum :installation_id
      String :code
      timestamptz :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
