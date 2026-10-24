# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:detachable_volume) do
      drop_column :wrapped_xts
    end
  end

  # The dropped keys can't be restored, so the column comes back nullable.
  down do
    alter_table(:detachable_volume) do
      add_column :wrapped_xts, :text, collate: '"C"'
    end
  end
end
