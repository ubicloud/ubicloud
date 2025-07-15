# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:locked_domain) do
      set_column_type :domain, :citext
    end
  end

  down do
    alter_table(:locked_domain) do
      set_column_type :domain, String
    end
  end
end
