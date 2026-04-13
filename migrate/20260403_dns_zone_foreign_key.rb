# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:dns_zone) do
      add_foreign_key [:project_id], :project, name: :dns_zone_project_id_fkey
    end
  end
end
