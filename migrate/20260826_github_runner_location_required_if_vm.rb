# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_runner) do
      h = {location_id: nil, vm_id: nil}
      add_constraint(:location_id_and_vm_id_set_together, ~Sequel.or(h) | h)
    end
  end
end
