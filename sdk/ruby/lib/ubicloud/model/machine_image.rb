# frozen_string_literal: true

module Ubicloud
  class MachineImage < Model
    set_prefix "m1"

    set_fragment "machine-image"

    set_columns :id, :name, :description, :location, :arch, :version, :state, :size_gib, :created_at, :active_version, :versions
  end
end
