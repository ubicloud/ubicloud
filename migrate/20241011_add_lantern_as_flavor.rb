# frozen_string_literal: true

Sequel.migration do
  change do
    add_enum_value(:postgres_flavor, "lantern")
  end
end
