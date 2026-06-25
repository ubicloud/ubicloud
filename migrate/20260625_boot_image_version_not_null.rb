# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:boot_image) do
      set_column_not_null :version
    end
  end
end
