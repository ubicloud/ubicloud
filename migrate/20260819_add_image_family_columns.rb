# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_resource) do
      add_column :target_image_family, String, collate: '"C"', null: false, default: "ubuntu-2204"
      add_constraint(:target_image_family_check, Sequel.lit("target_image_family IN ('ubuntu-2204', 'ubuntu-2604')"))
    end

    alter_table(:postgres_server) do
      add_column :image_family, String, collate: '"C"', null: false, default: "ubuntu-2204"
      add_constraint(:image_family_check, Sequel.lit("image_family IN ('ubuntu-2204', 'ubuntu-2604')"))
    end
  end

  down do
    alter_table(:postgres_resource) do
      drop_column :target_image_family
    end

    alter_table(:postgres_server) do
      drop_column :image_family
    end
  end
end
