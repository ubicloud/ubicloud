# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:ssh_public_key) do
      # UBID.to_base32_n("sk") => 819
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(819)")
      foreign_key :project_id, :project, type: :uuid, null: false
      String :name, null: false
      String :public_key, null: false
      unique [:project_id, :name]
    end
  end
end
