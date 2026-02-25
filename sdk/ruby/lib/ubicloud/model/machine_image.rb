# frozen_string_literal: true

module Ubicloud
  class MachineImage < Model
    set_prefix "m1"

    set_fragment "machine-image"

    set_columns :id, :name, :description, :visible, :location, :created_at, :active_version, :versions
  end
end
