# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :target_image_family, String, collate: '"C"', null: false, default: "ubuntu-2204"
      add_constraint(:target_image_family_check, target_image_family: %w[ubuntu-2204 ubuntu-2604])
    end

    alter_table(:postgres_server) do
      add_column :image_family, String, collate: '"C"', null: false, default: "ubuntu-2204"
      add_constraint(:image_family_check, image_family: %w[ubuntu-2204 ubuntu-2604])
    end
  end
end
