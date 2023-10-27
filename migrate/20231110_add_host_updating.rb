# frozen_string_literal: true

Sequel.migration do
  change do
    add_enum_value(:allocation_state, "updating")
  end
end
