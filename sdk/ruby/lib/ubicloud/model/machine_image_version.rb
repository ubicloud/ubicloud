# frozen_string_literal: true

module Ubicloud
  class MachineImageVersion < BaseModel
    set_prefix "mv"

    set_columns :id, :version, :state, :actual_size_mib, :archive_size_mib, :created_at

    # Create a new instance from a hash returned by the Ubicloud API.
    def initialize(adapter, values)
      @adapter = adapter
      @values = {}
      merge_into_values(values)
    end
  end
end
