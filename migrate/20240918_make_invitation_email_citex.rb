# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:project_invitation) do
      set_column_type :email, :citext
    end
  end

  down do
    alter_table(:project_invitation) do
      set_column_type :email, :text
    end
  end
end
