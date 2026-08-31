# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_runner) do
      add_column :encoded_jit_config, :text
    end
  end
end
