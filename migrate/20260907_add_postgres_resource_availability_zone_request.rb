# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :preferred_availability_zone_id, :text, collate: '"C"'
      add_column :required_availability_zone_id, :text, collate: '"C"'
      add_constraint(:at_most_one_availability_zone_request, Sequel.or(preferred_availability_zone_id: nil, required_availability_zone_id: nil))
    end
  end
end
