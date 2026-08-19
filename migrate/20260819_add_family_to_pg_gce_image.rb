# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:pg_gce_image) do
      add_column :family, :text, collate: '"C"', null: false, default: "ubuntu-2204"
    end
  end
end
