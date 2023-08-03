# frozen_string_literal: true

Sequel.migration do
  change do
    add_enum_value(:vm_display_state, "rebooting")
    add_enum_value(:vm_display_state, "starting")

    alter_table(:vm_host) do
      add_column :last_boot_id, :text, null: true
    end
  end
end
