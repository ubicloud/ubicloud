# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vm_init_script) do
      # UBID.to_base32_n("1n") => 53
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(53)")
      foreign_key :project_id, :project, type: :uuid, null: false
      String :name, null: false
      String :script, null: false
      unique [:project_id, :name]
    end

    alter_table(:vm) do
      add_foreign_key :init_script_id, :vm_init_script, type: :uuid
      add_column :init_script_args, String
    end
  end
end
