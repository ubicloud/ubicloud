# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_repository_bucket) do
      uuid :id, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 474) # UBID.to_base32_n("et") => 474
      String :access_key, null: false
      String :secret_key, null: false
    end

    alter_table(:github_repository) do
      add_column :bucket_name, String
    end
  end
end
