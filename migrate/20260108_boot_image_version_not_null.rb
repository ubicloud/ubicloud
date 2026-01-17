# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:boot_image) do
      set_column_allow_null :version, false
    end
  end
end
