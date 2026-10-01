# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:sshable) do
      add_column :host_keys, "text[]"
    end
  end
end
