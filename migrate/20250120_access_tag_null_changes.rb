# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    drop_table :applied_tag, :access_policy

    # Remove non-account entries, otherwise the foreign key creation will fail
    from(:access_tag).exclude(hyper_tag_id: from(:accounts).select(:id)).delete

    alter_table(:access_tag) do
      drop_index [:project_id, :name], name: :access_tag_project_id_name_index, concurrently: true
      drop_column :id
      drop_column :hyper_tag_table
      drop_column :name
      set_column_not_null :hyper_tag_id
      add_foreign_key [:hyper_tag_id], :accounts, name: :access_tag_hyper_tag_id_fkey
    end

    run "ALTER TABLE access_tag ADD CONSTRAINT access_tag_pkey PRIMARY KEY USING INDEX access_tag_project_id_hyper_tag_id_index"
  end

  down do
    run "ALTER TABLE access_tag DROP CONSTRAINT access_tag_pkey"

    alter_table(:access_tag) do
      add_column :id, :uuid
      add_column :hyper_tag_table, String
      add_column :name, String
      add_index [:project_id, :hyper_tag_id], name: :access_tag_project_id_hyper_tag_id_index, unique: true, concurrently: true
      add_index [:project_id, :name], name: :access_tag_project_id_name_index, unique: true, concurrently: true
      drop_constraint :access_tag_hyper_tag_id_fkey
      set_column_allow_null :hyper_tag_id
    end

    create_table(:access_policy) do
      uuid :id, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      String :name, null: false
      jsonb :body, null: false
      timestamptz :created_at, default: Sequel::CURRENT_TIMESTAMP, null: false
      TrueClass :managed, default: false, null: false
      index [:project_id, :name], unique: true, name: :access_policy_project_id_name_index
    end

    create_table(:applied_tag) do
      uuid :access_tag_id
      uuid :tagged_id, index: true
      String :tagged_table, null: false
      primary_key [:access_tag_id, :tagged_id]
    end
  end
end
