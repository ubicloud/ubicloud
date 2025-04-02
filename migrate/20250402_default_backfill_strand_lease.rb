# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:strand) do
      set_column_default :lease, Sequel.lit("now() - '1000 years'::interval")
    end

    self[:strand].where(lease: nil).update(lease: Sequel.lit("now() - '1000 years'::interval"))
  end

  down do
    alter_table(:strand) do
      set_column_default :lease, nil
    end
  end
end
