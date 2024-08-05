# frozen_string_literal: true

Sequel.migration do
  change do
    add_enum_value(:lb_node_state, "detaching")
  end
end
