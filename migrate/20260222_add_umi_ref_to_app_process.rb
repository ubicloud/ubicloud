# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:app_process) do
      add_column :umi_ref, :text
    end
  end

  down do
    alter_table(:app_process) do
      drop_column :umi_ref
    end
  end
end
