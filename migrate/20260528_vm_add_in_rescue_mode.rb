# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :in_rescue_mode, :boolean, default: false, null: false
    end
    add_enum_value(:vm_display_state, "rescue")
  end
end
