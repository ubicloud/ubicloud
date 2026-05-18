# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:cert) do
      add_column :private_hostname, :text, collate: '"C"'
    end
  end
end
