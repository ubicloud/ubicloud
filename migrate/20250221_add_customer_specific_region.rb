# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:customer_aws_region) do
      column :id, :uuid, primary_key: true
      column :access_key, String, null: false
      column :secret_key, String, null: false
      foreign_key :project_id, :project, type: :uuid, null: false
    end

    alter_table(:location) do
      add_foreign_key :customer_aws_region_id, :customer_aws_region, type: :uuid, null: true
    end

    run "INSERT INTO provider (name) VALUES ('aws');"
  end

  down do
    alter_table(:location) do
      drop_foreign_key :customer_aws_region_id
    end
    drop_table(:customer_aws_region)
    run "DELETE FROM provider WHERE name = 'aws';"
  end
end
