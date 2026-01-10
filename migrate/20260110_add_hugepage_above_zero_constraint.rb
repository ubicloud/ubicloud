# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      # Catch over-deallocation bugs.
      add_constraint(:used_hugepages_non_negative) { used_hugepages_1g >= 0 }
    end
  end
end
