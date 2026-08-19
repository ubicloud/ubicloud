# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:pg_gce_image) do
      add_column :family, :text, collate: '"C"', null: false, default: "ubuntu-2204"
      add_constraint(:pg_gce_image_family_check, family: %w[ubuntu-2204 ubuntu-2604])
    end
  end
end
