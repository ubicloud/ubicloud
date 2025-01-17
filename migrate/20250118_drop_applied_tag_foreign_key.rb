# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table :applied_tag do
      drop_foreign_key [:access_tag_id], name: :applied_tag_access_tag_id_fkey
    end

    alter_table(:access_tag) do
      drop_constraint :access_tag_pkey
      set_column_allow_null :hyper_tag_table
      set_column_allow_null :name
      set_column_allow_null :id
    end
  end

  down do
    alter_table(:access_tag) do
      set_column_not_null :name
      set_column_not_null :hyper_tag_table
      add_primary_key [:id]
    end

    alter_table :applied_tag do
      add_foreign_key [:access_tag_id], :access_tag, name: :applied_tag_access_tag_id_fkey
    end
  end
end
