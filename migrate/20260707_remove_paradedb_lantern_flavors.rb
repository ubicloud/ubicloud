# frozen_string_literal: true

Sequel.migration do
  # Postgres cannot drop enum values, so we create-swap-remove: create the new enum, swap the column onto it, drop the old one.
  up do
    from(:postgres_resource).exclude(flavor: "standard").update(flavor: "standard")

    rename_enum(:postgres_flavor, :postgres_flavor_old)
    create_enum(:postgres_flavor, %w[standard])

    alter_table(:postgres_resource) do
      set_column_default :flavor, nil
    end
    alter_table(:postgres_resource) do
      set_column_type :flavor, :postgres_flavor, using: Sequel.cast(Sequel.cast(:flavor, :text), :postgres_flavor)
      set_column_default :flavor, Sequel.cast("standard", :postgres_flavor)
    end

    drop_enum(:postgres_flavor_old)
  end

  down do
    rename_enum(:postgres_flavor, :postgres_flavor_old)
    create_enum(:postgres_flavor, %w[standard paradedb lantern])

    alter_table(:postgres_resource) do
      set_column_default :flavor, nil
    end
    alter_table(:postgres_resource) do
      set_column_type :flavor, :postgres_flavor, using: Sequel.cast(Sequel.cast(:flavor, :text), :postgres_flavor)
      set_column_default :flavor, Sequel.cast("standard", :postgres_flavor)
    end

    drop_enum(:postgres_flavor_old)
  end
end
