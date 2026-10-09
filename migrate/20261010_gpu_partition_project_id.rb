# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:gpu_partition) do
      add_foreign_key :project_id, :project, type: :uuid
    end
  end
end
