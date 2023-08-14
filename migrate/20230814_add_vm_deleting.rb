# frozen_string_literal: true

Sequel.migration do
  change do
    add_enum_value(:vm_display_state, "deleting")
  end
end
